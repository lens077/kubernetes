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
| 对象存储备份 | **暂缺** | MinIO 与数据库跑在同一批本地盘上，备份到那里不构成异地容灾。要做备份应指向集群外（node1 VPS 或云端），且要走 Barman Cloud Plugin（见上）。**这是当前的已知缺口。** |
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
