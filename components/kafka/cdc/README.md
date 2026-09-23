# ecommerce 搜索 CDC 链（k8s 正式部署）

PostgreSQL（node3 Pigsty，`10.10.21.172:5432`）→ Debezium → Kafka（本集群 Strimzi）→ Elasticsearch Sink → Elasticsearch（本集群 `elasticsearch` 命名空间）。
2026-09-15 自 node3 Docker/Pigsty 迁入并切流；node3 侧的 `kf-main`、`cdc-connect`、`cdc-elasticsearch` 已用 Pigsty `kafka-rm.yml` 与 `docker rm -v` 删除，本目录是唯一真相源。
配置与 `postgres-kafka-es-streaming-pipeline/deploy/docker-node3/connectors/*.json` 逐字段对齐；改 connector 前先读那边的 RUNBOOK（slot/offset/alias 语义在那里）。

| 文件 | 内容 |
|---|---|
| `kafka-single-node-internal.yaml` | KafkaNodePool + Kafka 4.3.0 单节点 KRaft，仅内部 listener（不暴露 loadbalancer）；内置 `kafkaExporter` 仅导出 `ecommerce_cdc.*` lag |
| `kafka-connect.yaml` | KafkaConnect 4.3.0，镜像含 Debezium PostgreSQL 3.6.1 + Confluent ES Sink；启用 `KubernetesSecretConfigProvider` |
| `rbac.yaml` | Connect SA 只能 `get` 两个凭据 Secret |
| `ecommerce-postgres-source.yaml` | Debezium source：slot/publication/topic 前缀统一 `ecommerce_cdc`，删除走 tombstone |
| `ecommerce-elasticsearch-sink.yaml` | ES sink：7 个 topic → 7 个 alias（`ecommerce_orders_*`、`ecommerce_products_*`、`ecommerce_catalog_products`），DLQ 副本数 1 |
| `connect-rest-netpol.yaml` | 放行 `ops` 命名空间（gatus）访问 Connect REST 8083 |

凭据 Secret（只存集群，不入库）：`kafka/cdc-postgres`（username/password）、`kafka/cdc-elasticsearch`（`ecommerce_cdc_sink` 用户）。

## 不变量

- PG 复制槽 `ecommerce_cdc` 必须在 Patroni `slots` 里声明（否则 PG 重启会被删，历史三次事故）；告警在 node3 `/infra/rules/ecommerce-cdc.yml`。
- Connect task 状态由 `ops/gatus` 的 `cdc-source-task` / `cdc-sink-task` 探针盯（connector 级 RUNNING 而 task FAILED 是事故形态）。Kafka exporter 的 `kafka_consumergroup_lag` 由 OTel Prometheus receiver 抓取 `:9404` 并转发 node3 Pigsty；node3 vmalert 的 `CdcSinkLag*` 规则消费该指标。
- ES 索引先由 `components/elasticsearch/bootstrap-indices.sh` 创建（模板 + `<alias>_v1` + write alias，replicas=0），再起 sink；让 sink 自动建索引会得到错 mapping（2026-09-23 新集群踩过，见 elasticsearch/README）。
- source 必须带 `lsn.flush.mode=connector_and_driver` + `heartbeat.interval.ms`：被监控表不写时槽不推进，CNPG `max_slot_wal_keep_size=-1` 会涨到盘满。告警 `vmalert/rules/ecommerce-cdc.yml`（`restart_lsn` 差 >256MB / 槽 inactive / 指标缺失）。

## 重灌（索引换版本后）

`bash components/kafka/cdc/reflow-sink.sh`：STOP sink → consumer group `connect-ecommerce-elasticsearch-sink` offset reset 到 earliest → resume → 等 lag 归零 → 打印各 alias 文档数。不动 PG 槽、不重快照——topic 里保留了全部事件。

## 重快照

删 KafkaConnector CR → 删 slot（`select pg_drop_replication_slot('ecommerce_cdc')`）→ 删 `ecommerce_cdc.*` topic → 清空 `<alias>_v1` 索引（或建新版本索引换 alias）→ 重新 apply source、sink。

## 指标与告警（2026-09-23）

Connect 的 JMX Prometheus Exporter 规则在 `connect-metrics-configmap.yaml`，由 `kafka-connect.yaml` 的 `spec.metricsConfig`
引用；otel collector `prometheus/kafka` 的 `strimzi-jmx` job 按 Pod 标签 `strimzi.io/kind∈{Kafka,KafkaConnect}` + 端口名 `tcp-prometheus` 抓 :9404。
关键指标：`kafka_connect_connector_task_status{connector,task,status}`、`debezium_metrics_connected{context="streaming"}`、
`debezium_metrics_millisecondsbehindsource`（-1 = 空闲无事件）。规则 `components/vmalert/rules/ecommerce-cdc.yml`：
`CDCConnectTaskNotRunning`(2m) / `CDCDebeziumDisconnected`(3m) / `CDCDebeziumLagHigh`(>5min) / `CDCConnectMetricsMissing`。
它们**看不见** Connect offset 落后复制槽——那是 `connector_and_driver` 的结构性现象，靠 source 的
`offset.mismatch.strategy=trust_greater_lsn` 自愈（重启实测不重快照），不做差值告警；完整性靠对账（下节）。

两个坑：① jmx_exporter 的 pattern 是 `domain<prop=val, ...><>attr`——域名后是 `<`，写成 `debezium.x:type=` 匹配 0 条；
② 改 ConfigMap 后 `kubectl delete pod` **不会**让 Strimzi 重渲染 `/opt/kafka/custom-config/metrics-config.json`，
要 `kubectl -n kafka annotate pod my-connect-cluster-connect-0 strimzi.io/manual-rolling-update=true` 让 operator 滚。

## 完整性对账（2026-09-23）

`reconcile/`：PG 侧 CNPG custom query `cnpg_cdc_rows_count{cdc_table}`（`cnpg-cdc-rowcount-queries.yaml`，挂在
`pg-cluster.yaml` 的 `spec.monitoring.customQueriesConfigMap`；exporter 角色的读权限用 `cnpg-exporter-grants.sql` 授，
含默认权限），ES 侧 CronJob `cdc-reconcile-es` 每 5 分钟 `_count` 推进 VM 为 `cdc_es_docs_count{cdc_table}`。
规则 `CDCReconcileMismatch`（差值持续 15m）/ `CDCReconcileStale`（CronJob 20m 无成功）。

**`trust_greater_lsn` 压力实验**（同日）：800 条独立事务 UPDATE（50ms 间隔）期间重启 task 三次——spus topic +800、
search_catalog topic +800，不丢不重；7 个 id 最终态 PG = ES。结论：driver 推过的区间不含监控表事件，「信任槽」在这个
配置下是安全的。样本 800/3 次重启；上副本后要重跑一次（槽在故障切换时的持久性是另一个前提）。
