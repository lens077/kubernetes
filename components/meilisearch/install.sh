#!/usr/bin/env bash
# =============================================================================
# Meilisearch —— 商品即时搜索; 幂等; 可单独执行:
#   bash components/meilisearch/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

key=$(get_cred meili-master-key)   # 只生成一次; 重装不换 key(换了客户端要同步改)

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${MEILI_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic meilisearch-master-key \
  --from-literal=MEILI_MASTER_KEY="$key" \
  --dry-run=client -o yaml | kctl apply -f -

helm_install_component "$DIR"
routes_apply "$DIR"

log_ok "$ID 安装完成(svc: $NAMESPACE/meilisearch:7700, master key 见 /root/.k8s-installer-credentials)"
