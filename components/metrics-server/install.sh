#!/usr/bin/env bash
# =============================================================================
# metrics-server —— 幂等; 可被 80-components.sh 调用, 也可单独执行:
#   bash components/metrics-server/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

log_ok "$ID 安装完成(验证: kubectl top nodes)"
