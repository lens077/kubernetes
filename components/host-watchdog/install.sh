#!/usr/bin/env bash
# 下发 host-watchdog 的受管检查清单到目标主机。
#
# 用法：
#   bash components/host-watchdog/install.sh node1            # dry-run：只打印受管键差异
#   CONFIRM=yes bash components/host-watchdog/install.sh node1 node2   # 实际下发
#
# 设计边界（2026-11-10 建立清单版本管理时定）：
#   * hosts/<alias>.env 只放「检查项定义」；NTFY_URL / NTFY_TOPIC / NTFY_TICKET_TOPIC /
#     NTFY_TEST_TOPIC / NTFY_TOKEN / NTFY_PUBLISHER_USER 是本地凭据与投递目标，
#     只存在于主机 /etc/host-watchdog/watchdog.env，本脚本永不覆盖、也不读取其值。
#   * 只覆盖下面 MANAGED_KEYS 列出的行；主机文件里的其他键、注释、敏感行原样保留。
#   * 写前备份到 watchdog.env.bak-<时间戳>（0600），原子替换，权限沿用原文件。
#   * 不 stop / restart / enable 任何 systemd 单元：watchdog.timer 每 5 分钟自然读新配置。
#     11-10 Mac LaunchAgent 的教训是「unload 后在当前 agent 会话里注册不回来」，别重演。
#   * 退役检查项时，本脚本之后必须再跑 retire-check.sh 清掉状态文件里的旧事件，
#     否则 notify.py 的「缺席不合成恢复」语义会让条目永久滞留（pangolin:8 就是这么来的）。

set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONF=/etc/host-watchdog/watchdog.env
MANAGED_KEYS="HOST_LABEL WATCH SYSTEMD_UNITS HTTP_CHECKS PANGOLIN_DB PANGOLIN_IGNORE_SITES DISK_PATHS DISK_WARN_PCT DISK_CRIT_PCT HC_PING_URL NOTIFY_HOLD_SECONDS NOTIFY_RECOVER_SECONDS"

die() { echo "✘ $*" >&2; exit 1; }

[ $# -ge 1 ] || die "用法: bash $(basename "$0") <host> [host ...]（默认 dry-run；实际下发加 CONFIRM=yes）"

for host in "$@"; do
  case "$host" in
    node[1-6]|k[1-3]) ;;
    *) die "拒绝操作未知主机: $host（仅允许 node1-6 / k1-3 的 ssh alias）" ;;
  esac

  manifest="$DIR/hosts/$host.env"
  [ -r "$manifest" ] || die "缺少受管清单: $manifest"

  keys_b64=$(printf '%s' "$MANAGED_KEYS" | base64 | tr -d '\n')
  manifest_b64=$(base64 < "$manifest" | tr -d '\n')
  confirm=False
  [ "${CONFIRM:-no}" = yes ] && confirm=True

  echo "── $host ──"
  {
    printf 'MANIFEST_B64 = "%s"\n' "$manifest_b64"
    printf 'KEYS_B64 = "%s"\n' "$keys_b64"
    printf 'CONFIRM = %s\n' "$confirm"
    printf 'CONF = "%s"\n' "$CONF"
    cat <<'PY'
import base64, os, shutil, sys, tempfile, time

manifest = base64.b64decode(MANIFEST_B64).decode('utf-8')
keys = base64.b64decode(KEYS_B64).decode('utf-8').split()
managed = {}
for line in manifest.splitlines():
    s = line.strip()
    if not s or s.startswith('#') or '=' not in s:
        continue
    k, v = s.split('=', 1)
    if k.strip() in keys:
        managed[k.strip()] = v.strip()

def parse(text):
    out = {}
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith('#') and '=' in s:
            k, v = s.split('=', 1)
            out[k.strip()] = v.strip()
    return out

if not os.path.isfile(CONF):
    raise SystemExit(f'missing {CONF}')
st = os.stat(CONF)
before = open(CONF, encoding='utf-8').read()

out, replaced = [], set()
for line in before.splitlines():
    s = line.strip()
    if s and not s.startswith('#') and '=' in s:
        k = s.split('=', 1)[0].strip()
        if k in managed:
            if k not in replaced:
                out.append(f'{k}={managed[k]}')
                replaced.add(k)
            continue                      # 重复行丢弃，避免同一个键出现两次
    out.append(line)                      # 注释、空行、非受管键（含 NTFY_* 凭据）原样保留
for k, v in managed.items():
    if k not in replaced:
        out.append(f'{k}={v}')
after = '\n'.join(out) + '\n'

old, new = parse(before), parse(after)
changed = [k for k in managed if old.get(k) != new.get(k)]
for k in changed:
    print(f'  {k}:')
    print(f'    - {old.get(k, "<absent>")}')
    print(f'    + {new[k]}')
if not changed:
    print('  受管键无差异（本地凭据行未触碰）')

if not CONFIRM:
    print('  [dry-run] 未写盘。实际下发：CONFIRM=yes bash install.sh <host> [...]')
    raise SystemExit(0)

if after == before:
    print('  无需写盘')
    raise SystemExit(0)

bak = f'{CONF}.bak-{time.strftime("%Y%m%d-%H%M%S")}'
shutil.copy2(CONF, bak)
os.chmod(bak, st.st_mode & 0o777)

fd, tmp = tempfile.mkstemp(prefix='.watchdog.env.', dir=os.path.dirname(CONF))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(after)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, CONF)
    dfd = os.open(os.path.dirname(CONF), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
print(f'  ✓ 已下发；备份 {bak}（权限 {oct(st.st_mode & 0o777)}）')
print('  未重启服务；下一次 host-watchdog.timer（5 分钟内）自然生效。')
print('  若本次移除了检查项，请接着跑 retire-check.sh 清理 incidents.json 的旧事件。')
PY
  } | ssh -T -o ConnectTimeout=12 "$host" 'python3 -'
done
