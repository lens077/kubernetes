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
