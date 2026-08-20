#!/usr/bin/env bash
# Kyverno —— 准入 policy（选型定稿 §11, audit 先行）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (4 控制器最小化, webhook 排除 kube-system/argocd)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version 3.8.2
kctl -n "$NAMESPACE" rollout status deploy/kyverno-admission-controller --timeout=180s
kctl apply -f "$DIR/examples/policies-audit.yaml"
log_ok "$ID 安装完成(验证: 建个无 limits 的 pod 后 kubectl get policyreport -A)"
