#!/usr/bin/env bash
# =============================================================================
# Consul —— 服务注册/发现 + KV 配置中心(ecommerce Kratos 服务依赖); 幂等; 可单独执行:
#   bash components/consul/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${CONSUL_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

helm_install_component "$DIR"
routes_apply "$DIR"

# ACL 恢复：chart 只负责 bootstrap root token，不会替 ecommerce 建应用 policy/token。
# 每次 install/重建都幂等补齐 policy；已有应用 token 有效则保留，失效/缺失才签发新 token。
# 凭据只在进程与 K8s Secret 之间流动，不打印；策略不授予 KV 管理权限。
reconcile_ecommerce_acl() {
  local root app policy_file new
  root=$(kctl -n "$NAMESPACE" get secret consul-bootstrap-acl-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [[ -n $root ]] || { log_warn "缺少 consul-bootstrap-acl-token，跳过 ecommerce ACL 恢复（Consul ACL bootstrap 尚未完成）"; return 0; }
  policy_file=$(mktemp)
  cat > "$policy_file" <<'POLICY'
service_prefix "" { policy = "write" }
node_prefix "" { policy = "read" }
agent_prefix "" { policy = "read" }
query_prefix "" { policy = "read" }
key_prefix "" { policy = "read" }
POLICY
  kctl -n "$NAMESPACE" cp "$policy_file" consul-server-0:/tmp/ecommerce-services.hcl >/dev/null
  if ! kctl -n "$NAMESPACE" exec consul-server-0 -- sh -c \
    "CONSUL_HTTP_TOKEN=\"$root\" consul acl policy create -name ecommerce-services -description 'ecommerce service registration and discovery' -rules @/tmp/ecommerce-services.hcl >/dev/null"; then
    # policy 已存在时 create 会返回非 0；后续仍要验证/恢复应用 token。
    log_info "ecommerce-services policy 已存在或未更新, 继续检查应用 token"
  fi
  rm -f "$policy_file"

  app=$(kctl -n ecommerce get secret consul-ecommerce-token -o jsonpath='{.data.CONSUL_HTTP_TOKEN}' 2>/dev/null | base64 -d || true)
  if [[ -n $app ]] && kctl -n "$NAMESPACE" exec consul-server-0 -- env CONSUL_HTTP_TOKEN="$app" consul acl token read -self >/dev/null 2>&1; then
    log_info "ecommerce Consul 应用 token 有效, 保留现值"
    return 0
  fi

  new=$(kctl -n "$NAMESPACE" exec consul-server-0 -- env CONSUL_HTTP_TOKEN="$root" \
    consul acl token create -description 'ecommerce services' -policy-name ecommerce-services -format json \
    | jq -r '.SecretID // empty')
  [[ -n $new ]] || { log_warn "无法签发 ecommerce Consul 应用 token"; return 0; }
  kctl -n ecommerce create secret generic consul-ecommerce-token \
    --from-literal=CONSUL_HTTP_TOKEN="$new" --dry-run=client -o yaml | kctl apply -f - >/dev/null
  log_ok "ecommerce Consul 应用 token 已恢复(Secret ecommerce/consul-ecommerce-token)"
}

reconcile_ecommerce_acl

log_ok "$ID 安装完成(集群内 consul-server.$NAMESPACE.svc:8500; 局域网 API 看 svc consul-expose-servers 的 EXTERNAL-IP)"
