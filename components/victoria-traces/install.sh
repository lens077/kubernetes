#!/usr/bin/env bash
# VictoriaTraces —— 链路后端(OTel Collector 直写 OTLP; Grafana 用 jaeger 数据源读); 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (保留 ${VT_RETENTION}, 磁盘上限 ${VT_DISK_CAP}, PVC ${VT_STORAGE_SIZE}/${SC_NAME})"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version "$CHART_VERSION"
routes_apply "$DIR"
log_ok "$ID 安装完成"
log_info "  OTLP 写入: http://victoria-traces.$NAMESPACE.svc.cluster.local:10428/insert/opentelemetry/v1/traces"
log_info "  Jaeger 兼容查询(Grafana jaeger 数据源用): http://victoria-traces.$NAMESPACE.svc.cluster.local:10428/select/jaeger"
log_info "  UI: https://$HOSTNAME/select/vmui"
