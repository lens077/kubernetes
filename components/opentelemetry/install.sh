#!/usr/bin/env bash
# =============================================================================
# OpenTelemetry Collector —— exporters/pipelines 按"集群里实际装了哪些后端"生成
#   幂等; 可单独执行: bash components/opentelemetry/install.sh
#
# 为什么要动态: 三条 pipeline 各自依赖一个后端。后端没装却写了 exporter, collector
# 启动后会一直重试报错; 后端装了却没写, 数据就直接丢了。查集群而不是查选择清单 ——
# 这样单独执行时也判断正确。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

VM_SVC="vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428"
LOKI_SVC="loki.logging.svc.cluster.local:3100"
JAEGER_SVC="jaeger.observability.svc.cluster.local"

exporters="" pipelines="" signals=()

if comp_installed victoriametrics vm-single-victoria-metrics-single-server; then
  exporters+="    otlp_http/victoriametrics:
      compression: gzip
      encoding: proto
      metrics_endpoint: http://$VM_SVC/opentelemetry/v1/metrics
      tls:
        insecure: true
"
  # prometheus receiver 抓 collector 自身的 8888(chart 默认生成了它却没挂进任何
  # pipeline, 等于死配置) —— 挂上后 otelcol_* 自观测指标才会进后端, 队列积压才看得见。
  # k8s_cluster 由 clusterMetrics preset 自动追加, 不用写。
  pipelines+="      metrics:
        receivers: [otlp, prometheus]
        processors: [delta_to_cumulative]
        exporters: [otlp_http/victoriametrics]
"
  signals+=("metrics→VictoriaMetrics")
fi

if comp_installed logging loki; then
  # Loki 3.x 原生 OTLP 摄入端点(应用侧 otelzap 推的日志走这条; 容器日志仍归 fluent-bit)
  exporters+="    otlp_http/loki:
      endpoint: http://$LOKI_SVC/otlp
      tls:
        insecure: true
"
  pipelines+="      logs:
        receivers: [otlp]
        processors: []
        exporters: [otlp_http/loki]
"
  signals+=("logs→Loki")
fi

if comp_installed observability jaeger; then
  exporters+="    otlp_grpc/jaeger:
      endpoint: $JAEGER_SVC:4317
      tls:
        insecure: true
"
  pipelines+="      traces:
        receivers: [otlp]
        processors: []
        exporters: [otlp_grpc/jaeger]
"
  signals+=("traces→Jaeger")
fi

if [[ -z $exporters ]]; then
  log_warn "集群里没有任何观测后端(victoriametrics/loki/jaeger), 跳过 $ID"
  log_warn "  装完后端后重跑本脚本即可补上对应 pipeline"
  exit 0
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (${signals[*]})"

# 组件名用新命名(otlp_http/otlp_grpc/delta_to_cumulative): 旧别名在 collector 0.130+
# 每次启动刷 deprecation warn; 新名自 0.130 起可用
dyn=$(mktemp)
cat > "$dyn" <<EOF
config:
  exporters:
$exporters
  service:
    pipelines:
$pipelines
EOF

helm_install_component "$DIR" -f "$dyn"
rm -f "$dyn"

log_ok "$ID 安装完成(应用把 OTLP 推到 otel-opentelemetry-collector.$NAMESPACE.svc:4317/4318)"
