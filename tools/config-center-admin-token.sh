#!/usr/bin/env bash
# =============================================================================
# config-center-admin-token.sh —— 取一枚 Config Center 管理 token(Casdoor access token)
#
#   ssh node4 'umask 077; printf "%s\n%s\n" "<casdoor 用户名>" "<密码>" > /root/.casdoor-login'
#   bash tools/config-center-admin-token.sh            # 写到 /root/.config-center-admin-token(0600), 有效 15 分钟
#   bash tools/config-center-admin-token.sh --print    # 只打印到 stdout(给 CONFIG_CENTER_ADMIN_TOKEN=$(…) 用)
#
# 为什么不能直接 password grant: Casdoor 应用 ecommerce 只开了 authorization_code / client_credentials /
# refresh_token。这里用账号会话登录, 让 Casdoor 直接签发 code(前端 SDK 就是这么做的), 再换 access token。
# client_secret 通过同一会话从 /api/get-application 读取, 不落盘。
# 之后接着跑 tools/config-center-pre-seed.sh 即可(它读 /root/.config-center-admin-token)。
# =============================================================================
set -Eeuo pipefail
umask 077

LOGIN_FILE=${CASDOOR_LOGIN_FILE:-/root/.casdoor-login}
OUT=${CONFIG_CENTER_ADMIN_TOKEN_FILE:-/root/.config-center-admin-token}
CASDOOR=${CASDOOR_URL:-https://casdoor.apikv.com}
ORG=${CASDOOR_ORG:-lens}
APP=${CASDOOR_APP:-ecommerce}
CID=${CASDOOR_CLIENT_ID:-baxf6718e392099b7915}       # 与 config-center 的 CASDOOR_AUDIENCE 一致
REDIRECT=${CASDOOR_REDIRECT:-https://config.apikv.com/callback}
PRINT=false; [[ ${1:-} == --print ]] && PRINT=true

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
die() { log "✘ $*"; exit 1; }

[[ -r $LOGIN_FILE ]] || die "缺少 $LOGIN_FILE(两行: 用户名、密码; 0600)"
u=$(sed -n 1p "$LOGIN_FILE"); p=$(sed -n 2p "$LOGIN_FILE")
[[ -n $u && -n $p ]] || die "$LOGIN_FILE 需要两行: 用户名、密码"

ck=$(mktemp); trap 'rm -f "$ck"' EXIT

# 1) 账号会话
body=$(jq -nc --arg u "$u" --arg p "$p" --arg app "$APP" --arg org "$ORG" \
  '{application:$app, organization:$org, username:$u, password:$p, autoSignin:true, type:"login"}')
r=$(curl -sS -c "$ck" -X POST "$CASDOOR/api/login" -H 'Content-Type: application/json' -d "$body")
[[ $(jq -r .status <<<"$r") == ok ]] || die "Casdoor 登录失败: $(jq -r '.msg // .status' <<<"$r")"

# 2) 应用 client_secret(同会话可读)
app=$(curl -sS -b "$ck" "$CASDOOR/api/get-application?id=admin/$APP")
cs=$(jq -r '.data.clientSecret // empty' <<<"$app")
[[ -n $cs ]] || die "读取应用 $APP 的 clientSecret 失败: $(jq -r '.msg // .status' <<<"$app")"

# 3) 让 Casdoor 直接签发 authorization code(OAuth 参数走 query, type:"code" 走 JSON 体)
enc() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
q="clientId=$CID&responseType=code&grantType=authorization_code&redirectUri=$(enc "$REDIRECT")&scope=openid%20profile%20email&state=cli"
body=$(jq -nc --arg u "$u" --arg p "$p" --arg app "$APP" --arg org "$ORG" \
  '{application:$app, organization:$org, username:$u, password:$p, autoSignin:true, type:"code"}')
cr=$(curl -sS -b "$ck" -c "$ck" -X POST "$CASDOOR/api/login?$q" -H 'Content-Type: application/json' -d "$body")
code=$(jq -r '.data // empty' <<<"$cr")
[[ -n $code ]] || die "签发 code 失败: $(jq -r '.msg // .status' <<<"$cr")"

# 4) code → access token
tok=$(curl -sS -X POST "$CASDOOR/api/login/oauth/access_token" \
  --data-urlencode grant_type=authorization_code --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$cs" \
  --data-urlencode "code=$code" --data-urlencode "redirect_uri=$REDIRECT")
at=$(jq -r '.access_token // empty' <<<"$tok")
[[ -n $at ]] || die "换 token 失败: $(jq -r '(.error // "") + " " + (.error_description // "")' <<<"$tok")"
exp=$(jq -r '.expires_in // "?"' <<<"$tok")

if [[ $PRINT == true ]]; then
  printf '%s\n' "$at"
else
  printf '%s' "$at" > "$OUT"; chmod 600 "$OUT"
fi
log "管理 token 已获取(${exp}s 内有效)$([[ $PRINT == true ]] || echo " → $OUT")"

# 5) 自检: 管理面 ListNamespaces
if cc=$(KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf} kubectl -n config-center get svc config-center -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [[ -n $cc ]]; then
  n=$(curl -sS -X POST "http://$cc:30010/config.v1.ConfigService/ListNamespaces" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $at" -d '{}' | jq -r 'if .code then "ERR " + .code + ": " + .message else (.namespaces // [] | length | tostring) + " namespaces" end')
  log "Config Center 管理面自检: $n"
fi
