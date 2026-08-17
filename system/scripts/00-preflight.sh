#!/usr/bin/env bash
# =============================================================================
# 00-preflight —— 环境预检
#   - 操作系统/架构/内核/cgroup v2 检查, 低版本 Ubuntu 引导升级 HWE 内核
#   - 需要重启的变更(内核/cgroup)在这里收敛: 置 reboot-required 标记并中止,
#     重启后重新执行 start.sh 自动续跑
#   - 配置合法性检查(CIDR 冲突等), 提前失败好过 kubeadm init 后失败
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

REBOOT_FLAG="$STATE_DIR/reboot-required"

# --- 1. 操作系统 -------------------------------------------------------------
check_os() {
  [[ $(os_id) == ubuntu ]] || die "仅支持 Ubuntu 系列, 当前: $(os_id)"
  local ver; ver=$(os_ver)
  ver_ge "$ver" "20.04" || die "需要 Ubuntu >= 20.04, 当前: $ver"
  case $ver in
    20.04) log_warn "Ubuntu 20.04 已停止标准支持, 可用但建议升级到 22.04+/24.04+" ;;
    22.04|24.04|26.04) log_info "Ubuntu $ver LTS ✓" ;;
    *)     log_warn "Ubuntu $ver 非 LTS 版本, 未充分验证, 继续执行" ;;
  esac
  [[ -d /run/systemd/system ]] || die "系统未使用 systemd"
  if systemd-detect-virt --container --quiet; then
    die "检测到容器环境, 本脚本只能在物理机/虚拟机上执行"
  fi
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
    || die "需要 bash >= 4.4, 当前: $BASH_VERSION"
}

# --- 2. 硬件资源(只警告不阻断, kubeadm 自身还有硬性预检) -----------------------
check_hw() {
  local cpus mem_kb mem_gb disk_gb virt
  cpus=$(nproc)
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  mem_gb=$(( mem_kb / 1024 / 1024 ))
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  log_info "硬件: ${cpus}C / ${mem_gb}G 内存 / 根分区可用 ${disk_gb}G / 虚拟化: $virt / 架构: $ARCH"
  (( cpus >= 2 ))    || log_warn "CPU < 2 核, kubeadm 预检将告警"
  (( mem_gb >= 4 ))  || log_warn "内存 < 4G, 只够跑控制面, 基础设施组件(80 阶段)请谨慎勾选"
  (( disk_gb >= 20 )) || log_warn "根分区可用空间 < 20G, 镜像与日志可能撑满磁盘"
}

# --- 3. 内核版本(Cilium eBPF 特性按内核分级) -----------------------------------
check_kernel() {
  local kr; kr=$(uname -r)
  log_info "内核: $kr"
  kernel_ge 5.4 && rm -f "$REBOOT_FLAG"

  if ! kernel_ge 5.4; then
    if [[ $(os_ver) == 20.04 ]] && confirm "内核 < 5.4 无法满足 Cilium 要求, 安装 HWE 内核(5.15)并重启?" Y; then
      apt_update
      pkg_install "linux-generic-hwe-$(os_ver)"
      touch "$REBOOT_FLAG"
      die "HWE 内核已安装, 请重启后重新执行 sudo bash start.sh 继续"
    fi
    die "内核 $kr 过旧(Cilium 需要 >= 5.4), 请升级内核后重试"
  fi

  if ! kernel_ge 5.10; then
    log_warn "内核 < 5.10: eBPF Host-Routing 不可用, 将回退 legacy 路由(有性能损失)"
    if [[ $(os_ver) == 20.04 ]] && confirm "建议安装 HWE 内核(5.15)获得完整 eBPF 能力, 现在安装?" Y; then
      apt_update
      pkg_install "linux-generic-hwe-$(os_ver)"
      touch "$REBOOT_FLAG"
      die "HWE 内核已安装, 请重启后重新执行 sudo bash start.sh 继续"
    fi
  fi

  # 特性矩阵提示(60-cilium 会按内核自动开关)
  local f_hostrt="✔" f_bbr="✔" f_bigtcp="✔" f_netkit="✔"
  kernel_ge 5.10 || f_hostrt="✘(需>=5.10)"
  kernel_ge 5.18 || f_bbr="✘(需>=5.18)"
  kernel_ge 6.3  || f_bigtcp="✘(需>=6.3)"
  # netkit 是纯 Guest 内核特性(veth 替代), 与宿主机/虚拟化平台无关;
  # 有别于 XDP 加速——后者依赖网卡驱动, 虚拟机普遍不支持
  local kconf; kconf="/boot/config-$(uname -r)"
  if ! kernel_ge 6.8; then
    f_netkit="✘(需>=6.8)"
  elif [[ -r $kconf ]] && ! grep -qE '^CONFIG_NETKIT=(y|m)' "$kconf"; then
    f_netkit="✘(内核未编译 CONFIG_NETKIT)"
  fi
  log_info "eBPF 特性支持: Host-Routing $f_hostrt | BBR带宽管理 $f_bbr | BIG-TCP $f_bigtcp | netkit $f_netkit"
}

# --- 4. cgroup v2(K8s 新版本要求; 20.04 默认 v1, 改 GRUB 后需重启) --------------
check_cgroup_v2() {
  if [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]; then
    log_info "cgroup v2 ✓"
    rm -f "$REBOOT_FLAG"
    return 0
  fi
  log_warn "当前为 cgroup v1, kubelet/新版本 K8s 要求 cgroup v2, 需修改内核启动参数并重启"
  cat > /etc/default/grub.d/98-k8s-cgroupv2.cfg <<'EOF'
# k8s-installer: 启用 cgroup v2(unified hierarchy)
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT systemd.unified_cgroup_hierarchy=1"
EOF
  update-grub
  touch "$REBOOT_FLAG"
  die "已写入 cgroup v2 启动参数, 请重启后重新执行 sudo bash start.sh 继续(已完成步骤会自动跳过)"
}

# --- 5. 配置合法性 -------------------------------------------------------------
check_config() {
  case $NODE_ROLE in
    control-plane|worker) ;;
    *) die "NODE_ROLE 必须是 control-plane 或 worker, 当前: $NODE_ROLE" ;;
  esac
  if is_worker; then
    [[ $SINGLE_NODE == true ]] && log_warn "worker 节点忽略 SINGLE_NODE 设置"
    # 非交互模式必须在启动前就备齐加入参数(交互模式可在 50 阶段粘贴 join 命令)
    if ! is_interactive && [[ ! -f $STATE_DIR/join.params ]] \
       && [[ -z $JOIN_TOKEN || -z $JOIN_ENDPOINT || -z $JOIN_CA_CERT_HASH ]]; then
      die "worker 非交互模式需要 JOIN_ENDPOINT/JOIN_TOKEN/JOIN_CA_CERT_HASH — 在控制面执行: kubeadm token create --print-join-command"
    fi
  fi
  [[ $NODE_NAME =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "NODE_NAME 不合法: $NODE_NAME"
  [[ $NODE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NODE_IP 不合法: $NODE_IP"
  [[ $POD_CIDR =~ / && $SERVICE_CIDR =~ / ]] || die "POD_CIDR / SERVICE_CIDR 必须是 CIDR 格式"

  # 经典翻车点: Pod/Service 网段与宿主机局域网重叠 → 路由黑洞
  if cidr_contains "$POD_CIDR" "$NODE_IP"; then
    die "POD_CIDR($POD_CIDR) 与节点 IP($NODE_IP) 重叠, 请更换 Pod 网段"
  fi
  if cidr_contains "$SERVICE_CIDR" "$NODE_IP"; then
    die "SERVICE_CIDR($SERVICE_CIDR) 与节点 IP($NODE_IP) 重叠, 请更换 Service 网段"
  fi
  if cidr_contains "$POD_CIDR" "${SERVICE_CIDR%/*}" || cidr_contains "$SERVICE_CIDR" "${POD_CIDR%/*}"; then
    die "POD_CIDR 与 SERVICE_CIDR 相互重叠"
  fi
  if [[ $CILIUM_ENABLE_L2_ANNOUNCEMENTS == true ]]; then
    local ip_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    [[ $CILIUM_LB_POOL_START =~ $ip_re ]] || die "CILIUM_LB_POOL_START 不是合法 IP: $CILIUM_LB_POOL_START"
    [[ $CILIUM_LB_POOL_STOP  =~ $ip_re ]] || die "CILIUM_LB_POOL_STOP 不是合法 IP: $CILIUM_LB_POOL_STOP"
    local start_n stop_n node_n
    start_n=$(ip2int "$CILIUM_LB_POOL_START"); stop_n=$(ip2int "$CILIUM_LB_POOL_STOP"); node_n=$(ip2int "$NODE_IP")
    (( start_n <= stop_n )) || die "LB 地址池起止颠倒: $CILIUM_LB_POOL_START > $CILIUM_LB_POOL_STOP"
    # 池内地址会被 LB-IPAM 随意分配并做 ARP 通告, 覆盖到在用地址会造成 IP 冲突
    if (( node_n >= start_n && node_n <= stop_n )); then
      die "LB 地址池($CILIUM_LB_POOL_START-$CILIUM_LB_POOL_STOP)包含节点 IP $NODE_IP, 会引发地址冲突, 请缩小范围"
    fi
  fi
  log_info "节点: $NODE_NAME($NODE_IP) 角色: $NODE_ROLE | Pod网段: $POD_CIDR | Service网段: $SERVICE_CIDR"
}

# --- 6. 外网连通性(只警告: 有缓存/镜像加速时不依赖直连) --------------------------
check_network() {
  # 按需代理状态明示: 在线→本次下载走代理; 离线→自动直连(开启代理后重跑即切换, 无需改配置)
  if [[ -n $PROXY_URL ]]; then
    if proxy_alive; then log_info "按需代理在线: $PROXY_URL (本次下载将借道)"
    else log_info "按需代理未开启, 本次直连(需要时启动代理后重跑即可)"; fi
  fi
  if with_proxy curl -fsI --connect-timeout 5 --max-time 8 https://api.github.com >/dev/null 2>&1; then
    log_info "GitHub 连通 ✓"
  else
    log_warn "GitHub 不可直达: 版本解析将使用兜底值; 可开启 PROXY_URL 代理或设置 GITHUB_PROXY"
  fi
  if [[ $USE_CN_MIRRORS == true ]]; then
    if curl -fsI --connect-timeout 5 --max-time 8 "https://$CN_MIRROR_DOMAIN" >/dev/null 2>&1; then
      log_info "镜像加速站 $CN_MIRROR_DOMAIN 连通 ✓"
    else
      log_warn "镜像加速站 $CN_MIRROR_DOMAIN 不可达, 镜像拉取可能变慢或失败"
    fi
  fi
}

main() {
  stage_begin "00-preflight" "环境预检"
  add_step os     "操作系统与运行环境检查"          check_os
  add_step hw     "硬件资源检查"                    check_hw
  add_step kernel "内核版本与 eBPF 特性检查"        check_kernel
  add_step cgroup "cgroup v2 检查(必要时改 GRUB)"   check_cgroup_v2
  add_step config "config.env 配置合法性检查"       check_config
  add_step net    "外网连通性探测"                  check_network
  run_steps
  stage_end
}
main "$@"
