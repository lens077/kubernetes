#!/usr/bin/env bash
# =============================================================================
# bugsink —— 错误追踪(Sentry SDK 兼容); 幂等; 可单独执行: bash components/bugsink/install.sh
# 首次启动用 CREATE_SUPERUSER 建 admin(密码走 creds 机制, 重装不变)。
# 应用接入: 在面板建项目拿 DSN(形如 https://<key>@bugsink.<域名>/<project_id>), 见 README。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

# SECRET_KEY 要求 >= 50 字符; get_cred 只给 24 个十六进制字符, 这里单独生成并持久化
mkdir -p "$STATE_DIR/creds"
if [[ ! -f $STATE_DIR/creds/bugsink-secret-key ]]; then
  openssl rand -base64 60 | tr -d '\n=/+' | cut -c1-64 > "$STATE_DIR/creds/bugsink-secret-key"
  chmod 600 "$STATE_DIR/creds/bugsink-secret-key"
fi
secret_key=$(cat "$STATE_DIR/creds/bugsink-secret-key")
admin_pass=$(get_cred bugsink-admin)
admin_email="admin@$HOSTNAME"

log_step "安装 $ID → 命名空间 $NAMESPACE (PVC ${BUGSINK_STORAGE_SIZE}/${SC_NAME}, 事件保留 ${BUGSINK_EVENT_RETENTION_DAYS} 天)"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic bugsink-secret \
  --from-literal=SECRET_KEY="$secret_key" \
  --from-literal=CREATE_SUPERUSER="$admin_email:$admin_pass" \
  --dry-run=client -o yaml | kctl apply -f -

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"
routes_apply "$DIR"

log_ok "$ID 安装完成: https://$HOSTNAME  用户 $admin_email / 密码见 /root/.k8s-installer-credentials"
log_info "  issue 通知 → 告警桥: 面板里 Project → Alerts → Webhook, URL 用 alert-bridge 的 Bugsink webhook(见凭据文件)"
