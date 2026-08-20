#!/usr/bin/env bash
# VictoriaLogs —— 日志存储（选型定稿 §8, 用户拍板）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (单机版, PVC=${SC_NAME})"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 0.13.9
log_ok "$ID 安装完成(svc: $NAMESPACE/vl-victoria-logs-single-server:9428)"
