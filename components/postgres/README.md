# postgres —— CloudNativePG 算子

## 1. 定位

PostgreSQL 的生命周期管理（建库、备份、故障转移、滚动升级）。默认配置会安装算子、
创建 `pg-main` 与 `ecommerce` 数据库，并自动接入宿主网 TLSRoute；设置
`PG_CREATE_MAIN_CLUSTER=false` 时才退回只装算子、手工应用 `examples/pg-cluster.yaml`。

ecommerce 的业务库和 outbox CDC 源表都运行在该实例上。

## 2. 上游最佳实践

来源：[CloudNativePG 文档](https://cloudnative-pg.io/documentation/)（1.30 线，2026-08 复核）

- 算子与实例分离：算子装一次，`Cluster` CR 按需创建。
- 生产实例 ≥3 副本（同步复制），WAL 归档到对象存储。注意 **1.26 起原生
  `backup.barmanObjectStore` 已 deprecated**，新配置走 CNPG-I 的 Barman Cloud Plugin。
- resources 推荐 requests=limits（Guaranteed QoS，算子会配合调 OOM 优先级保 postmaster）；
  `shared_buffers` 起点 = 容器内存的 25%。
- `spec.walStorage` 分卷可让 PGDATA 满盘不殃及 WAL；**加上后不可移除**，属单向决定。
- 参数调优走 `spec.postgresql.parameters`，别进容器改 `postgresql.conf`（会被 reconcile 覆盖）。
- 算子自动为实例签发 TLS 证书（服务端 + 客户端 CA），默认就是加密连接；CA 90 天自动续期。
- 配 VPA 时**只能 `updateMode: Off`**（官方明令）：算子视 `spec.resources` 为真相源，
  VPA 改副本会被顶回，驱逐又被 primary PDB 挡住。取推荐值手动写回 CR。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| ≥3 实例同步复制 | dev 使用 `instances: 1` | 当前先控制资源开销；生产 HA 需另行规划 ≥3 实例、反亲和和独立故障域。 |
| requests=limits 含 CPU（Guaranteed） | **只钉内存 1Gi，CPU 不限** | 内存紧 + 查询是突发负载（与 VM/dragonfly 同理）。代价是 QoS 降为 Burstable、丢掉 OOM 调优收益，主动取舍。 |
| `walStorage` 分卷 | 不分 | 本集群两个 PVC 都落同一个 LVM VG，I/O 并行收益为零；只剩"满盘隔离"一条，对 10Gi 测试实例不值得背"加了拆不掉"的单向决定。 |
| 对象存储备份 | **已接集群内 MinIO**（2026-10-22） | MinIO 与数据库跑在同一批本地盘上，**备份到那里不构成异地容灾**——主机或 LVM VG 整体损毁时备份一起没。走 CNPG-I 的 Barman Cloud Plugin（`backup.barmanObjectStore` 已 deprecated），保留 30 天，每日 03:15 UTC 全量 + WAL 连续归档。已具备误删/数据损坏/PITR 防护；真容灾仍缺集群外一路，见 `manifests/` 与第 6 节。 |
| bitnami postgresql-ha | 换 CNPG | bitnami 镜像 2025 年起受限；CNPG 不需要 pgpool/repmgr 附加组件。 |

## 4. 暴露方式

- 集群内：CNPG 自动创建 `<cluster>-rw` / `<cluster>-ro` / `<cluster>-r` 三个 Service。
- 宿主网：安装器自动创建独立 Gateway + TLSRoute，按 `pg.dev.test` SNI 透传到
  `pg-main-rw:5432`；说明见 [`gateway/README.md`](gateway/README.md)。
- 兼容入口：旧客户端不能发送 direct TLS ClientHello 时，手工应用
  [`examples/pg-tcproute.yaml`](examples/pg-tcproute.yaml)，不由安装器自动创建。

## 5. 验证

```bash
kubectl -n cnpg-system get deploy cnpg-cloudnative-pg          # READY 1/1
kubectl api-resources | grep postgresql.cnpg.io                # CRD 已注册
```

自动安装与路由状态：

```bash
kubectl -n postgresql wait --for=condition=Ready cluster/pg-main --timeout=600s
kubectl -n postgresql wait --for=condition=Programmed \
  gateway/pg-passthrough-gateway --timeout=180s
kubectl -n postgresql get tlsroute pg-main -o wide
VIP=$(kubectl -n postgresql get gateway pg-passthrough-gateway \
  -o jsonpath='{.status.addresses[0].value}')
```

宿主网必须使用支持 direct TLS negotiation 的客户端，连接时同时校验 CNPG CA 和
`pg.dev.test` 主机名：

```bash
PGPASSWORD=xxx psql "host=pg.dev.test hostaddr=$VIP user=app dbname=ecommerce \
  sslmode=verify-full sslnegotiation=direct sslrootcert=<pg-main-ca 的 ca.crt>" \
  -c "SELECT ssl, version FROM pg_stat_ssl WHERE pid=pg_backend_pid()"
# 期望 ssl=t，且 version 非空
```

## 6. 踩坑

- **经网关握手失败，`openssl -starttls postgres` 也连不上**：TLS passthrough 网关（Envoy）
  只认**直接 TLS**——第一个包必须是带 SNI 的 ClientHello。而 PostgreSQL 传统协商是先发
  8 字节明文 `SSLRequest` 再升级 TLS，Envoy 解析不了，握手必挂。客户端必须用
  libpq ≥17 的 `sslnegotiation=direct`（服务端 PG 17+ 接受）；`psql` 走网关不带这个参数
  就是连不上，不是网关坏了。集群内直连 Service 不受影响（不经 Envoy）。
- **`verify-full` 报主机名不匹配**：CNPG 默认服务端证书 SAN 只含 `<cluster>-rw/-ro/-r`
  的内部 DNS 名。经网关用域名连必须在 `spec.certificates.serverAltDNSNames` 里加上
  对外域名（见 `examples/pg-cluster.yaml`）；改完 CNPG 热轮换证书，无需重启实例。
- **PVC Pending**：OpenEBS LVM 本地卷有节点亲和，实例只能建在有对应 VG 的节点上。
- **改了 postgresql.conf 却被还原**：CNPG 会 reconcile 回 CR 里声明的参数，
  改配置要改 `spec.postgresql.parameters`。
- **Debezium CDC 相关**：复制槽残留、`publication` 缺失、`binary.handling.mode` 取值等
  一整套踩坑记录在仓库根的 [TODO.md](../../TODO.md)（2026-08-06 那次排查）。
- **备份相关（2026-10-22 接 Barman Cloud Plugin 时踩到，三条都能无声咬人）**：
  1. **CNPG 的 `schedule` 是 6 段 cron（秒 分 时 日 月 周），不是标准 5 段。**
     想「每天 03:15」必须写 `0 15 3 * * *`；按 5 段直觉写 `15 3 * * *` 实际语义是
     「每小时第 3 分第 15 秒」，20 小时能跑 43 次全量、吃掉 2.8 GiB。
  2. **插件做的备份，CNPG 自带 exporter 看不见。**
     `cnpg_collector_last_available_backup_timestamp` 恒为 0，
     `.status.lastSuccessfulBackup` / `firstRecoverabilityPoint` 也不填充——
     它们只认内置 `barmanObjectStore`。所以另有一个 CronJob 探针
     （`manifests/cnpg-backup-freshness-probe/`）每 30 分钟读 Backup CR 真值推 VM，
     并由 `CNPGBackupProbeMissing` 盯探针自身。验证这些 30 分钟级指标**别用 VM 即时查询**
     （回看窗口只有 5 分钟，会 25/30 的时间返回空），要用 `query_range` 或 `/api/v1/series`。
  3. **`instanceSidecarConfiguration.env` 里的 `AWS_REQUEST_CHECKSUM_CALCULATION` /
     `AWS_RESPONSE_CHECKSUM_VALIDATION` / `AWS_NO_CHUNKED_ENCODING` 不是可选项。**
     boto3 新版默认强制算 `x-amz-content-sha256` 并对分片启用 chunked encoding，
     MinIO 这类非 AWS 实现会直接报 `x-amz-content-sha256`（插件 issue #393），
     去掉它们 WAL 归档必失败。
- **备份落点仍是集群内 MinIO**：与数据库共用同一批本地盘，挡得住误删/数据损坏/PITR，
  挡不住主机或 LVM VG 整体损毁。要真容灾需再加一路集群外对象存储。

- **参数改了却不自动生效（2026-10-30/31 连接耗尽事故的复盘，CNPG 1.30）**：
  1. **字段名先对上**。CNPG 1.30 的 CRD 是 `spec.postgresql.parameters`；
     老记忆里的 `spec.postgresConfiguration` 不存在，`kubectl patch` 会报
     `unknown field "spec.postgresConfiguration"` 但 **patch 命令整体返回成功**——
     看起来"打了"，实际什么都没改。改完用
     `kubectl -n postgresql get cluster pg-main -o jsonpath='{.spec.postgresql.parameters.max_connections}'`
     回读确认。
  2. **官方承诺与实测的差距**：文档称改需重启的参数会自动滚动重启
     （1.30 原文："If the change involves a parameter requiring a restart, the
     operator will perform a rolling upgrade."），但 2026-10-31 实测：集群
     **healthy、无 Extraction Error** 的状态下 patch
     `superuser_reserved_connections`，operator 观察 10 分钟以上未动作，
     手动删 Pod 才生效（疑似单实例主库的保守策略）。**别只等自动重启**：
     patch 5 分钟后连库查 `pg_settings.pending_restart` / 直接 `show <参数>`，
     没生效就 `kubectl delete pod --grace-period=90`（**勿 --force**，见 4.e）。
  3. **死锁形态**：当实例 manager 因连接耗尽不可用时（连接被租户打满，
     manager 自己也拿不到槽位），集群 phase 变成
     `Instance Status Extraction Error: HTTP communication issue`——
     **operator 无法读取实例状态，就不会调度重启**，spec 变更无限期挂起；
     同时 manager 的 liveness 也可能连不上，kubelet 反复杀容器，形成
     "改了参数 → 不生效 → 手动删 Pod → 新实例照样 53300 → 循环"的僵局。
     2026-10-31 恢复时 `max_connections` 200→300→500 三次 patch 全部
     挂在这个状态里，最后一次干净重启才生效。
  4. **runbook**：
     a. 先看 phase：`kubectl -n postgresql get cluster pg-main -o jsonpath='{.status.phase}'`。
        正常应是 `Cluster in healthy state`；若是 Extraction Error，先解决连接耗尽
        （缩容客户端 / 找占用者），**别指望 patch 自己生效**。
     b. 不用连库就能读配置：`kubectl exec ... -- postgres -C max_connections -D $PGDATA`
        （这是"下次启动会用的值"）；运行中的实际值必须连库 `show max_connections`。
     c. 找占用者时连不上库的死循环可绕：`/proc/net/tcp` 按 local port 5432 统计
        已建立连接的来源 IP（注意过滤的是**本地**端口），或让各租户逐个缩容。
     d. `max_connections` 从文件到生效**必须重启**进程：`postgresql.conf`（100）→
        `custom.conf`（operator 写，当前 500）不一致时以 custom.conf 为准，
        但运行中进程还是旧值。
     e. **强删 Pod 的后遗症**：`--force --grace-period=0` 会跳过卷卸载，新 Pod 在
        同节点会 `FailedMount: device already mounted`——到该节点
        `umount /var/lib/kubelet/pods/<旧pod>/volumes/kubernetes.io~csi/<pvc>/mount`
        后自动恢复。非必要不 force；正常 delete 会走 smart shutdown，
        如果它卡住，多半又是上面的连接僵局。

## 连接容量与租户口径（2026-10-31 连接耗尽事故的 P2 结论）

**各租户池上限（prod 实值 = 仓库值，来自 Config Center `config.entry`，2026-10-31 核对）**

| 租户 | 口径 | max_conns |
|---|---|---|
| ecommerce 10 个业务服务（address/behavior/cart/inventory/merchant/order/payment/product/search/user） | 每服务 **×2 副本**，Config Center 热改键 `data.database.pool.max_conns` | 20（min 5） |
| openfga | `components/openfga/values.yaml` | 10 |
| libra-dl | `main.go` SetMaxOpenConns | 8 |
| umami | Prisma 默认 = num_cpus×2+1（External Secret 无 connection_limit） | ~5-9 |
| scorpius | **不在口径内**：SQLite，不连 pg-main | — |

**峰值必须按 Pod 算**：10×2×20 + openfga 10 + umami ~9 + libra-dl 8 ≈ **430+**；
崩溃循环时旧进程池未释放、新进程池再爬坡，瞬时更高。2026-10-30 打满 200
（当时上限）即此形态。当前稳态实测 ~60 连接，对照 480 可用（500−20 保留）余量充足。

**四层防线（已就位）**：max_connections=500、superuser_reserved_connections=20、
`PostgresConnUsageHigh`(80%) 告警、Config Center 可热改各租户 max_conns。

**PgBouncer：搁置**。触发条件（满足其一再启）：租户峰值按 Pod 算接近 300；
或 PG 升多实例需要跨实例池化。届时用 CNPG `Pooler` CR（transaction 模式），
前置条件是各服务确认无 session 级特性（prepared statements 需
`default_query_exec_mode=exec`、advisory lock、LISTEN/NOTIFY）。

**两个待办（Config Center 热改，无发版成本，下次顺手）**：
1. 各服务 DSN 加 `application_name=<服务名>`——pgx 默认不设，`pg_stat_activity`
   里只能看 IP 猜服务（2026-10-31 排障实证的窘境）；
2. `min_conns` 5→2：10×2×5=100 个常驻 idle 连接是纯内存负担。
