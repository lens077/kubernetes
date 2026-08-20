#!/usr/bin/env bash
# OpenKruise —— 仅 ImagePullJob（选型定稿 §7）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (featureGates: ImagePullJobGate)"
helm_install_component "$DIR" --version 1.9.1
log_ok "$ID 安装完成(验证: kubectl apply -f examples/imagepulljob-demo.yaml)"
