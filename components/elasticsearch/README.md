# Elasticsearch

Elasticsearch 9.4.5 + analysis-ik 单节点（镜像 `ccr.ccs.tencentyun.com/sumery/ecommerce-elasticsearch:9.4.5-ik-9.4.5`，源自 pipeline 仓 `Dockerfile.elasticsearch`），是 ecommerce 搜索 CDC 链的目标库；`search` 服务经 Config Center 的 `search.catalog.endpoint = http://elasticsearch.elasticsearch.svc.cluster.local:9200` 只读 alias `ecommerce_catalog_products`。
2026-09-15 自 node3 Docker `cdc-elasticsearch` 迁入并切流，node3 副本已删除；仅 ClusterIP，不经 Pangolin 暴露（原 `es.apikv.com` 已退役）。

- 凭据：`elasticsearch-auth`（key `password-file`，挂成 0400 文件供 `ELASTIC_PASSWORD_FILE`，ES 拒绝 0644）；探针必须带认证（匿名 401 会被当成不健康）。
- 账号：`ecommerce_cdc_sink`（角色 `ecommerce-cdc-sink`：`ecommerce_*` 读写建索引 + cluster monitor）、`ecommerce_search`（角色 `ecommerce-search-read`：只读 catalog + cluster monitor，search 启动时会打 `GET /`）；search 用的是同权限的 API key，存 `ecommerce/search-k8s-api-key`。
- 索引契约：7 个索引模板 `ecommerce-cdc-<alias>`（pattern `<alias>_v*`，shards 1 / replicas 0，mapping 来自 pipeline 仓 `index-mappings.json`）→ `<alias>_v1` → write alias。单节点下 replicas 必须为 0，否则 YELLOW。
- 私有镜像拉取：`tcr-pull-secret`（从 `ecommerce` 命名空间同款复制）。
