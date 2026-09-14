#!/usr/bin/env bash
# Rotate service tokens with a fail-closed state machine.
# Requires an existing operator token; never accepts an admin password.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" && pwd)/env.sh"
ENVIRONMENT=${ENVIRONMENT:-pre}; NS=${ECOMMERCE_NAMESPACE:-ecommerce}; SELECTOR=${SELECTOR_SECRET:-ecommerce-config-source-$ENVIRONMENT}
DRY=1; [[ ${1:-} == --apply ]] && DRY=0
ADMIN_TOKEN_SECRET=${ADMIN_TOKEN_SECRET:-config-center/config-center-operator$(if [[ $ENVIRONMENT == pre ]]; then echo; else echo -$ENVIRONMENT; fi):token}
[[ $DRY == 1 || ${CONFIRM:-no} == yes ]] || die "轮换写入需要 CONFIRM=yes"
ns=${ADMIN_TOKEN_SECRET%%/*}; rest=${ADMIN_TOKEN_SECRET#*/}; sec=${rest%%:*}; key=${rest#*:}
operator=$(kctl -n "$ns" get secret "$sec" -o jsonpath="{.data.$key}" | base64 -d)
ids=$(kctl -n "$NS" get secret "$SELECTOR" -o jsonpath='{.metadata.annotations.config-center/service-token-ids}' 2>/dev/null || true)
[[ -n $ids ]] || die "$NS/$SELECTOR 缺少 service-token-ids 注解；先运行 harvest --rotate-tokens 生成可审计的 token ID 关联，拒绝猜测旧 token"
services=${SERVICES:-"address behavior cart inventory merchant order payment product search user"}
CC_URL=${CONFIG_CENTER_URL:-http://$(kctl -n config-center get svc config-center -o jsonpath='{.spec.clusterIP}'):30010}
rpc(){ curl -fsS --max-time 20 -X POST "$CC_URL/config.v1.ConfigService/$1" -H 'Content-Type: application/json' -H "x-config-center-service-token: $operator" -H 'x-config-center-client-name: token-rotation' -d "$2"; }
for svc in $services; do
  old_id=$(jq -r --arg s "$svc" '.[$s] // empty' <<<"$ids"); [[ -n $old_id ]] || die "$svc: 缺少旧 token ID，拒绝轮换"
  if [[ $DRY == 1 ]]; then echo "$svc: old=$old_id -> issue new, verify, update selector, revoke old"; continue; fi
  issued=$(rpc IssueMachineToken "$(jq -nc --arg s "$svc" --arg e "$ENVIRONMENT" '{service_name:$s,environment:$e,note:"service-token rotation",role:"MACHINE_TOKEN_ROLE_SERVICE"}')")
  new=$(jq -r .token <<<"$issued"); new_id=$(jq -r .meta.id <<<"$issued"); [[ -n $new && -n $new_id ]] || die "$svc: 新 token 签发失败"
  old_cfg=$(kctl -n "$NS" get secret "$SELECTOR" -o jsonpath="{.data.$svc\.yaml}" | base64 -d)
  next=$(SERVICE_TOKEN="$new" OLD="$old_cfg" python3 - <<'PY'
import os,yaml
x=yaml.safe_load(os.environ['OLD']); x['config_center']['service_token']=os.environ['SERVICE_TOKEN']; print(yaml.safe_dump(x,allow_unicode=True,sort_keys=False))
PY
)
  kubectl -n "$NS" create secret generic "$SELECTOR" --from-literal="$svc.yaml=$next" --dry-run=client -o json | jq --arg k "$svc.yaml" --arg v "$(printf %s "$next"|base64)" --arg id "$new_id" --arg s "$svc" '.data[$k]=$v | .metadata.annotations["config-center/service-token-ids"]=(.metadata.annotations["config-center/service-token-ids"]|fromjson|. + {($s):$id}|tojson)' | kubectl apply -f - >/dev/null
  verify=$(rpc GetKey "$(jq -nc --arg s "$svc" --arg e "$ENVIRONMENT" '{namespace:$s,environment:$e,key:"bootstrap.yaml"}')")
  [[ $(jq -r .entry.key <<<"$verify") == bootstrap.yaml ]] || die "$svc: 新 token 读回失败，旧 token 尚未吊销"
  revoke=$(curl -fsS --max-time 20 -X POST "$CC_URL/config.v1.ConfigService/RevokeMachineToken" -H 'Content-Type: application/json' -H "x-config-center-service-token: $operator" -d "$(jq -nc --arg id "$old_id" '{id:$id}')")
  jq -e '.code == null' <<<"$revoke" >/dev/null || die "$svc: 新 token 已生效但旧 token 吊销失败，需重试"
  echo "$svc: rotated old=$old_id new=$new_id"
done
