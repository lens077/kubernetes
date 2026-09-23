#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}"); comp_load_meta "$DIR"; comp_require_cluster
ns_ensure "$NAMESPACE"
[[ -n "${ELASTICSEARCH_IMAGE_PULL_SECRET:-}" ]] && kctl -n "$NAMESPACE" get secret "$ELASTICSEARCH_IMAGE_PULL_SECRET" >/dev/null
for f in "$DIR"/manifests/*.yaml; do kctl apply -f "$f"; done
kctl -n "$NAMESPACE" rollout status statefulset/elasticsearch --timeout=300s
# 索引契约(模板 + _v1 + write alias)必须先于 ES sink 存在, 否则 sink 自动建出错 mapping(见 bootstrap-indices.sh 头注)
bash "$DIR/bootstrap-indices.sh" || log_warn "索引契约与现有索引不一致(exit $?): bash $DIR/bootstrap-indices.sh --rotate 建新版本并切 alias, 然后重灌 sink"

# ---- search 只读 API key(2026-09-23): 角色 ecommerce-search-read + API key → Secret search-api-key ----
# 幂等: 角色每次 PUT(声明式); API key 只在 Secret 缺失时签一次(ES API key 明文只返回一次, 不能重读)。
# 要轮换: kubectl -n elasticsearch delete secret search-api-key 后重跑, 再在 ES 里 invalidate 旧 key。
es_admin() { kctl -n "$NAMESPACE" exec -c elasticsearch elasticsearch-0 -- curl -sS -u "elastic:$1" -H 'Content-Type: application/json' "${@:2}"; }
espw=$(kctl -n "$NAMESPACE" get secret elasticsearch-auth -o jsonpath='{.data.password-file}' | base64 -d)
es_admin "$espw" -X PUT http://127.0.0.1:9200/_security/role/ecommerce-search-read -d '{
  "cluster": ["monitor"],
  "indices": [{"names": ["ecommerce_catalog_products", "ecommerce_catalog_products_*"], "privileges": ["read", "view_index_metadata"]}]
}' >/dev/null && log_ok "ES 角色 ecommerce-search-read 已就位(只读 catalog)"
if ! kctl -n "$NAMESPACE" get secret search-api-key >/dev/null 2>&1; then
  key=$(es_admin "$espw" -X POST http://127.0.0.1:9200/_security/api_key -d '{
    "name": "ecommerce-search",
    "role_descriptors": {"ecommerce-search-read": {"cluster": ["monitor"],
      "indices": [{"names": ["ecommerce_catalog_products", "ecommerce_catalog_products_*"], "privileges": ["read", "view_index_metadata"]}]}}
  }' | jq -r '.encoded // empty')
  [[ -n $key ]] || die "签发 search API key 失败"
  kctl -n "$NAMESPACE" create secret generic search-api-key --from-literal=api_key="$key" >/dev/null
  unset key; log_ok "search API key 已签发 → Secret $NAMESPACE/search-api-key(api_key = base64(id:key), 直接放 Authorization: ApiKey)"
fi
unset espw
routes_apply "$DIR"   # gateway/httproute.yaml: es.dev.test → :9200(给 Pangolin es-dev 用)
log_ok "$ID 安装完成"
