#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "Meilisearch→ https://search.${CLUSTER_DOMAIN:-app.com} master key $(get_cred meili-master-key) (svc: search/meilisearch:7700, GET /health)"
