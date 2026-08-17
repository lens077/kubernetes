#!/usr/bin/env bash
# =============================================================================
# external-secrets(ESO) —— 幂等; 可被 80-components.sh 调用, 也可单独执行:
#   VAULT_ROLE_ID=... VAULT_SECRET_ID=... bash components/external-secrets/install.sh
#
# AppRole 凭据(secret zero)从环境变量注入,写成 Secret vault-approle,不入 Git。
# 来源:线上 VPS /home/docker/vault/approle-eso.json(见 docker-deploy 仓 vault/README)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

# webhook 就绪前 apply ESO 的 CR 会撞 TLS 握手失败,先等它
kctl -n "$NAMESPACE" rollout status deploy/external-secrets-webhook --timeout=300s

# ---- secret zero: AppRole 凭据 ---------------------------------------------
if [[ -n ${VAULT_ROLE_ID:-} && -n ${VAULT_SECRET_ID:-} ]]; then
  kctl -n "$NAMESPACE" create secret generic vault-approle \
    --from-literal=role-id="$VAULT_ROLE_ID" \
    --from-literal=secret-id="$VAULT_SECRET_ID" \
    --dry-run=client -o yaml | kctl apply -f -
  log_ok "Secret vault-approle 已写入"
elif kctl -n "$NAMESPACE" get secret vault-approle >/dev/null 2>&1; then
  log_skip "Secret vault-approle 已存在(未传新凭据,保留现值)"
else
  log_warn "缺 AppRole 凭据 → ClusterSecretStore 会 NotReady。获取后重跑
  (VPS 的 SSH 坐标见私有仓 docker-deploy 的 vault/README.md;本仓公开,刻意不写):
  ssh <VPS> 'cat /home/docker/vault/approle-eso.json'
  VAULT_ROLE_ID=... VAULT_SECRET_ID=... bash components/external-secrets/install.sh"
fi

# ---- ClusterSecretStore ----------------------------------------------------
retry 5 5 kctl apply -f "$DIR/clustersecretstore.yaml"

# ---- 验证(有凭据才有意义) --------------------------------------------------
if kctl -n "$NAMESPACE" get secret vault-approle >/dev/null 2>&1; then
  ready=""
  for _ in $(seq 1 12); do
    ready=$(kctl get clustersecretstore vault \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ $ready == True ]] && break
    sleep 5
  done
  [[ $ready == True ]] || die "ClusterSecretStore vault 未就绪: $(kctl get clustersecretstore vault \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
  常见原因:Vault sealed(去 VPS 跑 vault/unseal.sh)、凭据错、LAN 出网不通"
  log_ok "ClusterSecretStore vault Ready"
fi

log_ok "$ID 安装完成(冒烟: kubectl apply -f $DIR/examples/externalsecret-demo.yaml)"
