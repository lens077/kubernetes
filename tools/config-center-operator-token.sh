#!/usr/bin/env bash
# =============================================================================
# config-center-operator-token.sh —— 用管理员 JWT 签一枚 role=OPERATOR 的 machine token, 存成 K8s Secret
#
#   在控制面节点执行(需要 /root/.casdoor-login, 见 config-center-admin-token.sh 头注释):
#     bash tools/config-center-operator-token.sh                 # environment=pre, Secret config-center/config-center-operator
#     ENVIRONMENT=dev bash tools/config-center-operator-token.sh
#   之后所有 harvest / 轮换都不再需要 Casdoor 会话:
#     ADMIN_TOKEN_SECRET=config-center/config-center-operator:token bash tools/config-center-harvest.sh
#
# operator token 的边界(control-tower docs/design/machine-token.md「operator 角色」): 只在自身 environment 内
# 读写键、签发/吊销 service token; 不能签 operator、不能 DeleteKey/Rollback。明文只进 Secret, 不打印、不落盘。
# 前置: config 服务镜像 ≥ 0.2.11(goose 版本 3, machine_token.role 列)。
# 轮换: 重跑本脚本(签新 → 覆盖 Secret), 再用管理员 JWT 在管理台 /tokens 吊销旧的那枚。
# =============================================================================
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}; [[ -r $KUBECONFIG ]] || unset KUBECONFIG

ENVIRONMENT=${ENVIRONMENT:-pre}
SECRET_NS=${SECRET_NS:-config-center}
SECRET_NAME=${SECRET_NAME:-config-center-operator}
SERVICE_NAME=${SERVICE_NAME:-harvest}          # 主体名会是 operator:harvest, 落审计与 revision author
CC_URL=${CONFIG_CENTER_URL:-http://$(kubectl -n config-center get svc config-center -o jsonpath='{.spec.clusterIP}'):30010}

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
die() { log "✘ $*"; exit 1; }
rpc() { curl -sS --max-time 20 -X POST "$CC_URL/config.v1.ConfigService/$1" -H 'Content-Type: application/json' "${@:3}" -d "$2"; }
rpc_ok() { if jq -e '.code != null' <<<"$1" >/dev/null 2>&1; then die "$2: $(jq -r '"\(.code): \(.message)"' <<<"$1")"; fi; }

# 0) 前置: 服务版本支持 role
ver=$(kubectl -n config-center get deploy config-center -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
log "config 服务镜像 $ver(需 ≥ 0.2.11)"

# 1) 管理员 JWT(15 分钟, 只在本进程内存)
ADMIN=$(bash "$HERE/config-center-admin-token.sh" --print) || die "取管理员 JWT 失败(见上; /root/.casdoor-login 是否就绪?)"
[[ -n $ADMIN ]] || die "管理员 JWT 为空"

# 2) 签发 operator
note="$(hostname) harvest/rotate operator, issued $(date +%F)"
body=$(jq -nc --arg s "$SERVICE_NAME" --arg e "$ENVIRONMENT" --arg n "$note" \
  '{service_name:$s, environment:$e, note:$n, role:"MACHINE_TOKEN_ROLE_OPERATOR"}')
resp=$(rpc IssueMachineToken "$body" -H "Authorization: Bearer $ADMIN")
rpc_ok "$resp" "IssueMachineToken"
tok=$(jq -r '.token // empty' <<<"$resp"); id=$(jq -r '.meta.id' <<<"$resp"); role=$(jq -r '.meta.role' <<<"$resp")
[[ -n $tok ]] || die "未返回 token"
[[ $role == MACHINE_TOKEN_ROLE_OPERATOR ]] || die "返回的 role 是 $role, 服务端不认识 OPERATOR(镜像未升级?)"
log "已签发 operator token id=$id (environment=$ENVIRONMENT, namespaces=*)"

# 3) 存成 Secret(覆盖)
kubectl -n "$SECRET_NS" create secret generic "$SECRET_NAME" --from-literal=token="$tok" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$SECRET_NS" annotate secret "$SECRET_NAME" "config-center/machine-token-id=$id" --overwrite >/dev/null
log "Secret $SECRET_NS/$SECRET_NAME 已写入(注解记录 token id, 便于吊销)"

# 4) 用它读一次、写一次(读回), 证明真的能当管理面用
resp=$(rpc GetKey '{"namespace":"cart","environment":"'"$ENVIRONMENT"'","key":"bootstrap.yaml"}' -H "x-config-center-service-token: $tok" -H "x-config-center-client-name: operator-token-check")
rpc_ok "$resp" "operator GetKey"
log "✔ operator 读 cart/$ENVIRONMENT/bootstrap.yaml v$(jq -r .entry.version <<<"$resp") 成功"
resp=$(rpc ListMachineTokens '{"environment":"'"$ENVIRONMENT"'"}' -H "x-config-center-service-token: $tok")
rpc_ok "$resp" "operator ListMachineTokens"
log "✔ operator 可列 token($(jq -r '.tokens|length' <<<"$resp") 枚)"
log "完成。之后: ADMIN_TOKEN_SECRET=$SECRET_NS/$SECRET_NAME:token bash tools/config-center-harvest.sh --dry-run"
