#!/usr/bin/env bash
# 被 80-components.sh 汇总进 /root/.k8s-installer-credentials 的一行摘要
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "alert-bridge → Bugsink webhook URL: http://alert-bridge.observability.svc.cluster.local:9199/bugsink/$(get_cred bugsink-bridge-token) (ntfy 凭据: \$STATE_DIR/creds/ntfy.env)"
