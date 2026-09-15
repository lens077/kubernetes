# meilisearch —— 退役回滚组件

> **退役状态（2026-09-04）**：ecommerce 已切到 Elasticsearch；本组件的 Helm release、运行资源、Secret、HTTPRoute、PVC/PV 与 `search` namespace 均已删除。`ADDON_MEILISEARCH` 与 `DEFAULT_ENABLED` 默认为 `false`。本目录只保留显式人工回滚安装能力，不属于现役拓扑。

## 1. 定位

历史搜索后端的可重建安装器。旧索引数据已经删除；若紧急回退，必须显式启用本组件、重新构建索引，并恢复与旧 search 镜像匹配的 Bootstrap。不得把它重新加入现役服务矩阵。

已有安装器状态的主机可能在 `$STATE_DIR/components.selected` 留有旧选择；拉取本次退役变更后，先运行 `bootstrap/start.sh --reset-state 80-components` 删除旧选择，再重跑 `80-components` 阶段，让 `ADDON_MEILISEARCH=false` 重新生成选择。安装脚本本身也会 fail-closed：只有把 `bootstrap/config.env` 显式改为 `ADDON_MEILISEARCH=true` 并重置阶段，或单独执行时显式传入 `MEILISEARCH_RETIREMENT_ROLLBACK=true`，才允许安装。

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
| Service 默认 | ClusterIP + HTTPRoute | 对外只经共享网关（`search.dev.test`）。 |
| 无 limits | `limits.memory 1Gi` | 索引构建期内存峰值；1Gi 对当前商品量级有余量。 |

## 4. 显式启用后的暴露方式

- 集群内：`meilisearch.search.svc.cluster.local:7700`
- 对外：`https://search.dev.test`（共享网关）
- 认证：`Authorization: Bearer <master key>`，key 由安装器凭据目录提供

## 5. 回滚重建后的验证

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
- **退役边界**：默认安装流程不得创建本组件。只有明确的人工回滚决策才能把开关改为 `true`；回滚结束后再次卸载，并确认全集群工作负载、Job 与 NetworkPolicy 都不引用 `7700`。
