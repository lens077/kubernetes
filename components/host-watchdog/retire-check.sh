#!/usr/bin/env bash
# 安全退役 host-watchdog 检查项：从 incidents.json 删除旧事件条目。
#
# 用法：
#   bash components/host-watchdog/retire-check.sh node2 docker:gorse-gorse-1 http:gorse
#   bash components/host-watchdog/retire-check.sh node1 docker:redis pangolin:8
#
# 前置条件（脚本会强制校验）：受管清单里已经移除对应检查项，且已用 install.sh 下发到主机。
# 如果检查项仍然活跃，脚本拒绝删除——否则下一轮 5 分钟 timer 会立刻重建事件。
#
# 为什么需要它：notify.py 的 process() 对「本轮未出现且非 held 的旧 key」只把
# recover_since 置 None，既不发恢复通知，也不删除条目。直接从 WATCH/HTTP_CHECKS
# 删检查项会让旧事件永久滞留在状态文件里（node1 的 pangolin:8 从 10-24 滞留到 11-10）。
#
# ⚠️ 删除条目不会向 ntfy 补发「恢复」通知——手机通知栏里那条旧故障需手动清除。
#    如果确实需要一条说明性通知，请单独确认后再发。
#
# 写状态文件前备份 incidents.json，并用 fcntl.flock 与正在运行的 timer 互斥，
# 原子替换（0600 root:root），不 stop / restart 服务。

set -uo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
host=${1:-}
shift || true
[ -n "$host" ] && [ $# -ge 1 ] || {
  echo "用法: bash $(basename "$0") <host> <key> [key ...]" >&2
  exit 1
}
case "$host" in
  node[1-6]|k[1-3]) ;;
  *) echo "✘ 拒绝操作未知主机: $host" >&2; exit 1 ;;
esac
manifest="$DIR/hosts/$host.env"
[ -r "$manifest" ] || { echo "✘ 缺少受管清单: $manifest" >&2; exit 1; }

manifest_b64=$(base64 < "$manifest" | tr -d '\n')
retire_b64=$(printf '%s\n' "$@" | base64 | tr -d '\n')

echo "── $host 退役事件条目 ──"
{
  printf 'MANIFEST_B64 = "%s"\n' "$manifest_b64"
  printf 'RETIRE_B64 = "%s"\n' "$retire_b64"
  cat <<'PY'
import base64, fcntl, json, os, pathlib, shutil, subprocess, sys, tempfile, time

CONF = '/etc/host-watchdog/watchdog.env'
STATE = '/var/lib/host-watchdog/incidents.json'
NOTIFY = '/usr/local/lib/host-watchdog/notify.py'
retire = [line.strip() for line in base64.b64decode(RETIRE_B64).decode().splitlines() if line.strip()]

def parse_env(text):
    out = {}
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith('#') and '=' in s:
            k, v = s.split('=', 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out

env = parse_env(open(CONF, encoding='utf-8').read())

# 当前仍会产生事件的 key 集合。只要待退役的 key 还在这里，就拒绝删状态。
active = set()
for name in env.get('WATCH', '').split():
    active.add('docker:' + name)
for item in env.get('HTTP_CHECKS', '').split():
    if '=' in item:
        active.add('http:' + item.split('=', 1)[0])
for unit in env.get('SYSTEMD_UNITS', '').split():
    active.add('systemd:' + unit)
if env.get('PANGOLIN_DB'):
    child_env = dict(os.environ, PANGOLIN_DB=env['PANGOLIN_DB'],
                     PANGOLIN_IGNORE_SITES=env.get('PANGOLIN_IGNORE_SITES', ''))
    proc = subprocess.run([sys.executable, NOTIFY, '--pangolin'], env=child_env,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f'✘ 无法读取 Pangolin 站点清单，拒绝继续: rc={proc.returncode}')
    for line in proc.stdout.splitlines():
        parts = line.split('\t')
        if parts and parts[0]:
            active.add(parts[0])

still_active = [k for k in retire if k in active]
if still_active:
    print('✘ 以下检查项仍在本机配置中，拒绝删除状态（先改清单并下发 install.sh）:')
    for k in still_active:
        print('    ' + k)
    raise SystemExit(1)

path = pathlib.Path(STATE)
if not path.exists():
    raise SystemExit(f'✘ {STATE} 不存在')
st = path.stat()
lock_path = path.with_name(path.name + '.lock')
if lock_path.is_symlink():
    raise SystemExit('✘ 状态锁文件是符号链接，拒绝操作')
fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
removed, skipped = [], []
with os.fdopen(fd, 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        state = json.loads(path.read_text(encoding='utf-8'))
        if state.get('version') != 1 or not isinstance(state.get('incidents'), dict):
            raise ValueError('incompatible notification state')
        incidents = state['incidents']
        for key in retire:
            if key in incidents:
                inc = incidents.pop(key)
                removed.append((key, inc.get('reminder_index')))
            else:
                skipped.append(key)
        bak = f'{STATE}.bak-{time.strftime("%Y%m%d-%H%M%S")}'
        shutil.copy2(path, bak)
        os.chmod(bak, st.st_mode & 0o777)
        fd2, tmp = tempfile.mkstemp(prefix='.incidents.json.', dir=str(path.parent))
        try:
            with os.fdopen(fd2, 'w', encoding='utf-8') as f:
                json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)
                f.write('\n')
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, st.st_mode & 0o777)
            os.replace(tmp, path)
            dfd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except Exception:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)

for key, idx in removed:
    print(f'  ✓ 已删除 {key}（reminder_index={idx}）')
for key in skipped:
    print(f'  -- {key} 状态文件中不存在，跳过')
print(f'  备份 {bak}；剩余事件 {len(state["incidents"])} 条')
print('  注意：notify.py 不会为退役项补发恢复通知，手机通知栏的旧故障请手动清除。')
PY
} | ssh -T -o ConnectTimeout=12 "$host" 'python3 -'
