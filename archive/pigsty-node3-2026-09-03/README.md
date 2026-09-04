# node3 Pigsty 收割原件（2026-09-03）

node3 重装前从 Pigsty v4.5.0 单机部署上只读收割的**渲染后配置**与冷拷贝数据。
分析与反哺结论见仓库根目录的 [`PIGSTY-HARVEST-2026-09-03.md`](../../PIGSTY-HARVEST-2026-09-03.md)。

`raw/` 已写入 `.gitignore`，**不进 git**：里面有 `pigsty.yml` 明文口令、pgbouncer `userlist.txt`、
ntfy/bugsink/newt 凭据、Pigsty CA 私钥和数据库数据。node3 下线后这些口令应全部轮换。

## raw/ 目录结构（路径与 node3 上一致）

| 路径 | 内容 |
|---|---|
| `root/pigsty/pigsty.yml*` | 部署清单（含 4 份历史备份）；`CLAUDE.md`/`VERSION` 为上游文件 |
| `etc/patroni/`、`pg/conf/pg-meta-1.yml` | Patroni 渲染配置：DCS、HA 参数、**PostgreSQL oltp 参数模板** |
| `pg/data/pg_hba.conf`、`postgresql*.conf`、`patroni.dynamic.json` | 运行时生效的 HBA 与参数 |
| `pg/tmp/*.sql` | 角色模型（`pg-init-roles.sql`）、模板库初始化（`pg-init-template.sql`：monitor schema、bloat 视图、heartbeat）、`ecommerce` 库与 `app` 用户建库脚本 |
| `pg/bin/` | Pigsty 运维脚本：`pg-backup`、`pg-pitr`、`pg-vacuum`、`pg-repack`、`pg-fork`、`pg-failover-callback` 等 |
| `etc/pgbouncer/` | 事务池配置、`pgb_hba.conf`、按用户池参数 |
| `etc/haproxy/` | primary 5433 / replica 5434 / default 5436 / offline 5438 四层服务 + Patroni REST 健康检查 |
| `etc/pgbackrest/`、`usr/local/sbin/pg-backup-healthchecked`、`var/spool/cron/crontabs/postgres` | 备份策略与「备份→Healthchecks 死人开关」包装 |
| `data/infra/prometheus.yml`、`etc/default/{vmetrics,vlogs,vtraces,vmalert,alertmanager,…}` | 抓取配置、`cls/ins/ip/job` 标签模型、各服务启动参数（保留期/上限） |
| `data/infra/rules/` | vmalert 规则：Pigsty 内置 8 文件 + **用户自写 `ecommerce-*.yml` 4 文件** |
| `etc/alertmanager.yml`、`usr/local/libexec/pigsty-alert-ntfy.py`、`etc/systemd/system/pigsty-alert-audit.service` | 告警路由与 ntfy/bugsink 桥接（用户自写） |
| `etc/grafana/`、`data/infra/datasources/`、`data/infra/dashboards/` | Grafana 配置、数据源预置、67 个上游仪表盘 JSON |
| `etc/vector/` | 日志采集 VRL：PG csvlog 26 列解析、patroni/pgbackrest/nginx/journald/redis |
| `etc/pg_exporter.yml`、`etc/pgbouncer_exporter.yml`、`etc/blackbox.yml` | 84 个 PG 采集器定义；黑盒探测模块 |
| `etc/otelcol/` | node3 本地 OTel Collector（Bearer 鉴权 + 三路写入 Victoria） |
| `etc/nginx/`、`etc/pki/`、`etc/dnsmasq.d/` | 门户反代、CA 分发、内部域名 |
| `etc/kafka/`、`etc/redis/`、`etc/etcd/`、`etc/default/silo`、`etc/stunnel/` | KRaft + SCRAM-SHA-512 + ACL；主从 Redis；TLS etcd；Silo(MinIO) |
| `etc/tuned/profiles/oltp/`、`etc/security/limits.d/`、`etc/sysctl.d/` | 节点调优 |
| `home/docker/ecommerce-cdc/` | Debezium → Kafka → Elasticsearch 9 + IK 的 CDC 工程（本地仓 `docker-postgres-kafka-es-streaming-pipeline/ecommerce-cdc` 亦有副本） |
| `data/gatus/`、`data/healthchecks/`、`data/bugsink/` | 合成监控、死人开关、错误追踪的 compose 与配置 |
| `_secrets/` | newt 站点凭据、ntfy/bugsink/healthchecks 凭据、OTel bearer token、Pigsty CA（含私钥）；2026-09-04 补：root/dba/redis 的 `.ssh`、`.pgpass`、`.pg_service.conf`、`.mcli`、LyraPass cloud `env`、kafka `secrets.yml`、redis/etcd/kafka TLS、4 个自定义容器的 `docker inspect`（含环境变量明文） |
| `_extra/` | 2026-09-04 二次扫描补收：`host-watchdog`（脚本/timer/env）、第二个 gatus `/opt/ecommerce-gatus`、6 个 systemd `memory.conf`、`pigsty-kafka-*` 脚本、sshd/netplan/apt/ufw 配置、root 的 bashrc/bash_history |
| `_data/node3-pgdata-pgbackrest-silo-cold-copy.tar.gz` | PG 已停止状态下的 `/pg/data` 冷拷贝（PG 18）、pgbackrest 仓库（最近全备 `20260903-010002F`）、Silo 对象（136K） |
| `_data/{ecommerce,bugsink,openfga}.pgdump`、`globals.sql` | 由冷拷贝在本机 `postgres:18` 容器导出的逻辑备份（`pg_restore -l` 校验通过）；`meta` 库依赖 postgis 未导出 |
| `_data/lyrapass-cloud-pg.pg_dumpall.sql` | LyraPass cloud 库（postgres:16 容器，14 表） |
| `_data/node3-app-volumes.tar.gz` | LyraPass `vault.db`/settings、healthchecks `hc.sqlite`、`grafana.db`、ecommerce-gatus 历史、bugsink `/data` |
| `_data/ecommerce-cdc-plugins-with-jars.tar.gz` | Kafka Connect ES sink 插件目录，含 PR #940 构建出的 57 个 jar |

未拷贝（重装即丢，见 `RESTORE-RUNBOOK-2026-09-04.md` §1.2）：Elasticsearch 索引（可由 PG 全量重建）、
Kafka 日志段（51M，7 天保留）、Victoria 指标/日志/追踪数据（802M）、gatus 探测历史、三个本地构建镜像。
