#!/usr/bin/env bash
# =============================================================================
# umami —— 网站分析(无 cookie, 自托管); 幂等; 可单独执行: bash components/umami/install.sh
# 数据库是集群内 CNPG pg-main 的 umami 库(UMAMI_DB_ENDPOINT), 本组件不建库也不建 PVC。
# 2026-09-22: 旧 node3 Pigsty 已退役; 启用前先在 pg-main 里建好 umami 库与同名属主角色。
# 首次启动跑 Prisma 迁移建表, 默认账号 admin/umami —— 登录后**立刻改密码**。
# 应用接入: 面板 Settings → Websites 建站点拿 websiteId, 见 README。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (PG ${UMAMI_DB_ENDPOINT}, 镜像 ${UMAMI_IMAGE##*/})"
ns_ensure "$NAMESPACE"

# 凭据: ESO 从 OpenBao secret/k8s/$CLUSTER_NAME/umami 物化(app-secret/two-factor-key/database-url)。
# 降级路径不能凭空造 DATABASE_URL —— 密码不在仓库里(硬规则 4), 必须由调用方给 UMAMI_DATABASE_URL。
if ! cred_via_eso "$DIR" "$NAMESPACE" umami-secret; then
  [[ -n ${UMAMI_DATABASE_URL:-} ]] || die "ESO 不可用且未提供 UMAMI_DATABASE_URL。
  二选一:
    1) 修好 ESO/OpenBao 后重跑(推荐, 真相源在 secret/k8s/$CLUSTER_NAME/umami)
    2) UMAMI_DATABASE_URL='postgresql://umami:<密码>@${UMAMI_DB_ENDPOINT}/umami' bash $0"
  mkdir -p "$STATE_DIR/creds"
  # APP_SECRET 换掉只会让登录态失效; TWO_FACTOR_ENCRYPTION_KEY 换掉会让已绑定的 2FA
  # 永久失效, 所以两者都只生成一次并持久化, 重装复用。
  for k in umami-app-secret umami-two-factor-key; do
    [[ -f $STATE_DIR/creds/$k ]] && continue
    openssl rand -hex 32 > "$STATE_DIR/creds/$k"
    chmod 600 "$STATE_DIR/creds/$k"
  done
  kctl -n "$NAMESPACE" create secret generic umami-secret \
    --from-literal=APP_SECRET="$(cat "$STATE_DIR/creds/umami-app-secret")" \
    --from-literal=TWO_FACTOR_ENCRYPTION_KEY="$(cat "$STATE_DIR/creds/umami-two-factor-key")" \
    --from-literal=DATABASE_URL="$UMAMI_DATABASE_URL" \
    --dry-run=client -o yaml | kctl apply -f -
fi

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"
routes_apply "$DIR"

log_ok "$ID 安装完成: https://$HOSTNAME  首次登录 admin/umami —— 立刻改密码"
log_info "  埋点: 面板 Settings → Websites 建站点拿 websiteId,"
log_info "        再在 ecommerce 仓设 NEXT_PUBLIC_UMAMI_WEBSITE_ID / VITE_UMAMI_WEBSITE_ID"
