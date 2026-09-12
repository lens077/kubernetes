#!/usr/bin/env bash
# Tetragon 运行时安全观察：三节点采集，策略保持 audit-only。
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 ${NAMESPACE}（三节点观察模式）"
ns_ensure "$NAMESPACE"

# 1.7.1 固定 chart/app 版本，升级前先复核 ARM64、内核和 CRD release notes。
helm_install_component "$DIR" --version 1.7.1 --wait --timeout 5m
kctl -n "$NAMESPACE" rollout status daemonset/tetragon --timeout=300s
kctl -n "$NAMESPACE" rollout status deployment/tetragon-operator --timeout=300s

log_ok "$ID 安装完成（三节点；策略由 ecommerce/infrastructure/tetragon 管理）"
