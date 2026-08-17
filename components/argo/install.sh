#!/usr/bin/env bash
# =============================================================================
# ArgoCD —— 官方 yaml manifest 安装; 幂等; 可单独执行:
#   bash components/argo/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

ver=${ARGOCD_VERSION:-}
[[ -z $ver ]] && ver=$(resolve_version ARGOCD argoproj/argo-cd "v3.5.1" "")

log_step "安装 $ID $ver → 命名空间 $NAMESPACE"
ns_ensure "$NAMESPACE"

manifest="${CACHE_DIR:-/tmp}/argocd-install-$ver.yaml"
mkdir -p "$(dirname "$manifest")"
[[ -s $manifest ]] || fetch "$(gh_url "https://raw.githubusercontent.com/argoproj/argo-cd/$ver/manifests/install.yaml")" "$manifest"

# CRD 体积超 client-side apply 的注解上限(同 strimzi 的坑), 必须 server-side
kctl apply -n "$NAMESPACE" --server-side --force-conflicts -f "$manifest"

# 网关终结 TLS: server 走明文, 否则会出现"网关已解密、server 又要求 HTTPS"的重定向死循环
kctl -n "$NAMESPACE" patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kctl -n "$NAMESPACE" rollout restart deploy argocd-server >/dev/null

routes_apply "$DIR"
log_ok "$ID 安装完成(https://$HOSTNAME; 初始密码见 summary 或 argocd-initial-admin-secret)"
