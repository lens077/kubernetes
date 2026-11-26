#!/usr/bin/env bash
# 只读审计：仓库受管清单 ↔ 主机实际配置，并扫描「僵尸事件」。
#
# 用法：
#   bash components/host-watchdog/verify.sh                 # 审计 hosts/ 下全部主机
#   bash components/host-watchdog/verify.sh node1 node2     # 指定主机
#
# 退出码：0 = 全一致且无僵尸；1 = 存在漂移或僵尸条目（适合挂到巡检/CI）。
# 僵尸定义：incidents.json 里的条目超过 24h 没有 last_seen 更新。
# notify.py 对「从检查项里消失的 key」不合成恢复、也不自动删除条目，
# 所以这类条目会永久滞留（2026-11-10 之前 node1 的 pangolin:8 就是标本）。

set -uo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
MANAGED_KEYS="HOST_LABEL WATCH SYSTEMD_UNITS HTTP_CHECKS PANGOLIN_DB PANGOLIN_IGNORE_SITES DISK_PATHS DISK_WARN_PCT DISK_CRIT_PCT HC_PING_URL NOTIFY_HOLD_SECONDS NOTIFY_RECOVER_SECONDS"

hosts=("$@")
if [ ${#hosts[@]} -eq 0 ]; then
  hosts=()
  for f in "$DIR"/hosts/*.env; do
    [ -e "$f" ] || continue
    hosts+=("$(basename "$f" .env)")
  done
fi
[ ${#hosts[@]} -gt 0 ] || { echo "✘ hosts/ 下没有清单" >&2; exit 1; }

rc=0
for host in "${hosts[@]}"; do
  case "$host" in
    node[1-6]|k[1-3]) ;;
    *) echo "✘ 拒绝操作未知主机: $host" >&2; rc=1; continue ;;
  esac
  manifest="$DIR/hosts/$host.env"
  if [ ! -r "$manifest" ]; then
    echo "✘ 缺少受管清单: $manifest" >&2; rc=1; continue
  fi

  manifest_b64=$(base64 < "$manifest" | tr -d '\n')
  keys_b64=$(printf '%s' "$MANAGED_KEYS" | base64 | tr -d '\n')

  echo "── $host ──"
  {
    printf 'MANIFEST_B64 = "%s"\n' "$manifest_b64"
    printf 'KEYS_B64 = "%s"\n' "$keys_b64"
    cat <<'PY'
import base64, datetime, json, os, sys

CONF = '/etc/host-watchdog/watchdog.env'
STATE = '/var/lib/host-watchdog/incidents.json'
keys = base64.b64decode(KEYS_B64).decode().split()
manifest = {}
for line in base64.b64decode(MANIFEST_B64).decode().splitlines():
    s = line.strip()
    if s and not s.startswith('#') and '=' in s:
        k, v = s.split('=', 1)
        if k.strip() in keys:
            manifest[k.strip()] = v.strip()

def parse(text):
    out = {}
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith('#') and '=' in s:
            k, v = s.split('=', 1)
            out[k.strip()] = v.strip()
    return out

bad = 0
try:
    actual = parse(open(CONF, encoding='utf-8').read())
except Exception as e:
    print(f'  ✘ 读不到 {CONF}: {type(e).__name__}')
    raise SystemExit(1)

for k in sorted(keys):
    if k not in manifest:
        continue
    a = actual.get(k, '<absent>')
    if a == manifest[k]:
        print(f'  OK   {k}')
    else:
        print(f'  DIFF {k}: 仓库={manifest[k]}  主机={a}')
        bad += 1

try:
    state = json.load(open(STATE, encoding='utf-8'))
except FileNotFoundError:
    print(f'  --  {STATE} 不存在（尚无事件）')
    state = {'incidents': {}}
except Exception as e:
    print(f'  ✘ 读不到 {STATE}: {type(e).__name__}')
    raise SystemExit(1)

now = datetime.datetime.now().timestamp()
zombies = []
for key, inc in (state.get('incidents') or {}).items():
    last = inc.get('last_seen') or inc.get('first_seen') or 0
    age = now - last
    if age > 86400:
        stamp = datetime.datetime.fromtimestamp(last).strftime('%Y-%m-%d %H:%M')
        zombies.append((key, stamp, int(age // 3600), inc.get('reminder_index')))
if zombies:
    print('  ✘ 僵尸事件（>24h 无 last_seen 更新）:')
    for key, stamp, hours, idx in sorted(zombies):
        print(f'      {key:32s} last_seen={stamp}  停滞 {hours}h  reminder_index={idx}')
    bad += len(zombies)
else:
    print('  OK   无僵尸事件')

print(f'  结论: {"漂移/僵尸需处理" if bad else "一致"}')
raise SystemExit(1 if bad else 0)
PY
  } | ssh -T -o ConnectTimeout=12 "$host" 'bash -n /etc/host-watchdog/watchdog.env && python3 -' || rc=1
done

echo
if [ "$rc" -ne 0 ]; then
  echo "✘ 存在漂移或僵尸，见上"
else
  echo "✓ 全部主机清单一致且无僵尸事件"
fi
exit "$rc"
