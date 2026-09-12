# OpenTelemetry Collector：集群遥测入口

## 1. 定位

集群内应用把 OTLP 数据发送到 `otel-opentelemetry-collector.opentelemetry.svc:4317/4318`。Collector 当前将三类信号写入 node3 的 Victoria 后端：

| 信号 | 远端入口 | 后端 |
|---|---|---|
| metrics | `metrics.apikv.com/opentelemetry/v1/metrics`（**只有 http**） | VictoriaMetrics |
| logs | `node3-logs.apikv.com/insert/opentelemetry/v1/logs` | VictoriaLogs |
| traces | `node3-traces.apikv.com/insert/opentelemetry/v1/traces` | VictoriaTraces |

⚠️ metrics 的域名 2026-08-29 由 `node3-metrics.apikv.com` 改名为 `metrics.apikv.com`，且新资源在 Pangolin 上没配 TLS（`https://metrics.apikv.com` 返回 404）。改名当天这里没同步，collector 对旧域名拿到 404，持续 `Exporting failed. Dropping data.`——**指标链路静默断了，logs/traces 不受影响**。改这三个域名时务必回来同步本表与 `component.env`。

三个 `REMOTE_*_URL` 在 [`component.env`](component.env) 中独立配置。某项未设置时，`install.sh` 才检查集群内对应后端并回退；设置远端后不双写本地，避免观测存储负载留在集群内。

容器 stdout 不走此 Collector，由 Vector DaemonSet 直接写 VictoriaLogs。必须区分应用 OTLP logs、Kubernetes Event 和容器 stdout 三条链。

## 2. 上游最佳实践

来源：[OpenTelemetry Collector 文档](https://opentelemetry.io/docs/collector/)。

- Agent（DaemonSet）+ Gateway（Deployment）适合大集群；当前小集群使用单层 Deployment。
- 生产必须启用 `memory_limiter` 与 `batch`，防止后端抖动时撑爆 Collector。
- exporter 使用有界 sending queue、超时和 retry；队列耗尽后仍会丢数据，因此 Collector 与远端后端都要监控。
- 组件名使用 `otlp_http`、`otlp_grpc`、`delta_to_cumulative`。旧别名会产生 deprecation warning。
- Collector 自身指标位于 `:8888`，必须写入指标后端做自观测。

## 3. 本集群取舍

| 上游默认或建议 | 本集群 | 原因 |
|---|---|---|
| Agent + Gateway 两层 | 单层 Deployment | 3 节点小集群，一层足够；少一个常驻 DaemonSet。 |
| `logsCollection` preset | 关闭 | 容器日志由 Vector 采集，开启会重复写入。 |
| exporters 写死在 values | `install.sh` 动态生成 | 三类信号可独立选择远端或集群内回退，未部署的后端不会产生无效重试。 |
| chart 自带 `prometheus` receiver | 保留，只抓 Collector `:8888` | 这是 Collector 自观测，不是 Kubernetes Pod discovery。 |
| 平台安全指标 | 独立 `prometheus/cilium` receiver | 精确发现 Cilium agent/operator、Hubble metrics 与 Vector security exporter，不泛抓其他 Pod。 |

`clusterMetrics` preset 提供 `k8s_cluster` receiver；`kubernetesEvents` preset 提供 Kubernetes Event receiver。它们不抓 Pod `/metrics`，不能替代 Prometheus discovery。

## 4. 平台安全指标 discovery

[`values.yaml`](values.yaml) 在一个受限 receiver 中创建四个 scrape job：

- `cilium-agent`：保留 `k8s-app=cilium`、phase 为 Running、端口名为 `prometheus` 的 Pod target；
- `cilium-operator`：保留 `name=cilium-operator`、phase 为 Running、端口名为 `prometheus` 的 Pod target；
- `hubble`：保留 `k8s-app=cilium`、phase 为 Running、端口名为 `hubble-metrics` 的 Pod target；
- `vector-security`：只发现 `logging` namespace、`app.kubernetes.io/name=vector` 的 Running Pod，并把 Pod IP 定向到 exporter `:9598`；Vector 的 ingress NetworkPolicy 只允许本 Collector identity 访问该端口。

Cilium agent/operator 每 30 秒抓取；Hubble 与 Vector security 每 15 秒抓取；全部超时 10 秒。前三个 job 限制在 `kube-system`，第四个限制在 `logging`，不会泛抓业务 Pod 或 Envoy `:9964`。

现有 chart ClusterRole 已为 `k8s_cluster`/Kubernetes Event 提供 `pods get/list/watch`，同一权限足够 Pod discovery，不需要新增写权限或 cluster-admin。

必须确认以下指标已经写入 VictoriaMetrics：

```text
cilium_bpf_map_pressure
cilium_controllers_failing
cilium_errors_warnings_total
cilium_drop_count_total
cilium_endpoint_regeneration_time_stats_seconds
cilium_api_limiter_processed_requests_total
hubble_drop_total
hubble_flows_processed_total
ecommerce_tetragon_security_events_total
```

这些指标的运维含义、机器相关参数和 24 小时基线手顺见 [`../../bootstrap/CILIUM.md`](../../bootstrap/CILIUM.md)。

## 5. 暴露方式

Collector 不对公网暴露。集群内 OTLP 地址：

```text
otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4317  # gRPC
otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4318  # HTTP
```

远端 Victoria 写入口由 Pangolin/Traefik 暴露，只用于 Collector/Vector 写入。读取路径受 Pangolin SSO 保护。

## 6. 部署与验证

直接执行组件安装器会应用当前 values；无需重跑整个 80 阶段：

```bash
bash components/opentelemetry/install.sh
kubectl -n opentelemetry rollout status deploy/otel-opentelemetry-collector --timeout=180s
```

确认最终配置包含 Cilium、Hubble 与 Vector security job：

```bash
kubectl -n opentelemetry get cm otel-opentelemetry-collector \
  -o jsonpath='{.data.relay}' | sed -n '/prometheus\/cilium:/,/zipkin:/p'
```

确认 Collector 没有持续 exporter/scrape 错误：

```bash
kubectl -n opentelemetry logs deploy/otel-opentelemetry-collector --since=10m \
  | grep -iE 'error|warn|fail|drop'
```

公网读路径会被 SSO 重定向。通过 node3 本机 VictoriaMetrics 查询落库：

```bash
ssh node3 'python3 - <<"PY"
import json, urllib.parse, urllib.request
for metric in (
    "cilium_bpf_map_pressure",
    "cilium_controllers_failing",
    "cilium_errors_warnings_total",
    "cilium_drop_count_total",
    "cilium_endpoint_regeneration_time_stats_seconds_count",
    "cilium_api_limiter_processed_requests_total",
    "hubble_drop_total",
    "hubble_flows_processed_total",
    "ecommerce_tetragon_security_events_total",
):
    query = f"count({metric})"
    url = "http://127.0.0.1:8428/api/v1/query?" + urllib.parse.urlencode({"query": query})
    result = json.load(urllib.request.urlopen(url, timeout=5))["data"]["result"]
    print(metric, result)
PY'
```

成功判据是查询结果非空，并且单条样本带 `k8s_node_name`、`k8s_pod_name`、`service_name` 等 target 标签。

⚠️ **查 VM 时标签名是下划线，不是点号**：node3 的 VictoriaMetrics 启动带 `-opentelemetry.usePrometheusNaming=true`〔实测 2026-09-01〕。本组件配置里写的 `k8s.node.name` 是**摄入前的 OTel 属性名**（那里点号是对的），VM 落库时会转成下划线。两者不矛盾，但查询用错口径会返回空结果**且不报错**。

## 7. 故障排查

- **HTTP 500/502 或 connection refused**：先检查 node3/Pangolin 远端，不要只重启 Collector。队列打满后的 dropped items 无法追回。
- **配置里有 receiver，但 VictoriaMetrics 没数据**：依次验证 Pod discovery、Collector 日志、远端写入口和 node3 本机查询。「配置存在」不算落库成功。
- **只有 Collector 自身指标**：chart 的 `prometheus` receiver 只抓 `:8888`。确认 metrics pipeline 同时包含 `prometheus/cilium`。
- **Collector 与后端同批启动时短暂连接失败**：retry 会恢复；必须查看近期日志和后端新样本，不能用历史错误判断当前仍故障。
- **`Using legacy service.telemetry.resource inline map format`**：来自 chart 生成的默认值；当前不影响采集。
- **`k8sobjects` alias deprecated**：`kubernetesEvents.useK8sEventsReceiver=false` 仍使用已验证的旧 receiver。迁移到新 receiver 前先离线渲染并验证 Event 落库。
