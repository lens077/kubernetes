#!/usr/bin/env bash
# start.sh 阶段范围(--from/--to/--only/--verify/--worker)与 --dry-run 的回归矩阵。
# 只走 start.sh 的参数解析与 RUN_LIST 计算: --dry-run 在 require_root/ensure_dirs/加锁之前退出,
# 因此本测试无需 root, 不写 /var/lib/k8s-installer, 不执行任何阶段脚本。
set -euo pipefail

BOOTSTRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
START="$BOOTSTRAP_DIR/start.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# run_list <参数...> → stdout 只含阶段 id(每行一个); 失败时返回 start.sh 的退出码
run_list() {
  bash "$START" --dry-run "$@" 2>/dev/null | cut -f1
}

expect_list() {  # expect_list "<期望 id 列表(空格分隔)>" <参数...>
  local expected=$1; shift
  local actual
  actual=$(run_list "$@" | tr '\n' ' ' | sed 's/ $//') \
    || fail "start.sh --dry-run $* 意外失败"
  [[ $actual == "$expected" ]] \
    || fail "start.sh --dry-run $*: 期望 [$expected], 实际 [$actual]"
}

expect_reject() {  # expect_reject "<错误片段>" <参数...>
  local needle=$1; shift
  local out rc=0
  out=$(bash "$START" --dry-run "$@" 2>&1 >/dev/null) || rc=$?
  (( rc == 2 )) || fail "start.sh --dry-run $*: 期望退出码 2, 实际 $rc"
  grep -q -- "$needle" <<<"$out" \
    || fail "start.sh --dry-run $*: 错误信息缺少 [$needle], 实际: $out"
}

ALL="00-preflight 10-system-base 20-kernel-tuning 30-download 40-container-runtime 45-etcd-disk 50-kubernetes 60-cilium 70-storage 80-components 90-verify"

# --- 控制面 -----------------------------------------------------------------
expect_list "$ALL"
expect_list "00-preflight 10-system-base 20-kernel-tuning 30-download 40-container-runtime 45-etcd-disk 50-kubernetes 60-cilium 70-storage" \
  --to 70-storage
expect_list "80-components 90-verify" --from 80-components
expect_list "60-cilium 70-storage" --from 60-cilium --to 70-storage
expect_list "60-cilium" --from 60-cilium --to 60-cilium
expect_list "30-download" --only 30-download
expect_list "90-verify" --verify
expect_list "90-verify" --yes --verify

# --- worker: 跳过集群级阶段; --to 终点本身被跳过也是合法范围 --------------------
expect_list "00-preflight 10-system-base 20-kernel-tuning 30-download 40-container-runtime 50-kubernetes 70-storage 90-verify" \
  --worker
expect_list "00-preflight 10-system-base 20-kernel-tuning 30-download 40-container-runtime 50-kubernetes" \
  --worker --to 60-cilium
expect_list "70-storage 90-verify" --worker --from 60-cilium
expect_list "90-verify" --worker --from 80-components
expect_list "90-verify" --worker --verify

# --- 拒绝项(退出码 2, 不写系统) ------------------------------------------------
expect_reject "未知阶段" --from 99-nope
expect_reject "未知阶段" --to 99-nope
expect_reject "未知阶段" --only 99-nope
expect_reject "位于 --from" --from 80-components --to 60-cilium
expect_reject "--only 不能与" --only 60-cilium --from 50-kubernetes
expect_reject "--only 不能与" --verify --to 70-storage
expect_reject "需要参数值" --to
expect_reject "需要参数值" --from --to 70-storage
expect_reject "需要参数值" --only
expect_reject "未知参数" --bogus
expect_reject "worker 角色下不执行" --worker --only 60-cilium
expect_reject "没有可执行阶段" --worker --from 60-cilium --to 60-cilium
# 范围内夹着未跳过的 50-kubernetes 时仍有可执行阶段
expect_list "50-kubernetes" --worker --from 45-etcd-disk --to 60-cilium

# --- dry-run 的输出契约: 阶段 id 在 stdout, 标题以 TAB 分隔, 提示在 stderr ----------
line=$(bash "$START" --dry-run --only 60-cilium 2>/dev/null)
[[ $line == $'60-cilium\t'* ]] || fail "dry-run 输出格式应为 <id><TAB><标题>, 实际: $line"
bash "$START" --dry-run --only 60-cilium 2>&1 >/dev/null | grep -q 'dry-run 不执行' \
  || fail "dry-run 提示应输出到 stderr"

printf 'stage range tests: OK\n'
