#!/usr/bin/env bash
# =============================================================================
# Redis(官方 OSS 单机, 原生 TLS) —— 幂等; 可单独执行:
#   bash components/redis/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pass=$(get_cred redis-password)

log_step "安装 $ID → 命名空间 $NAMESPACE (maxmemory ${REDIS_MAXMEMORY}, TLS by global-ca-issuer)"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic redis-password-secret \
  --from-literal=password="$pass" \
  --dry-run=client -o yaml | kctl apply -f -

# TLS 证书先于 chart: Pod 启动即挂 secret redis-tls, 没有它会卡 ContainerCreating
kctl get clusterissuer global-ca-issuer >/dev/null 2>&1 \
  || die "ClusterIssuer global-ca-issuer 不存在, 先装 cert-manager 组件"
_cert=$(mktemp)
render_tpl "$DIR/certificate.yaml" "$_cert"
kctl apply -f "$_cert"; rm -f "$_cert"
kctl -n "$NAMESPACE" wait certificate/redis-tls --for=condition=Ready --timeout=120s

# OCI chart 必须显式 --version(registry 不解析 latest, 同 dragonflydb 的坑);
# CloudPirates 是 monorepo 多 chart 共库, GitHub release tag 对不上单个 chart 版本,
# 无法走 resolve_version, 故在 config.env 里显式钉版本(同 fluent-bit 的做法)。
helm_install_component "$DIR" --version "${REDIS_CHART_VERSION:-0.34.17}"

routes_apply "$DIR"
log_ok "$ID 安装完成(集群内 rediss://redis.$NAMESPACE.svc:6380, 密码见 creds/redis-password)"
