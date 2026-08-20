#!/usr/bin/env bash
# Spegel —— P2P 镜像缓存试装（选型定稿 §9）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (DaemonSet)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 0.7.4
log_ok "$ID 安装完成(命中率观察: kubectl -n spegel logs ds/spegel | grep -i mirror)"
