# ecommerce 搜索 CDC 链（k8s 正式部署）

PostgreSQL（node3 Pigsty，`10.10.21.172:5432`）→ Debezium → Kafka（本集群 Strimzi）→ Elasticsearch Sink → Elasticsearch（本集群 `elasticsearch` 命名空间）。
2026-09-15 自 node3 Docker/Pigsty 迁入并切流；node3 侧的 `kf-main`、`cdc-connect`、`cdc-elasticsearch` 已用 Pigsty `kafka-rm.yml` 与 `docker rm -v` 删除，本目录是唯一真相源。
配置与 `postgres-kafka-es-streaming-pipeline/deploy/docker-node3/connectors/*.json` 逐字段对齐；改 connector 前先读那边的 RUNBOOK（slot/offset/alias 语义在那里）。

| 文件 | 内容 |
|---|---|
| `kafka-single-node-internal.yaml` | KafkaNodePool + Kafka 4.3.0 单节点 KRaft，仅内部 listener（不暴露 loadbalancer） |
| `kafka-connect.yaml` | KafkaConnect 4.3.0，镜像含 Debezium PostgreSQL 3.6.1 + Confluent ES Sink；启用 `KubernetesSecretConfigProvider` |
| `rbac.yaml` | Connect SA 只能 `get` 两个凭据 Secret |
| `ecommerce-postgres-source.yaml` | Debezium source：slot/publication/topic 前缀统一 `ecommerce_cdc`，删除走 tombstone |
| `ecommerce-elasticsearch-sink.yaml` | ES sink：7 个 topic → 7 个 alias（`ecommerce_orders_*`、`ecommerce_products_*`、`ecommerce_catalog_products`），DLQ 副本数 1 |
| `connect-rest-netpol.yaml` | 放行 `ops` 命名空间（gatus）访问 Connect REST 8083 |

凭据 Secret（只存集群，不入库）：`kafka/cdc-postgres`（username/password）、`kafka/cdc-elasticsearch`（`ecommerce_cdc_sink` 用户）。

## 不变量

- PG 复制槽 `ecommerce_cdc` 必须在 Patroni `slots` 里声明（否则 PG 重启会被删，历史三次事故）；告警在 node3 `/infra/rules/ecommerce-cdc.yml`。
- Connect task 状态由 `ops/gatus` 的 `cdc-source-task` / `cdc-sink-task` 探针盯（connector 级 RUNNING 而 task FAILED 是事故形态）。
- ES 索引先由 `components/elasticsearch` 的模板创建（`<alias>_v1` + write alias，replicas=0），再起 sink；让 sink 自动建索引会得到错 mapping。

## 重快照

删 KafkaConnector CR → 删 slot（`select pg_drop_replication_slot('ecommerce_cdc')`）→ 删 `ecommerce_cdc.*` topic → 清空 `<alias>_v1` 索引（或建新版本索引换 alias）→ 重新 apply source、sink。
