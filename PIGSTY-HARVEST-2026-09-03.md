# node3 Pigsty 收割与反哺清单 — 2026-09-03

背景：node3 将重装并加入三节点 k8s，PostgreSQL 改用 CNPG。本文记录 node3 上 Pigsty v4.5.0
及其周边自建设施**实际配置了什么**，以及哪些经验搬进本仓库（bootstrap/components）和
ecommerce 项目。原件已只读收割到 `archive/pigsty-node3-2026-09-03/raw/`（含口令，不进 git，
目录说明见 [`archive/pigsty-node3-2026-09-03/README.md`](archive/pigsty-node3-2026-09-03/README.md)）。

## 0. 先说结论

1. **node3 上有 5 类能力在重装后会消失，且本仓库目前没有替代**：vmalert + Alertmanager + ntfy 桥、
   黑盒探测（blackbox）、合成监控（gatus）、死人开关（healthchecks）、错误追踪（bugsink）。
   它们的配置全部收割完毕，可作为新组件直接容器化（§6、§9）。
2. **Pigsty 最值得搬的是 PostgreSQL 的四套「模板」**：oltp 参数模板、角色/默认权限模型、HBA 分层、
   事务池参数。它们都能映射到 CNPG 的 `Cluster` / `Pooler` / `Database` CR（§4）。
3. **你自己写的 4 个告警规则文件、告警桥、备份死人开关、CDC 工程**是这次收割里含金量最高的部分，
   它们不是 Pigsty 自带的，重装后要原样迁走（§5.3、§6、§8）。
4. 数据已做冷拷贝：PG 已停止，`/pg/data`（449M）一致；pgbackrest 最近一次全备是今天 01:00
   （`20260903-010002F`）。恢复路径见 §10。

## 1. node3 现状：三层清单

### 1.1 Pigsty 模块（`pigsty.yml`：单机模板 + 少量定制）

| 模块 | 实际配置 | 说明 |
|---|---|---|
| PGSQL `pg-meta` | PG 18，`pg_conf: oltp.yml`，`C.UTF-8`，扩展 postgis/pgvector/pg_repack/wal2json；库 `ecommerce`(owner `app`)、`meta`；用户 `app`(dbrole_admin)、`dbuser_meta`、`dbuser_view`(dbrole_readonly)；HBA 追加「intra 全员口令」；cron 每日 01:00 全备 | `app` 直接拿 `dbrole_admin`，比生产建议宽（§4.2） |
| INFRA | VictoriaMetrics/Logs/Traces 各 15 天保留（VL/VT 各限 50GiB）、vmalert 10s 评估、Alertmanager、Grafana（匿名可读、`/ui/` 子路径）、blackbox、nginx 门户（`i.pigsty`）、dnsmasq、自签 CA | `repo_enabled: false`（单机不建本地 yum/apt 仓） |
| NODE | `node_tune: oltp`（tuned）、`limits.d/limits.conf`（nofile/nproc 1048576，memlock 2.5G）、node_exporter、vector、haproxy | tuned 与本安装器 sysctl 的冲突见 HOSTING-READINESS §8.5 |
| ETCD | 单节点，TLS 双向，`quota-backend-bytes` 8G，`auto-compaction-retention: 24h` | 只给 Patroni 用 |
| REDIS `redis-ms` | 6379 主 + 6380 从，`maxmemory 512MB allkeys-lru`，`save 1200 1`，`stop-writes-on-bgsave-error no`，stunnel 提供 TLS | 集群已选 Dragonfly 原生 TLS |
| KAFKA `kf-main` | KRaft 单节点 4.3.1，BROKER 监听 `SASL_SSL` + `SCRAM-SHA-512`，`StandardAuthorizer` + `allow.everyone.if.no.acl.found=false`，`auto.create.topics.enable=false`，用户 `ecommerce_app` 按前缀 ACL，topic `ecommerce.events` 3 分区 7 天 | 这是 ecommerce 定稿事件主干的唯一实例（§7） |
| MINIO(silo) | 单盘，桶 `data/meta/pgsql`，对象共 136K | 几乎没用起来 |
| DOCKER/APP | pgadmin（默认 app） | — |

### 1.2 你在 Pigsty 之上自建的运维层（全部非 Pigsty 自带）

| 能力 | 实现 | 收割位置 |
|---|---|---|
| K8s/安全/观测链路告警 | `ecommerce-k8s.yml`(7 条)、`ecommerce-security.yml`(4)、`ecommerce-observability-readiness.yml`(2)、`ecommerce-ces-audit.yml`(1) | `raw/data/infra/rules/` |
| 告警通知 | Alertmanager → `127.0.0.1:9099` → `pigsty-alert-ntfy.py`（ntfy 推送，severity→priority；bugsink webhook 桥 `172.17.0.1:9199`）| `raw/usr/local/libexec/`、`raw/etc/alertmanager.yml` |
| 备份死人开关 | postgres crontab 01:00 → `pg-backup-healthchecked`（`/start` → `pg-backup full` → 成功 ping / 失败 `/fail`） | `raw/usr/local/sbin/` |
| 合成监控 | gatus v5.36：6 个分组（core-public / node1-public / node2-public / node3-public / node3-origin / node3-tcp / kubernetes-observability / auxiliary），统一条件 `STATUS` + `CERTIFICATE_EXPIRATION > 720h` + `RESPONSE_TIME < 5000`，ntfy 告警，容器只读+限额 | `raw/data/gatus/` |
| 死人开关服务 | healthchecks v4.3（sqlite，注册关闭，Prometheus 指标开） | `raw/data/healthchecks/` |
| 错误追踪 | bugsink（Sentry 协议，单用户，webhook 白名单 `host.docker.internal`，事件保留 90 天） | `raw/data/bugsink/` |
| OTel 入口 | otelcol-contrib：OTLP gRPC/HTTP + `bearertokenauth`，`memory_limiter` + `delta_to_cumulative` + `batch`，三路写入 VM/VL/VT | `raw/etc/otelcol/` |
| 公网暴露 | newt（Pangolin 隧道）站点凭据 | `raw/_secrets/opt/newt/config.json` |

### 1.3 ecommerce 数据链（用户工程）

`home/docker/ecommerce-cdc/`：Debezium 3.6.1 → Kafka → Elasticsearch 9.4.5 + IK（自建镜像、
自建 reindex 工具、alias 切换脚本、ES8 回滚 compose）。本地仓库
`docker-postgres-kafka-es-streaming-pipeline/ecommerce-cdc` 已有同一套源码；node3 上多出的是
`secrets/` 与 9 月 3 日更新的 `configure.sh`/`compose.yml`/`index-mappings.json`。

## 2. 「消失即无替代」清单（按优先级）

| 能力 | node3 实现 | 本仓库现状 | 去向 |
|---|---|---|---|
| 告警评估与通知 | vmalert + Alertmanager + ntfy 桥 | 无 vmalert/alertmanager 组件；`config.env` 只有 VM/VL | 新组件 `vmalert`、`alertmanager`（§9） |
| 链路后端 | VictoriaTraces（Grafana 用 jaeger 数据源读 `/select/jaeger`） | 只有 jaeger/tempo 组件 | 新组件 `victoria-traces`，与 VM/VL 同一家族，ecommerce STACK §2.7 已按 VT 设计 |
| 黑盒/合成监控 | blackbox_exporter + gatus | 无 | 新组件 `gatus`（含 blackbox 语义） |
| cron 死人开关 | healthchecks | 无 | 新组件 `healthchecks`；CNPG 备份、ces-audit CronJob 接入 |
| 错误追踪 | bugsink | 无 | 新组件 `bugsink` |
| PG 深度指标 | pg_exporter 84 个采集器 + 29 个 PGSQL 仪表盘 | CNPG 自带 `cnpg_*` 指标，仪表盘不兼容 | 可选：pg_exporter Deployment 指向 pg-main，仪表盘原样复活（§5.5） |
| Kafka | 独立 KRaft 单节点 | Strimzi 组件存在但 `ADDON_STRIMZI=false`（2026-08-20 退役） | 需要拍板（§7） |
| Elasticsearch | docker 单节点 9.4.5 + IK | 无 | 需要拍板（§7） |
| 对象存储 | Silo | `ADDON_MINIO=false` | 需要拍板（§7） |

## 3. 可直接搬走的文件（原件 → 目标）

| 原件 | 目标 | 改动 |
|---|---|---|
| `data/infra/rules/ecommerce-*.yml` | 新 `vmalert` 组件的 rules ConfigMap | 指标名已是下划线（`k8s_container_restarts`），零改动 |
| `usr/local/libexec/pigsty-alert-ntfy.py` + `etc/alertmanager.yml` | `alertmanager` 组件 + 一个 webhook 桥 Deployment | 环境变量改成 Secret；bugsink 桥地址改成 Service |
| `data/gatus/config.yaml` | `gatus` 组件 | `node3-origin`/`node3-tcp` 两组改成集群内 Service 探测 |
| `data/healthchecks/compose.yml`、`usr/local/sbin/pg-backup-healthchecked` | `healthchecks` 组件；CNPG `ScheduledBackup` 旁加 CronJob ping | 把 curl 三段式改成对 `cnpg_collector_last_available_backup_timestamp` 的告警 + 死人开关双保险 |
| `etc/otelcol/config.yaml` | 已有 `opentelemetry` 组件 | 补 `bearertokenauth` 与 `delta_to_cumulative`（集群内 collector 目前直推 node3，重装后改为写本集群 VM/VL/VT） |
| `etc/vector/postgres.yaml` VRL | `vector` 组件 | CNPG 的 PG 日志是 JSON 行（`record.*` 字段），不是 csvlog 文件；字段名可沿用，解析改 `parse_json` |
| `etc/vector/vector.yaml` 的 VL 请求头 | `vector` 组件 | `VL-Stream-Fields: job,ins,ip` 的流字段思路 = 现有 `_stream_fields=namespace,node,pod,container`，已一致 |
| `pg/tmp/pg-init-roles.sql`、`pg-init-template.sql` | CNPG `bootstrap.initdb.postInitApplicationSQL` / `Database` CR | 去掉 Pigsty 专属（file_fdw server、cmdb）；`monitor` schema、bloat 视图、heartbeat 保留 |
| `pg/conf/pg-meta-1.yml` 的 `parameters` | CNPG `spec.postgresql.parameters` | 映射见 §4.1 |
| `etc/pgbouncer/*` | CNPG `Pooler` CR | 映射见 §4.4 |
| `etc/kafka/server.properties` + `pigsty.yml` 的 `kafka_users/topics` | Strimzi `KafkaUser`/`KafkaTopic` | 若拍板重启 Strimzi |
| `data/infra/dashboards/pgsql/*.json`（29 个） | `grafana` 组件 provisioning | 依赖 pg_exporter 指标名与 `cls/ins/ip` 标签 |

## 4. PostgreSQL：从 Pigsty oltp 模板到 CNPG

### 4.1 参数映射（Pigsty 按 4C/8G 渲染；CNPG 按容器 memory 重算）

CNPG 托管、**不要**写进 `parameters` 的键：`archive_*`、`hot_standby`、`listen_addresses`、`port`、
`logging_collector`、`log_destination/directory/filename/rotation*`、`ssl*`、`unix_socket_directories`、
`cluster_name`、`full_page_writes`、`wal_log_hints`、`shared_preload_libraries`（写 `pg_stat_statements.*`、
`auto_explain.*` 参数时算子自动加载）。`wal_level` CNPG 默认即 `logical`，Debezium 不用再改。

| 组 | Pigsty 值 | 进 CNPG 的建议 | 备注 |
|---|---|---|---|
| 内存 | `shared_buffers 1857MB`(25%)、`effective_cache_size 5568MB`、`work_mem 64MB`、`maintenance_work_mem 465MB`、`hash_mem_multiplier 8.0`、`huge_pages try` | 按 `resources.limits.memory` 重算：shared 25%、cache 75%；`work_mem` 从 16MB 起（`max_connections` 200 × 64MB 会超）；`huge_pages off`（节点没配静态大页） | 现有 `pg-cluster.yaml` 只写了 shared_buffers 256MB/1Gi |
| 连接 | `max_connections 500`、`superuser_reserved_connections 10`、`idle_in_transaction_session_timeout 10min`、`deadlock_timeout 50ms`、`max_locks_per_transaction 500` | 200 + Pooler；其余照抄 | 事务池前置后 500 无必要 |
| 并行 | `max_parallel_workers 2`、`*_per_gather 2`、`parallel_setup_cost 2000`、`parallel_tuple_cost 0.2`、`min_parallel_table_scan_size 32MB` | 照抄（4 vCPU 节点抑制并行倾向） | OLTP 取舍 |
| WAL/检查点 | `wal_compression lz4`、`checkpoint_timeout 15min`、`checkpoint_completion_target 0.95`、`min_wal_size 2GB`、`max_wal_size 8GB`、`max_slot_wal_keep_size 12GB`、`idle_replication_slot_timeout 7d`、`wal_writer_delay 20ms`、`commit_delay 20`、`commit_siblings 10` | `wal_compression lz4`、检查点两项照抄；WAL 上限按 PVC 比例缩（10Gi 卷用 512MB/2GB/3GB）；`max_slot_wal_keep_size` 与 `idle_replication_slot_timeout` **必须设**——Debezium slot 停机时保护磁盘 | PG18 `idle_replication_slot_timeout` |
| 后台写/清理 | `bgwriter_delay 10ms`、`bgwriter_lru_maxpages 800`、`bgwriter_lru_multiplier 5.0`、`vacuum_cost_delay 20ms`、`vacuum_cost_limit 2000`、`autovacuum_vacuum_scale_factor 0.08`、`autovacuum_analyze_scale_factor 0.04`、`autovacuum_vacuum_threshold 500`、`autovacuum_analyze_threshold 250`、`autovacuum_freeze_max_age 1e9`、`log_autovacuum_min_duration 1s` | 照抄 | 小表少清、大表早清 |
| 查询/IO | `random_page_cost 1.1`、`effective_io_concurrency 200`、`maintenance_io_concurrency 100`、`default_statistics_target 400`、`io_method worker`、`io_workers 4`、`temp_file_limit 2GB`、`track_io_timing on`、`track_functions all`、`track_activity_query_size 8192`、`track_commit_timestamp on` | 照抄；`temp_file_limit` 按卷缩 | PG18 `io_method` |
| 日志（**审计价值最高**） | `log_min_duration_statement 100`、`log_statement ddl`、`log_lock_waits on`、`log_lock_failures on`、`log_temp_files 1024`、`log_checkpoints on`、`log_connections authorization`、`log_replication_commands on`、`log_timezone UTC`、`auto_explain.log_min_duration 1s` + `log_analyze/verbose/timing/nested on`、`pg_stat_statements.max 10000` + `track all` + `track_utility off` + `track_planning off` | 全部照抄（都不在托管列表） | 100ms 慢查询 + 1s 自动 explain 是现网可接受的粒度 |
| 复制 | `max_wal_senders 50`、`max_replication_slots 50`、`hot_standby_feedback on`、`max_standby_streaming_delay 3min`、`max_standby_archive_delay 10min`、`wal_receiver_status_interval 1s`、`sync_replication_slots on`、`max_logical_replication_workers 8`、`max_sync_workers_per_subscription 6` | `hot_standby_feedback`、两个 delay、逻辑复制两项照抄；senders/slots 10 够用 | CNPG 多实例时生效 |

### 4.2 角色与默认权限模型（`pg-init-roles.sql` / `pg-init-template.sql`）

Pigsty 的分层：

```
NOLOGIN 组角色:  dbrole_readonly ← dbrole_readwrite ← dbrole_admin(含 pg_monitor)   dbrole_offline(受限只读, ETL 专用)
系统用户:        postgres(dbsu)  replicator(REPLICATION+pg_monitor+readonly)  dbuser_dba(SUPERUSER+admin)
                 dbuser_monitor(pg_monitor+readonly, 会话级 log_min_duration_statement=1000)
业务用户:        app → dbrole_admin(建表权)   dbuser_view → dbrole_readonly
默认权限链:      ALTER DEFAULT PRIVILEGES FOR ROLE {postgres,dbuser_dba,dbrole_admin,<每个业务 owner>}
                 GRANT ... TO dbrole_readonly / dbrole_offline / dbrole_readwrite / dbrole_admin
库级:            REVOKE CREATE ON DATABASE/SCHEMA public FROM PUBLIC; GRANT CREATE TO dbrole_admin
模板库:          CREATE SCHEMA monitor; pg_stat_statements/pgstattuple/pg_buffercache/pageinspect/pg_prewarm/
                 pg_visibility/pg_freespacemap 装进 monitor; btree_gist/btree_gin/pg_trgm/intarray 装 public
                 monitor.heartbeat 表 + monitor.beating()（主库 upsert、从库只读；pg_exporter 用它测复制延迟）
                 monitor.pg_table_bloat / pg_index_bloat / pg_bloat 视图（SECURITY DEFINER，授 pg_monitor）
                 monitor.explain(text) → EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
```

搬进 CNPG 的做法：

- 组角色与系统用户用 `spec.managed.roles[]`（`login: false`、`inRoles`、`passwordSecret`）声明，密码走 ESO/OpenBao。
- 默认权限链、`REVOKE CREATE ON SCHEMA public`、`monitor` schema 与视图放 `bootstrap.initdb.postInitTemplateSQL`
  （进 template1，之后每个新库都带）；库级 `REVOKE/GRANT CREATE` 放 `Database` CR 之后的一次性 Job 或 `postInitApplicationSQL`。
- **ecommerce 的「每服务一个 schema」规则应叠加在这套模型上**：每个服务一个 `LOGIN` 角色，
  `IN ROLE dbrole_readwrite`，只对自己的 schema `GRANT CREATE`；迁移（goose）用单独的 `dbrole_admin` 成员角色跑；
  报表/BI 用 `dbrole_offline` 只连 `-ro` 服务。node3 上 `app` 直接拿 `dbrole_admin` 是图省事，别照抄。
- `dbuser_monitor` 的会话级 `log_min_duration_statement = 1000` 值得学：监控用户的查询不污染慢查询日志。

### 4.3 HBA 分层（`pg/data/pg_hba.conf`，按顺序）

```
local  dbsu           ident                      # postgres 只准本机 socket
repl   replicator     localhost + intranet scram
monitor dbuser_monitor localhost + infra 主机 scram   # 监控账号只准从监控机来
admin  dbuser_dba     intranet scram; 其它地址 hostssl scram
biz    +dbrole_readonly(含 readwrite/admin) localhost(给 pgbouncer) + intranet scram
etl    +dbrole_offline intranet scram
兜底   all all intranet scram                    # pigsty.yml 里 order 800 的那条定制
```

CNPG：`spec.postgresql.pg_hba` 里的规则会插在算子必需规则之后、默认 `host all all all scram-sha-256` 之前。
建议至少三条：监控角色只允许集群内 Pod 网段；业务角色 `hostssl` + `scram`；`reject` 掉不该出现的组合
（Pigsty 的 `pgb_hba.conf` 对 `dbuser_monitor`/`dbuser_dba` 写了显式 `reject 0.0.0.0/0`，是同一个思路）。

### 4.4 连接池（`etc/pgbouncer/*` → CNPG `Pooler`）

| Pigsty | 值 | CNPG `Pooler.spec.pgbouncer` |
|---|---|---|
| `pool_mode` | `transaction` | `poolMode: transaction` |
| `default_pool_size` / `reserve_pool_size` / `reserve_pool_timeout` | 50 / 30 / 1 | `parameters` 同名 |
| `max_client_conn` / `max_db_connections` / `max_user_connections` | 20000 / 100 / 100 | 同名；`max_db_connections` 要 < PG `max_connections` |
| `server_lifetime` / `server_reset_query` | 600 / `DISCARD ALL` | 同名 |
| `ignore_startup_parameters` | `extra_float_digits, application_name, TimeZone, DateStyle, IntervalStyle, search_path` | 同名；**pgx/sqlc 客户端必须**，否则 `search_path`/`TimeZone` 报错 |
| `max_prepared_statements` | 256 | 同名；事务池下 pgx 默认预编译语句依赖它（pgbouncer ≥1.21） |
| 按用户覆盖 | `dbuser_dba pool_mode=session max_user_connections=16`、`dbuser_monitor pool_mode=session 8` | Pooler 不支持 per-user 段；给 DBA/监控直连 `-rw` 服务，不走池 |
| 认证 | `auth_type = hba` + `pgb_hba.conf` | `spec.pgbouncer.pg_hba`；算子自动生成 `auth_query` |

服务分层：Pigsty haproxy 的 **primary 5433 / replica 5434 / default 5436 / offline 5438**（健康检查打
Patroni REST `/primary` `/read-only` `/replica`）对应 CNPG 的 `-rw` / `-ro` / `-r` Service。
「offline」这一层（ETL/报表只打从库，且用受限角色）值得在 CNPG 上用第二个 `Pooler`（`type: ro`）
+ `dbrole_offline` 复刻，避免报表拖垮主库。

### 4.5 备份与 PITR

Pigsty：pgbackrest 本地仓、`archive-async` + `archive-push-queue-max 4GiB`、`zst` 压缩、`start-fast`、
`delta` 恢复、`retention-full 2`、每日 01:00 全备、备份包死人开关；Patroni 用 pgbackrest 作
`create_replica_methods` 之一（拉从库不打主库）。`pg/bin/pg-pitr` 是按时间/LSN/名字恢复的封装。

CNPG 对应（组件 README 已承认「对象存储备份暂缺」）：

1. Barman Cloud Plugin（`ObjectStore` CR）指向**集群外**对象存储；WAL 归档连续 + `ScheduledBackup` 每日；
   `retentionPolicy` 取 7~14 天而不是「2 个全备」。
2. 「备份成功」的判据用两条：`cnpg_collector_last_available_backup_timestamp` 告警（超 26h 未更新 → warning）
   + healthchecks 死人开关（备份 CronJob/钩子 ping）。Pigsty 那套只有后者。
3. 恢复演练脚本化：CNPG `bootstrap.recovery` + `recoveryTarget`，等价于 `pg-pitr`。

### 4.6 扩展与镜像

node3 装了 `postgis-3`、`pgvector`、`pg_repack`、`wal2json`、`jit`；模板库还依赖 `pgstattuple`、
`pg_buffercache`、`pageinspect`、`pg_prewarm`、`pg_visibility`、`pg_freespacemap`、`pg_trgm`、`btree_gist/gin`。
CNPG 官方 `postgresql:18-standard` 镜像自带 contrib（上面 monitor 系列与 pg_trgm 都在）与 pgvector/pgaudit；
postgis 用 `ghcr.io/cloudnative-pg/postgis`；pg_repack、wal2json 两者都不含，需要自定义镜像〔以所选镜像标签的
清单为准〕。PG 18 + K8s `ImageVolume` 还可以用 CNPG 的 `spec.postgresql.extensions` 把扩展镜像挂进 `minimal`
镜像（[CNPG Recipe 23](https://www.gabrielebartolini.it/articles/2025/12/cnpg-recipe-23-managing-extensions-with-imagevolume-in-cloudnativepg)），
不用自己维护大镜像。ecommerce 现用 `pgoutput`，wal2json 可以不要；pg_repack 是在线消除膨胀的工具，建议保留。
另注意 PG 18 起 JIT 在独立包 `postgresql-18-jit`，`minimal` 镜像不含。

## 5. 观测与告警

### 5.1 数据面参数（node3 实测）

| 组件 | 关键启动参数 | 集群内对应 |
|---|---|---|
| VictoriaMetrics | `-retentionPeriod=15d -promscrape.config=... -promscrape.fileSDCheckInterval=5s -opentelemetry.usePrometheusNaming=true`，全局 `scrape_interval 10s / timeout 8s` | `victoriametrics` 组件已开 `usePrometheusNaming`；补 `retentionPeriod` 显式值 |
| VictoriaLogs | `-retentionPeriod=15d -retention.maxDiskSpaceUsageBytes=50GiB -insert.maxLineSizeBytes=1MB -search.maxQueryDuration=120s` | `victoria-logs` 组件补磁盘上限与行长上限（避免撑满 LVM 卷） |
| VictoriaTraces | `-retentionPeriod=15d -retention.maxDiskSpaceUsageBytes=50GiB` | 新组件 |
| vmalert | `-evaluationInterval=10s -rule=/infra/rules/*.yml`，remoteRead/Write 回 VM（`ALERTS_FOR_STATE` 可查） | 新组件；remoteWrite 必开，否则 `AlertFiringTooLong` 元规则失效 |
| Alertmanager | `group_by [alertname]`, `group_wait 30s`, `group_interval 5m`, `repeat_interval 1h`；`NodeDown` 抑制同 `ip` 的 node 类告警 | 新组件 |
| Grafana | 匿名 Viewer、`root_url /ui/` 子路径、`allow_embedding`、`versions_to_keep 100`、`min_refresh_interval 100ms`；数据源 uid 固定 `ds-prometheus / ds-vlogs / ds-vtraces / ds-meta / ds-static` | `grafana` 组件：固定数据源 uid，仪表盘 JSON 才能跨环境导入 |
| node_exporter | `--collector.tcpstat --collector.processes --no-collector.softnet --no-collector.nvme` | otel-node 主机指标已覆盖大部分 |

### 5.2 标签模型 `cls / ins / ip / job`

Pigsty 全部仪表盘与规则只认四个标签：`cls`（集群，如 `pg-meta`）、`ins`（实例，如 `pg-meta-1`）、
`ip`、`job`（`pgsql/node/infra/etcd/redis/kafka/minio/docker`）。目标文件按 `job` 分目录做 file_sd。
在 k8s 里用 relabel 就能复刻：`cls` ← CNPG 集群名 / StatefulSet 名，`ins` ← Pod 名，`ip` ← Pod IP。
这是复用它 67 个仪表盘的前提，也是 ecommerce 「指标标签禁止高基数」规则的具体落法。

### 5.3 告警规则

- 你写的 14 条（§1.2）直接搬。其中三条规矩已写进注释，应固化为团队规范：
  **每条规则必须有 `for:`**；**每个采集链路配 `absent()` 兜底**（`K8sClusterMetricsMissing`、`HubbleFlowTelemetryMissing`）；
  **`AlertFiringTooLong` 元规则**逼迫修根因或删规则。
- Pigsty 内置 65 条告警 + 700 余条 recording rule（`pgsql` 16/402、`node` 16/163、`redis` 6/96、`kafka` 15/19、
  `etcd` 5/9、`minio` 5、`infra` 2）。PG 那 16 条对应 CNPG 指标：

| Pigsty 告警 | 语义 | CNPG 指标写法 |
|---|---|---|
| `PostgresDown` / `PgExporterDown` | 实例或采集器不可用 | `cnpg_collector_up == 0` / `absent(cnpg_collector_up)` |
| `PostgresRestart` | 意外重启 | `changes(cnpg_pg_postmaster_start_time[10m]) > 0` |
| `PostgresReplicationBreak` / `Lag` | 复制断/延迟 | `cnpg_pg_replication_streaming_replicas < instances-1`、`cnpg_pg_replication_lag > 30` |
| `PostgresXidWarpAround` | 事务 ID 回卷 | `cnpg_pg_database_xid_age > 1e9`（阈值与 `autovacuum_freeze_max_age` 对齐） |
| `PostgresConnUsageHigh` | 连接占用 | `cnpg_backends_total / cnpg_pg_settings_setting{name="max_connections"} > 0.8` |
| `PostgresIdleInXact` | 长事务 | `cnpg_backends_max_tx_duration_seconds > 300` |
| `PostgresPressureHigh` / `PostgresPartition` | 负载/分区 | 需 pg_exporter 或自定义查询 |
| `PgbouncerDown` / `ClientQueue` / `QuerySlow` | 池 | Pooler 自带 pgbouncer 指标（`cnpg_pgbouncer_*`） |
| `PatroniDown` / `PatroniFailSafeActive` | HA 组件 | 无对应（算子接管）；改看 `cnpg_collector_*` 与 Cluster 条件 |

- `node.yml` 的 `NodeDiskSlow`、`NodeTcpRetransHigh`、`NodeTimeDrift`、`NodeFdFull` 在 k8s 节点上同样有效，
  指标名来自 node_exporter；otel-node 的 hostmetrics 指标名不同，要么改表达式，要么补 node_exporter DaemonSet。

### 5.4 日志

`etc/vector/postgres.yaml` 的 VRL 把 PG csvlog **26 列**（PG18 多了 `backend_type`、`leader_pid`、`query_id`）
拆成字段，并从 `duration: N ms` 抽出 `duration` 数值——这使 VictoriaLogs 里能直接按 `duration > 1000` 查慢查询、
按 `code` 查错误码、按 `app` 查应用名。CNPG 把同样的字段放在 JSON 行的 `record.*` 下，字段名一致，
`vector` 组件加一段 `parse_json` 分支即可。`VL-Stream-Fields: job,ins,ip` 与现有 `_stream_fields` 思路相同，
不要把 `pid`/`sid` 这种高基数字段放进流字段。

### 5.5 让 29 个 PGSQL 仪表盘复活（可选）

pg_exporter 是无状态二进制，`/etc/pg_exporter.yml`（84 个采集器，按 PG 版本分支）直接可用。
在集群里跑一个 Deployment 指向 `pg-main-rw:5432`（`dbuser_monitor`，`PG_EXPORTER_AUTO_DISCOVERY=true`，
排除 `template0,template1,postgres`），VM 抓取时打 `cls=pg-main, ins=pg-main-1, ip=<pod ip>, job=pgsql`，
Grafana 导入 `raw/data/infra/dashboards/pgsql/`。`pg_heartbeat` 采集器依赖 §4.2 的 `monitor.beating()`。
pgbouncer 侧同理（`pgbouncer_exporter.yml` + Pooler）。

## 6. 运维保障层的容器化要点

| 组件 | node3 上的取舍（值得保留） | 容器化注意 |
|---|---|---|
| gatus | `read_only` + `no-new-privileges` + `tmpfs /tmp` + `mem_limit 192m`；条件三件套；`failure-threshold 2 / success-threshold 2 / send-on-resolved`；`kubernetes-observability` 组直接查 VM/VL API 验证「数据真的进来了」 | sqlite → PVC；探测目标从 `127.0.0.1` 改成 Service；公网探测继续走 newt 出站 |
| healthchecks | `REGISTRATION_OPEN=False`、`PROMETHEUS_ENABLED=True`、`UWSGI_PROCESSES=1`、sqlite | 同上；`SITE_ROOT` 改集群域名；备份 CronJob、ces-audit、goose 迁移 Job 都接 ping |
| bugsink | `SINGLE_USER`、`USER_REGISTRATION=CB_NOBODY`、`ALERTS_WEBHOOK_OUTBOUND_MODE=allowlist_only`、`MAX_EVENT_AGE_DAYS=90`、`stop_grace_period 30s` | DSN 给 Go 服务与前端；webhook 白名单改成告警桥 Service |
| 告警桥 | 171 行 python，无第三方依赖，`ThreadingHTTPServer`，body 上限 1MB，severity→ntfy priority | 直接打成 distroless 镜像；`NTFY_*` 进 Secret |
| OTel 入口 | Bearer token 文件鉴权（`/run/secrets/otel-tokens`），公网入口只暴露 4318 | 集群内 collector 已有；对外仍经 newt，鉴权照搬 |
| newt | `--disable-clients --disable-ssh --metrics` | 已有 `newt` 组件；站点凭据在 `_secrets/` |

## 7. 需要拍板的三件基础设施

| 组件 | node3 的实现 | 选项 A | 选项 B |
|---|---|---|---|
| Kafka | KRaft 单节点，SCRAM-SHA-512 + 前缀 ACL，`auto.create.topics=false`，`ecommerce.events` 3 分区/7 天；CDC 依赖它 | 重启 `kafka`(Strimzi) 组件：KRaft 单 broker，`KafkaUser` SCRAM + 同样的 ACL，`KafkaTopic` 声明；内存 ≥1.2G | 继续 NATS JetStream（config.env 2026-08-20 定稿），CDC 改用 Debezium Server 直写 ES，不经 Kafka |
| Elasticsearch | 9.4.5 + IK 自建镜像，`xpack.security` 开、`memory_lock`、`-Xmx768m`、`mem_limit 2g` | StatefulSet 单节点复用该镜像（`memlock` ulimit 需 `securityContext` 或 `bootstrap.memory_lock=false`） | 维持 Meilisearch 直到有 3 节点空余内存 |
| 对象存储 | Silo 单盘，对象 136K | `minio` 组件按 Silo 改造（Versioning + Lifecycle，按 ecommerce TECH.md） | 暂缓，图片继续走外部 `minio.apikv.com` |

三者合计约 3.5~4G 内存，超过 HOSTING-READINESS §7 的裁剪后余量；node3 加入后总内存 22G，
才有空间同时上 Kafka + ES。建议顺序：CNPG → 观测/告警 → ES → Kafka。

## 8. 反哺 ecommerce 项目（对照 `STACK.md`）

1. **连接串回到集群内**：`STACK.md §2.4` 记录「已切到 node3 Pigsty，客户端 `verify-ca`」。改为 Pooler
   `pg-main-pooler-rw.postgresql.svc:5432`（写）与 `-pooler-ro`（读），CA 用 CNPG `pg-main-ca`
   经 trust-manager 分发，`sslmode=verify-full` + `serverAltDNSNames`。
2. **事务池兼容**：pgx 默认预编译语句在事务池下依赖 `max_prepared_statements`；`ignore_startup_parameters`
   必须含 `search_path`（sqlc 生成代码不设 search_path，但驱动会发 `TimeZone`/`extra_float_digits`）。
3. **角色**：每服务一个 `LOGIN` 角色 `IN ROLE dbrole_readwrite`，只对本服务 schema 有 `CREATE`；
   goose 迁移用 `dbrole_admin` 成员；`tools/search-indexer` 与报表用 `dbrole_offline` 连 `-ro`。
4. **慢查询与审计口径**：`log_min_duration_statement 100ms`、`auto_explain 1s`、`log_statement ddl`、
   `log_lock_waits`、`idle_in_transaction_session_timeout 10min`——把它们写进 `docs/INFRASTRUCTURE-OPERATIONS.md`
   作为「数据库侧 SLO」，应用侧的 OTel span 阈值与之对齐。
5. **CDC 硬约束**（来自 `connectors/postgres-source.json`）：`publication.autocreate.mode=disabled`（发布由迁移创建）、
   固定 `slot.name`、`snapshot.mode=initial`、`ExtractNewRecordState` + `delete-to-tombstone`、
   `errors.tolerance=none` + DLQ topic、ES 侧 `ALIAS_INDEX` + `ExtractField$Key`。这些应进 `backend/infrastructure/kafka-connect/`
   的说明，而不是只留在 node3 的 compose 里。Debezium 的 `heartbeat.action.query` 可以直接写 §4.2 的 `monitor.heartbeat`。
6. **告警规范**：`ecommerce-k8s.yml` 头部注释里的三条教训（12 个 Pod 崩溃 9 小时无人发现 → 必须有 K8s 层规则；
   点号指标名断供不报错 → 先查 series 再写；缺 `for:` 的规则等于没有告警）写进 `context/team/alerting-signal-hygiene.md`
   已有文件，并把「`absent()` 兜底」和「`AlertFiringTooLong`」列为必选项。
7. **合成监控即验收**：gatus 的 `kubernetes-observability` 组用「查询 VM 是否有 `k8s_deployment_available`」
   「查询 VL 是否有 24h 内 Event」判定观测链路，比 Pod Ready 更接近真相；`docs/TESTING.md` 的部署验收可以引用同样的查询。
8. **错误追踪**：Go 服务与前端接 bugsink DSN（Sentry SDK），告警桥把 bugsink 事件也推 ntfy——
   `STACK.md §2.7` 说的「Alertmanager 未形成 ntfy 闭环」在 node3 上其实已经闭环，只是没进仓库。
9. **Kafka 安全基线**（若重启 Strimzi）：SCRAM-SHA-512、每应用一个 user、前缀 ACL（topic/group 前缀 `ecommerce.`、
   cluster `IdempotentWrite`）、`auto.create.topics=false`、`super.users` 只给平台账号。
10. **节点调优补丁**（进 `bootstrap/scripts/20-kernel-tuning.sh`，来自 tuned `oltp`）：`vm.dirty_expire_centisecs=500`、
    `vm.dirty_writeback_centisecs=100`、`net.ipv4.tcp_max_tw_buckets=262144`、`tcp_syn_retries/tcp_synack_retries=3`、
    `kernel.sched_autogroup_enabled=0`、`kernel.numa_balancing=0`；`limits.d` 加 `memlock`（ES/大页需要）。
    `vm.overcommit_memory` Pigsty 取 0/`overcommit_ratio 100`，本安装器取 1（Redis fork），保留安装器值。

## 9. 本仓库待办（2026-09-03 晚间已落实 1/2/3/6，接线说明见 [`OBSERVABILITY-INTEGRATION.md`](OBSERVABILITY-INTEGRATION.md)）

| # | 事项 | 位置 | 状态 |
|---|---|---|---|
| 1 | 新组件 `vmalert` + `alertmanager` + `alert-bridge`（ntfy/bugsink），rules 来自 `raw/data/infra/rules/ecommerce-*.yml` | `components/` | ✅ 已落实；规则另加 `cnpg.yml`、`observability-pipeline.yml` |
| 2 | 新组件 `victoria-traces`；`victoria-logs` 补 `-retention.maxDiskSpaceUsageBytes` 与 `-insert.maxLineSizeBytes` | `components/` | ✅ VT 已落实；VL 两个参数仍待补 |
| 3 | 新组件 `gatus`、`healthchecks`、`bugsink` | `components/` | ✅ 已落实 |
| 4 | `postgres` 组件：`pg-cluster.yaml` 参数按 §4.1 扩写；`managed.roles` + `postInitTemplateSQL` 落 §4.2；`pg_hba` 落 §4.3；新增 `Pooler` rw/ro（§4.4）；Barman Cloud Plugin + `ScheduledBackup`（§4.5）；镜像含 postgis/pgvector（§4.6） | `components/postgres/` | 待办 |
| 5 | 可选组件 `pg-exporter`（复活 PGSQL 仪表盘） | `components/` | 待办 |
| 6 | `vector` 组件加 CNPG JSON 日志分支；`grafana` 组件固定数据源 uid | `components/vector/`、`components/grafana/` | ✅ grafana 数据源 uid 已固定（VL/VT/Alertmanager）；vector 的 CNPG JSON 分支待办 |
| 7 | `20-kernel-tuning.sh` 合并 §8.10 的 sysctl/limits | `bootstrap/scripts/` | 待办 |
| 8 | Kafka / ES / 对象存储三项拍板（§7）后再动 `config.env` 开关 | `bootstrap/config.env` | 待拍板 |

## 10. node3 重装前检查清单

已完成（本地 `archive/pigsty-node3-2026-09-03/raw/`）：

- [x] 全部渲染配置（§1 三层）
- [x] 凭据：newt 站点、ntfy/bugsink/healthchecks、OTel bearer token、Pigsty CA 含私钥
- [x] `/pg/data` 冷拷贝（PG 已停止，一致）、pgbackrest 仓库（全备 `20260902-010001F`、`20260903-010002F` + WAL 归档）、Silo 对象

重装前仍需确认：

- [ ] Elasticsearch 索引不需要保留（可由 PG 通过 `reindex` 工具全量重建）
- [ ] Kafka `ecommerce.events` 7 天内的事件不需要保留
- [ ] bugsink 90 天事件、gatus/healthchecks 历史不需要保留
- [ ] `docker-postgres-kafka-es-streaming-pipeline/ecommerce-cdc` 本地仓与 node3 9 月 3 日版本 `compose.yml`/`configure.sh`/`index-mappings.json` 已合并
- [ ] node3 下线后轮换 `pigsty.yml` 里的全部口令（PG、Grafana、Kafka、Redis、MinIO、etcd、Patroni、haproxy）

数据恢复到 CNPG 的路径：用 `postgres:18` 容器挂载冷拷贝的 `pg/data` 启动（同大版本；启动参数覆盖
`-c archive_mode=off -c ssl=off -c shared_preload_libraries=''`，否则会找 `/pg/cert` 与 pgbackrest）
→ `pg_dump -Fc ecommerce` → CNPG `bootstrap.initdb.import`（`microservice` 类型）或 `pg_restore` 到
`Database` CR 建好的库。pgbackrest 仓库不能被 CNPG 直接消费，只作为第二份保险。
