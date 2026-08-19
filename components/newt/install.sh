#!/usr/bin/env bash
# =============================================================================
# newt —— Pangolin 隧道客户端(把集群服务经公网 VPS 暴露); 幂等; 可单独执行:
#   NEWT_ID=xxx NEWT_SECRET=yyy bash components/newt/install.sh
#
# 凭据从哪来: Pangolin 面板建一个 type=newt 的站点时生成, 只在创建那一刻回显一次
# (面板 API 之后不再返回 secret)。首次拿到后本脚本会存进 creds 目录, 重复执行直接复用。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

# 环境变量优先(首次安装), 否则读 creds(重装/重跑)
newt_id=${NEWT_ID:-}
newt_secret=${NEWT_SECRET:-}
[[ -z $newt_id     && -f $STATE_DIR/creds/newt-id     ]] && newt_id=$(cat "$STATE_DIR/creds/newt-id")
[[ -z $newt_secret && -f $STATE_DIR/creds/newt-secret ]] && newt_secret=$(cat "$STATE_DIR/creds/newt-secret")

if [[ -z $newt_id || -z $newt_secret ]]; then
  log_error "缺少 newt 凭据。到 Pangolin 面板新建一个 type=newt 的站点, 然后:"
  log_info  "  NEWT_ID=<newtId> NEWT_SECRET=<secret> bash $DIR/install.sh"
  log_info  "  (secret 只在建站点那一刻回显一次, 之后面板 API 不再返回 —— 丢了只能重建站点)"
  die "凭据缺失"
fi

# 落 creds, 之后重跑不必再传
mkdir -p "$STATE_DIR/creds"
printf '%s' "$newt_id"     > "$STATE_DIR/creds/newt-id"
printf '%s' "$newt_secret" > "$STATE_DIR/creds/newt-secret"
chmod 600 "$STATE_DIR/creds/newt-id" "$STATE_DIR/creds/newt-secret"

log_step "安装 $ID → 命名空间 $NAMESPACE (Pangolin 隧道客户端)"
ns_ensure "$NAMESPACE"

kctl -n "$NAMESPACE" create secret generic newt-credentials \
  --from-literal=id="$newt_id" \
  --from-literal=secret="$newt_secret" \
  --dry-run=client -o yaml | kctl apply -f -

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"

log_ok "$ID 安装完成"
log_info "验证隧道真的建立了(看面板 online 而不是看 Pod Running):"
log_info "  kubectl -n $NAMESPACE logs deploy/newt | grep -i 'connect\\|registered'"
