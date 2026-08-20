#!/usr/bin/env bash
# Argo Rollouts —— 金丝雀控制器（选型定稿 §9）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 2.41.1
log_ok "$ID 安装完成(验证: kubectl apply -f examples/rollout-demo.yaml)"
