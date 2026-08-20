#!/usr/bin/env bash
# Vector Agent —— 容器日志采集 + VRL PII 脱敏（选型定稿 §8）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (DaemonSet)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 0.57.0
log_ok "$ID 安装完成(脱敏单测样例: examples/vector-test.yaml)"
