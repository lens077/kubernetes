# loki —— 日志后端（单体模式）

## 1. 定位

集群日志的存储与查询后端。两条入口：

- **容器日志**：fluent-bit（DaemonSet）采集 → Loki 的 push API
- **应用日志**：应用用 otelzap 等把日志走 OTLP 推给 [opentelemetry](../opentelemetry/)
  Collector → Collector 的 logs pipeline 写 Loki 的 `/otlp`

[grafana](../grafana/) 把它当日志数据源。

## 2. 上游最佳实践

来源：[Loki Helm 文档](https://grafana.com/docs/loki/latest/setup/install/helm/)

- 三种部署形态：**SingleBinary**（<20GB/天）、SimpleScalable（中等）、Distributed（大规模）。
- Loki 3.x 的推荐 schema 是 `v13` + `tsdb`。老集群从 boltdb-shipper 迁移要保留旧 schema 段，
  **不能直接改 from 日期**（会让旧数据查不到）。
- 生产建议用对象存储（S3/MinIO）而不是 filesystem，这样节点故障不丢数据、也能水平扩展。
- OTLP 原生摄入端点是 `/otlp`（Loki 3.x 起内置），需要 `allow_structured_metadata`（3.x 默认开）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 生产用对象存储 | **filesystem + 本地 PVC** | MinIO 也跑在同一个集群、同样的本地 LVM 盘上——绕一圈并不增加可靠性，反而多一跳和一份内存。日志是可再生数据，这里接受节点故障丢失。 |
| chart 默认起 read/write/backend | 全部 `replicas: 0` | SingleBinary 模式下这些是多余的；chart 默认值会把它们一起拉起来。 |
| chart 自带 `gateway`（nginx） | 关闭 | 对外入口统一走 Cilium 共享网关，再套一层 nginx 只是多一跳。注意这个 `gateway` 与 Gateway API 无关，同名容易误解。 |
| chunksCache / resultsCache（memcached） | 关闭 | 两个 memcached 默认各要几百 MB，单机集群的查询量根本用不上。 |
| lokiCanary | 关闭 | 它是持续写探针日志来监控 Loki 自身可用性的，单机集群没必要，还会持续占用写入配额。 |
| `auth_enabled: true` | `false` | 单租户。开了之后每个请求都要带 `X-Scope-OrgID`，fluent-bit、Grafana、OTel 三处都要配。 |

## 4. 暴露方式

- OTLP 摄入（集群内）：`http://loki.logging.svc.cluster.local:3100/otlp`
- push API（fluent-bit）：`loki.logging.svc.cluster.local:3100`，输出配置见 `examples/`
- 查询（Grafana 数据源）：`http://loki.logging.svc.cluster.local:3100`
- 对外：`https://logs.dev.test`（共享网关）

> [!NOTE]
> `auth_enabled: false` 意味着**任何能访问该域名的人都能读写日志**。当前只在内网 +
> 自签证书下暴露；如果以后要出公网，先在网关上加认证（或把这条 HTTPRoute 删掉，只留集群内访问）。

## 5. 验证

真验证（打一条日志再查回来）：

```bash
# 经 OTLP 端点写入
kubectl -n logging exec statefulset/loki -- sh -c 'wget -qO- --post-data "{}" http://127.0.0.1:3100/ready'

# 查询（Loki 的 query_range 默认回看最近一段时间）
kubectl -n logging exec statefulset/loki -- sh -c \
  'wget -qO- "http://127.0.0.1:3100/loki/api/v1/labels"'
```

端到端（打点 → 回查）由 `bootstrap/scripts/90-verify.sh` 的可观测冒烟覆盖：
它经 OTel Collector 打一条 OTLP 日志，再用 `{service_name="otel-smoke-<ts>"}` 查回来。

## 6. 踩坑

- **OTLP 日志 push 返回 400**：多半是 `allow_structured_metadata` 被关（Loki 3.x 默认开，
  但从旧版 values 迁移过来时容易带上 `false`）。
- **改了 schemaConfig 的 from 日期后旧日志查不到**：schema 段是按时间分段的，
  改已有段的日期等于宣称"历史数据用新格式存"，索引就对不上了。要加新段而不是改旧段。
- **磁盘涨得比预期快**：`retention_period` 只在 compactor 启用时才真正删数据。
  单体模式下 compactor 内置，确认 `kubectl -n logging logs statefulset/loki | grep -i compact` 有动作。
