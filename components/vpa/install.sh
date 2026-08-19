#!/usr/bin/env bash
# =============================================================================
# VPA(只装 recommender, 出推荐值不自动改) —— 幂等; 可单独执行:
#   bash components/vpa/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed kube-system metrics-server \
  || log_warn "metrics-server 未就绪: recommender 拿不到实时用量, 推荐值会一直为空"

log_step "安装 $ID(仅 recommender) → 命名空间 $NAMESPACE"

# ⚠️ chart 不会随 helm upgrade 更新 CRD(helm 的既定行为)。首装由 chart 建, 升级换版本时
# 需手动 apply 新 CRD:
#   kubectl apply --server-side -f \
#     https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-<ver>/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml
helm_install_component "$DIR" --version "${VPA_CHART_VERSION:-0.11.0}"

log_ok "$ID 安装完成(挂 VPA CR 后用 kubectl describe vpa <名字> 看推荐值)"
log_info "示例: kubectl apply -f $DIR/examples/vpa-off-mode.yaml"
