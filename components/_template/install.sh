#!/usr/bin/env bash
# =============================================================================
# <组件> 安装 —— 幂等; 可被 80-components.sh 调用, 也可单独执行:
#   bash components/<组件>/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE"
ns_ensure "$NAMESPACE"

# 需要密码的组件在这里取(只生成一次, 重复执行结果一致):
#   pass=$(get_cred "$ID-admin")

# helm 安装: values.yaml 里的 ${SC_NAME} 等占位符由 render_tpl 替换
helm_install_component "$DIR"

# Gateway 路由(gateway/*.yaml)
routes_apply "$DIR"

log_ok "$ID 安装完成"
