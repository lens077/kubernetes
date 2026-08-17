# opentelemetry —— 遥测数据的统一入口（Collector）

## 1. 定位

集群里唯一的 OTLP 接收端。应用只需要把 metrics/logs/traces 推到
`otel-opentelemetry-collector.opentelemetry.svc:4317`，由 Collector 分发到三个后端：

| 信号 | 后端 | 端点 |
|---|---|---|
| metrics | [victoriametrics](../victoriametrics/) | `/opentelemetry/v1/metrics` |
| logs | [loki](../loki/) | `/otlp` |
| traces | [jaeger](../jaeger/) | `:4317` gRPC |

后端换了（比如 Loki 换成别的），只改 Collector 的 exporter，**应用侧零改动**——
这正是中间加一层 Collector 的意义。

## 2. 上游最佳实践

来源：[OpenTelemetry Collector 文档](https://opentelemetry.io/docs/collector/)

- Agent（DaemonSet）+ Gateway（Deployment）两层是大集群的推荐形态；小集群一层就够。
- 生产必配 `memory_limiter` 与 `batch` processor，防止后端抖动时把 Collector 撑爆。
- 组件名 v0.130 起改用 `otlp_http` / `otlp_grpc` / `delta_to_cumulative`，
  旧别名（`otlphttp` / `otlp` / `deltatocumulative`）**每次启动都会刷 deprecation warn**。
- Collector 自身的指标在 `:8888`，应该抓进后端做自观测（队列积压、丢点数）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Agent + Gateway 两层 | **单层 Deployment** | 两节点，一层足够；两层要多一个 DaemonSet 的常驻内存。 |
| `logsCollection` preset | **关闭** | 容器日志由集群里已有的 fluent-bit 采集，开了就是双份（存储翻倍、标签还不一致）。 |
| exporters 写死在 values | **按集群实况动态生成** | 后端没装却写了 exporter，Collector 会一直重试报错；后端装了却没写，数据直接丢。`install.sh` 查集群里的 Service 来决定，单独执行时也判断正确。 |
| chart 默认不挂 prometheus receiver | **挂进 metrics pipeline** | chart 生成了这个 receiver 却没挂进任何 pipeline，等于死配置。挂上之后 `otelcol_*` 自观测指标才会进 VM——队列积压、发送失败数才看得见。 |

## 4. 暴露方式

不对外暴露。集群内 OTLP：`otel-opentelemetry-collector.opentelemetry.svc.cluster.local`
的 `4317`（gRPC）/ `4318`（HTTP）。

集群外应用要直接上报的话见 [`../jaeger/examples/otlp-grpcroute.yaml`](../jaeger/examples/otlp-grpcroute.yaml)
（注意 Cilium 的 ALPN 开关）。

## 5. 验证

真验证（三条 pipeline 各打一条真数据再回查）由 `bootstrap/scripts/90-verify.sh` 的
`smoke_observability` 覆盖，也可以单独跑：

```bash
sudo bash bootstrap/start.sh --only 90-verify
```

它会往 4318 打 OTLP 指标/日志/链路，再分别从 VM / Loki / Jaeger 查回来，
只校验**实际启用**的后端。

快速自查：

```bash
kubectl -n opentelemetry logs deploy/otel-opentelemetry-collector | grep -ciE '"error"'   # 应为 0
kubectl -n victoriametrics exec vm-single-victoria-metrics-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=count({__name__=~"otelcol_.*"})'
```

## 6. 踩坑

- **启动时刷一屏 `connection refused` / `no such host`**：Collector 与后端同批部署时，
  它先起来、后端还没就绪。retry_sender 会自动恢复，日志停了就说明好了 ——
  光看日志分不清「已自愈的历史噪声」和「至今没通」，所以才有打点→回查的冒烟测试。
- **`otlphttp` 别名的 deprecation warn**：改用 `otlp_http`（本组件已经改了）。
- **只剩一条 warn 去不掉**（`Using legacy service.telemetry.resource inline map format`）：
  来自 chart 自己生成的默认值，不是我们的 values。chart 用 `mustMergeOverwrite` 合并，
  null 删不掉键，硬改反而会出一个 map + array 并存的畸形配置。等上游修。
- **VM 里查不到刚推的指标**：VM 默认 `-search.latencyOffset=30s`，等 30s 再查。
