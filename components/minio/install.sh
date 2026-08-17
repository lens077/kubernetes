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

pass=$(get_cred minio-root)

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${MINIO_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

# 凭据走 Secret: 原来是写死在 Deployment 的明文 env, kubectl get deploy 就能看到
kctl -n "$NAMESPACE" create secret generic minio-root \
  --from-literal=user=admin --from-literal=password="$pass" \
  --dry-run=client -o yaml | kctl apply -f -

tmp=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")"
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

routes_apply "$DIR"
log_ok "$ID 安装完成(S3: minio-service.$NAMESPACE.svc:9000 / 控制台 https://$HOSTNAME)"
