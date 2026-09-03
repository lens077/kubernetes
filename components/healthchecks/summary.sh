#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "healthchecks → https://hc.${CLUSTER_DOMAIN:-dev.test} 用户 admin@hc.${CLUSTER_DOMAIN:-dev.test} / 密码 $(get_cred healthchecks-admin) (svc: ops/healthchecks:8000)"
