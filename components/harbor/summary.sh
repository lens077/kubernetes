#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "Harbor → https://${HOSTNAME:-harbor.${CLUSTER_DOMAIN:-dev.test}}；OCI 仓库 + Trivy；管理员初始密码见 $STATE_DIR/creds/harbor-admin"
