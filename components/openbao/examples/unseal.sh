#!/usr/bin/env bash
# Pod 重启后手工解封(file 存储的 seal 状态不随重启保留解封)
set -euo pipefail
STATE_DIR=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/k8s-installer}
UNSEAL_KEY=$(awk -F': ' '/Unseal Key 1/{print $2}' "$STATE_DIR/creds/openbao-init")
kubectl -n openbao exec openbao-0 -- bao operator unseal "$UNSEAL_KEY"
