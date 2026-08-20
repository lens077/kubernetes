#!/usr/bin/env bash
# OpenBao —— 凭据后端 + ESO 接线（选型定稿 §4）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (standalone + file 存储)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 0.29.2
kctl -n "$NAMESPACE" wait --for=condition=PodScheduled pod/openbao-0 --timeout=120s
sleep 5

bao_exec() { kctl -n "$NAMESPACE" exec -i openbao-0 -- "$@"; }
init_file="$STATE_DIR/creds/openbao-init"

# 初始化(仅一次): 1 share/1 threshold —— 测试环境取舍, 生产应提高并离线保存
if ! bao_exec bao status -format=json 2>/dev/null | grep -q '"initialized": *true'; then
  log_step "初始化 OpenBao (init 输出落 $init_file, 不进 git)"
  mkdir -p "$STATE_DIR/creds"
  bao_exec bao operator init -key-shares=1 -key-threshold=1 > "$init_file"
  chmod 600 "$init_file"
fi
UNSEAL_KEY=$(awk -F': ' '/Unseal Key 1/{print $2}' "$init_file")
ROOT_TOKEN=$(awk -F': ' '/Initial Root Token/{print $2}' "$init_file")

# 解封(幂等)
bao_exec bao status -format=json 2>/dev/null | grep -q '"sealed": *false' \
  || bao_exec bao operator unseal "$UNSEAL_KEY" >/dev/null

# KV v2 + 演示 secret + ESO 只读 token
bao_exec env BAO_TOKEN="$ROOT_TOKEN" bao secrets enable -path=secret kv-v2 2>/dev/null || true
bao_exec env BAO_TOKEN="$ROOT_TOKEN" bao kv put secret/demo username=demo password=change-me >/dev/null
bao_exec env BAO_TOKEN="$ROOT_TOKEN" sh -c 'cat > /tmp/eso-read.hcl <<POLICY
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
POLICY
bao policy write eso-read /tmp/eso-read.hcl' >/dev/null
if [[ ! -f "$STATE_DIR/creds/openbao-eso-token" ]]; then
  bao_exec env BAO_TOKEN="$ROOT_TOKEN" bao token create -policy=eso-read -ttl=768h -format=json \
    | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' > "$STATE_DIR/creds/openbao-eso-token"
  chmod 600 "$STATE_DIR/creds/openbao-eso-token"
fi
kctl -n external-secrets create secret generic openbao-eso-token \
  --from-literal=token="$(cat "$STATE_DIR/creds/openbao-eso-token")" \
  --dry-run=client -o yaml | kctl apply -f -
kctl apply -f "$DIR/examples/eso-wiring.yaml"
log_ok "$ID 安装完成(验证: kubectl -n default get externalsecret demo-from-openbao 应 Ready)"
