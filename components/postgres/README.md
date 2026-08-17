# postgres —— CloudNativePG 算子

## 1. 定位

PostgreSQL 的生命周期管理（建库、备份、故障转移、滚动升级）。本组件**只装算子**，
数据库实例由用户按需 apply（规格差异大）：`examples/pg-cluster.yaml`。

ecommerce 的业务库、Debezium CDC 的源库都跑在它上面。

## 2. 上游最佳实践

来源：[CloudNativePG 文档](https://cloudnative-pg.io/documentation/)

- 算子与实例分离：算子装一次，`Cluster` CR 按需创建。
- 生产实例 ≥3 副本（同步复制），配 `backup.barmanObjectStore` 做 WAL 归档到对象存储。
- 参数调优走 `spec.postgresql.parameters`，别进容器改 `postgresql.conf`（会被 reconcile 覆盖）。
- 算子自动为实例签发 TLS 证书（服务端 + 客户端 CA），默认就是加密连接。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| ≥3 实例同步复制 | 示例给 `instances: 1` | 两节点集群，3 副本必然有两个落在同一节点，故障域没变——徒增内存。要 HA 先加节点。 |
| 对象存储备份 | **暂缺** | MinIO 与数据库跑在同一批本地盘上，备份到那里不构成异地容灾。要做备份应指向集群外（node3 或云端）。**这是当前的已知缺口。** |
| bitnami postgresql-ha | 换 CNPG | bitnami 镜像 2025 年起受限；CNPG 不需要 pgpool/repmgr 附加组件。 |

## 4. 暴露方式

- 集群内：CNPG 自动创建 `<cluster>-rw` / `<cluster>-ro` / `<cluster>-r` 三个 Service
- 对外：TLS passthrough + SNI 分流，模板与说明见 [`gateway/README.md`](gateway/README.md)
  （**TLSRoute 必须用 `v1`**，旧清单的 `v1alpha2` 已不再 served）

## 5. 验证

```bash
kubectl -n cnpg-system get deploy cnpg-cloudnative-pg          # READY 1/1
kubectl api-resources | grep postgresql.cnpg.io                # CRD 已注册
```

真验证（建一个实例再连进去）：

```bash
kubectl create ns postgresql
kubectl apply -f components/postgres/examples/pg-cluster.yaml   # 注意 ${SC_NAME} 需先替换
kubectl -n postgresql wait --for=condition=Ready cluster/pg-main --timeout=600s
kubectl -n postgresql exec pg-main-1 -- psql -U postgres -c 'select version()'
```

## 6. 踩坑

- **PVC Pending**：OpenEBS LVM 本地卷有节点亲和，实例只能建在有对应 VG 的节点上。
- **改了 postgresql.conf 却被还原**：CNPG 会 reconcile 回 CR 里声明的参数，
  改配置要改 `spec.postgresql.parameters`。
- **Debezium CDC 相关**：复制槽残留、`publication` 缺失、`binary.handling.mode` 取值等
  一整套踩坑记录在仓库根的 [TODO.md](../../TODO.md)（2026-08-06 那次排查）。
