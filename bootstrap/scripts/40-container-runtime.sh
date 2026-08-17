#!/usr/bin/env bash
# =============================================================================
# 40-container-runtime —— runc / containerd / crictl
#   - 全部从 30 的校验缓存安装(独立执行本脚本时会自动补跑下载)
#   - containerd: SystemdCgroup + certs.d 镜像加速 + 可选代理 drop-in
#   - sandbox(pause) 镜像在 50 阶段与 kubeadm 精确对齐, 此处不猜版本
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

CONTAINERD_CONFIG="/etc/containerd/config.toml"

# --- 0. 确保工件缓存就绪(orchestrator 已后台下载; 单独执行时同步补跑) --------------
ensure_artifacts() {
  ensure_versions
  [[ -f $CACHE_DIR/.complete ]] || bash "$K8S_SCRIPTS_DIR/30-download.sh"
}

# --- 0.5 既有安装评估(接管策略; node1 陈旧配置崩溃循环的教训) ------------------------
#   版本接近(同主版本, ΔY<=2, ΔZ<=3) + 行为验证(现有二进制能解析现有配置) → 备份后推进
#   差异过大/验证失败 → 备份后清掉易出意外的旧配置, 清本阶段状态强制全部重做
#   无法备份恢复的(/var/lib/containerd 镜像层) → 仅主版本跳变时弹窗询问
assess_existing_runtime() {
  local bin=/usr/local/bin/containerd
  [[ -x $bin ]] || bin=$(command -v containerd 2>/dev/null || true)
  if [[ -z $bin || ! -x $bin ]]; then
    log_info "未检测到既有 containerd, 按全新安装推进"
    return 0
  fi
  local cur
  cur=$("$bin" --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
  if [[ -z $cur ]]; then
    log_warn "既有 containerd 无法读取版本, 按差异过大处理"
  else
    log_info "检测到既有 containerd $cur (目标 $CONTAINERD_V)"
    if ver_close "$cur" "$CONTAINERD_V"; then
      # 行为一致性验证: 现有二进制解析现有配置
      if [[ -f /etc/containerd/config.toml ]] && "$bin" config dump >/dev/null 2>&1; then
        backup_once /etc/containerd/config.toml
        log_ok "版本接近且行为验证通过, 原配置已备份, 推进(二进制仍会对齐到目标版)"
        return 0
      fi
      log_warn "版本接近但行为验证失败(config 解析异常), 转重装覆盖"
    else
      log_warn "版本差异过大($cur → $CONTAINERD_V), 重装覆盖并清理旧配置"
    fi
  fi

  systemctl stop containerd 2>/dev/null || true
  backup_once /etc/containerd/config.toml
  rm -f /etc/containerd/config.toml
  rm -f /etc/systemd/system/containerd.service.d/http-proxy.conf "$PREPULL_DROPIN" 2>/dev/null
  # 镜像层数据无法备份恢复原样 → 主版本跳变才询问
  local cur_major=${cur#v}; cur_major=${cur_major%%.*}
  local tgt_major=${CONTAINERD_V#v}; tgt_major=${tgt_major%%.*}
  if [[ -n $cur && $cur_major != "$tgt_major" ]] && [[ -n $(ls -A /var/lib/containerd 2>/dev/null) ]]; then
    if confirm_danger "主版本跳变($cur→$CONTAINERD_V): 清空 /var/lib/containerd(镜像层, 无法备份恢复)?" "wipe-containerd-data"; then
      rm -rf /var/lib/containerd/*
    else
      log_warn "保留旧数据目录; 若启动异常再手动清理 /var/lib/containerd"
    fi
  fi
  state_reset "40-container-runtime"   # 本阶段全部步骤强制真实重做
  systemctl daemon-reload
}

# --- 1. runc -------------------------------------------------------------------
install_runc() { install -m 755 "$A_RUNC" /usr/local/sbin/runc; }
verify_runc()  { /usr/local/sbin/runc --version | grep -q "${RUNC_V#v}"; }

# --- 2. containerd 二进制 + systemd 单元 ------------------------------------------
install_containerd() {
  tar -xzf "$A_CONTAINERD_TGZ" -C /usr/local/
  install -m 644 "$A_CONTAINERD_SVC" /etc/systemd/system/containerd.service
}
verify_containerd_bin() { /usr/local/bin/containerd --version | grep -q "${CONTAINERD_V#v}"; }

# --- 3. containerd 配置 -----------------------------------------------------------
gen_containerd_config() {
  mkdir -p /etc/containerd /etc/containerd/certs.d
  backup_once "$CONTAINERD_CONFIG"
  /usr/local/bin/containerd config default > "$CONTAINERD_CONFIG"

  # cgroup 驱动与 kubelet 对齐(systemd)
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG"
  # 启用 certs.d 目录化的 registry 配置
  sed -i "s|^\([[:space:]]*config_path = \)''$|\1'/etc/containerd/certs.d'|" "$CONTAINERD_CONFIG"
}
verify_containerd_config() {
  grep -q 'SystemdCgroup = true' "$CONTAINERD_CONFIG" \
    && grep -q "config_path = '/etc/containerd/certs.d'" "$CONTAINERD_CONFIG"
}

# --- 4. registry 配置(certs.d 目录式, 每个上游一个 hosts.toml) -----------------------
#   优先级: 用户自带完整目录(CONTAINERD_CERTS_SRC / files/certs.d) > USE_CN_MIRRORS 生成 > 不配置
write_registry_mirrors() {
  # 路线一: 原样安装用户自带的 certs.d 目录(宿主机维护的一份完整 registry 配置)
  local src=$CONTAINERD_CERTS_SRC
  [[ -z $src && -d $K8S_BASE_DIR/files/certs.d ]] && src="$K8S_BASE_DIR/files/certs.d"
  if [[ -n $src ]]; then
    [[ $src != /* ]] && src="$K8S_BASE_DIR/$src"
    [[ -d $src ]] || die "CONTAINERD_CERTS_SRC=$src 目录不存在"
    [[ -n $(find "$src" -name hosts.toml -print -quit 2>/dev/null) ]] \
      || die "$src 下未发现任何 hosts.toml, 不是合法的 certs.d 目录"
    mkdir -p /etc/containerd/certs.d
    cp -a "$src"/. /etc/containerd/certs.d/
    log_info "已安装自带 registry 配置: $src → /etc/containerd/certs.d ($(find /etc/containerd/certs.d -name hosts.toml | wc -l | tr -d ' ') 个 hosts.toml)"
    return 0
  fi

  # 路线二: 按 CN_MIRROR_DOMAIN 生成 DaoCloud 系 mirror
  if [[ $USE_CN_MIRRORS != true ]]; then
    log_info "未提供自带 certs.d 且 USE_CN_MIRRORS=false, 跳过 registry 加速配置"
    return 0
  fi
  local upstream prefix server
  # 上游仓库 → 加速前缀(DaoCloud 命名规则: <前缀>.m.daocloud.io)
  local -A mirrors=(
    [docker.io]=docker
    [registry.k8s.io]=k8s
    [gcr.io]=gcr
    [ghcr.io]=ghcr
    [quay.io]=quay
  )
  for upstream in "${!mirrors[@]}"; do
    prefix=${mirrors[$upstream]}
    server="https://$upstream"
    [[ $upstream == docker.io ]] && server="https://registry-1.docker.io"
    mkdir -p "/etc/containerd/certs.d/$upstream"
    cat > "/etc/containerd/certs.d/$upstream/hosts.toml" <<EOF
# k8s-installer 托管: $upstream 镜像加速(失败自动回源)
server = "$server"

[host."https://$prefix.$CN_MIRROR_DOMAIN"]
  capabilities = ["pull", "resolve"]
EOF
  done
}

# --- 5. containerd 代理(可选, 仅影响镜像拉取) ---------------------------------------
write_containerd_proxy() {
  local dropin_dir=/etc/systemd/system/containerd.service.d
  if [[ $CONTAINERD_USE_PROXY == true && -n $PROXY_URL ]]; then
    mkdir -p "$dropin_dir"
    cat > "$dropin_dir/http-proxy.conf" <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=localhost,127.0.0.1,$NODE_IP,$POD_CIDR,$SERVICE_CIDR,.cluster.local,10.0.0.0/8,192.168.0.0/16"
EOF
  else
    # 配置关闭时清掉旧 drop-in, 保证结果恒定
    rm -f "$dropin_dir/http-proxy.conf"
  fi
  return 0
}

# --- 6. 启动 -----------------------------------------------------------------------
start_containerd() {
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
}
verify_containerd_running() {
  # restart 返回后 gRPC socket 就绪还需一拍, 轮询等待而不是瞬时判负
  local i
  for ((i = 0; i < 10; i++)); do
    if svc_active containerd && /usr/local/bin/ctr version 2>/dev/null | grep -qi 'server'; then
      return 0
    fi
    sleep 2
  done

  log_error "containerd 20s 内未就绪, 现场诊断:"
  systemctl status containerd --no-pager -l 2>&1 | head -10 >&2
  journalctl -u containerd -n 15 --no-pager 2>&1 | tail -15 >&2
  ls -l /run/containerd/containerd.sock 2>&1 | head -2 >&2
  if ! /usr/local/bin/containerd config dump >/dev/null 2>&1; then
    log_error "config.toml 解析失败(containerd config dump 报错), 检查 /etc/containerd/config.toml"
  fi
  return 1
}

# --- 7. crictl ----------------------------------------------------------------------
install_crictl() {
  tar -xzf "$A_CRICTL_TGZ" -C /usr/local/bin
  cat > /etc/crictl.yaml <<'EOF'
# k8s-installer 托管
runtime-endpoint: "unix:///run/containerd/containerd.sock"
image-endpoint: "unix:///run/containerd/containerd.sock"
timeout: 10
debug: false
pull-image-on-create: false
disable-pull-on-run: false
EOF
}
verify_crictl() { /usr/local/bin/crictl version >/dev/null; }

main() {
  stage_begin "40-container-runtime" "容器运行时"
  ensure_artifacts
  # 配置类步骤是"配置+二进制"的纯函数, 永远重做——防旧安装尝试的陈旧配置被断点状态固化(node1 实测)
  rm -f "$STATE_DIR/state/40-container-runtime:ctrd-cfg.done" \
        "$STATE_DIR/state/40-container-runtime:mirrors.done" \
        "$STATE_DIR/state/40-container-runtime:proxy.done" \
        "$STATE_DIR/state/40-container-runtime:takeover.done"
  add_step takeover  "既有安装评估(版本接管策略)"           assess_existing_runtime
  add_step runc      "安装 runc $RUNC_V"                    install_runc            verify_runc
  add_step ctrd-bin  "安装 containerd $CONTAINERD_V"        install_containerd      verify_containerd_bin
  add_step ctrd-cfg  "生成 containerd 配置(SystemdCgroup)"  gen_containerd_config   verify_containerd_config
  add_step mirrors   "registry 镜像加速(certs.d)"           write_registry_mirrors
  add_step proxy     "containerd 代理 drop-in(可选)"        write_containerd_proxy
  add_step start     "启动 containerd"                      start_containerd        verify_containerd_running
  add_step crictl    "安装 crictl $CRICTL_V"                install_crictl          verify_crictl
  run_steps
  stage_end
}
main "$@"
