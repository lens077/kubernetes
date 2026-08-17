# jaeger —— 分布式链路追踪（v2 all-in-one + badger）

## 1. 定位

trace 的存储与查询。[opentelemetry](../opentelemetry/) Collector 的 traces pipeline
往这里导出（`jaeger.observability.svc:4317`），[grafana](../grafana/) 把它当 trace 数据源。

存储后端是 **badger + 本地 PVC**，不依赖 Elasticsearch。

## 2. 上游最佳实践

来源：[Jaeger v2 文档](https://www.jaegertracing.io/docs/2.0/)

- all-in-one 形态（collector + query + storage 一个进程）适合单机与开发环境；
  生产的 collector/query 分离是为了独立扩容。
- 存储后端按规模选：内存（调试）→ badger（单机持久化）→ Cassandra/Elasticsearch（生产集群）。
- badger 用 TTL 自动过期，不需要额外的索引清理 CronJob（ES 后端才需要 esIndexCleaner）。
- 应用不要直连 Jaeger，统一推给 OTel Collector，由 Collector 做批处理与多后端分发。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Helm chart 安装 | **手写 manifests** | chart 没有 volume 钩子（badger 要挂 PVC），Helm 4 的 post-renderer 又有静默降级风险。手写清单还能把「为什么这么配」的注释留在文件里。详见 `manifests/README.md`。 |
| Elasticsearch 后端 | **badger + 本地 PVC** | ES 迁移前 7 天的 span 索引合计约 17MB —— 为这点数据养一个 ES 集群不划算。badger 的 value log 单文件上限约 1GB，5Gi 有两个数量级余量。 |
| 无状态 Jaeger（存储在外部） | 接受**节点绑定** | OpenEBS LVM 是本地卷 + WaitForFirstConsumer，PVC 一绑定 Jaeger 就钉在那个节点上，节点故障时 Pod 无法漂移。trace 属可丢数据，判断为可接受。 |
| ES 的 esIndexCleaner 7 天 | badger `ttl.spans: 168h` | 语义对齐，少一个 CronJob。 |

## 4. 暴露方式

- 集群内 OTLP 接收：`jaeger.observability.svc.cluster.local:4317`（gRPC）/ `:4318`（HTTP）
- UI：`https://jaeger.app.com`（共享网关，`gateway/httproute.yaml`）
- 集群外应用直接上报：见 `examples/otlp-grpcroute.yaml`，**但要先开 Cilium 的 ALPN**（见踩坑）

## 5. 验证

真验证（打一条 span 再从 API 查回来）：

```bash
TS=$(date +%s)000000000
kubectl -n observability run trace-probe --rm --restart=Never --image=curlimages/curl:latest -- \
  curl -s -o /dev/null -w "%{http_code}\n" -X POST -H 'Content-Type: application/json' \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"probe\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"5b8efff798038103d269b633813fc60c\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"probe\",\"kind\":1,\"startTimeUnixNano\":\"$TS\",\"endTimeUnixNano\":\"$TS\"}]}]}]}" \
  http://jaeger.observability.svc.cluster.local:4318/v1/traces

kubectl -n observability exec deploy/jaeger -- wget -qO- http://127.0.0.1:16686/api/services
# 期望输出里包含 "probe"
```

端到端（经 OTel Collector）由 `bootstrap/scripts/90-verify.sh` 的可观测冒烟覆盖。

## 6. 踩坑

- **GRPCRoute 显示 Accepted 但从来不生效**：Cilium 默认 `enable-gateway-api-alpn=false`，
  gRPC 需要的 h2 无法经 ALPN 协商。旧集群那条 `jaeger-grpc-route` 存活 55 天、`status`
  始终为空，除 ALPN 外还叠了 4 处不相容：Gateway 命名空间（`default` vs `observability`）、
  listener 名（`sectionName: tls` vs 实际的 `https`）、hostname 与 listener 限定不符、
  `allowedRoutes.from: Same` 挡住跨命名空间。现在共享网关用 `from: All` 消除了最后一条。
- **改了 ConfigMap 但没生效**：不再由 Helm 管理，改配置**不会**自动重启 Pod。
  `install.sh` 里已经在 apply 后 `rollout restart`；手动改的话记得自己重启。
- **`ephemeral: true` 时 badger 忽略 directories**：会改用临时目录，PVC 挂了等于白挂，
  重启即丢数据。必须 `ephemeral: false`。

## 变更记录

**2026-08-17：迁入组件契约。** manifests 里的 `openebs-lvmpv` / `5Gi` 改为
`${SC_NAME}` / `${JAEGER_STORAGE_SIZE}` 占位符，由 `install.sh` 渲染；
路由从 `gateway/` 改挂共享网关 `default/cilium-gateway`。

**2026-08-06：存储后端从 Elasticsearch 迁移到 badger，同时弃用 Helm。**
ES 中遗留的 `ecommerce-jaeger-*` 索引已删除；ES 本身保留（还有业务索引与 Kibana）。
otel-collector 无需改动——它只与 Jaeger 的 Service 通信，不接触存储后端。

**2026-08-06：清理失效的 `jaeger-grpc-route`。** 详见上方「踩坑」。
