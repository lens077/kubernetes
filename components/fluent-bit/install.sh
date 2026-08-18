#!/usr/bin/env bash
# =============================================================================
# Fluent Bit —— Kubernetes 容器日志采集器；幂等；可单独执行：
#   bash components/fluent-bit/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed logging loki \
  || die "Loki 尚未安装：先执行 components/loki/install.sh，或由 80-components 按依赖安装"

ver=${FLUENT_BIT_CHART_VERSION:-0.58.1}
log_step "安装 $ID → 命名空间 $NAMESPACE (chart $ver / 输出 Loki)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version "$ver"

log_ok "$ID 安装完成(日志输出: http://loki.$NAMESPACE.svc.cluster.local:3100/loki/api/v1/push)"
