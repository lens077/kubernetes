#!/usr/bin/env bash
# =============================================================================
# config-center-rotate-service-tokens.sh —— ecommerce service token 的 fail-closed 轮换
#
#   ENV=pre bash tools/config-center-rotate-service-tokens.sh            # dry-run: 只打印计划
#   CONFIRM=yes ENV=pre bash tools/config-center-rotate-service-tokens.sh --apply
#
# 三阶段, 旧 token 只在最后一阶段吊销(2026-09-15 演练教训: 先吊销再滚动, 滚动一半失败 → 9 个服务
# 的 Pod 拿着已吊销的 token 跑, watch 流 401):
#   A 逐服务: 签发新 token → 用【新 token 本身】GetKey 读回 → 写 selector Secret(新 id 记入
#     service-token-ids, 旧 id 记入 service-token-ids-previous)。任何失败 → 停, 旧 token 完好。
#   B 滚动全部消费者并等就绪(只用 get 轮询, 不需要 list 权限)。失败 → 停, 旧 token 仍有效, Pod
#     要么已在新 token 上, 要么还在旧 token 上, 都能用。
#   C 全部就绪后吊销 previous 里的旧 token, 清空 previous。吊销失败 → 停, previous 保留。
# 续跑: previous 注解非空 = 上次停在 B/C。此时不签新 token, 只重做 B(等就绪) + C(吊销), 幂等。
#
# 身份: 只用预先签好的 operator token(ADMIN_TOKEN_SECRET), 不接受管理员密码; operator 不能签 operator。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" && pwd)/env.sh"

ENVIRONMENT=${ENVIRONMENT:-pre}
NS=${ECOMMERCE_NAMESPACE:-ecommerce}
SELECTOR=${SELECTOR_SECRET:-ecommerce-config-source-$ENVIRONMENT}
ANN_IDS="config-center/service-token-ids"
ANN_PREV="config-center/service-token-ids-previous"
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-240}
DRY=1; [[ ${1:-} == --apply ]] && DRY=0
ADMIN_TOKEN_SECRET=${ADMIN_TOKEN_SECRET:-config-center/config-center-operator$([[ $ENVIRONMENT == pre ]] || echo "-$ENVIRONMENT"):token}
[[ $DRY == 1 || ${CONFIRM:-no} == yes ]] || die "轮换写入需要 CONFIRM=yes"

ns=${ADMIN_TOKEN_SECRET%%/*}; rest=${ADMIN_TOKEN_SECRET#*/}; sec=${rest%%:*}; key=${rest#*:}
operator=$(kctl -n "$ns" get secret "$sec" -o jsonpath="{.data.$key}" | base64 -d)
[[ -n $operator ]] || die "读不到 operator token: $ADMIN_TOKEN_SECRET"
CC_URL=${CONFIG_CENTER_URL:-http://$(kctl -n config-center get svc config-center -o jsonpath='{.spec.clusterIP}'):30010}
services=${SERVICES:-"address behavior cart inventory merchant order payment product search user"}

rpc() { # rpc <Method> <json> <token>
  curl -fsS --max-time 20 -X POST "$CC_URL/config.v1.ConfigService/$1" -H 'Content-Type: application/json' \
    -H "x-config-center-service-token: $3" -H 'x-config-center-client-name: token-rotation' -d "$2"
}
ann() { local v; v=$(kctl -n "$NS" get secret "$SELECTOR" -o jsonpath="{.metadata.annotations.$1}" 2>/dev/null || true); [[ -n $v ]] && printf '%s' "$v" || printf '{}'; }
ids=$(ann "$ANN_IDS");  [[ $ids != "{}" ]] || die "$NS/$SELECTOR 缺少 $ANN_IDS 注解; 先 harvest --rotate-tokens 建立 token ID 关联, 拒绝猜测旧 token"
prev=$(ann "$ANN_PREV")

# ---- B: 滚动 + 只用 get 轮询等就绪 -------------------------------------------
wait_ready() { # wait_ready <deploy>
  local dep=$1 t=0 j
  while (( t < ROLLOUT_TIMEOUT )); do
    j=$(kctl -n "$NS" get deploy "$dep" -o json)
    if jq -e '(.spec.replicas // 1) as $r | (.status.observedGeneration // 0) >= .metadata.generation
              and (.status.updatedReplicas // 0) == $r and (.status.readyReplicas // 0) == $r
              and (.status.replicas // 0) == $r' <<<"$j" >/dev/null; then return 0; fi
    sleep 5; t=$((t+5))
  done
  return 1
}
roll_consumers() {
  local svc dep
  for svc in $services; do
    dep="ecommerce-$svc-deploy"
    kctl -n "$NS" get deploy "$dep" >/dev/null 2>&1 || { log_info "· $dep 不存在, 跳过"; continue; }
    [[ $(kctl -n "$NS" get deploy "$dep" -o jsonpath='{.spec.replicas}') == 0 ]] && { log_info "· $dep 副本 0, 跳过"; continue; }
    kctl -n "$NS" rollout restart "deploy/$dep" >/dev/null
  done
  for svc in $services; do
    dep="ecommerce-$svc-deploy"
    kctl -n "$NS" get deploy "$dep" >/dev/null 2>&1 || continue
    [[ $(kctl -n "$NS" get deploy "$dep" -o jsonpath='{.spec.replicas}') == 0 ]] && continue
    wait_ready "$dep" && log_ok "$dep 已在新 token 上就绪" || die "$dep ${ROLLOUT_TIMEOUT}s 内未就绪; 旧 token 未吊销, 消费者仍可用。排查后重跑本脚本(续跑模式)"
  done
}
# ---- C: 吊销 previous 中的旧 token -------------------------------------------
revoke_previous() {
  local svc old r failed=""
  for svc in $(jq -r 'keys[]' <<<"$prev"); do
    old=$(jq -r --arg s "$svc" '.[$s]' <<<"$prev")
    r=$(rpc RevokeMachineToken "$(jq -nc --arg id "$old" '{id:$id}')" "$operator") || r='{"code":"transport"}'
    if jq -e '.code == null' <<<"$r" >/dev/null; then log_ok "$svc: 旧 token $old 已吊销"; else failed+=" $svc($old)"; fi
  done
  [[ -z $failed ]] || die "吊销失败:$failed —— previous 注解保留, 重跑本脚本只会重试吊销"
  kctl -n "$NS" annotate secret "$SELECTOR" "$ANN_PREV-" >/dev/null
}

# ---- 续跑模式 ------------------------------------------------------------------
if [[ $prev != "{}" ]]; then
  log_info "检测到上次未完成的轮换($(jq -r 'keys|join(" ")' <<<"$prev")): 不签新 token, 只重做 B(等就绪)+C(吊销)"
  [[ $DRY == 0 ]] || { echo "dry-run: 会等这些消费者就绪后吊销 previous 中的 token"; exit 0; }
  roll_consumers; revoke_previous
  log_ok "续跑完成"; exit 0
fi

# ---- A: 逐服务签发 + 用新 token 读回 + 写 Secret --------------------------------
if [[ $DRY == 1 ]]; then
  for svc in $services; do echo "$svc: old=$(jq -r --arg s "$svc" '.[$s] // "<missing>"' <<<"$ids") → A 签发+新token读回+写Secret, B 滚动等就绪, C 吊销旧"; done
  echo "dry-run 结束: 未签发、未写 Secret、未滚动、未吊销"; exit 0
fi
for svc in $services; do
  old_id=$(jq -r --arg s "$svc" '.[$s] // empty' <<<"$ids"); [[ -n $old_id ]] || die "$svc: 缺少旧 token ID, 拒绝轮换"
  issued=$(rpc IssueMachineToken "$(jq -nc --arg s "$svc" --arg e "$ENVIRONMENT" \
    '{service_name:$s,environment:$e,note:"service-token rotation",role:"MACHINE_TOKEN_ROLE_SERVICE"}')" "$operator")
  new=$(jq -r '.token // empty' <<<"$issued"); new_id=$(jq -r '.meta.id // empty' <<<"$issued")
  [[ -n $new && -n $new_id ]] || die "$svc: 新 token 签发失败: $(jq -c 'del(.token)' <<<"$issued" 2>/dev/null)"
  # 用新 token 本身读回(不是 operator): 证明这枚 token 能当该服务用
  back=$(rpc GetKey "$(jq -nc --arg s "$svc" --arg e "$ENVIRONMENT" '{namespace:$s,environment:$e,key:"bootstrap.yaml"}')" "$new") \
    || { rpc RevokeMachineToken "$(jq -nc --arg id "$new_id" '{id:$id}')" "$operator" >/dev/null || true; die "$svc: 新 token $new_id 读不了 $svc/$ENVIRONMENT/bootstrap.yaml, 已吊销它; 旧 token 完好"; }
  [[ $(jq -r '.entry.key // empty' <<<"$back") == bootstrap.yaml ]] || die "$svc: 新 token 读回内容异常; 旧 token 完好"
  old_cfg=$(kctl -n "$NS" get secret "$SELECTOR" -o jsonpath="{.data.$svc\.yaml}" | base64 -d)
  next=$(SERVICE_TOKEN="$new" OLD="$old_cfg" python3 - <<'PY'
import os, yaml
x = yaml.safe_load(os.environ['OLD']); x['config_center']['service_token'] = os.environ['SERVICE_TOKEN']
print(yaml.safe_dump(x, allow_unicode=True, sort_keys=False))
PY
)
  kctl -n "$NS" get secret "$SELECTOR" -o json | jq --arg k "$svc.yaml" --arg v "$(printf %s "$next" | base64 | tr -d '\n')" \
      --arg s "$svc" --arg nid "$new_id" --arg oid "$old_id" --arg A "$ANN_IDS" --arg P "$ANN_PREV" '
    .metadata.annotations = (.metadata.annotations // {})
    | .metadata.annotations[$A] = ((.metadata.annotations[$A] // "{}") | fromjson | . + {($s): $nid} | tojson)
    | .metadata.annotations[$P] = ((.metadata.annotations[$P] // "{}") | fromjson | . + {($s): $oid} | tojson)
    | .data[$k] = $v
    | {apiVersion, kind, type, metadata: {name: .metadata.name, namespace: .metadata.namespace, annotations: .metadata.annotations, labels: (.metadata.labels // {})}, data}' \
    | kctl apply -f - >/dev/null || die "$svc: selector Secret 写入失败; 旧 token 完好, 新 token $new_id 已签发未启用(可用 RevokeMachineToken 清理)"
  log_ok "$svc: A 完成 new=$new_id (old=$old_id 待 C 阶段吊销)"
done
prev=$(ann "$ANN_PREV")

# ---- B + C ----------------------------------------------------------------------
roll_consumers
revoke_previous
log_ok "轮换完成: $(wc -w <<<"$services") 个服务, 旧 token 已全部吊销"
