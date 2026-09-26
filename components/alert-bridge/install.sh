#!/usr/bin/env bash
# =============================================================================
# alert-bridge —— Alertmanager/Bugsink webhook → ntfy 推送; 幂等; 可单独执行:
#   NTFY_URL=https://ntfy.example.com NTFY_TOPIC=infra NTFY_TOKEN=tk_xxx bash components/alert-bridge/install.sh
#
# 凭据来源(优先级从高到低):
#   1. 环境变量 NTFY_URL / NTFY_TOPIC / NTFY_TOKEN
#   2. $STATE_DIR/creds/ntfy.env(KEY=VALUE 行; 首次从环境变量拿到后会自动落到这里, 重跑免传)
#   3. 都没有: 拒绝部署，避免覆盖现有 Secret 后静默丢通知。
# NTFY_TOPIC=core；NTFY_TICKET_TOPIC / NTFY_TEST_TOPIC 必须显式配置。
# BUGSINK_BRIDGE_TOKEN 是 Bugsink → 桥 的路径口令, 自动生成并持久化(creds 机制), 重装不变。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

creds_file="$STATE_DIR/creds/ntfy.env"
# Read defaults in a subshell; explicit environment values (including empty) win.
# Preserve unrelated entries because Gatus shares this credential file.
for key in NTFY_URL NTFY_TOPIC NTFY_TICKET_TOPIC NTFY_TEST_TOPIC NTFY_TOKEN; do
  if [[ -z ${!key+x} && -f $creds_file ]]; then
    value=$(source "$creds_file"; printf '%s' "${!key-}")
    printf -v "$key" '%s' "$value"
  fi
done
ntfy_url=${NTFY_URL:-} ntfy_topic=${NTFY_TOPIC:-} ntfy_token=${NTFY_TOKEN:-}
ntfy_ticket_topic=${NTFY_TICKET_TOPIC:-} ntfy_test_topic=${NTFY_TEST_TOPIC:-}
[[ $ntfy_url == https://* && -n $ntfy_topic && -n $ntfy_ticket_topic && -n $ntfy_test_topic ]] \
  || die "需要 HTTPS NTFY_URL 及 core/ticket/test 三个显式 topic；未修改 Secret"
[[ $ntfy_topic != "$ntfy_ticket_topic" && $ntfy_topic != "$ntfy_test_topic" && $ntfy_ticket_topic != "$ntfy_test_topic" ]] \
  || die "core/ticket/test topic 必须彼此不同；未修改 Secret"
[[ -n ${SC_NAME:-} ]] || die "SC_NAME 未配置（持久通知状态需要 PVC）"
[[ -f $STATE_DIR/creds/bugsink-bridge-token ]] \
  || ! kctl -n "$NAMESPACE" get secret alert-bridge-ntfy >/dev/null 2>&1 \
  || die "现有 bridge Secret 存在但本地 Bugsink token 缺失，拒绝轮换/覆盖"
mkdir -p "$STATE_DIR/creds"
(umask 077
 for key in NTFY_URL NTFY_TOPIC NTFY_TICKET_TOPIC NTFY_TEST_TOPIC NTFY_TOKEN; do
   printf '%s=%q\n' "$key" "${!key-}"
 done >> "$creds_file")
chmod 600 "$creds_file"
bridge_token=$(get_cred bugsink-bridge-token)   # 只生成一次

log_step "安装 $ID → 命名空间 $NAMESPACE (core/ticket/test 分流；持久退避状态)"
ns_ensure "$NAMESPACE"

kctl -n "$NAMESPACE" create secret generic alert-bridge-ntfy \
  --from-literal=NTFY_URL="$ntfy_url" \
  --from-literal=NTFY_TOPIC="$ntfy_topic" \
  --from-literal=NTFY_TICKET_TOPIC="$ntfy_ticket_topic" \
  --from-literal=NTFY_TEST_TOPIC="$ntfy_test_topic" \
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
log_warn "首次挂载空状态卷会立即通知当前 firing 组；保留 alert-bridge-state PVC 以保留退避状态"
log_info "  readiness: /healthz（配置不完整返回 503）；liveness: /livez"
