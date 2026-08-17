#!/usr/bin/env bash
# =============================================================================
# gateway —— 共享 L7 入口(泛域名证书 + default/cilium-gateway)
#   幂等; 可被 80-components.sh 调用, 也可单独执行:
#     bash components/gateway/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

[[ ${CILIUM_ENABLE_GATEWAY_API:-true} == true ]] \
  || { log_skip "config.env 里 CILIUM_ENABLE_GATEWAY_API=false, 跳过共享网关"; exit 0; }
kctl get gatewayclass cilium >/dev/null 2>&1 \
  || die "GatewayClass cilium 不存在 —— 先跑 bootstrap 的 60-cilium(gatewayAPI.enabled)"
kctl get clusterissuer global-ca-issuer >/dev/null 2>&1 \
  || die "缺 ClusterIssuer global-ca-issuer —— 先装 cert-manager 组件"

log_step "应用共享网关(域名后缀 ${CLUSTER_DOMAIN:-app.com})"
tmp=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")"
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

# 证书没签出的话 Gateway 的 https listener 会一直 Programmed=False, 这里让失败早暴露
kctl -n default wait --for=condition=Ready certificate/global-default-tls-cert --timeout=180s \
  || log_warn "泛域名证书未就绪: kubectl -n default describe certificate global-default-tls-cert"

if kctl -n default wait --for=condition=Programmed gateway/cilium-gateway --timeout=180s; then
  addr=$(kctl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
  log_ok "共享网关就绪: $addr (80/443) —— 组件路由 parentRef 到 default/cilium-gateway"
else
  log_warn "网关未 Programmed: kubectl -n default describe gateway cilium-gateway"
fi
