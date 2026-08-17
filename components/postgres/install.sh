#!/usr/bin/env bash
# =============================================================================
# CloudNativePG 算子 —— 只装算子; 数据库实例由用户按需 apply(规格差异大)
#   幂等; 可单独执行: bash components/postgres/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID(CloudNativePG 算子) → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

log_ok "$ID 算子安装完成"
log_info "建库: kubectl create ns postgresql && kubectl apply -f $DIR/examples/pg-cluster.yaml"
log_info "对外暴露(TLS passthrough + SNI 分流): 见 $DIR/gateway/README 里的说明"
