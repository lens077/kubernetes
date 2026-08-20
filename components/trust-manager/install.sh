#!/usr/bin/env bash
# trust-manager —— CA bundle 分发（选型定稿 §4, 用户拍板）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

kctl -n cert-manager get secret global-root-ca-secret >/dev/null \
  || die "cert-manager ns 里找不到 global-root-ca-secret Secret(证书链未就绪?)"

log_step "安装 $ID → 命名空间 $NAMESPACE (trust ns=cert-manager)"
ns_ensure "$NAMESPACE"
helm_install_component "$DIR" --version v0.24.0
kctl -n trust-system rollout status deploy/trust-manager --timeout=120s
kctl apply -f "$DIR/examples/bundle-global-root-ca.yaml"
log_ok "$ID 安装完成(验证: 新建 ns 应自动出现 cm/global-root-ca)"
