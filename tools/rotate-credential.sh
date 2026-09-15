#!/usr/bin/env bash
# =============================================================================
# rotate-credential.sh —— 共享凭据轮换的完整四段, 按顺序一次做完, 把不一致窗口压到最短
#
#   bash tools/rotate-credential.sh dragonfly            # 真轮换(需要 Config Center 管理/operator token)
#   bash tools/rotate-credential.sh dragonfly --dry-run  # 只演示每一段会做什么
#
#   ① OpenBao 写新随机值           tools/openbao-seed.sh --rotate <组件>
#   ② ESO 立刻同步 + 提供方滚动     components/<组件>/install.sh(cred_via_eso 检测到值变 → rollout restart)
#   ③ 消费方重写                    tools/config-center-harvest.sh(Config Center 里 10 份 bootstrap.yaml) + --consumer config-center
#   ④ 验收                          ecommerce 各 Deployment rollout status
#
# 只允许「每次启动都从 Secret 读凭据」的组件(dragonfly / meilisearch / minio / redis); grafana、harbor、
# bugsink、healthchecks 首次初始化后把口令存进自己的库, 改 Secret 无效 —— openbao-seed.sh 会拒绝。
# 装了 reloader 时第 ② 段的滚动会被它抢先做掉, 顺序不变、结果一致。
# 管理 token: /root/.config-center-admin-token(Casdoor 会话)或 ADMIN_TOKEN_SECRET=<ns>/<name>:<key>(operator token, P4)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" &>/dev/null && pwd)/env.sh"
TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

comp=${1:-}; [[ -n $comp ]] || { sed -n 2,18p "$0"; exit 1; }
DRY=""; [[ ${2:-} == --dry-run ]] && DRY=--dry-run
comp_require_cluster

# 组件目录名与 OpenBao 路径段可能不同(dragonflydb ↔ dragonfly)
case $comp in
  dragonfly|dragonflydb) dir=dragonflydb; seed=dragonfly ;;
  *) dir=$comp; seed=$comp ;;
esac
[[ -f $COMPONENTS_DIR/$dir/install.sh ]] || die "没有组件 $dir"
[[ -f $COMPONENTS_DIR/$dir/externalsecret.yaml ]] || die "$dir 还没接 ESO(缺 externalsecret.yaml), 不能走这条轮换路径"

# 先确认第 ③ 段有权限, 否则轮换到一半消费方连不上, 只能人工收尾
if [[ -z $DRY ]]; then
  [[ -n ${ADMIN_TOKEN_SECRET:-} || -r ${ADMIN_TOKEN_FILE:-/root/.config-center-admin-token} ]] \
    || die "缺少 Config Center 管理 token: 先 bash tools/config-center-admin-token.sh, 或设 ADMIN_TOKEN_SECRET(operator token)"
  eso_store_ready || die "ClusterSecretStore ${ESO_STORE:-openbao} 未就绪, 不能轮换"
fi

log_step "① OpenBao 写新值: k8s/${CLUSTER_NAME:-?}/$seed"
bash "$TOOLS_DIR/openbao-seed.sh" --rotate $DRY "$seed"

log_step "② ESO 同步 + 提供方滚动: components/$dir/install.sh"
if [[ -n $DRY ]]; then log_info "[dry-run] 会执行 install.sh: cred_via_eso 检测到 Secret 值变化 → rollout restart"; else
  bash "$COMPONENTS_DIR/$dir/install.sh"
fi

log_step "③ 消费方重写: Config Center 各服务 bootstrap.yaml + config-center 自举 Secret"
bash "$TOOLS_DIR/config-center-harvest.sh" $DRY
bash "$TOOLS_DIR/config-center-harvest.sh" --consumer config-center $DRY

if [[ -z $DRY ]]; then
  log_step "④ 验收"
  fail=0
  for d in $(kctl -n ecommerce get deploy -o name | grep 'ecommerce-.*-deploy'); do
    kctl -n ecommerce rollout status "$d" --timeout=120s >/dev/null 2>&1 && log_ok "$d" || { log_warn "$d 未就绪"; fail=1; }
  done
  (( fail == 0 )) && log_ok "轮换完成: $comp" || die "有服务未就绪, 检查其日志(通常是消费方还在用旧密码 → 重跑 harvest)"
fi
