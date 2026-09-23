# Elasticsearch

Elasticsearch 9.4.5 单节点使用公开镜像 `docker.elastic.co/elasticsearch/elasticsearch:9.4.5`，是 ecommerce 搜索 CDC 链的目标库；当前恢复不依赖 TCR 凭据或 IK 插件。`search` 服务经 Config Center 的 `search.catalog.endpoint = http://elasticsearch.elasticsearch.svc.cluster.local:9200` 只读 alias `ecommerce_catalog_products`。
2026-09-15 自 node3 Docker `cdc-elasticsearch` 迁入并切流，node3 副本已删除；仅 ClusterIP，不经 Pangolin 暴露（原 `es.apikv.com` 已退役）。

- 凭据：`elasticsearch-auth`（key `password-file`，通过 `ELASTIC_PASSWORD` 注入）；探针必须带认证（匿名 401 会被当成不健康）。
- 账号：`ecommerce_cdc_sink`（角色 `ecommerce-cdc-sink`：`ecommerce_*` 读写建索引 + cluster monitor）、`ecommerce_search`（角色 `ecommerce-search-read`：只读 catalog + cluster monitor，search 启动时会打 `GET /`）；search 用的是同权限的 API key，存 `ecommerce/search-k8s-api-key`。
- 索引契约：7 个索引模板 `ecommerce-cdc-<alias>`（pattern `<alias>_v*`，shards 1 / replicas 0，`dynamic: strict`，`name`/`description` 走 IK），mapping 真相源是本目录 `index-mappings.json`（从 pipeline 仓 `deploy/docker-node3/index-mappings.json` 拷来，改那边要同步这边）→ `<alias>_v1` → write alias。`bootstrap-indices.sh` 落地，`install.sh` 末尾调用。单节点下 replicas 必须为 0，否则 YELLOW。
- **2026-09-23 实付**：集群重建后这一步从没跑过，7 个索引全是 sink 自动建的——标准分词把中文切单字、`spu_code.search` 子字段不存在、`price` 是 float、replicas=1 让集群常年 YELLOW；`search` 服务的 `multi_match` 在那种索引上要么误命中要么查不到。修法是 `bootstrap-indices.sh --rotate`（建 `_v2` 切 alias）+ `components/kafka/cdc/reflow-sink.sh`（reset sink offset 重放 topic），7 表文档数与 PG 行数逐表对齐后删 `_v1`。
- 已知语义边界（不是 bug）：`ik_smart` 把「精华液」当整词，文档只有「精华」就搜不到；「精华」「小棕瓶」「钛金属」都能命中。要改得改契约，不在部署层动。
- 恢复边界：镜像已切换为公开 Elasticsearch 官方镜像；生产环境若恢复 IK 或私有镜像，必须另行配置 imagePullSecret 和索引 analyzer 验收。
