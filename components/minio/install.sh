#!/usr/bin/env bash
# =============================================================================
# MinIO(pgsty/silo 镜像) —— S3 兼容对象存储; 幂等; 可单独执行:
#   bash components/minio/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${MINIO_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

# 凭据(L3):首选线上 Vault(secret/k8s/minio)经 ESO 物化;store 不可用再回退
# get_cred 本地随机值。两条路产出同一个 Secret minio-root{user,password},Deployment 无感。
if kctl get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
  # 旧的 get_cred 版 Secret 不归 ESO 所有,存在则先删,否则 ESO 报 secret exists 拒接管
  if kctl -n "$NAMESPACE" get secret minio-root >/dev/null 2>&1 \
     && ! kctl -n "$NAMESPACE" get secret minio-root -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null | grep -q ExternalSecret; then
    log_warn "接管 legacy minio-root Secret(get_cred 版)→ 改由 Vault/ESO 物化"
    kctl -n "$NAMESPACE" delete secret minio-root
  fi
  kctl apply -f "$DIR/externalsecret.yaml"
  for _ in $(seq 1 24); do
    kctl -n "$NAMESPACE" get secret minio-root >/dev/null 2>&1 && break
    sleep 5
  done
  kctl -n "$NAMESPACE" get secret minio-root >/dev/null 2>&1 \
    || die "ESO 未物化 minio-root:查 Vault 的 secret/k8s/minio 是否存在、store 是否 Ready、VPS vault 是否 sealed"
else
  log_warn "ClusterSecretStore vault 不可用 → 回退 get_cred 本地随机凭据(与 Vault 脱钩,重装不保凭据)"
  pass=$(get_cred minio-root)
  kctl -n "$NAMESPACE" create secret generic minio-root \
    --from-literal=user=admin --from-literal=password="$pass" \
    --dry-run=client -o yaml | kctl apply -f -
fi

tmp=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")"
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

routes_apply "$DIR"
log_ok "$ID 安装完成(S3: minio-service.$NAMESPACE.svc:9000 / 控制台 https://$HOSTNAME)"
