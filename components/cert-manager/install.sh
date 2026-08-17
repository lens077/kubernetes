#!/usr/bin/env bash
# =============================================================================
# cert-manager —— 安装本体 + 集群自签签发体系(selfsigned → 根证书 → global-ca-issuer)
#   幂等; 可被 80-components.sh 调用, 也可单独执行:
#     bash components/cert-manager/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

# webhook 没就绪时 apply Issuer/Certificate 会被 admission 拒掉, 这里必须等
log_info "等待 webhook 就绪(签发体系依赖它做准入校验)"
kctl -n "$NAMESPACE" rollout status deploy/cert-manager-webhook --timeout=300s

log_step "应用签发体系: selfsigned 引导 → global-root-ca → global-ca-issuer"
while read -r f; do
  [[ -n $f ]] && kctl apply -f "$f"
done < <(manifest_files "$DIR/issuers")

# 根证书签出前, 下游组件的证书会一直 Pending —— 这里等到位, 让失败暴露在本组件
if kctl -n "$NAMESPACE" wait --for=condition=Ready certificate/global-root-ca --timeout=180s; then
  log_ok "根证书已签发(secret: $NAMESPACE/global-root-ca-secret)"
else
  log_warn "根证书 180s 内未 Ready, 用下面的命令看原因(下游 HTTPS 会一直等它):"
  log_warn "  kubectl -n $NAMESPACE describe certificate global-root-ca"
fi

log_ok "$ID 安装完成"
