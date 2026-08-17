# Jaeger

Jaeger v2(all-in-one)部署在 `observability` 命名空间,存储后端为 **badger + 本地 PVC**。

| 目录 | 内容 |
|---|---|
| `manifests/` | **部署入口**。原生 K8s 清单 + `install.sh`,含迁移背景与运维须知 |
| `gateway/` | Gateway API 的 HTTPRoute 清单(`kubectl apply` 管理) |
| `istio/` | Istio 场景下的接入说明 |
| `test/` | 发送测试 trace 的 Go 客户端(http / grpc) |

```bash
cd manifests && ./install.sh
```

## 变更记录

**2026-08-06:存储后端从 Elasticsearch 迁移到 badger,同时弃用 Helm。**

- 不再依赖 `elasticsearch-es-http.elastic-stack:9200`;ES 中遗留的 `ecommerce-jaeger-*` 索引已删除。
- ES 本身继续保留 —— 里面还有 `ecommerce_orders_*` / `ecommerce_products_*` 业务索引和 Kibana。
- 弃用 Helm 的原因(chart 无 volume 钩子 + Helm 4 post-renderer 的静默降级风险)见 `manifests/README.md`。
- 目录 `helm/` 已更名为 `gateway/`:Helm 方案废弃后,其中只剩 Gateway/Route 清单。
- otel-collector **无需改动**,它只与 Jaeger 的 Service 通信,不接触存储后端。

**2026-08-06:清理失效的 `jaeger-grpc-route`(GRPCRoute)及其配套文件。**

该路由自创建起 55 天从未生效,`status` 一直为空。原因不是"少了个 Gateway",而是它与同目录的 `gateway.yml` 之间有 4 处互不相容:Gateway 命名空间(`default` vs `observability`)、listener 名(`sectionName: tls` vs 实际叫 `https`)、hostname(`jaeger-grpc.app.com` vs listener 限定的 `jaeger-ui.app.com`)、以及 `allowedRoutes.from: Same` 的跨命名空间限制。此外 Cilium 的 `enable-gateway-api-alpn=false`,gRPC 所需的 h2 无法通过 ALPN 协商。

集群侧只有 GRPCRoute 被 apply 过,`observability-gateway` 和对应 Certificate 从未创建 —— 是个半途放弃的实验。全仓库无任何客户端引用 `jaeger-grpc.app.com`。

已删除:集群中的 GRPCRoute,以及 `gateway/` 下的 `grpc-route.yml`、`gateway.yml`、`certificate.yml`。

同时删除 `gateway/gateway.sh`。它创建的 `elastic-gateway`(elastic-stack 命名空间)和 `jaeger-route` 在集群中均不存在,且它为 `jaeger-ui.app.com` 建的路由会与现有的 `jaeger-ui-route` 撞域名 —— 留着是隐患而非备份。

外部 OTLP gRPC 入口本就存在:`otel-collector` 是 LoadBalancer(`192.168.3.117:4317`)。走 collector 也比直连 jaeger 更合理 —— trace 会经过 `k8s_attributes` / `memory_limiter` / `batch`,直连则全部绕过。
