#!/usr/bin/env bash
# Kyverno —— 准入 policy（选型定稿 §11, audit 先行）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (4 控制器最小化, webhook 排除 kube-system/argocd)"
ns_ensure "$NAMESPACE"
# 镜像走 TCR 镜像仓(values.yaml 里已改 registry/repository), 拉取凭据先物化, 否则第一个 Pod 就 401
tcr_pull_secret_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 3.9.1 --timeout 10m
kctl -n "$NAMESPACE" rollout status deploy/kyverno-admission-controller --timeout=180s
# Pod Ready ≠ webhook 已监听: 刚滚完那几秒 apply ClusterPolicy 会撞 policymutate webhook
# "connection refused"(2026-09-22 实测), 所以带重试
retry 6 5 kctl apply -f "$DIR/examples/policies-audit.yaml"
log_ok "$ID 安装完成(验证: bash $DIR/examples/smoke.sh)"
