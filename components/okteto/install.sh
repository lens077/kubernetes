#!/usr/bin/env bash
# =============================================================================
# okteto —— 内环开发 CLI。**不往集群装任何东西**: 本脚本做的是客户端自检 +
# 集群侧前置条件校验, 幂等; 可单独执行:
#   bash components/okteto/install.sh
#
# 真正的使用入口是 `okteto up <svc>`(见 README)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "检查 $ID 使用条件(本机 CLI 组件, 不部署集群资源)"

if ! has_cmd okteto; then
  log_warn "本机没有 okteto CLI。安装:"
  log_info "  brew install okteto     # 或 https://github.com/okteto/okteto/releases"
  log_info "  首次 okteto up 会从 GitHub 下载 syncthing 二进制 —— 大陆需挂代理(PROXY_URL)"
  exit 0                           # 不是错误: 这个组件在别的机器上用也合理
fi
log_ok "okteto CLI: $(okteto version 2>&1 | head -1)"

# 集群侧前置: okteto up 要建 PVC 放依赖缓存(persistentVolume.enabled)
if kctl get storageclass "${SC_NAME:-openebs-lvm}" >/dev/null 2>&1; then
  log_ok "StorageClass ${SC_NAME:-openebs-lvm} 存在(dev 容器的依赖缓存 PVC 用它)"
else
  log_warn "StorageClass ${SC_NAME:-openebs-lvm} 不存在: manifest 里要么指定别的 SC, 要么关掉 persistentVolume"
fi

# 与 GitOps 的共存检查 —— 这是本组件最容易吃亏的地方(见 README §GitOps)
if kctl get ns argocd >/dev/null 2>&1; then
  log_warn "集群装了 ArgoCD: okteto up 会把原 Deployment 缩到 0 并新建 <name>-okteto,"
  log_warn "  在 GitOps 眼里是漂移。开工前先关目标 App 的自动同步(selfHeal/prune),"
  log_warn "  收工后务必恢复 —— 忘了恢复比忘了关更糟(此后所有部署静默不生效)。"
  log_info "  ecommerce 仓的 scripts/argocd-devwindow.sh 是一个可抄的 off/on 实现"
fi

log_ok "$ID 检查完成"
log_info "用法: okteto context use $(kctl config current-context) --namespace <ns> && okteto up <svc>"
log_info "示例 manifest: $DIR/examples/okteto.yaml"
