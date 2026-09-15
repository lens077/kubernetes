#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by functions loaded from lib/common.sh
# lib/common.sh 的 LB-IPAM 地址询问与答案持久化(离线; 用文件代替 /dev/tty, 不需要终端)。
#   - config.env 没写地址且有"终端" → 逐项询问, 非法 IPv4 重问, 答案写入 $LB_IPAM_ANSWERS(0600)
#   - 再次加载时 config.env 留空的项由答案补上; config.env 显式写了的优先
#   - 无终端 → 返回 1(00-preflight 据此报错退出)
set -euo pipefail

BOOTSTRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
# shellcheck source=../lib/common.sh
source "$BOOTSTRAP_DIR/lib/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
STATE_DIR="$root/state"
LOG_DIR="$root/log"
MAIN_LOG="$LOG_DIR/install.log"
LB_IPAM_ANSWERS="$STATE_DIR/lb-ipam.env"
mkdir -p "$LOG_DIR"

# --- 1. 询问: 第 2 个答案先给非法值, 应重问 --------------------------------------------
CILIUM_GATEWAY_LB_IP="" CILIUM_LB_POOL_START="" CILIUM_LB_POOL_STOP=""
lb_ipam_addresses_missing || fail "empty addresses must count as missing"
LB_IPAM_TTY="$root/tty"
printf '%s\n' 10.10.31.240 not-an-ip 10.10.31.241 10.10.31.249 > "$LB_IPAM_TTY"
prompt_lb_ipam_addresses >/dev/null || fail "prompt with a tty file must succeed"
[[ $CILIUM_GATEWAY_LB_IP == 10.10.31.240 && $CILIUM_LB_POOL_START == 10.10.31.241 && $CILIUM_LB_POOL_STOP == 10.10.31.249 ]] \
  || fail "prompt did not set the three variables (got $CILIUM_GATEWAY_LB_IP/$CILIUM_LB_POOL_START/$CILIUM_LB_POOL_STOP)"
lb_ipam_addresses_missing && fail "addresses still reported missing after prompt"
[[ -f $LB_IPAM_ANSWERS ]] || fail "answers file was not written"
[[ $(stat -f %Lp "$LB_IPAM_ANSWERS" 2>/dev/null || stat -c %a "$LB_IPAM_ANSWERS") == 600 ]] \
  || fail "answers file must be 0600"
grep -q '^CILIUM_LB_POOL_START="10.10.31.241"$' "$LB_IPAM_ANSWERS" || fail "answers file content unexpected"
grep -q 'not-an-ip' "$LB_IPAM_TTY.out" 2>/dev/null && fail "unexpected side file"
grep -q "不是合法的 IPv4" "$LB_IPAM_TTY" || fail "invalid input must be rejected with a message on the tty"

# --- 2. 只问缺失的项: config.env 已写 Gateway VIP 时不再问它 -----------------------------
CILIUM_GATEWAY_LB_IP="192.168.3.120" CILIUM_LB_POOL_START="" CILIUM_LB_POOL_STOP=""
printf '%s\n' 192.168.3.121 192.168.3.199 > "$LB_IPAM_TTY"
prompt_lb_ipam_addresses >/dev/null || fail "partial prompt must succeed"
[[ $CILIUM_GATEWAY_LB_IP == 192.168.3.120 && $CILIUM_LB_POOL_STOP == 192.168.3.199 ]] \
  || fail "partial prompt must keep explicit value and fill only the missing ones"

# --- 3. 重新加载: 留空的由答案补上, 显式写的优先 -----------------------------------------
CILIUM_GATEWAY_LB_IP="" CILIUM_LB_POOL_START="10.10.99.1" CILIUM_LB_POOL_STOP=""
load_lb_ipam_answers
[[ $CILIUM_GATEWAY_LB_IP == 192.168.3.120 ]] || fail "reload must fill empty Gateway VIP from answers"
[[ $CILIUM_LB_POOL_START == 10.10.99.1 ]] || fail "explicit config value must win over saved answer"
[[ $CILIUM_LB_POOL_STOP == 192.168.3.199 ]] || fail "reload must fill empty pool stop from answers"

# --- 4. 无终端: 返回 1, 不写文件, 不改变量 ----------------------------------------------
rm -f "$LB_IPAM_ANSWERS"
CILIUM_GATEWAY_LB_IP="" CILIUM_LB_POOL_START="" CILIUM_LB_POOL_STOP=""
has_tty() { return 1; }
LB_IPAM_TTY=""
if prompt_lb_ipam_addresses >/dev/null 2>&1; then fail "prompt without a tty must fail"; fi
[[ ! -e $LB_IPAM_ANSWERS ]] || fail "no answers file may be written without a tty"
lb_ipam_addresses_missing || fail "variables must stay empty without a tty"

# --- 5. 开关推导 ---------------------------------------------------------------------
CILIUM_ENABLE_LB_IPAM=auto CILIUM_ENABLE_GATEWAY_API=false CILIUM_ENABLE_L2_ANNOUNCEMENTS=false
lb_ipam_enabled && fail "auto with Gateway+L2 off must be off"
CILIUM_ENABLE_L2_ANNOUNCEMENTS=true
lb_ipam_enabled || fail "auto with L2 on must be on"
CILIUM_ENABLE_L2_ANNOUNCEMENTS=false CILIUM_ENABLE_GATEWAY_API=true
lb_ipam_enabled || fail "auto with Gateway on must be on"
CILIUM_ENABLE_LB_IPAM=true CILIUM_ENABLE_GATEWAY_API=false
lb_ipam_enabled || fail "explicit true must be on"
CILIUM_ENABLE_LB_IPAM=false CILIUM_ENABLE_GATEWAY_API=true
lb_ipam_enabled && fail "explicit false must be off even with Gateway on (preflight rejects the combo)"
unset CILIUM_ENABLE_LB_IPAM
lb_ipam_enabled || fail "unset must behave as auto"

printf 'LB-IPAM prompt/persistence tests: OK\n'
