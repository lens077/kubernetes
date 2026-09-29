#!/usr/bin/env bash
# vmauth 访问矩阵验收: 允许的只读路径 200, 其余(写入/管理/无凭据/错凭据)一律拒绝。
#   BASE=https://metrics.apikv.com bash components/vmauth/verify.sh      # 公网(默认)
#   BASE=http://127.0.0.1:18427 bash components/vmauth/verify.sh          # port-forward 灰度
# 凭据从 Secret victoriametrics/vmauth-credentials 现取, 只在内存里用。写入类用例只发空请求体, 不写数据。
set -uo pipefail
BASE=${BASE:-https://metrics.apikv.com}
sec() { kubectl -n victoriametrics get secret vmauth-credentials -o jsonpath="{.data.$1}" | base64 -d; }
TOKEN=$(sec read-token); PASS=$(sec ui-password)
fail=0
check() {  # check <期望码正则> <描述> <curl 参数...>
  local want=$1 desc=$2 code body; shift 2
  body=$(curl -s -w '\n%{http_code}' --max-time 15 "$@"); code=${body##*$'\n'}; body=${body%$'\n'*}
  if [[ $code =~ ^($want)$ ]]; then printf 'ok    %-52s %s\n' "$desc" "$code"
  else printf 'FAIL  %-52s %s (want %s) %s\n' "$desc" "$code" "$want" "${body:0:80}"; fail=1; fi
}
# 已认证但路径不在白名单: vmauth 返回 400 「missing route」, 请求没有转发给 VM。
# 必须同时核对正文, 否则 VM 自己的 400(参数错误)会被误当成拒绝。
deny() {  # deny <描述> <curl 参数...>
  local desc=$1 code body; shift
  body=$(curl -s -w '\n%{http_code}' --max-time 15 "$@"); code=${body##*$'\n'}; body=${body%$'\n'*}
  if [[ $code =~ ^(401|403)$ || ( $code == 400 && $body == *"missing route"* ) ]]; then printf 'ok    %-52s %s 拒绝\n' "$desc" "$code"
  else printf 'FAIL  %-52s %s 未被拒绝: %s\n' "$desc" "$code" "${body:0:80}"; fail=1; fi
}
B=(-H "Authorization: Bearer $TOKEN")
U=(-u "ops:$PASS")
Q='/api/v1/query?query=vm_app_version'
check 401     '无凭据 查询'                          "$BASE$Q"
check 401     '错误 token 查询'                      -H 'Authorization: Bearer wrong' "$BASE$Q"
check 401     '未展开的占位符不能当 token'            -H 'Authorization: Bearer %{VMAUTH_READ_TOKEN}' "$BASE$Q"
check 401     '错误密码 VMUI'                        -u ops:wrong "$BASE/vmui/"
check 200     'token 查询'                           "${B[@]}" "$BASE$Q"
check 200     'token query_range'                    "${B[@]}" "$BASE/api/v1/query_range?query=up&start=-5m&step=60s"
check 200     'token label values'                   "${B[@]}" "$BASE/api/v1/label/__name__/values?limit=1"
check 200     'VMUI 页面(用户名密码)'                "${U[@]}" "$BASE/vmui/"
check 200     'VMUI 发起的查询(用户名密码)'          "${U[@]}" "$BASE$Q"
check 200     'VMUI /prometheus 前缀查询'             "${U[@]}" "$BASE/prometheus$Q"
check 200     'VMUI 启动配置 /prometheus/vmui/config.json' "${U[@]}" "$BASE/prometheus/vmui/config.json"
deny          'token 访问 VMUI 页面(只给程序查询用)'  "${B[@]}" "$BASE/vmui/"
deny 'token 写 /api/v1/write'               "${B[@]}" -X POST --data-binary '' "$BASE/api/v1/write"
deny 'token 写 /api/v1/import'              "${B[@]}" -X POST --data-binary '' "$BASE/api/v1/import"
deny 'token 写 /opentelemetry/v1/metrics'   "${B[@]}" -X POST --data-binary '' "$BASE/opentelemetry/v1/metrics"
deny 'token 删除 /api/v1/admin/tsdb/delete_series' "${B[@]}" -X POST "$BASE/api/v1/admin/tsdb/delete_series?match%5B%5D=nonexistent_metric_for_auth_check"
deny 'token /snapshot/list'               "${B[@]}" "$BASE/snapshot/list"
deny 'token /flags'                         "${B[@]}" "$BASE/flags"
deny 'token /metrics'                       "${B[@]}" "$BASE/metrics"
deny 'VMUI 用户 删除接口'                   "${U[@]}" -X POST "$BASE/api/v1/admin/tsdb/delete_series?match%5B%5D=nonexistent_metric_for_auth_check"
deny '无凭据 /flags'                        "$BASE/flags"
deny '无凭据 /metrics'                      "$BASE/metrics"
deny '无凭据 /debug/pprof/'                 "$BASE/debug/pprof/"
# 浏览器要弹出用户名密码框, 401 必须带 Basic 挑战头
if curl -s -D - -o /dev/null --max-time 15 "$BASE/vmui/" | grep -qi '^www-authenticate: *basic'; then
  echo 'ok    401 带 WWW-Authenticate: Basic(浏览器会弹框)'
else echo 'FAIL  401 缺 WWW-Authenticate: Basic'; fail=1; fi
exit $fail
