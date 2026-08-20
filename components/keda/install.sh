#!/usr/bin/env bash
# KEDA —— 事件驱动扩缩（选型定稿 §7）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 2.20.2
log_ok "$ID 安装完成(验证: kubectl apply -f examples/cron-demo.yaml 观察副本 0↔2)"
