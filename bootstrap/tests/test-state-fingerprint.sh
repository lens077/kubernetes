#!/usr/bin/env bash
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
STATE_DIR="$root/state-root"
export BACKUP_DIR="$STATE_DIR/backups"
export CACHE_DIR="$root/cache"
export LOG_DIR="$root/log"
export K8S_FILES_DIR="$root/files"
STAGE_ID="60-cilium"
ensure_dirs

for key in preflight prepull helm wait l2 conn; do
  touch "$STATE_DIR/state/$STAGE_ID:$key.done"
done

state_reconcile_fingerprint desired sha-a preflight prepull helm wait l2 conn \
  || fail "first fingerprint must invalidate downstream steps"
for key in preflight prepull helm wait l2 conn; do
  [[ ! -e "$STATE_DIR/state/$STAGE_ID:$key.done" ]] \
    || fail "first fingerprint left $key marked done"
done

for key in preflight prepull helm wait l2 conn; do
  touch "$STATE_DIR/state/$STAGE_ID:$key.done"
done
if state_reconcile_fingerprint desired sha-a preflight prepull helm wait l2 conn; then
  fail "unchanged fingerprint must not report a change"
fi
for key in preflight prepull helm wait l2 conn; do
  [[ -e "$STATE_DIR/state/$STAGE_ID:$key.done" ]] \
    || fail "unchanged fingerprint invalidated $key"
done

state_reconcile_fingerprint desired sha-b preflight prepull helm wait l2 conn \
  || fail "changed fingerprint must invalidate downstream steps"
for key in preflight prepull helm wait l2 conn; do
  [[ ! -e "$STATE_DIR/state/$STAGE_ID:$key.done" ]] \
    || fail "changed fingerprint left $key marked done"
done

fingerprint_file="$STATE_DIR/state/$STAGE_ID:desired.fingerprint.done"
[[ $(<"$fingerprint_file") == sha-b ]] || fail "fingerprint was not stored atomically"
state_reset "$STAGE_ID"
[[ ! -e $fingerprint_file ]] || fail "stage reset did not remove fingerprint"

if state_reconcile_fingerprint "" sha-c helm 2>/dev/null; then
  fail "empty fingerprint name must be rejected"
fi
if state_reconcile_fingerprint desired "" helm 2>/dev/null; then
  fail "empty fingerprint value must be rejected"
fi
if state_reconcile_fingerprint desired sha-c 2>/dev/null; then
  fail "missing downstream steps must be rejected"
fi

printf 'state fingerprint tests: OK\n'
