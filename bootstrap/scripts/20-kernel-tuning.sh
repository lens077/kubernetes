#!/usr/bin/env bash
# =============================================================================
# 20-kernel-tuning —— 内核与系统调优(面向 Cilium eBPF + 数据库/中间件负载)
#   - 全部即时生效(sysctl/THP/模块运行时写入), GRUB 仅做持久化 → 无需中途重启
#   - sysctl 收敛为单一托管文件, 修复原脚本重复追加 keepalive 的问题
#   - 原脚本中"注释形式"的 Cilium 内核选项要求, 改写为真实校验逻辑
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

SYSCTL_FILE="/etc/sysctl.d/99-k8s-optimized.conf"

# --- 1. 关闭 Swap(K8s 要求) -----------------------------------------------------
disable_swap() {
  swapoff -a
  backup_once /etc/fstab
  # 只注释未被注释过的 swap 行, 幂等
  sed -ri 's/^([^#].*[[:space:]]swap[[:space:]].*)$/# \1/' /etc/fstab
}
verify_swap() { [[ -z $(swapon --noheadings 2>/dev/null) ]]; }

# --- 2. 内核模块 ----------------------------------------------------------------
load_modules() {
  local modules=(overlay br_netfilter nf_conntrack xt_socket vxlan tcp_bbr)
  [[ $CILIUM_ENABLE_IPSEC == true ]] && modules+=(esp4 ipcomp xfrm4_tunnel tunnel4)
  local m
  for m in "${modules[@]}"; do modprobe "$m"; done
  printf '%s\n' "${modules[@]}" > /etc/modules-load.d/k8s.conf
  systemctl restart systemd-modules-load.service
}
verify_modules() {
  lsmod | grep -qw br_netfilter && [[ -d /sys/module/overlay || -n $(lsmod | grep -w overlay) ]]
}

# --- 3. sysctl(单一托管文件, 每次整体覆盖 → 结果恒定) ------------------------------
write_sysctl() {
  # 原脚本遗留的大厂参数文件与错误键(fs.epoll.max_user_instances 不存在)一并清理
  rm -f /etc/sysctl.d/99-kubernetes-cri.conf

  local ipv6_block=""
  if [[ $DISABLE_IPV6 == true ]]; then
    ipv6_block="
# ========== 禁用 IPv6(config.env: DISABLE_IPV6) ==========
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1"
  fi

  # kernel.nmi_watchdog 是 x86 专属(NMI 硬件看门狗), ARM64 上写入返回 ENOTSUPP(524)
  # 探测可写才纳入托管文件(x86 上探测动作本身就完成了设置; GRUB 参数两个平台都无害)
  local nmi_block=""
  if sysctl -w kernel.nmi_watchdog=0 >/dev/null 2>&1; then
    nmi_block="kernel.nmi_watchdog = 0"
  else
    log_info "kernel.nmi_watchdog 在本平台不可写(ARM64 无 NMI watchdog), 已从 sysctl 托管文件剔除"
  fi

  cat > "$SYSCTL_FILE" <<EOF
# k8s-installer 托管文件, 手工修改会在下次执行时被覆盖
# ========== 基础网络转发 ==========
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
$ipv6_block

# ========== TCP 缓冲(7G 内存级别的安全上限) ==========
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 1048576 4194304
net.ipv4.tcp_wmem = 4096 1048576 4194304

net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535
# NodePort 区间从临时端口中保留, 避免和业务出连接端口冲突
net.ipv4.ip_local_reserved_ports = 30000-32767

# ========== eBPF(Cilium 数据面) ==========
net.core.bpf_jit_enable = 1
net.core.bpf_jit_kallsyms = 1
net.core.bpf_jit_harden = 0

# ========== 拥塞控制: fq + BBR ==========
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0

# ========== 连接跟踪(约 50 万条; Cilium eBPF 有独立 CT 表, 此处覆盖主机侧流量) ==========
net.netfilter.nf_conntrack_max = 500000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30

# 配合较短 established 超时, 开启 keepalive 保护长连接(DB/MQ 客户端)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# ========== 软中断权重 ==========
net.core.dev_weight = 64
net.core.dev_weight_rx_bias = 16
net.core.dev_weight_tx_bias = 16

# ========== 内存管理 ==========
vm.swappiness = 0
# Redis/PostgreSQL fork 型子进程需要 overcommit, 否则 bgsave 可能失败
vm.overcommit_memory = 1
vm.panic_on_oom = 0
vm.vfs_cache_pressure = 50
# ES 系搜索引擎的硬性要求; Meilisearch(LMDB mmap)/数据库同样受益
vm.max_map_count = 262144
# 提前小批量刷脏页, 平滑数据库写入的尾延迟
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15

# ========== 句柄与进程 ==========
fs.file-max = 52706963
fs.nr_open = 52706963
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.aio-max-nr = 1048576
kernel.pid_max = 4194304

# ========== 低延迟杂项 ==========
$nmi_block
EOF
  # 新版 procps 的 sysctl --system 任一键失败即返回非零(如个别平台差异键),
  # 应用取尽力而为, 关键键的硬校验由下一步 verify_sysctl_applied 负责
  sysctl --system >/dev/null 2>&1 \
    || log_warn "sysctl --system 报告部分键未生效(平台差异), 以关键键校验结果为准"
}
verify_sysctl_applied() {
  verify_sysctl net.ipv4.tcp_congestion_control bbr \
    && verify_sysctl net.ipv4.ip_forward 1 \
    && verify_sysctl net.core.somaxconn 4096 \
    && verify_sysctl net.netfilter.nf_conntrack_max 500000 \
    && verify_sysctl vm.max_map_count 262144
}

# --- 4. 资源限制(用 limits.d 而不是覆盖系统的 limits.conf) -------------------------
write_limits() {
  cat > /etc/security/limits.d/99-k8s.conf <<'EOF'
# k8s-installer 托管
* soft nofile 655350
* hard nofile 655350
* soft nproc 655350
* hard nproc 655350
* soft core unlimited
* hard core unlimited
EOF
}
verify_limits() { [[ -s /etc/security/limits.d/99-k8s.conf ]]; }

# --- 5. journald 上限(防止日志吃满磁盘) --------------------------------------------
config_journald() {
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-k8s.conf <<'EOF'
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=200M
EOF
  systemctl restart systemd-journald
}

# --- 6. 裁剪无关服务 ---------------------------------------------------------------
disable_services() {
  local svc
  for svc in "${DISABLE_SERVICES[@]}"; do
    if svc_exists "$svc"; then
      systemctl disable --now "$svc" 2>/dev/null || true
      log_info "已停用: $svc"
    fi
  done
}

# --- 7. 透明大页(运行时立即关闭 + GRUB 持久化, 避免数据库延迟抖动) --------------------
disable_thp_runtime() {
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
}
verify_thp() { grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled; }

persist_grub_tuning() {
  if ! has_cmd update-grub; then
    log_warn "未检测到 grub(可能是特殊镜像), 跳过启动参数持久化; THP/nmi 已运行时生效"
    return 0
  fi
  local params="nmi_watchdog=0 transparent_hugepage=never"
  if [[ $MITIGATIONS_OFF == true ]]; then
    params+=" mitigations=off"
    log_warn "已加入 mitigations=off: 关闭 CPU 漏洞缓解, 仅限完全可信内网(见 README 分析)"
  fi
  # shellcheck disable=SC2016  # $GRUB_CMDLINE_LINUX_DEFAULT 要留给 grub-mkconfig source 时展开
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s"\n' "$params" \
    > /etc/default/grub.d/99-k8s-tuning.cfg
  update-grub
  touch "$STATE_DIR/reboot-recommended"
}

# --- 8. IO 调度器(NVMe/virtio 直通 none, SATA SSD 用 mq-deadline; LVM 低延迟基础) ----
config_io_scheduler() {
  cat > /etc/udev/rules.d/60-k8s-iosched.rules <<'EOF'
# k8s-installer 托管: 数据库/etcd 负载的低延迟 IO 调度策略
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
EOF
  udevadm control --reload
  udevadm trigger --subsystem-match=block --action=change
}

# --- 9. Cilium 内核配置校验(原脚本注释块 → 真实检查) --------------------------------
check_cilium_kernel_config() {
  local kconf
  kconf="/boot/config-$(uname -r)"
  if [[ ! -r $kconf ]]; then
    log_warn "缺少 $kconf, 无法校验内核编译选项(发行版内核一般均满足), 跳过"
    return 0
  fi

  # 必需项: eBPF 数据面基础
  local required=(BPF BPF_SYSCALL NET_CLS_BPF BPF_JIT NET_CLS_ACT NET_SCH_INGRESS
                  CRYPTO_SHA1 CRYPTO_USER_API_HASH CGROUPS CGROUP_BPF PERF_EVENTS SCHEDSTATS)
  # 可选项: 隧道 / L7 代理(TPROXY) / 带宽管理(FQ) / masquerade(ipset) / netkit 数据面
  local optional=(VXLAN GENEVE FIB_RULES
                  NETFILTER_XT_TARGET_TPROXY NETFILTER_XT_TARGET_MARK NETFILTER_XT_TARGET_CT
                  NETFILTER_XT_MATCH_MARK NETFILTER_XT_MATCH_SOCKET
                  NET_SCH_FQ NETFILTER_XT_SET IP_SET IP_SET_HASH_IP NETKIT)
  [[ $CILIUM_ENABLE_IPSEC == true ]] && optional+=(XFRM XFRM_OFFLOAD XFRM_ALGO XFRM_USER
                  INET_ESP INET_IPCOMP INET_XFRM_TUNNEL INET_TUNNEL
                  CRYPTO_AEAD CRYPTO_GCM CRYPTO_SEQIV CRYPTO_CBC CRYPTO_HMAC CRYPTO_SHA256 CRYPTO_AES)

  local opt missing_required=() missing_optional=()
  for opt in "${required[@]}"; do
    grep -Eq "^CONFIG_${opt}=(y|m)" "$kconf" || missing_required+=("$opt")
  done
  for opt in "${optional[@]}"; do
    grep -Eq "^CONFIG_${opt}=(y|m)" "$kconf" || missing_optional+=("$opt")
  done

  if (( ${#missing_optional[@]} > 0 )); then
    log_warn "内核缺少可选选项(相关特性不可用): ${missing_optional[*]}"
  fi
  if (( ${#missing_required[@]} > 0 )); then
    die "内核缺少 Cilium 必需选项: ${missing_required[*]} (参考 docs.cilium.io system_requirements)"
  fi
  log_info "Cilium 内核选项校验通过($(basename "$kconf"))"
}

main() {
  stage_begin "20-kernel-tuning" "内核与系统调优"
  add_step swap     "关闭 Swap 并注释 fstab"              disable_swap        verify_swap
  add_step modules  "加载并持久化内核模块"                load_modules        verify_modules
  add_step sysctl   "写入 sysctl 调优(eBPF/BBR/conntrack)" write_sysctl        verify_sysctl_applied
  add_step limits   "资源限制 limits.d"                   write_limits        verify_limits
  add_step journald "journald 日志上限"                   config_journald
  add_step services "停用无关服务"                        disable_services
  add_step thp      "关闭透明大页(运行时)"                disable_thp_runtime verify_thp
  add_step grub     "GRUB 启动参数持久化"                 persist_grub_tuning
  add_step iosched  "IO 调度器 udev 规则"                 config_io_scheduler
  add_step kconfig  "Cilium 内核编译选项校验"             check_cilium_kernel_config
  run_steps
  stage_end
}
main "$@"
