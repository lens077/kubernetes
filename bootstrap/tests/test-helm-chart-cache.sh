#!/usr/bin/env bash
# 回归: 缓存里有精确版本 tgz 时 helm_install_component 必须把 tgz 路径交给 helm, 且不 repo add。
# 2026-09-22 事故: 只跳过了 repo add 却仍传 "repo/chart" → "repo xxx not found", 手工 scp 的 chart 装不上。
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 只加载被测函数, 打桩它的依赖(不碰真实 helm / 集群)
source <(sed -n '/^helm_install_component()/,/^}/p' "$repo/components/_lib/env.sh")
CACHE_DIR="$root/cache"; mkdir -p "$CACHE_DIR/charts"
ID=demo NAMESPACE=demo RELEASE=demo HELM_REPO="demo https://example.invalid" HELM_CHART=demo/demo
repo_add_calls=0; helm_args=""
helm_repo_add() { repo_add_calls=$((repo_add_calls + 1)); }
helm_chart_ref_via_github_proxy() { echo "$1"; }
helm_cmd() { helm_args="$*"; }
retry() { shift 2; "$@"; }
render_tpl() { :; }

# 1) 命中缓存: chart_ref = tgz 路径, 零次 repo add
: > "$CACHE_DIR/charts/demo-1.2.3.tgz"; printf 'x' > "$CACHE_DIR/charts/demo-1.2.3.tgz"
helm_install_component "$root" --version 1.2.3
[[ $helm_args == *"$CACHE_DIR/charts/demo-1.2.3.tgz"* ]] || fail "缓存命中时应传 tgz 路径, 实际: $helm_args"
[[ $helm_args != *" demo/demo "* ]] || fail "缓存命中时不应再传 repo/chart 引用"
[[ $repo_add_calls == 0 ]] || fail "缓存命中时不应 repo add(调了 $repo_add_calls 次)"

# 2) 版本不匹配: 回退 repo add + repo/chart
helm_args=""; repo_add_calls=0
helm_install_component "$root" --version 9.9.9
[[ $helm_args == *" demo/demo "* ]] || fail "缓存未命中时应传 repo/chart, 实际: $helm_args"
[[ $repo_add_calls == 1 ]] || fail "缓存未命中时应 repo add 一次(调了 $repo_add_calls 次)"

# 3) 空文件不算缓存(scp 中断留下的 0 字节)
helm_args=""; repo_add_calls=0
: > "$CACHE_DIR/charts/demo-2.0.0.tgz"
helm_install_component "$root" --version 2.0.0
[[ $helm_args == *" demo/demo "* && $repo_add_calls == 1 ]] || fail "0 字节 tgz 不应被当作缓存命中"

# 4) 无 --version: 永远走 repo
helm_args=""; repo_add_calls=0
helm_install_component "$root"
[[ $helm_args == *" demo/demo "* && $repo_add_calls == 1 ]] || fail "无 --version 时应走 repo"

printf 'PASS: helm_install_component 缓存命中/未命中/空文件/无版本 四条路径正确\n'
