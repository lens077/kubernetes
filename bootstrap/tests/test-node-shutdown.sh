#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
# shellcheck source=../lib/common.sh
source "$BOOTSTRAP_DIR/lib/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_budget() {
  local total=$1 critical=$2 expected=$3 actual
  actual=$(node_shutdown_budget_seconds "$total" "$critical") \
    || fail "expected valid budget: $total/$critical"
  [[ $actual == "$expected" ]] \
    || fail "$total/$critical: expected '$expected', got '$actual'"
}

assert_invalid() {
  local total=$1 critical=$2
  if node_shutdown_budget_seconds "$total" "$critical" >/dev/null 2>&1; then
    fail "expected invalid budget: $total/$critical"
  fi
}

assert_budget 90s     30s  "90 30"
assert_budget 1m30s   30s  "90 30"
assert_budget 2h5m4s  1h   "7504 3600"
assert_budget 0s      0s   "0 0"

assert_invalid ""    30s
assert_invalid 90    30s
assert_invalid 1.5m  30s
assert_invalid 01m   30s
assert_invalid 1d    30s
assert_invalid 30s   31s
assert_invalid 0s    1s

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
cat > "$tmp_dir/kubelet.yaml" <<'EOF'
shutdownGracePeriod: 1m30s
shutdownGracePeriodCriticalPods: 30s
EOF
[[ $(kubelet_shutdown_budget_seconds "$tmp_dir/kubelet.yaml") == "90 30" ]] \
  || fail "expected kubelet runtime budget to normalize to '90 30'"
printf 'shutdownGracePeriod: 90s\n' > "$tmp_dir/kubelet-invalid.yaml"
if kubelet_shutdown_budget_seconds "$tmp_dir/kubelet-invalid.yaml" >/dev/null 2>&1; then
  fail "expected incomplete kubelet runtime budget to fail"
fi

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/busctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_BUSCTL_OUTPUT:?}"
EOF
chmod 755 "$fake_bin/busctl"
PATH="$fake_bin:$PATH"
export FAKE_BUSCTL_OUTPUT='t 90000000'
[[ $(logind_effective_inhibit_seconds) == 90 ]] \
  || fail "expected live logind delay to normalize to 90 seconds"
cat > "$tmp_dir/zzz-kubelet.conf" <<'EOF'
[Login]
InhibitDelayMaxSec=90
EOF
export NODE_SHUTDOWN_LOGIND_DROPIN="$tmp_dir/zzz-kubelet.conf"
export NODE_SHUTDOWN_KUBELET_CONFIG="$tmp_dir/kubelet.yaml"
verify_graceful_node_shutdown_config \
  || fail "expected config.env, kubelet, drop-in and live logind values to match"

log_error() { :; }
printf '[Login]\nInhibitDelayMaxSec=60\n' > "$tmp_dir/zzz-kubelet.conf"
if verify_graceful_node_shutdown_config; then
  fail "expected mismatched logind drop-in to fail consistency validation"
fi
printf '[Login]\nInhibitDelayMaxSec=90\n' > "$tmp_dir/zzz-kubelet.conf"
printf 'shutdownGracePeriod: 60s\nshutdownGracePeriodCriticalPods: 30s\n' > "$tmp_dir/kubelet.yaml"
if verify_graceful_node_shutdown_config; then
  fail "expected mismatched kubelet runtime budget to fail consistency validation"
fi

export FAKE_BUSCTL_OUTPUT='t 90000001'
if logind_effective_inhibit_seconds >/dev/null 2>&1; then
  fail "expected sub-second logind delay to fail consistency parsing"
fi

printf 'PASS: GracefulNodeShutdown duration and consistency validation\n'
