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

# 暴露模式二选一，统一交给独立脚本，install.sh 不再自己写 server.insecure：
#   http（默认）= 共享网关终结 TLS，server 走明文（本集群原状）
#   tls          = server 自出 TLS，网关只做 SNI passthrough（原生 gRPC 可用）
# 两条路径互斥且都可重入，切换用 components/argo/mode-{http,tls}.sh。
MODE=${ARGOCD_SERVER_MODE:-http}
case $MODE in
  http|tls) ;;
  *) die "ARGOCD_SERVER_MODE 只能是 http 或 tls（当前: $MODE）" ;;
esac
bash "$DIR/mode-$MODE.sh"

log_ok "$ID 安装完成(https://$HOSTNAME, 模式 $MODE; 初始密码见 summary 或 argocd-initial-admin-secret)"
