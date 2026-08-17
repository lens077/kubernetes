# meilisearch —— 商品即时搜索

## 1. 定位

ecommerce 的搜索后端（商品即时搜索）。2026-08 从 OpenSearch/Elasticsearch 改判过来的：
elastic v9 客户端的产品头校验连不上 OpenSearch，而搜索面只有一条查询，
Meilisearch 中文分词开箱可用、还省 1G+ 内存。

## 2. 上游最佳实践

来源：[Meilisearch 文档](https://www.meilisearch.com/docs)、
[meilisearch-kubernetes](https://github.com/meilisearch/meilisearch-kubernetes)

- `MEILI_ENV=production` 时**强制要求 master key**（development 模式不要求，且会开放 UI）。
- master key 至少 16 字节；用它派生只读/只写的 API key 给客户端，不要把 master key 发给应用。
- 单实例设计，没有官方的分布式模式；高可用靠快照 + 重建。
- 索引构建期是内存峰值，按文档量给 limits。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| master key 手工设置 | `get_cred meili-master-key` | 只生成一次存 creds，重装不换 key（换了客户端要同步改）。 |
| Service 默认 | ClusterIP + HTTPRoute | 对外只经共享网关（`search.app.com`）。 |
| 无 limits | `limits.memory 1Gi` | 索引构建期内存峰值；1Gi 对当前商品量级有余量。 |

## 4. 暴露方式

- 集群内：`meilisearch.search.svc.cluster.local:7700`
- 对外：`https://search.app.com`（共享网关）
- 认证：`Authorization: Bearer <master key>`，key 见 `/root/.k8s-installer-credentials`

## 5. 验证

```bash
KEY=$(cat /var/lib/k8s-installer/creds/meili-master-key)
kubectl -n search exec statefulset/meilisearch -- \
  wget -qO- --header "Authorization: Bearer $KEY" http://127.0.0.1:7700/health
# {"status":"available"}
```

真验证（写一条文档再搜回来）：

```bash
kubectl -n search exec statefulset/meilisearch -- sh -c \
  "wget -qO- --header 'Authorization: Bearer $KEY' --header 'Content-Type: application/json' \
   --post-data '[{\"id\":1,\"name\":\"探针商品\"}]' http://127.0.0.1:7700/indexes/probe/documents"
sleep 3
kubectl -n search exec statefulset/meilisearch -- sh -c \
  "wget -qO- --header 'Authorization: Bearer $KEY' 'http://127.0.0.1:7700/indexes/probe/search?q=探针'"
```

## 6. 踩坑

- **启动即退出、日志说要 master key**：`MEILI_ENV=production` 下 key 是必需的，
  secret 没建好就会这样。
- **客户端 401**：master key 与应用侧配置不一致。重装不会换 key，但删过 creds 文件就会。
- **迁移待办**：ecommerce 仓的 search 服务要从 elastic 客户端换成 meilisearch-go，
  address 服务要删 ES 残留 DI，CDC 管道要从 BulkIndexer 改成 documents 批量 + index swap。
  详见 ecommerce 仓的 TODO.md。
