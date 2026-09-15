#!/usr/bin/env bash
# =============================================================================
# Reloader 安装 —— Secret/ConfigMap 变更时自动滚动引用它的工作负载; 幂等; 可单独执行:
#   bash components/reloader/install.sh
#   RELOADER_CHART_VERSION=2.2.17 bash components/reloader/install.sh   # 钉 chart 版本
#
# 它只补 ESO 链路的最后一环(Vault/OpenBao → ESO → Secret → *Reloader 滚动 Pod*)。
# 消费方在 Config Center 里的凭据不归它管, 那是 tools/config-center-harvest.sh 的事(README §1)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

# chart 版本与 app 版本不同号(chart 2.2.x ↔ app v1.4.x), GitHub release tag 是 app 版本,
# 不能拿 resolve_version 去猜 chart 号 —— 显式钉死, 升级时改这里并重跑。
ver=${RELOADER_CHART_VERSION:-2.2.17}

log_step "安装 $ID → 命名空间 $NAMESPACE (chart $ver, 单副本, 只滚带注解的工作负载)"
ns_ensure "$NAMESPACE"

# 装了 Argo Rollouts 才开 isArgoRollouts, 否则控制器起来就报 CRD 缺失
extra=()
if ! kctl get crd rollouts.argoproj.io >/dev/null 2>&1; then
  log_info "未发现 Argo Rollouts CRD, 关闭 isArgoRollouts"
  extra+=(--set reloader.isArgoRollouts=false)
fi

helm_install_component "$DIR" --version "$ver" "${extra[@]}"

kctl -n "$NAMESPACE" rollout status "deploy/${RELEASE}-reloader" --timeout=120s >/dev/null \
  || die "$ID 未就绪: kubectl -n $NAMESPACE logs deploy/${RELEASE}-reloader"

log_ok "$ID 安装完成"
log_info "给工作负载加注解即可接入(README §4):"
log_info "  kubectl -n <ns> annotate deploy/<name> secret.reloader.stakater.com/reload=<secret名>"
log_info "端到端自检(建临时 Secret+Deployment, 改值后看是否滚动): bash components/reloader/examples/selftest.sh"
