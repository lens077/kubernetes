#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by check_config loaded through process substitution
set -euo pipefail

BOOTSTRAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
# shellcheck source=../lib/common.sh
source "$BOOTSTRAP_DIR/lib/common.sh"
# 只加载纯配置校验函数；不能 source 00-preflight.sh（尾部会执行 main）。
# shellcheck disable=SC1090
source <(sed -n '/^check_config()/,/^}/p' "$BOOTSTRAP_DIR/scripts/00-preflight.sh")

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
STATE_DIR="$root/state"
LOG_DIR="$root/log"
MAIN_LOG="$LOG_DIR/install.log"
mkdir -p "$LOG_DIR"

NODE_ROLE=control-plane
NODE_NAME=node4
NODE_IP=10.10.21.161
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/12
SINGLE_NODE=true
CILIUM_ENABLE_GATEWAY_API=true
CILIUM_ENABLE_L2_ANNOUNCEMENTS=true
CILIUM_GATEWAY_LB_IP=10.10.31.240
CILIUM_LB_POOL_START=10.10.31.241
CILIUM_LB_POOL_STOP=10.10.31.249

check_config >/dev/null || fail "valid out-of-subnet internal VIP pool was rejected"

# 同网段专属 VIP 也是合法模式；所有权属于运维前置条件，不是脚本能自动证明的事。
CILIUM_GATEWAY_LB_IP=10.10.21.180
CILIUM_LB_POOL_START=10.10.21.181
CILIUM_LB_POOL_STOP=10.10.21.189
check_config >/dev/null || fail "valid same-subnet VIP pools were rejected"

# Gateway 独占 /32；一旦与 default-pool 重叠，两池会 CONFLICTING。
CILIUM_GATEWAY_LB_IP=10.10.21.185
if (check_config >/dev/null 2>&1); then
  fail "overlapping Gateway/default pools were accepted"
fi

CILIUM_GATEWAY_LB_IP=10.10.21.179
CILIUM_LB_POOL_START=10.10.21.190
CILIUM_LB_POOL_STOP=10.10.21.180
if (check_config >/dev/null 2>&1); then
  fail "reversed LB pool was accepted"
fi

CILIUM_GATEWAY_LB_IP=10.10.21.180
CILIUM_LB_POOL_START=10.10.21.160
CILIUM_LB_POOL_STOP=10.10.21.170
if (check_config >/dev/null 2>&1); then
  fail "default pool containing node IP was accepted"
fi

CILIUM_GATEWAY_LB_IP=10.10.21.161
CILIUM_LB_POOL_START=10.10.21.180
CILIUM_LB_POOL_STOP=10.10.21.189
if (check_config >/dev/null 2>&1); then
  fail "Gateway pool containing node IP was accepted"
fi

# 开着 Gateway API 却关掉 L2/LB-IPAM：共享 Gateway 永远拿不到地址，preflight 必须拒绝。
CILIUM_ENABLE_L2_ANNOUNCEMENTS=false
CILIUM_LB_POOL_START=""
CILIUM_LB_POOL_STOP=""
CILIUM_GATEWAY_LB_IP=""
if (check_config >/dev/null 2>&1); then
  fail "Gateway API enabled without LB-IPAM/L2 pool was accepted"
fi

# 两项一起关闭时允许池变量为空（当前安装器会删除旧 gateway-pool/default-pool/default-l2）。
CILIUM_ENABLE_GATEWAY_API=false
check_config >/dev/null || fail "disabled Gateway+L2 with empty pool was rejected"

printf 'LB/Gateway config tests: OK\n'
