#!/usr/bin/env bash
# =============================================================================
# OpenTelemetry Collector —— exporters/pipelines 按"集群里实际装了哪些后端"生成
#   幂等; 可单独执行: bash components/opentelemetry/install.sh
#
# 为什么要动态: 三条 pipeline 各自依赖一个后端。后端没装却写了 exporter, collector
# 启动后会一直重试报错; 后端装了却没写, 数据就直接丢了。查集群而不是查选择清单 ——
# 这样单独执行时也判断正确。
# 后端优先级(2026-09-03): metrics→victoriametrics; logs→victoria-logs > loki;
# traces→victoria-traces > jaeger。三条都可被 REMOTE_*_URL 覆盖为远端。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

# 动态配置分支使用 += 组装；显式初始化，保证「无远端且无本地后端」时能走跳过分支。
exporters=""
pipelines=""
signals=()

VM_SVC="vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428"
LOKI_SVC="loki.logging.svc.cluster.local:3100"
JAEGER_SVC="jaeger.observability.svc.cluster.local"
VL_SVC="vl-victoria-logs-single-server.logging.svc.cluster.local:9428"
VT_SVC="victoria-traces.observability.svc.cluster.local:10428"

# 远端观测后端(node3 Pigsty, 经 node1 的 Pangolin 公网入口)。
#
# 为什么做成开关而不是写死: 三条信号各自可以独立地"推远端"或"落本地"。设了对应的
# REMOTE_*_URL 就改推远端并**跳过本地后端**(这正是把观测负载挪出内网的意义 ——
# 双写只会让内网多扛一份)。没设就退回原来的集群内后端, 与本脚本原有行为一致。
#
# 路径不能省: VictoriaLogs / VictoriaTraces 的 OTLP 摄入路径带 /insert 前缀,
# 用 otlphttp 的 endpoint 会被自动补成 /v1/logs 而 404 —— 必须用
# logs_endpoint / traces_endpoint 给全路径。实测 node3-traces 上不带 /insert 的
# /opentelemetry/v1/traces 返回 400, 带 /insert 的返回 200。
REMOTE_METRICS_URL="${REMOTE_METRICS_URL:-}"
REMOTE_LOGS_URL="${REMOTE_LOGS_URL:-}"
REMOTE_TRACES_URL="${REMOTE_TRACES_URL:-}"

if [[ -n $REMOTE_METRICS_URL ]]; then
  exporters+="    otlp_http/remote_metrics:
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
  pipelines+="      metrics:
        receivers: [otlp, prometheus, prometheus/cilium]
        processors: [memory_limiter, delta_to_cumulative, batch]
        exporters: [otlp_http/remote_metrics]
"
  signals+=("metrics→远端($REMOTE_METRICS_URL)")
elif comp_installed victoriametrics vm-single-victoria-metrics-single-server; then
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
        receivers: [otlp, prometheus, prometheus/cilium]
        processors: [memory_limiter, delta_to_cumulative, batch]
        exporters: [otlp_http/victoriametrics]
"
  signals+=("metrics→VictoriaMetrics")
fi

if [[ -n $REMOTE_LOGS_URL ]]; then
  exporters+="    otlp_http/remote_logs:
      compression: gzip
      encoding: proto
      logs_endpoint: $REMOTE_LOGS_URL
      timeout: 15s
      retry_on_failure:
        enabled: true
        max_elapsed_time: 5m
      sending_queue:
        enabled: true
        num_consumers: 2
        queue_size: 1000
"
  pipelines+="      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_http/remote_logs]
"
  signals+=("logs→远端($REMOTE_LOGS_URL)")
elif comp_installed logging vl-victoria-logs-single-server; then
  # VictoriaLogs 原生 OTLP 摄入(路径带 /insert 前缀, 必须用 logs_endpoint 给全路径)。
  # 2026-09-03 起是日志主后端(Loki 退为次选); 容器日志由 Vector 直写 VL, 这里只承载应用侧 OTLP 日志与 K8s Event。
  exporters+="    otlp_http/victorialogs:
      compression: gzip
      encoding: proto
      logs_endpoint: http://$VL_SVC/insert/opentelemetry/v1/logs
      tls:
        insecure: true
"
  pipelines+="      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_http/victorialogs]
"
  signals+=("logs→VictoriaLogs")
elif comp_installed logging loki; then
  # Loki 3.x 原生 OTLP 摄入端点(应用侧 otelzap 推的日志走这条; 容器日志仍归 fluent-bit)
  exporters+="    otlp_http/loki:
      endpoint: http://$LOKI_SVC/otlp
      tls:
        insecure: true
"
  pipelines+="      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_http/loki]
"
  signals+=("logs→Loki")
fi

if [[ -n $REMOTE_TRACES_URL ]]; then
  exporters+="    otlp_http/remote_traces:
      compression: gzip
      encoding: proto
      traces_endpoint: $REMOTE_TRACES_URL
      timeout: 15s
      retry_on_failure:
        enabled: true
        max_elapsed_time: 5m
      sending_queue:
        enabled: true
        num_consumers: 2
        queue_size: 1000
"
  pipelines+="      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_http/remote_traces]
"
  signals+=("traces→远端($REMOTE_TRACES_URL)")
elif comp_installed observability victoria-traces; then
  # VictoriaTraces 原生 OTLP 摄入(同样带 /insert 前缀); Grafana 走 jaeger 数据源读 /select/jaeger
  exporters+="    otlp_http/victoriatraces:
      compression: gzip
      encoding: proto
      traces_endpoint: http://$VT_SVC/insert/opentelemetry/v1/traces
      tls:
        insecure: true
"
  pipelines+="      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_http/victoriatraces]
"
  signals+=("traces→VictoriaTraces")
elif comp_installed observability jaeger; then
  exporters+="    otlp_grpc/jaeger:
      endpoint: $JAEGER_SVC:4317
      tls:
        insecure: true
"
  pipelines+="      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp_grpc/jaeger]
"
  signals+=("traces→Jaeger")
fi

if [[ -z $exporters ]]; then
  log_warn "集群里没有任何观测后端(victoriametrics/victoria-logs/loki/victoria-traces/jaeger), 跳过 $ID"
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

helm_install_component "$DIR" --version "$CHART_VERSION" -f "$dyn"
rm -f "$dyn"

log_ok "$ID 安装完成(应用把 OTLP 推到 otel-opentelemetry-collector.$NAMESPACE.svc:4317/4318)"
