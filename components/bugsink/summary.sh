#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "bugsink    → https://bugsink.${CLUSTER_DOMAIN:-dev.test} 用户 admin@bugsink.${CLUSTER_DOMAIN:-dev.test} / 密码 $(get_cred bugsink-admin) (svc: ops/bugsink:8000)"
