#!/usr/bin/env bash
# =============================================================================
# 10-system-base —— 系统基础配置
#   主机名 / apt 与基础包 / 代理别名 / hosts / 时区 / chrony(兼容 20.04 无 sources.d)
#   可选项(交互确认): 静态 IP(netplan 独立文件)、sshd(drop-in 按字段生效)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

# --- 主机名 -------------------------------------------------------------------
set_hostname() { hostnamectl set-hostname "$NODE_NAME"; }
verify_hostname() { [[ $(hostname) == "$NODE_NAME" ]]; }

# --- apt 更新与基础包 -----------------------------------------------------------
apt_refresh() {
  apt_update
  if resolve_opt "$RUN_FULL_UPGRADE" "执行 apt full-upgrade? (可能升级内核, 重启后生效, 建议执行)" Y; then
    apt_env apt-get full-upgrade -y \
      -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold
    # 系统提示需要重启(通常是内核升级)时仅做标记, 重启统一放到安装完成后
    [[ -f /var/run/reboot-required ]] && touch "$STATE_DIR/reboot-recommended"
  fi
  return 0
}

install_base_packages() {
  pkg_install git curl wget vim net-tools ethtool iproute2 gpg ca-certificates \
    apt-transport-https chrony lvm2 xfsprogs jq bash-completion conntrack socat ipset \
    gdisk parted
}
verify_base_packages() { has_cmd curl && has_cmd jq && has_cmd chronyc && has_cmd vgcreate; }

# --- 代理别名(修复原脚本: alias 换行导致 https_proxy 未 export 的问题) ------------
write_proxy_aliases() {
  local content
  content="alias proxy='export http_proxy=$PROXY_URL https_proxy=$PROXY_URL HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL'
alias unproxy='unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY'"
  ensure_block "$TARGET_HOME/.bashrc" "proxy-aliases" "$content"
  [[ $TARGET_HOME != /root ]] && ensure_block /root/.bashrc "proxy-aliases" "$content"
  return 0
}

# --- /etc/hosts(托管块, 重复执行不追加) -----------------------------------------
write_hosts() {
  backup_once /etc/hosts
  local content="" entry self_present=false
  for entry in "${EXTRA_HOSTS[@]}"; do
    content+="$entry"$'\n'
    [[ $entry == "$NODE_IP $NODE_NAME" ]] && self_present=true
  done
  [[ $self_present == false ]] && content+="$NODE_IP $NODE_NAME"$'\n'
  ensure_block /etc/hosts "cluster-hosts" "${content%$'\n'}"
}
verify_hosts() { getent hosts "$NODE_NAME" >/dev/null; }

# --- 时区 ----------------------------------------------------------------------
set_timezone() { timedatectl set-timezone "$TIMEZONE"; }
verify_timezone() { [[ $(timedatectl show -p Timezone --value) == "$TIMEZONE" ]]; }

# --- chrony NTP(20.04 chrony 3.5 无 sources.d, 走 chrony.conf 托管块) -------------
config_chrony() {
  local pools="" p
  for p in "${NTP_POOLS[@]}"; do pools+="$p"$'\n'; done
  pools=${pools%$'\n'}

  if [[ -d /etc/chrony/sources.d ]] && grep -qs '^sourcedir /etc/chrony/sources.d' /etc/chrony/chrony.conf; then
    # 22.04+: 独立 sources 文件; 替换系统默认池前备份一次
    backup_once /etc/chrony/sources.d/ubuntu-ntp-pools.sources
    printf '# k8s-installer 托管: 国内低延迟 NTP 池\n%s\n' "$pools" \
      > /etc/chrony/sources.d/ubuntu-ntp-pools.sources
  else
    # 20.04: 注释掉默认 pool 行, 托管块追加国内池
    backup_once /etc/chrony/chrony.conf
    sed -ri 's/^(pool[[:space:]].*)$/# \1/' /etc/chrony/chrony.conf
    ensure_block /etc/chrony/chrony.conf "ntp-pools" "$pools"
  fi
  systemctl restart chrony
  # 允许大步长校时一次, 避免与标准时间偏差过大
  chronyc -a makestep >/dev/null || true
}
verify_chrony() {
  # 单元名兼容(chrony/chronyd)
  local unit=chrony
  svc_exists chrony || unit=chronyd

  local i
  for ((i = 0; i < 8; i++)); do
    svc_active "$unit" && break
    sleep 2
  done
  if ! svc_active "$unit"; then
    log_error "chrony 服务未进入 active, 现场诊断:"
    systemctl status "$unit" --no-pager -l 2>&1 | head -8 >&2
    journalctl -u "$unit" -n 8 --no-pager 2>&1 | tail -8 >&2
    return 1
  fi

  # 关键: chronyc sources 只列出"已完成 DNS 解析"的池实例, 刚 restart 后的几秒内
  # 列表为空属正常(命令本身退出码仍是 0) → 必须轮询等内容出现, 不能只看退出码
  # (此前的 bug: 重启后同一秒立即检查, 空列表被判为失败, 每次必现)
  local out=""
  for ((i = 0; i < 15; i++)); do
    out=$(chronyc -N sources 2>/dev/null) || out=""
    [[ $out == *aliyun* || $out == *tencent* ]] && return 0
    sleep 2
  done

  log_error "30s 内未在 chrony 源列表见到配置的国内池, 大概率是 DNS 解析问题, 现场诊断:"
  log_error "· chronyc -N sources 实际输出:"
  printf '%s\n' "${out:-(空)}" | head -6 >&2
  log_error "· 已配置的池:"
  grep -rns '^pool\|^server' /etc/chrony/chrony.conf /etc/chrony/sources.d/ 2>/dev/null | head -6 >&2
  log_error "· DNS 自检: $(resolvectl query ntp.aliyun.com 2>&1 | head -2 | tr '\n' ' ')"
  return 1
}

# --- 自动安全更新(只装安全补丁; 不自动重启, 重启由 kured 在维护窗口内协调) -----------
config_auto_upgrades() {
  if [[ $ENABLE_AUTO_SECURITY_UPGRADES != true ]]; then
    log_info "未启用自动安全更新, 跳过"
    return 0
  fi
  pkg_install unattended-upgrades
  backup_once /etc/apt/apt.conf.d/20auto-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// k8s-installer 托管
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/52-k8s-unattended.conf <<'EOF'
// k8s-installer 托管: 只打安全补丁, 绝不自动重启
// - kubelet/kubeadm/kubectl 已 apt-mark hold, unattended-upgrades 会自动跳过
// - containerd/runc 为二进制安装, 不受 apt 影响
// - 需要重启的内核补丁会生成 /var/run/reboot-required,
//   由 kured 在维护窗口内 drain 后重启(80 阶段可选安装)
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MinimalSteps "true";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}
verify_auto_upgrades() {
  [[ $ENABLE_AUTO_SECURITY_UPGRADES != true ]] \
    || { systemctl is-enabled --quiet apt-daily-upgrade.timer && has_cmd unattended-upgrade; }
}

# --- 静态 IP(可选+危险: 写独立 netplan 文件, 回滚=删文件后 netplan apply) ----------
config_static_ip() {
  if ! resolve_opt "$CONFIGURE_STATIC_IP" "配置静态 IP($NET_ADDRESS)? 远程执行配错会断连" N; then
    log_info "跳过静态 IP 配置(沿用当前网络)"
    return 0
  fi
  local iface=${NET_IFACE:-$(detect_default_iface)}
  [[ -n $iface ]] || die "无法检测默认网卡, 请在 config.env 设置 NET_IFACE"

  local dns_yaml="" d
  for d in "${NET_DNS[@]}"; do dns_yaml+="          - $d"$'\n'; done

  # 已经是目标地址时静默通过(幂等)
  if ip -4 addr show "$iface" 2>/dev/null | grep -qw "${NET_ADDRESS%/*}" \
     && [[ -f /etc/netplan/99-k8s-static.yaml ]]; then
    log_info "网卡 $iface 已是 $NET_ADDRESS, 跳过"
    return 0
  fi

  if [[ $ASSUME_YES != true ]]; then
    confirm_danger "即将写入 /etc/netplan/99-k8s-static.yaml: $iface → $NET_ADDRESS 网关 $NET_GATEWAY (SSH 可能瞬断)" \
      "apply-network" || { log_warn "用户取消, 跳过静态 IP 配置"; return 0; }
  fi

  cat > /etc/netplan/99-k8s-static.yaml <<EOF
# k8s-installer 托管: 集群节点静态地址(删除本文件并 netplan apply 即回滚)
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      dhcp6: false
      addresses:
        - $NET_ADDRESS
      nameservers:
        addresses:
$dns_yaml
      routes:
        - to: default
          via: $NET_GATEWAY
EOF
  chmod 600 /etc/netplan/99-k8s-static.yaml
  netplan generate   # 语法校验, 失败则不 apply
  netplan apply
  sleep 2
}
verify_static_ip() {
  # 未启用该选项时也要放行: 只要求 NODE_IP 确实配置在本机(集群各处都依赖它)
  ip -4 addr show | grep -qF "inet $NODE_IP/"
}

# --- sshd(可选: drop-in 按字段生效, 替代原脚本追加写法) ---------------------------
config_sshd() {
  if ! resolve_opt "$CONFIGURE_SSHD" "下发 sshd 配置(公钥登录/root 登录策略)?" N; then
    log_info "跳过 sshd 配置"
    return 0
  fi
  local permit_root=$SSHD_PERMIT_ROOT_LOGIN
  if [[ $permit_root == yes ]] && is_interactive; then
    confirm "允许 root 密码登录有安全风险, 确认开启? (拒绝则降级为 prohibit-password)" N \
      || permit_root="prohibit-password"
  fi

  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -qsi '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
    backup_once /etc/ssh/sshd_config
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  cat > /etc/ssh/sshd_config.d/99-k8s.conf <<EOF
# k8s-installer 托管
PermitRootLogin $permit_root
PubkeyAuthentication $SSHD_PUBKEY_AUTH
EOF
  # 配置有语法错误时立刻回撤, 绝不带病重启 sshd 导致失联
  if ! sshd -t 2>/dev/null; then
    rm -f /etc/ssh/sshd_config.d/99-k8s.conf
    die "sshd 配置校验失败, 已回撤 drop-in 文件"
  fi
  systemctl restart ssh
}
verify_sshd() { svc_active ssh || svc_active ssh.socket || svc_active sshd; }

main() {
  stage_begin "10-system-base" "系统基础配置"
  add_step hostname "设置主机名 $NODE_NAME"            set_hostname        verify_hostname
  add_step apt      "apt 更新(可选 full-upgrade)"      apt_refresh
  add_step pkgs     "安装基础软件包"                    install_base_packages verify_base_packages
  if [[ $WRITE_PROXY_ALIASES == true && -n $PROXY_URL ]]; then
    add_step proxyrc "写入 proxy/unproxy 别名"          write_proxy_aliases
  fi
  add_step hosts    "写入 /etc/hosts 集群解析"          write_hosts         verify_hosts
  add_step tz       "设置时区 $TIMEZONE"                set_timezone        verify_timezone
  add_step chrony   "配置 chrony NTP(国内源)"           config_chrony       verify_chrony
  add_step autoupd  "自动安全更新(unattended-upgrades)" config_auto_upgrades verify_auto_upgrades
  add_step netplan  "静态 IP(可选)"                     config_static_ip    verify_static_ip
  add_step sshd     "sshd 配置(可选)"                   config_sshd         verify_sshd
  run_steps
  stage_end
}
main "$@"
