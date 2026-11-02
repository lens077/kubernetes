#!/usr/bin/env bash
# 主机级 newt 客户端（Pangolin 站点）一键加/移除/巡检。
#
# 用法（在本机，有目标主机 SSH alias 与面板管理员凭据）：
#   面板凭据放 ~/.pangolin-admin.env（不入库）：
#     PANGOLIN_ADMIN_EMAIL=xxx
#     PANGOLIN_ADMIN_PASSWORD=xxx
#
#   ./newt-host.sh add node5          # 建站点(若缺) → 下发二进制+凭据+systemd → 验证握手与 online
#   ./newt-host.sh remove node5       # 停服务 → 删面板站点 → 清理文件
#   ./newt-host.sh list               # 面板全站点 online 巡检
#
# 依赖：curl/jq(或 python3)、ssh alias、GitHub 可达（云机走 ghfast.top 加速）。
# 凭据只在创建站点那一刻回显一次；本脚本把它落到目标机 /home/docker/newt/newt.env (0600)，不在本机留盘。
#
# 指标采集(otelcol)的加/移除不在这里：改 hosts/observability/hosts.json 后
#   make host-metrics-generate && make host-otel CONFIRM=yes [H=<host>]
# 移除：从 hosts.json 删掉该机，ssh 目标机 systemctl disable --now otelcol。

set -euo pipefail

NEWT_VERSION="1.19.0"                      # 与 components/newt/README.md 版本线对照保持一致
ENDPOINT="https://pangolin.apikv.com"
ORG="main"
ADMIN_ENV="${PANGOLIN_ADMIN_ENV:-$HOME/.pangolin-admin.env}"
GH_PROXY="https://ghfast.top/"             # 直连不通时套的前缀（机房与云机实测可用）
COOKIE=$(mktemp)
trap 'rm -f "$COOKIE"' EXIT

die() { echo "✘ $*" >&2; exit 1; }
api() {  # api <method> <path> [json-body]
  local method=$1 path=$2 body=${3:-}
  curl -sS -b "$COOKIE" -c "$COOKIE" -X "$method" "$ENDPOINT/api/v1$path" \
    -H 'Content-Type: application/json' -H 'x-csrf-token: x-csrf-protection' \
    ${body:+-d "$body"}
}

login() {
  [[ -r "$ADMIN_ENV" ]] || die "缺少 $ADMIN_ENV（PANGOLIN_ADMIN_EMAIL/PANGOLIN_ADMIN_PASSWORD）"
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  local resp
  resp=$(api POST /auth/login "{\"email\":\"$PANGOLIN_ADMIN_EMAIL\",\"password\":\"$PANGOLIN_ADMIN_PASSWORD\"}")
  grep -q '"success":true' <<<"$resp" || die "登录失败: $resp"
}

site_by_nice() {  # → "siteId"（找不到输出空）
  api GET "/org/$ORG/sites" | SITE="$1" python3 -c "
import json, os, sys
for s in json.load(sys.stdin)['data']['sites']:
    if s['niceId'] == os.environ['SITE']:
        print(s['siteId']); break
" 2>/dev/null || true
}

cmd_add() {
  local host=$1
  login
  local found
  found=$(site_by_nice "$host")
  local sid newt_id secret
  if [[ -n "$found" ]]; then
    sid=${found%% *}
    echo "→ 站点已存在: $host (siteId $sid)，跳过创建（secret 不可回显，如丢失需重建站点）"
    # 目标机上已有凭据就复用；没有则只能重建
    if ! ssh "$host" 'test -s /home/docker/newt/newt.env' 2>/dev/null; then
      die "目标机没有凭据且面板不回显 secret：请在面板删除站点 $host 后重跑 add"
    fi
  else
    echo "→ 创建 Pangolin 站点: $host"
    local resp
    resp=$(api PUT "/org/$ORG/site" "{\"name\":\"$host\",\"niceId\":\"$host\",\"type\":\"newt\"}")
    grep -q '"success":true' <<<"$resp" || die "建站失败: $resp"
    sid=$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['siteId'])" <<<"$resp")
    newt_id=$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['newtId'])" <<<"$resp")
    secret=$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['secret'])" <<<"$resp")
    ssh "$host" "mkdir -p /home/docker/newt && printf 'NEWT_ID=$newt_id\nNEWT_SECRET=$secret\nPANGOLIN_ENDPOINT=$ENDPOINT\n' > /home/docker/newt/newt.env && chmod 600 /home/docker/newt/newt.env"
  fi

  echo "→ 安装二进制 newt $NEWT_VERSION"
  if ! ssh "$host" "test -x /usr/local/bin/newt && /usr/local/bin/newt --version | grep -q '$NEWT_VERSION'"; then
    ssh "$host" "curl -fsSL -o /tmp/newt --connect-timeout 10 --max-time 300 \
      '${GH_PROXY}https://github.com/fosrl/newt/releases/download/$NEWT_VERSION/newt_linux_amd64' \
      && install -m 0755 /tmp/newt /usr/local/bin/newt && rm -f /tmp/newt"
  fi

  echo "→ 安装 systemd 单元"
  scp -q "$(dirname "$0")/newt.service.template" "$host:/etc/systemd/system/newt.service"
  ssh "$host" "sed -i 's/@SITE@/$host/; s/@SITEID@/$sid/' /etc/systemd/system/newt.service \
    && systemctl daemon-reload && systemctl enable --now newt && sleep 6"

  echo "→ 验证"
  ssh "$host" 'systemctl is-active newt' >/dev/null || die "服务未运行"
  ssh "$host" "journalctl -u newt -n 20 --no-pager | grep -q 'Tunnel connection to server established successfully!'" \
    || die "日志无握手成功（别拿 Running 当通了，见 components/newt/README.md §6）"
  local online
  online=$(api GET "/site/$sid" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['online'])")
  [[ "$online" == "True" ]] || die "面板站点未 online"
  echo "✔ $host 完成：隧道握手 OK，面板 online=True（siteId $sid）"
}

cmd_remove() {
  local host=$1
  login
  local found
  found=$(site_by_nice "$host")
  if ssh "$host" 'test -d /home/docker/newt' 2>/dev/null; then
    echo "→ 停止并清理目标机"
    ssh "$host" "systemctl disable --now newt 2>/dev/null; rm -f /etc/systemd/system/newt.service \
      /usr/local/bin/newt-old-*; rm -rf /home/docker/newt; systemctl daemon-reload"
  fi
  if [[ -n "$found" ]]; then
    local sid=${found%% *}
    echo "→ 删除面板站点 $host (siteId $sid)"
    api DELETE "/site/$sid" >/dev/null
  fi
  echo "✔ $host 已移除（目标机文件 + 面板站点）"
}

cmd_list() {
  login
  api GET "/org/$ORG/sites" | python3 -c "
import json,sys
for s in sorted(json.load(sys.stdin)['data']['sites'], key=lambda x: x['niceId']):
    print(f\"{s['niceId']:<20} siteId={s['siteId']:<4} online={s.get('online')}\")"
}

case "${1:-}" in
  add)    [[ -n "${2:-}" ]] || die "用法: $0 add <ssh-alias>"; cmd_add "$2" ;;
  remove) [[ -n "${2:-}" ]] || die "用法: $0 remove <ssh-alias>"; cmd_remove "$2" ;;
  list)   cmd_list ;;
  *) die "用法: $0 add|remove <ssh-alias> | list" ;;
esac
