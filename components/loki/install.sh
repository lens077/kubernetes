#!/usr/bin/env bash
# =============================================================================
# Loki 单体模式 —— 日志后端; 幂等; 可单独执行:
#   bash components/loki/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (保留 ${LOKI_RETENTION} / 存储 ${LOKI_STORAGE_SIZE})"
helm_install_component "$DIR"
routes_apply "$DIR"

log_ok "$ID 安装完成(OTLP 摄入: http://loki.$NAMESPACE.svc.cluster.local:3100/otlp; fluent-bit 输出示例见 examples/)"
