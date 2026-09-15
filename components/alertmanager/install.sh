#!/usr/bin/env bash
# Alertmanager —— 告警路由; 幂等; 可单独执行: bash components/alertmanager/install.sh
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed observability alert-bridge \
  || log_warn "alert-bridge 尚未安装: Alertmanager 的 webhook 会持续失败重试, 直到桥装上(bash components/alert-bridge/install.sh)"

log_step "安装 $ID → 命名空间 $NAMESPACE (receiver=alert-bridge, PVC ${ALERTMANAGER_STORAGE_SIZE}/${SC_NAME})"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version "$CHART_VERSION"
routes_apply "$DIR"
log_ok "$ID 安装完成"
log_info "  vmalert notifier: http://alertmanager.$NAMESPACE.svc.cluster.local:9093"
log_info "  UI: https://$HOSTNAME  (静默在这里做, 不要改规则去消音)"
