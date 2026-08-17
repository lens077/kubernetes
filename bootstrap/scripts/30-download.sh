#!/usr/bin/env bash
# =============================================================================
# 30-download —— 工件并行下载器
#   - 与系统配置阶段(10/20)并行执行: start.sh 在预检通过后即后台启动本脚本
#   - 版本解析一次后写入 versions.lock → 后续每次执行版本恒定
#   - 全部工件带 sha256 校验; 已存在且校验通过则跳过(断点续跑靠校验而非状态标记)
#   - 单独执行: bash scripts/30-download.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

COMPLETE_MARK="$CACHE_DIR/.complete"

# --- 各工件下载函数(均为: 缓存命中即返回, 否则下载+校验) --------------------------
dl_runc() {
  local base="https://github.com/opencontainers/runc/releases/download/$RUNC_V"
  if [[ -f $A_RUNC && -f $A_RUNC_SUM ]] && sha256_ok "$A_RUNC" "$A_RUNC_SUM" "runc.$ARCH"; then return 0; fi
  fetch "$(gh_url "$base/runc.sha256sum")" "$A_RUNC_SUM"
  fetch "$(gh_url "$base/runc.$ARCH")" "$A_RUNC"
  sha256_ok "$A_RUNC" "$A_RUNC_SUM" "runc.$ARCH"
}

dl_containerd() {
  local base="https://github.com/containerd/containerd/releases/download/$CONTAINERD_V"
  local tgz_name; tgz_name=$(basename "$A_CONTAINERD_TGZ")
  local sum="$A_CONTAINERD_TGZ.sha256sum"
  if [[ ! -f $A_CONTAINERD_TGZ || ! -f $sum ]] || ! sha256_ok "$A_CONTAINERD_TGZ" "$sum" "$tgz_name"; then
    fetch "$(gh_url "$base/$tgz_name.sha256sum")" "$sum"
    fetch "$(gh_url "$base/$tgz_name")" "$A_CONTAINERD_TGZ"
    sha256_ok "$A_CONTAINERD_TGZ" "$sum" "$tgz_name"
  fi
  # systemd 单元文件跟随版本 tag(修复原脚本从 main 分支取文件的漂移问题)
  [[ -s $A_CONTAINERD_SVC ]] \
    || fetch "$(gh_url "https://raw.githubusercontent.com/containerd/containerd/$CONTAINERD_V/containerd.service")" "$A_CONTAINERD_SVC"
  grep -q '\[Service\]' "$A_CONTAINERD_SVC"
}

dl_crictl() {
  local base="https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_V"
  local tgz_name; tgz_name=$(basename "$A_CRICTL_TGZ")
  local sum="$A_CRICTL_TGZ.sha256"
  if [[ -f $A_CRICTL_TGZ && -f $sum ]] && sha256_ok "$A_CRICTL_TGZ" "$sum" "$tgz_name"; then return 0; fi
  fetch "$(gh_url "$base/$tgz_name.sha256")" "$sum"
  fetch "$(gh_url "$base/$tgz_name")" "$A_CRICTL_TGZ"
  sha256_ok "$A_CRICTL_TGZ" "$sum" "$tgz_name"
}

dl_cilium_cli() {
  local base="https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_V"
  local tgz_name; tgz_name=$(basename "$A_CILIUM_CLI_TGZ")
  local sum="$A_CILIUM_CLI_TGZ.sha256sum"
  if [[ -f $A_CILIUM_CLI_TGZ && -f $sum ]] && sha256_ok "$A_CILIUM_CLI_TGZ" "$sum" "$tgz_name"; then return 0; fi
  fetch "$(gh_url "$base/$tgz_name.sha256sum")" "$sum"
  fetch "$(gh_url "$base/$tgz_name")" "$A_CILIUM_CLI_TGZ"
  sha256_ok "$A_CILIUM_CLI_TGZ" "$sum" "$tgz_name"
}

dl_helm() {
  # helm 官方分发走 get.helm.sh(非 GitHub, 不套 GITHUB_PROXY)
  local tgz_name; tgz_name=$(basename "$A_HELM_TGZ")
  local sum="$A_HELM_TGZ.sha256sum"
  if [[ -f $A_HELM_TGZ && -f $sum ]] && sha256_ok "$A_HELM_TGZ" "$sum" "$tgz_name"; then return 0; fi
  fetch "https://get.helm.sh/$tgz_name.sha256sum" "$sum"
  fetch "https://get.helm.sh/$tgz_name" "$A_HELM_TGZ"
  sha256_ok "$A_HELM_TGZ" "$sum" "$tgz_name"
}

dl_gateway_api() {
  [[ -s $A_GWAPI_YAML ]] && grep -q 'kind: CustomResourceDefinition' "$A_GWAPI_YAML" && return 0
  fetch "$(gh_url "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_V/standard-install.yaml")" \
    "$A_GWAPI_YAML"
  grep -q 'kind: CustomResourceDefinition' "$A_GWAPI_YAML"
}

# --- 并行调度 -----------------------------------------------------------------
declare -A JOB_PID=() JOB_LOG=()
start_job() {
  local name=$1; shift
  local logf="$LOG_DIR/dl-$name.log"
  : > "$logf"
  ( "$@" ) >>"$logf" 2>&1 &
  JOB_PID[$name]=$!
  JOB_LOG[$name]=$logf
  log_info "并行下载启动: $name"
}

main() {
  stage_begin "30-download" "工件并行下载"
  rm -f "$COMPLETE_MARK"

  ensure_versions
  print_versions

  start_job runc        dl_runc
  start_job containerd  dl_containerd
  start_job crictl      dl_crictl
  # cilium-cli / helm / Gateway API 是控制面(集群管理)专属, worker 不下载
  if is_control_plane; then
    start_job cilium-cli  dl_cilium_cli
    start_job helm        dl_helm
    [[ $CILIUM_ENABLE_GATEWAY_API == true ]] && start_job gateway-api dl_gateway_api
  fi

  local name failed=()
  for name in "${!JOB_PID[@]}"; do
    if wait "${JOB_PID[$name]}"; then
      log_ok "工件就绪: $name"
    else
      failed+=("$name")
      log_error "下载失败: $name (日志: ${JOB_LOG[$name]})"
      tail -n 5 "${JOB_LOG[$name]}" >&2 || true
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    die "以下工件下载失败: ${failed[*]} — 可设置 PROXY_URL/GITHUB_PROXY 后重跑本阶段(已完成的会跳过)"
  fi

  touch "$COMPLETE_MARK"
  stage_end
}
main "$@"
