#!/usr/bin/env bash
# =============================================================================
# VictoriaMetrics single —— 指标后端; 幂等; 可单独执行:
#   bash components/victoriametrics/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${VM_STORAGE_SIZE} / SC ${SC_NAME})"
helm_install_component "$DIR"
routes_apply "$DIR"

log_ok "$ID 安装完成(OTLP 写入端点: http://vm-single-victoria-metrics-single-server.$NAMESPACE.svc.cluster.local:8428/opentelemetry/v1/metrics)"
