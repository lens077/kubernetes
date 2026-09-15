#!/usr/bin/env bash
# =============================================================================
# OpenTelemetry Node Agent —— DaemonSet，只采主机指标
#   幂等; 可单独执行: bash components/opentelemetry-node/install.sh
#
# 与 components/opentelemetry 的分工:
#   - 那份是 Deployment, 收集群内应用的 OTLP + k8s_cluster + Prometheus 抓取;
#   - 这份是 DaemonSet, 只跑 hostmetrics, 每个节点一份。
# 两者各自把 metrics 推到同一个远端入口, 不互相接收。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

VM_SVC="vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428"
REMOTE_METRICS_URL="${REMOTE_METRICS_URL:-}"

# 出口与 opentelemetry 组件同构: 设了 REMOTE_METRICS_URL 就推远端, 否则回退集群内 VM。
if [[ -n $REMOTE_METRICS_URL ]]; then
  exporter_name="otlp_http/remote_metrics"
  exporter_block="    $exporter_name:
      compression: gzip
      encoding: proto
      metrics_endpoint: $REMOTE_METRICS_URL
      timeout: 15s
      retry_on_failure:
        enabled: true
        max_elapsed_time: 5m
      sending_queue:
        enabled: true
        num_consumers: 2
        queue_size: 1000
"
  signal="hostmetrics→远端($REMOTE_METRICS_URL)"
elif comp_installed victoriametrics vm-single-victoria-metrics-single-server; then
  exporter_name="otlp_http/victoriametrics"
  exporter_block="    $exporter_name:
      compression: gzip
      encoding: proto
      metrics_endpoint: http://$VM_SVC/opentelemetry/v1/metrics
      tls:
        insecure: true
"
  signal="hostmetrics→VictoriaMetrics"
else
  log_warn "没有可用的指标后端(未设 REMOTE_METRICS_URL 且集群内无 victoriametrics), 跳过 $ID"
  exit 0
fi

log_step "安装 $ID → 命名空间 $NAMESPACE ($signal)"

# receivers 里只写 hostmetrics: chart 的 hostMetrics preset 会把它注入进来。
# 其余 receiver(otlp/jaeger/zipkin)不进 pipeline 就不会被实例化, 也就不会监听端口。
dyn=$(mktemp)
cat > "$dyn" <<EOF
config:
  exporters:
$exporter_block
  service:
    pipelines:
      metrics:
        receivers: [hostmetrics]
        processors: [memory_limiter, resource/node, batch]
        exporters: [$exporter_name]
      logs: null
      traces: null
EOF

helm_install_component "$DIR" --version "$CHART_VERSION" -f "$dyn"
rm -f "$dyn"

log_ok "$ID 安装完成(每节点一份, 只推主机指标; 应用侧 OTLP 仍走 opentelemetry 组件)"
