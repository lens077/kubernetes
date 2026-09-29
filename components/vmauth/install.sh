#!/usr/bin/env bash
# =============================================================================
# vmauth —— metrics.apikv.com 的只读鉴权代理; 幂等; 可单独执行:
#   bash components/vmauth/install.sh
#   VMAUTH_SKIP_ROUTE=1 bash components/vmauth/install.sh   # 只装代理不切路由(灰度: 先在集群内验证)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed "$NAMESPACE" vm-single-victoria-metrics-single-server \
  || die "$ID: 找不到 $NAMESPACE/vm-single-victoria-metrics-single-server, 先装 victoriametrics"

log_step "安装 $ID → 命名空间 $NAMESPACE ($VMAUTH_IMAGE)"
ns_ensure "$NAMESPACE"

# 凭据: 与 otlp-public-auth 同机制(节点 creds 只生成一次, 重跑不变)。值只在 creds 文件与 Secret 里。
read_token=$(get_cred vmauth-read-token)
ui_password=$(get_cred vmauth-ui-password)
kctl -n "$NAMESPACE" create secret generic vmauth-credentials \
  --from-literal=read-token="$read_token" --from-literal=ui-password="$ui_password" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null

# 配置或凭据变化 → Pod 模板注解变化 → 滚动(vmauth 只在启动时展开 %{ENV})
VMAUTH_CONFIG_SHA=$( { cat "$DIR/manifests/vmauth.yaml"; printf '%s\n%s\n' "$read_token" "$ui_password"; } | sha256sum | cut -c1-16)
out=$(mktemp)
render_tpl "$DIR/manifests/vmauth.yaml" "$out" VMAUTH_IMAGE VMAUTH_CONFIG_SHA
kctl apply -f "$out"
rm -f "$out"
kctl -n "$NAMESPACE" rollout status deploy/vmauth --timeout=180s

if [[ ${VMAUTH_SKIP_ROUTE:-0} == 1 ]]; then
  log_warn "$ID: VMAUTH_SKIP_ROUTE=1, 未切换 $HOSTNAME 路由(公网仍直连 VM)"
else
  routes_apply "$DIR"
fi

log_ok "$ID 安装完成: https://$REMOTE_HOST 只读; 程序用 Authorization: Bearer <read-token>, 浏览器 VMUI 用户 ops"
log_info "  token/密码: kubectl -n $NAMESPACE get secret vmauth-credentials -o jsonpath='{.data.read-token}' | base64 -d"
