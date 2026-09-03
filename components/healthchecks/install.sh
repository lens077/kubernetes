#!/usr/bin/env bash
# =============================================================================
# healthchecks —— 死人开关(cron/备份到点不 ping 就告警); 幂等; 可单独执行:
#   bash components/healthchecks/install.sh
# 首次安装自动建超级用户 admin@<HOSTNAME>(密码走 creds 机制, 重装不变)。
# 接 CronJob 的模板见 examples/cnpg-backup-ping-cronjob.yaml 与 README。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

secret_key=$(get_cred healthchecks-secret-key)
admin_pass=$(get_cred healthchecks-admin)
admin_email="admin@$HOSTNAME"

log_step "安装 $ID → 命名空间 $NAMESPACE (PVC ${HEALTHCHECKS_STORAGE_SIZE}/${SC_NAME})"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic healthchecks-secret \
  --from-literal=SECRET_KEY="$secret_key" \
  --dry-run=client -o yaml | kctl apply -f -

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"
routes_apply "$DIR"

# 超级用户: 官方命令支持 --email/--password 非交互; 已存在会报 "already taken", 视为幂等成功
if kctl -n "$NAMESPACE" rollout status deploy/healthchecks --timeout=300s >/dev/null 2>&1; then
  msg=$(kctl -n "$NAMESPACE" exec deploy/healthchecks -- \
          /opt/healthchecks/manage.py createsuperuser --email "$admin_email" --password "$admin_pass" 2>&1 || true)
  case $msg in
    *"already taken"*) log_info "超级用户 $admin_email 已存在" ;;
    *)                 log_info "createsuperuser: ${msg:-ok}" ;;
  esac
else
  log_warn "Pod 5 分钟内未就绪(多半是镜像还在拉), 跳过建超级用户; 稍后重跑本脚本即可"
fi

log_ok "$ID 安装完成: https://$HOSTNAME  用户 $admin_email / 密码见 /root/.k8s-installer-credentials"
log_info "  集群内 ping 地址前缀: http://healthchecks.$NAMESPACE.svc.cluster.local:8000/ping/<uuid>"
