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

log_step "应用共享网关(域名后缀 ${CLUSTER_DOMAIN:-dev.test})"
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

# wait 只看 Programmed=True 出现; 之后用 lib/common.sh 的 shared_gateway_problems 复核:
# 条件必须属于当前 generation, 生成的 Service 请求注解与实际分配都必须是固定 VIP。
if ! kctl -n default wait --for=condition=Programmed gateway/cilium-gateway --timeout=180s; then
  kctl -n default describe gateway cilium-gateway | tail -40 >&2 || true
  die "共享 Gateway 180s 内未 Programmed(检查 LB-IPAM 池、固定 VIP、证书与 listener)"
fi
gw_json=$(kctl -n default get gateway cilium-gateway -o json)
svc_json=$(kctl -n default get svc cilium-gateway-cilium-gateway -o json 2>/dev/null) || svc_json=""
problems=$(shared_gateway_problems "$gw_json" "$svc_json" "$CILIUM_GATEWAY_LB_IP")
[[ -z $problems ]] || die "共享 Gateway 状态与固定 VIP $CILIUM_GATEWAY_LB_IP 不一致:"$'\n'"$problems"
log_ok "共享网关就绪: $CILIUM_GATEWAY_LB_IP (80/443, 固定 VIP, LB-IPAM 请求已满足) —— 组件路由 parentRef 到 default/cilium-gateway"
log_info "newt Pod → VIP:443 → HTTPRoute 的实际路径尚未验证, 见 README.md §5"
