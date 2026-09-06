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

# ---- 池(LB-IPAM)与 L2 通告解耦 ----------------------------------------------------
# 只经 newt/Pod 访问: Gateway 开、L2 关、池 auto → 池仍开, 地址照常校验。
CILIUM_ENABLE_L2_ANNOUNCEMENTS=false
CILIUM_ENABLE_LB_IPAM=auto
CILIUM_GATEWAY_LB_IP=10.10.31.240
CILIUM_LB_POOL_START=10.10.31.241
CILIUM_LB_POOL_STOP=10.10.31.249
check_config >/dev/null || fail "Gateway on + L2 off + LB-IPAM auto (pool without announcement) was rejected"
lb_ipam_enabled || fail "auto must derive LB-IPAM=on from Gateway API"
CILIUM_GATEWAY_LB_IP=10.10.31.245   # 池地址规则在 L2 关闭时同样生效
if (check_config >/dev/null 2>&1); then fail "overlap check skipped when L2 is off"; fi
CILIUM_GATEWAY_LB_IP=10.10.31.240

# Gateway 开却把池显式关掉：共享 Gateway 永远拿不到地址，preflight 必须拒绝。
CILIUM_ENABLE_LB_IPAM=false
if (check_config >/dev/null 2>&1); then fail "Gateway API enabled with LB-IPAM=false was accepted"; fi

# L2 开、池关：没有可通告的地址，拒绝。
CILIUM_ENABLE_GATEWAY_API=false
CILIUM_ENABLE_L2_ANNOUNCEMENTS=true
if (check_config >/dev/null 2>&1); then fail "L2 enabled with LB-IPAM=false was accepted"; fi

# 非法取值
CILIUM_ENABLE_LB_IPAM=maybe
if (check_config >/dev/null 2>&1); then fail "invalid CILIUM_ENABLE_LB_IPAM was accepted"; fi

# Gateway 关、L2 关、池 auto → 池关, 允许地址为空(安装器会删除旧池与 default-l2)。
CILIUM_ENABLE_LB_IPAM=auto
CILIUM_ENABLE_L2_ANNOUNCEMENTS=false
CILIUM_LB_POOL_START=""
CILIUM_LB_POOL_STOP=""
CILIUM_GATEWAY_LB_IP=""
check_config >/dev/null || fail "disabled Gateway+L2 with empty pool was rejected"
lb_ipam_enabled && fail "auto must derive LB-IPAM=off when Gateway and L2 are both off"

# 池开但地址为空且无终端：必须停下(不能默默继续到 60 阶段)。
# 在真实终端里跑测试时 has_tty 为真会进入询问, 这里强制"无终端"保证确定性。
has_tty() { return 1; }
CILIUM_ENABLE_LB_IPAM=true
LB_IPAM_TTY=""
if (check_config >/dev/null 2>&1); then fail "LB-IPAM on with empty addresses and no tty was accepted"; fi

printf 'LB/Gateway config tests: OK\n'
