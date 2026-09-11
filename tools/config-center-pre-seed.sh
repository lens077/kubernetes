#!/usr/bin/env bash
# =============================================================================
# config-center-pre-seed.sh —— 为本集群在 Config Center 里建立独立环境(默认 pre)并切换 ecommerce 服务
#
#   在控制面节点执行:
#     echo -n '<Casdoor access token>' > /root/.config-center-admin-token && chmod 600 /root/.config-center-admin-token
#     bash tools/config-center-pre-seed.sh                # 播种键 + 签发 token + 建 Secret + 切换 Deployment
#     bash tools/config-center-pre-seed.sh --dry-run      # 只读: 读 dev 配置、生成 pre 版本、不写任何东西
#     ENVIRONMENT=pre SERVICES="cart user" bash tools/config-center-pre-seed.sh   # 只处理部分服务
#
# 背景(2026-09-06 机房复现): 各服务的 bootstrap.yaml 由 Config Center 下发, dev 环境那份写的是内网集群
# Dragonfly 的 CA/密码, 机房集群连不上。control-tower 的设计是 service × environment 隔离, 所以给机房
# 用独立环境: 从 dev 复制每个服务的 bootstrap.yaml, 只替换 data.cache.redis 的 password/tls.ca_pem 为
# 本集群 Dragonfly 的值, 写入 <ENVIRONMENT>; 再为每个服务签发该环境的 machine token, 组装
# ecommerce-config-source-<ENVIRONMENT> Secret, 并把 Deployment 的 DEPLOYMENT_MODE 与 selector Secret
# 切过去(与 ecommerce 仓库 deploy/overlays/pre/patch-env.yaml 等价)。
#
# 凭据边界: 管理 token 只从文件读; 服务 token/密码/CA 只在本机进程与集群 Secret 之间流动, 不打印、不落盘。
# 需要: kubectl(admin.conf)、curl、jq、python3+PyYAML(节点已有)。
# =============================================================================
set -Eeuo pipefail

ENVIRONMENT=${ENVIRONMENT:-pre}
SOURCE_ENV=${SOURCE_ENV:-dev}
NS=${ECOMMERCE_NAMESPACE:-ecommerce}
SERVICES=${SERVICES:-"address behavior cart inventory merchant order payment product search user"}
ADMIN_TOKEN_FILE=${ADMIN_TOKEN_FILE:-/root/.config-center-admin-token}
KEY=bootstrap.yaml
DRY=false; [[ ${1:-} == --dry-run ]] && DRY=true
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
die() { log "✘ $*" >&2; exit 1; }

CC_URL=${CONFIG_CENTER_URL:-http://$(kubectl -n config-center get svc config-center -o jsonpath='{.spec.clusterIP}'):30010}
rpc() {  # rpc <Method> <json> [额外 curl 头...]
  local method=$1 body=$2; shift 2
  curl -sS --max-time 20 -X POST "$CC_URL/config.v1.ConfigService/$method" -H 'Content-Type: application/json' "$@" -d "$body"
}
rpc_ok() {  # 有 code 字段即 Connect 错误
  local resp=$1 what=$2
  if jq -e '.code != null' <<<"$resp" >/dev/null 2>&1; then die "$what: $(jq -r '"\(.code): \(.message)"' <<<"$resp")"; fi
}

# 本集群 Dragonfly 的 CA 与密码
CLUSTER_CA=$(kubectl -n "$NS" get cm global-root-ca -o jsonpath='{.data.ca\.crt}') || die "读取 $NS/global-root-ca 失败(trust-manager 未分发?)"
DF_PASSWORD=$(kubectl -n dragonfly get secret dragonfly-password-secret -o jsonpath='{.data.password}' | base64 -d) || die "读取 Dragonfly 密码失败"
[[ -n $CLUSTER_CA && -n $DF_PASSWORD ]] || die "集群 CA 或 Dragonfly 密码为空"

ADMIN_TOKEN=""
if [[ $DRY == false ]]; then
  [[ -r $ADMIN_TOKEN_FILE ]] || die "缺少管理 token 文件 $ADMIN_TOKEN_FILE(Casdoor access token, 0600)"
  ADMIN_TOKEN=$(tr -d '\n\r' < "$ADMIN_TOKEN_FILE")
  [[ -n $ADMIN_TOKEN ]] || die "管理 token 为空"
fi

# 从 dev 的 selector Secret 取每个服务的 dev token(读 dev 配置用)与 selector 模板
SRC_SECRET="ecommerce-config-source-$SOURCE_ENV"
DST_SECRET="ecommerce-config-source-$ENVIRONMENT"
kubectl -n "$NS" get secret "$SRC_SECRET" >/dev/null || die "缺少 $NS/$SRC_SECRET"

declare -A NEW_TOKENS=()
log "Config Center: $CC_URL | $SOURCE_ENV → $ENVIRONMENT | 服务: $SERVICES $([[ $DRY == true ]] && echo '(dry-run, 只读)')"
for svc in $SERVICES; do
  selector=$(kubectl -n "$NS" get secret "$SRC_SECRET" -o jsonpath="{.data.$svc\.yaml}" | base64 -d)
  dev_token=$(sed -nE 's/^\s*service_token:\s*//p' <<<"$selector" | tr -d '"'"'"' ')
  [[ -n $dev_token ]] || die "$svc: $SRC_SECRET 里没有 service_token"

  # 1) 读 dev 配置
  resp=$(rpc GetKey "{\"namespace\":\"$svc\",\"environment\":\"$SOURCE_ENV\",\"key\":\"$KEY\"}" -H "x-config-center-service-token: $dev_token")
  rpc_ok "$resp" "$svc: GetKey $SOURCE_ENV"
  dev_value=$(jq -r '.entry.value' <<<"$resp")
  [[ -n $dev_value && $dev_value != null ]] || die "$svc: $SOURCE_ENV/$KEY 为空"

  # 2) 只替换 redis 的 password / tls.ca_pem(其余原样; 结构缺失时报错而不是静默补)
  new_value=$(CLUSTER_CA="$CLUSTER_CA" DF_PASSWORD="$DF_PASSWORD" DEV_VALUE="$dev_value" python3 - "$svc" <<'PY'
import os, sys, yaml
svc = sys.argv[1]
doc = yaml.safe_load(os.environ["DEV_VALUE"])
try:
    redis = doc["data"]["cache"]["redis"]
except (KeyError, TypeError):
    sys.exit(f"{svc}: dev bootstrap.yaml 没有 data.cache.redis, 不知道该改哪里")
if "password" not in redis or "tls" not in redis or "ca_pem" not in redis["tls"]:
    sys.exit(f"{svc}: data.cache.redis 缺少 password/tls.ca_pem")
redis["password"] = os.environ["DF_PASSWORD"]
redis["tls"]["ca_pem"] = os.environ["CLUSTER_CA"]
# 自检: 重新序列化后再解析, 除这两个字段外必须与 dev 完全等价(防止 dump 改变其它值的类型/内容)
orig = yaml.safe_load(os.environ["DEV_VALUE"])
orig["data"]["cache"]["redis"]["password"] = os.environ["DF_PASSWORD"]
orig["data"]["cache"]["redis"]["tls"]["ca_pem"] = os.environ["CLUSTER_CA"]
class D(yaml.SafeDumper):
    pass
def str_presenter(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)
D.add_representer(str, str_presenter)
out = yaml.dump(doc, Dumper=D, allow_unicode=True, sort_keys=False, width=4096)
if yaml.safe_load(out) != orig:
    sys.exit(f"{svc}: 重新序列化后的配置与 dev 不等价, 拒绝写入")
sys.stdout.write(out)
PY
  ) || die "$svc: 生成 $ENVIRONMENT 配置失败"
  changed=$(diff <(echo "$dev_value") <(echo "$new_value") | grep -cE '^[<>]' || true)
  log "$svc: $SOURCE_ENV v$(jq -r '.entry.version' <<<"$resp") 读取成功, 生成 $ENVIRONMENT 版本(差异行 $changed)"
  [[ $DRY == true ]] && continue

  # 3) PutKey 到目标环境(管理 token)
  body=$(jq -n --arg ns "$svc" --arg env "$ENVIRONMENT" --arg key "$KEY" --arg v "$new_value" \
    '{namespace:$ns, environment:$env, key:$key, format:"CONFIG_FORMAT_YAML", value:$v, is_secret:false,
      comment:"seed from dev by tools/config-center-pre-seed.sh: cluster-local redis password/ca", description:"由 dev 复制, redis 凭据为本集群 Dragonfly"}')
  resp=$(rpc PutKey "$body" -H "Authorization: Bearer $ADMIN_TOKEN")
  rpc_ok "$resp" "$svc: PutKey $ENVIRONMENT(管理 token 无效/过期?)"
  log "$svc: $ENVIRONMENT/$KEY 已写入 v$(jq -r '.entry.version' <<<"$resp")"

  # 4) 签发该环境的 machine token(白名单默认=自身 namespace)
  resp=$(rpc IssueMachineToken "{\"service_name\":\"$svc\",\"environment\":\"$ENVIRONMENT\",\"note\":\"$(hostname) cluster, seeded $(date +%F)\"}" -H "Authorization: Bearer $ADMIN_TOKEN")
  rpc_ok "$resp" "$svc: IssueMachineToken"
  NEW_TOKENS[$svc]=$(jq -r '.token' <<<"$resp")
  [[ -n ${NEW_TOKENS[$svc]} && ${NEW_TOKENS[$svc]} != null ]] || die "$svc: 未返回 token"

  # 5) 用新 machine token 读回(数据面视角), 证明键+token 都生效。
  #    注意 is_secret 必须与 dev 一致(false): 置 true 时管理面 GetKey 返回 ****** 脱敏, 数据面 SDK 也拿不到真值。
  resp=$(rpc GetKey "{\"namespace\":\"$svc\",\"environment\":\"$ENVIRONMENT\",\"key\":\"$KEY\"}" -H "x-config-center-service-token: ${NEW_TOKENS[$svc]}")
  rpc_ok "$resp" "$svc: 新 token 读回 $ENVIRONMENT"
  [[ $(jq -r '.entry.value' <<<"$resp") == "$new_value" ]] || die "$svc: 读回内容与写入不一致(is_secret 脱敏? 版本冲突?)"
  log "$svc: machine token 已签发并读回校验通过"
done
[[ $DRY == true ]] && { log "dry-run 结束: 未写 Config Center、未建 Secret、未改 Deployment"; exit 0; }

# 6) 组装 selector Secret: 复制 dev 的 selector, 改 environment 与 service_token
log "组装 Secret $NS/$DST_SECRET"
args=()
tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
for svc in $SERVICES; do
  kubectl -n "$NS" get secret "$SRC_SECRET" -o jsonpath="{.data.$svc\.yaml}" | base64 -d \
    | sed -E "s/^(\s*environment:\s*).*/\1$ENVIRONMENT/; s/^(\s*service_token:\s*).*/\1${NEW_TOKENS[$svc]}/" > "$tmp/$svc.yaml"
  grep -qE "^\s*environment:\s*$ENVIRONMENT$" "$tmp/$svc.yaml" || die "$svc: selector 替换 environment 失败"
  args+=(--from-file="$svc.yaml=$tmp/$svc.yaml")
done
kubectl -n "$NS" create secret generic "$DST_SECRET" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -rf "$tmp"; trap - EXIT

# 7) 切换 Deployment(与 ecommerce deploy/overlays/pre/patch-env.yaml 等价, 按名字定位而不是按下标)
for svc in $SERVICES; do
  dep="ecommerce-$svc-deploy"
  idx=$(kubectl -n "$NS" get deploy "$dep" -o json | jq '.spec.template.spec.containers[0].env | map(.name) | index("DEPLOYMENT_MODE")')
  vol=$(kubectl -n "$NS" get deploy "$dep" -o json | jq '.spec.template.spec.volumes | map(.secret.secretName // "") | index("'"$SRC_SECRET"'")')
  [[ $idx != null && $vol != null ]] || die "$dep: 找不到 DEPLOYMENT_MODE 环境变量或 $SRC_SECRET 卷"
  kubectl -n "$NS" patch deploy "$dep" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/$idx/value\",\"value\":\"$ENVIRONMENT\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/$vol/secret/secretName\",\"value\":\"$DST_SECRET\"}]" >/dev/null
  log "$dep: DEPLOYMENT_MODE=$ENVIRONMENT, selector=$DST_SECRET"
done

log "等待滚动完成..."
fail=0
for svc in $SERVICES; do
  kubectl -n "$NS" rollout status "deploy/ecommerce-$svc-deploy" --timeout=180s >/dev/null 2>&1 \
    && log "✔ ecommerce-$svc-deploy 就绪" || { log "✘ ecommerce-$svc-deploy 未就绪: kubectl -n $NS logs deploy/ecommerce-$svc-deploy"; fail=1; }
done
exit $fail
