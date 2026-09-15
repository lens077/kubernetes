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

# 凭据(L3): ESO 从 ${ESO_STORE}(定稿 OpenBao, k8s/<集群>/minio)物化 Secret minio-root{user,password};
# store 不可用或 OFFLINE=1 时退回 get_cred 本地随机值(_lib/env.sh cred_via_eso)。两条路产出同一个 Secret, Deployment 无感。
# 组件当前 ADDON_MINIO=false(2026-08-20 定稿迁 Silo), 本段只保证重新启用时与其它组件同构。
if ! cred_via_eso "$DIR" "$NAMESPACE" minio-root; then
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
