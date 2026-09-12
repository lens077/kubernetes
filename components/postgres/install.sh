#!/usr/bin/env bash
# =============================================================================
# CloudNativePG —— 算子 + pg-main 实例 + ecommerce 库(2026-08-21 起全自动;
#   规格另裁时 PG_CREATE_MAIN_CLUSTER=false 退回只装算子+手工 apply examples/)
#   幂等; 可单独执行: bash components/postgres/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pg_tls_route_ready() {
  local accepted resolved
  accepted=$(kctl -n postgresql get tlsroute pg-main \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  resolved=$(kctl -n postgresql get tlsroute pg-main \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)
  [[ $accepted == True && $resolved == True ]]
}

log_step "安装 $ID(CloudNativePG 算子) → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

log_ok "$ID 算子安装完成"

# 2026-08-21 起: 勾选 ADDON_CNPG 即全自动建实例+库(原先只打印手工提示)。
# 规格差异大的场景仍可在 config.env 置 PG_CREATE_MAIN_CLUSTER=false 退回手工。
if [[ "${PG_CREATE_MAIN_CLUSTER:-true}" == "true" ]]; then
  # Cluster CR 要过算子的 webhook, 必须等算子真正就绪
  kctl -n "$NAMESPACE" rollout status deploy/cnpg-cloudnative-pg --timeout=180s
  ns_ensure postgresql
  _pg=$(mktemp)
  render_tpl "$DIR/examples/pg-cluster.yaml" "$_pg"
  retry 3 10 kctl apply -f "$_pg"
  rm -f "$_pg"
  log_step "等待 pg-main 实例就绪(首装含拉镜像+initdb, 最长 10min)"
  kctl -n postgresql wait cluster/pg-main --for=condition=Ready --timeout=600s
  kctl apply -f "$DIR/examples/pg-database.yaml"
  # Database CR 无标准 Ready condition, 轮询 applied 字段
  for _i in 1 2 3 4 5 6; do
    [[ "$(kctl -n postgresql get database ecommerce -o jsonpath='{.status.applied}' 2>/dev/null)" == "true" ]] && break
    sleep 5
  done
  log_ok "pg-main + ecommerce 库就绪(app 角色口令在 secret pg-main-app)"

  # pg-main-rw 存在后再挂路由，避免首次安装长期停在 ResolvedRefs=False。
  routes_apply "$DIR"
  if [[ ${CILIUM_ENABLE_GATEWAY_API:-true} == true ]] \
      && kctl get gatewayclass cilium >/dev/null 2>&1; then
    kctl -n postgresql wait --for=condition=Programmed \
      gateway/pg-passthrough-gateway --timeout=180s
    wait_for "pg-main TLSRoute Accepted + ResolvedRefs" 180 pg_tls_route_ready
    pg_vip=$(kctl -n postgresql get gateway pg-passthrough-gateway \
      -o jsonpath='{.status.addresses[0].value}')
    [[ -n $pg_vip ]] || die "pg-passthrough-gateway 已 Programmed 但没有分配地址"
    log_ok "pg-main 宿主网入口就绪: $pg_vip:5432 (SNI=pg.dev.test, TLS passthrough)"
  fi
else
  log_info "PG_CREATE_MAIN_CLUSTER=false: 手工建库 → kubectl apply -f $DIR/examples/pg-cluster.yaml + pg-database.yaml"
fi
