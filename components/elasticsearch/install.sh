#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}"); comp_load_meta "$DIR"; comp_require_cluster
ns_ensure "$NAMESPACE"
[[ -n "${ELASTICSEARCH_IMAGE_PULL_SECRET:-}" ]] && kctl -n "$NAMESPACE" get secret "$ELASTICSEARCH_IMAGE_PULL_SECRET" >/dev/null
for f in "$DIR"/manifests/*.yaml; do kctl apply -f "$f"; done
kctl -n "$NAMESPACE" rollout status statefulset/elasticsearch --timeout=300s
