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

log_step "安装 $ID → 命名空间 $NAMESPACE (maxmemory ${DRAGONFLY_MAXMEMORY} / ${DRAGONFLY_PROACTOR_THREADS} 线程)"
ns_ensure "$NAMESPACE"

# 密码: ESO 从 OpenBao/Vault 物化(externalsecret.yaml); store 未就绪或 OFFLINE=1 时退回 get_cred
ESO_SECRET_CHANGED=0
if ! cred_via_eso "$DIR" "$NAMESPACE" dragonfly-password-secret; then
  pass=$(get_cred dragonfly-password)
  kctl -n "$NAMESPACE" create secret generic dragonfly-password-secret \
    --from-literal=password="$pass" \
    --dry-run=client -o yaml | kctl apply -f -
fi

# 原生 TLS(与 redis 组件同构): cert-manager 签发, Pod 启动前 secret 必须就绪
kctl get clusterissuer global-ca-issuer >/dev/null 2>&1 \
  || die "ClusterIssuer global-ca-issuer 不存在, 先装 cert-manager 组件"
_cert=$(mktemp)
_tls_before=$(kctl -n "$NAMESPACE" get secret dragonfly-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | sha256sum | cut -c1-12 || true)
render_tpl "$DIR/certificate.yaml" "$_cert" REMOTE_HOST
kctl apply -f "$_cert"; rm -f "$_cert"
kctl -n "$NAMESPACE" wait certificate/dragonfly-tls --for=condition=Ready --timeout=120s
sleep 3   # SAN 变了 cert-manager 会重签, 给它把新 Secret 写回的时间
_tls_after=$(kctl -n "$NAMESPACE" get secret dragonfly-tls -o jsonpath='{.data.tls\.crt}' | sha256sum | cut -c1-12)
TLS_CHANGED=$([[ -n $_tls_before && $_tls_before != "$_tls_after" ]] && echo 1 || echo 0)

# OCI chart 必须带显式版本: registry 不解析 latest, 不给 --version 会报
# "unable to locate any tags in provided repository"(实测)。
# 留空时解析 GitHub 最新版并锁进 versions.lock, 保证重复执行一致; 兜底 v1.40.1。
ver=${DRAGONFLY_CHART_VERSION:-}
[[ -z $ver ]] && ver=$(resolve_version DRAGONFLY dragonflydb/dragonfly "v1.40.1" "")
log_info "chart 版本: $ver"
helm_install_component "$DIR" --version "$ver"

routes_apply "$DIR"

# Deployment 引用的 Secret 名没变时 helm/kubectl 都不会触发滚动; 密码从 env 读取, 值变了必须重启。
# 没装 reloader 时这里显式做; 装了 reloader 的话它也会做同一件事(注解见下), 二者幂等。
if [[ $ESO_SECRET_CHANGED == 1 || ${TLS_CHANGED:-0} == 1 ]]; then
  log_info "密码或证书已变, 滚动 deploy/dragonfly 让新值生效(消费方在 Config Center 里的密码请跑 tools/config-center-harvest.sh)"
  kctl -n "$NAMESPACE" rollout restart deploy/dragonfly >/dev/null
  kctl -n "$NAMESPACE" rollout status deploy/dragonfly --timeout=180s >/dev/null || log_warn "dragonfly 滚动未就绪"
fi
# Reloader 点名注解(chart 只有 podAnnotations, Deployment 级注解只能事后加; kubectl annotate 是 metadata
# 合并, helm 三方 merge 不会冲突 —— 与 README §6 说的「别 kubectl patch args」不是一回事)
kctl -n "$NAMESPACE" annotate deploy/dragonfly secret.reloader.stakater.com/reload=dragonfly-password-secret --overwrite >/dev/null

log_ok "$ID 安装完成(集群内 rediss://dragonfly.$NAMESPACE.svc:6379 原生 TLS; 密码真相源 OpenBao k8s/${CLUSTER_NAME:-<集群>}/dragonfly, 降级时见 creds/dragonfly-password)"
