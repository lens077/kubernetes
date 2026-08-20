#!/usr/bin/env bash
# NATS JetStream —— 事件底座（选型定稿 §1）; 幂等; 可单独执行:
#   bash components/nats/install.sh
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (JetStream 3 副本, PVC=${SC_NAME})"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 2.14.5
log_ok "$ID 安装完成(svc: $NAMESPACE/nats:4222; 验证见 examples/smoke.sh)"
