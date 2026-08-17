#!/usr/bin/env bash
# =============================================================================
# kured —— 内核补丁后在维护窗口内自动排空+重启; 幂等; 可单独执行:
#   bash components/kured/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 维护窗口 ${KURED_REBOOT_WINDOW_START}-${KURED_REBOOT_WINDOW_END} ${TIMEZONE}"
helm_install_component "$DIR"

log_ok "$ID 安装完成(节点出现 /var/run/reboot-required 时在窗口内自动排空并重启)"
