#!/usr/bin/env bash
# =============================================================================
# alert-bridge —— Alertmanager/Bugsink webhook → ntfy 推送; 幂等; 可单独执行:
#   NTFY_URL=https://ntfy.example.com NTFY_TOPIC=infra NTFY_TOKEN=tk_xxx bash components/alert-bridge/install.sh
#
# 凭据来源(优先级从高到低):
#   1. 环境变量 NTFY_URL / NTFY_TOPIC / NTFY_TOKEN
#   2. $STATE_DIR/creds/ntfy.env(KEY=VALUE 行; 首次从环境变量拿到后会自动落到这里, 重跑免传)
#   3. 都没有: 仍然安装, 桥只把告警写日志不推送(链路先打通, 凭据后补); 补上后重跑本脚本即可
# BUGSINK_BRIDGE_TOKEN 是 Bugsink → 桥 的路径口令, 自动生成并持久化(creds 机制), 重装不变。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

creds_file="$STATE_DIR/creds/ntfy.env"
ntfy_url=${NTFY_URL:-} ntfy_topic=${NTFY_TOPIC:-} ntfy_token=${NTFY_TOKEN:-}
if [[ -z $ntfy_url && -f $creds_file ]]; then
  # shellcheck disable=SC1090
  source "$creds_file"
  ntfy_url=${NTFY_URL:-}; ntfy_topic=${NTFY_TOPIC:-}; ntfy_token=${NTFY_TOKEN:-}
fi
if [[ -n $ntfy_url ]]; then
  [[ -n $ntfy_topic ]] || die "NTFY_URL 已给但 NTFY_TOPIC 为空"
  mkdir -p "$STATE_DIR/creds"
  printf 'NTFY_URL=%s\nNTFY_TOPIC=%s\nNTFY_TOKEN=%s\n' "$ntfy_url" "$ntfy_topic" "$ntfy_token" > "$creds_file"
  chmod 600 "$creds_file"
fi
bridge_token=$(get_cred bugsink-bridge-token)   # 只生成一次

log_step "安装 $ID → 命名空间 $NAMESPACE (ntfy: ${ntfy_url:-未配置, 只记日志})"
ns_ensure "$NAMESPACE"

kctl -n "$NAMESPACE" create secret generic alert-bridge-ntfy \
  --from-literal=NTFY_URL="$ntfy_url" \
  --from-literal=NTFY_TOPIC="$ntfy_topic" \
  --from-literal=NTFY_TOKEN="$ntfy_token" \
  --from-literal=BUGSINK_BRIDGE_TOKEN="$bridge_token" \
  --dry-run=client -o yaml | kctl apply -f -

kctl -n "$NAMESPACE" create configmap alert-bridge-script \
  --from-file=bridge.py="$DIR/bridge.py" \
  --dry-run=client -o yaml | kctl apply -f -

# 脚本指纹进 Pod 注解: ConfigMap 变了 Deployment 才会滚动(否则旧进程一直跑旧脚本)
# shellcheck disable=SC2034  # render_tpl 通过间接展开读取
BRIDGE_SHA256=$(sha256sum "$DIR/bridge.py" | awk '{print $1}')
out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")" BRIDGE_SHA256
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"

log_ok "$ID 安装完成"
log_info "  Alertmanager receiver: http://alert-bridge.$NAMESPACE.svc.cluster.local:9099/alerts"
log_info "  Bugsink webhook:       http://alert-bridge.$NAMESPACE.svc.cluster.local:9199/bugsink/<token>(token 见 /root/.k8s-installer-credentials)"
if [[ -z $ntfy_url ]]; then
  log_warn "ntfy 未配置: 告警只写桥的日志(kubectl -n $NAMESPACE logs deploy/alert-bridge), 不推送手机"
  log_warn "  补上后重跑: NTFY_URL=... NTFY_TOPIC=... NTFY_TOKEN=... bash $DIR/install.sh"
fi
