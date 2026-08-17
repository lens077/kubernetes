#!/usr/bin/env bash
# =============================================================================
# Dragonfly —— Redis 协议兼容缓存(go-redis 客户端零改动); 幂等; 可单独执行:
#   bash components/dragonflydb/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pass=$(get_cred dragonfly-password)

log_step "安装 $ID → 命名空间 $NAMESPACE (maxmemory ${DRAGONFLY_MAXMEMORY} / ${DRAGONFLY_PROACTOR_THREADS} 线程)"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic dragonfly-password-secret \
  --from-literal=password="$pass" \
  --dry-run=client -o yaml | kctl apply -f -

# OCI chart 必须带显式版本: registry 不解析 latest, 不给 --version 会报
# "unable to locate any tags in provided repository"(实测)。
# 留空时解析 GitHub 最新版并锁进 versions.lock, 保证重复执行一致; 兜底 v1.40.1。
ver=${DRAGONFLY_CHART_VERSION:-}
[[ -z $ver ]] && ver=$(resolve_version DRAGONFLY dragonflydb/dragonfly "v1.40.1" "")
log_info "chart 版本: $ver"
helm_install_component "$DIR" --version "$ver"

routes_apply "$DIR"
log_ok "$ID 安装完成(集群内 dragonfly.$NAMESPACE.svc:6379; 密码见 /root/.k8s-installer-credentials)"
