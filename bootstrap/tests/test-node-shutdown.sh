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

for threshold in 1 100 2147483647; do
  validate_terminated_pod_gc_threshold "$threshold" \
    || fail "expected valid PodGC threshold: $threshold"
done
for threshold in "" 0 -1 1.5 01 2147483648; do
  if validate_terminated_pod_gc_threshold "$threshold" >/dev/null 2>&1; then
    fail "expected invalid PodGC threshold: $threshold"
  fi
done

controller_manifest="$tmp_dir/kube-controller-manager.yaml"
cat > "$controller_manifest" <<'EOF'
apiVersion: v1
kind: Pod
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
EOF
[[ $(ensure_static_pod_command_arg "$controller_manifest" kube-controller-manager \
      terminated-pod-gc-threshold 100) == changed ]] \
  || fail "expected missing PodGC flag to be inserted"
[[ $(grep -Fc -- '--terminated-pod-gc-threshold=100' "$controller_manifest") == 1 ]] \
  || fail "expected exactly one PodGC flag after insertion"
[[ $(ensure_static_pod_command_arg "$controller_manifest" kube-controller-manager \
      terminated-pod-gc-threshold 100) == unchanged ]] \
  || fail "expected matching PodGC flag to remain unchanged"
printf '    - --terminated-pod-gc-threshold=200\n' >> "$controller_manifest"
[[ $(ensure_static_pod_command_arg "$controller_manifest" kube-controller-manager \
      terminated-pod-gc-threshold 100) == changed ]] \
  || fail "expected duplicate PodGC flags to be normalized"
[[ $(grep -Fc -- '--terminated-pod-gc-threshold=' "$controller_manifest") == 1 ]] \
  || fail "expected duplicate PodGC flags to be removed"

bad_manifest="$tmp_dir/bad-controller.yaml"
printf 'apiVersion: v1\nkind: Pod\n' > "$bad_manifest"
before=$(cksum "$bad_manifest")
if ensure_static_pod_command_arg "$bad_manifest" kube-controller-manager \
     terminated-pod-gc-threshold 100 >/dev/null 2>&1; then
  fail "expected manifest without kube-controller-manager command to fail"
fi
[[ $(cksum "$bad_manifest") == "$before" ]] \
  || fail "expected failed manifest update to leave source untouched"

split_manifest="$tmp_dir/split-controller.yaml"
cat > "$split_manifest" <<'EOF'
spec:
  containers:
  - command:
    - kube-controller-manager
    - --terminated-pod-gc-threshold
    - "200"
EOF
before=$(cksum "$split_manifest")
if ensure_static_pod_command_arg "$split_manifest" kube-controller-manager \
     terminated-pod-gc-threshold 100 >/dev/null 2>&1; then
  fail "expected split-form PodGC flag to fail instead of leaving conflicting args"
fi
[[ $(cksum "$split_manifest") == "$before" ]] \
  || fail "expected split-form rejection to leave manifest untouched"

ambiguous_manifest="$tmp_dir/ambiguous-controller.yaml"
cat > "$ambiguous_manifest" <<'EOF'
spec:
  containers:
  - command:
    - kube-controller-manager
  example:
    - kube-controller-manager
EOF
before=$(cksum "$ambiguous_manifest")
if ensure_static_pod_command_arg "$ambiguous_manifest" kube-controller-manager \
     terminated-pod-gc-threshold 100 >/dev/null 2>&1; then
  fail "expected ambiguous kube-controller-manager anchor to fail"
fi
[[ $(cksum "$ambiguous_manifest") == "$before" ]] \
  || fail "expected ambiguous anchor rejection to leave manifest untouched"

cluster_config="$tmp_dir/ClusterConfiguration.yaml"
cat > "$cluster_config" <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: 192.168.3.250:6443
controllerManager:
  extraArgs:
  - name: allocate-node-cidrs
    value: "true"
  - name: terminated-pod-gc-threshold
    value: "200"
  - name: terminated-pod-gc-threshold
    value: "300"
featureGates:
  SomeFutureGate: true
dns: {}
EOF
[[ $(ensure_kubeadm_controller_manager_arg_file "$cluster_config" \
      terminated-pod-gc-threshold 100) == changed ]] \
  || fail "expected live ClusterConfiguration target arg to change"
[[ $(grep -c 'name: terminated-pod-gc-threshold' "$cluster_config") == 1 ]] \
  || fail "expected duplicate ClusterConfiguration args to be normalized"
grep -q 'value: "100"' "$cluster_config" \
  || fail "expected ClusterConfiguration PodGC value to become 100"
grep -q '^controlPlaneEndpoint: 192.168.3.250:6443$' "$cluster_config" \
  || fail "expected unrelated controlPlaneEndpoint to be preserved"
grep -q '^  SomeFutureGate: true$' "$cluster_config" \
  || fail "expected unrelated feature gate to be preserved"
[[ $(ensure_kubeadm_controller_manager_arg_file "$cluster_config" \
      terminated-pod-gc-threshold 100) == unchanged ]] \
  || fail "expected matching live ClusterConfiguration to remain unchanged"

missing_extra="$tmp_dir/missing-extra.yaml"
printf 'apiVersion: kubeadm.k8s.io/v1beta4\nkind: ClusterConfiguration\ncontrollerManager: {}\n' \
  > "$missing_extra"
before=$(cksum "$missing_extra")
if ensure_kubeadm_controller_manager_arg_file "$missing_extra" \
     terminated-pod-gc-threshold 100 >/dev/null 2>&1; then
  fail "expected unsupported ClusterConfiguration shape to fail closed"
fi
[[ $(cksum "$missing_extra") == "$before" ]] \
  || fail "expected failed ClusterConfiguration update to leave source untouched"

export KCM_TERMINATED_POD_GC_THRESHOLD=100
export KCM_STATIC_POD_MANIFEST="$controller_manifest"
export FAKE_TERMINAL_PODS_JSON='{"items":[{"metadata":{"deletionTimestamp":null},"status":{"phase":"Succeeded"}},{"metadata":{"deletionTimestamp":null},"status":{"phase":"Failed"}},{"metadata":{"deletionTimestamp":null},"status":{"phase":"Failed"}},{"metadata":{"deletionTimestamp":"2026-08-21T00:00:00Z"},"status":{"phase":"Failed"}}]}'
kctl() {
  case " $* " in
    *" get configmap kubeadm-config "*) printf '%s\n' 'controllerManager:' '  extraArgs:' '  - name: terminated-pod-gc-threshold' '    value: "100"' ;;
    *" get pods -A -o json "*)          printf '%s\n' "$FAKE_TERMINAL_PODS_JSON" ;;
    *" get pods -l component=kube-controller-manager "*)
      printf '%s\n' '{"items":[{"spec":{"containers":[{"name":"kube-controller-manager","command":["kube-controller-manager","--allocate-node-cidrs=true","--terminated-pod-gc-threshold=100"]}]},"status":{"containerStatuses":[{"name":"kube-controller-manager","ready":true}]}}]}'
      ;;
    *) return 1 ;;
  esac
}
verify_terminated_pod_gc_config \
  || fail "expected manifest and controller-manager PodGC values to match"
[[ $(terminal_pod_count) == 3 ]] \
  || fail "expected terminal Pod counter to exclude deletionTimestamp and return 3"
terminated_pod_gc_converged || fail "expected terminal Pod count to be below threshold"

FAKE_TERMINAL_PODS_JSON=$(jq -nc \
  '{items: [range(0;112) | {metadata:{deletionTimestamp:null},status:{phase:"Failed"}}]}')
if terminated_pod_gc_converged; then
  fail "expected 112 terminal Pods to exceed threshold 100"
fi
FAKE_TERMINAL_PODS_JSON=$(jq -nc \
  '{items: [range(0;100) | {metadata:{deletionTimestamp:null},status:{phase:"Failed"}}]}')
terminated_pod_gc_converged || fail "expected terminal Pod count 100 to satisfy threshold 100"

printf 'PASS: node shutdown and terminal Pod GC validation\n'
