#!/usr/bin/env bash
# =============================================================================
# config-center-harvest.sh —— 按组件契约把地址/凭据/CA 写进 Config Center 各服务的 bootstrap.yaml
#
#   bash tools/config-center-harvest.sh --dry-run            # 只读: 脱敏 diff, 不写任何东西(推荐先跑)
#   bash tools/config-center-harvest.sh                      # 写入 pre 环境 + 滚动 ecommerce 服务
#   ENV=dev bash tools/config-center-harvest.sh --dry-run    # dev 策略: 网关域名 + CA
#   SERVICES="cart user" bash tools/config-center-harvest.sh # 只处理部分服务
#   bash tools/config-center-harvest.sh --check-mapping      # 离线门禁: 映射路径 ↔ control-tower schema
#   bash tools/config-center-harvest.sh --consumer config-center --dry-run   # control-tower config 服务自举 Secret(P3)
#
# 它取代 config-center-pre-seed.sh 的「改字段」部分: pre-seed 只会改 redis 两个字段, 这里按
# tools/config-center/mapping.yaml 处理全部依赖能力(redis/postgres/consul/otlp/casdoor/elasticsearch),
# 提供方来自 components/*/component.env 与 components/_external/*/component.env 的契约声明,
# 冲突时看 config.env 的 CC_PROVIDERS。新环境的首次播种(从 dev 复制整份)仍用 pre-seed.sh。
#
# 管理 token: 文件 /root/.config-center-admin-token(config-center-admin-token.sh 生成), 或
#   ADMIN_TOKEN_SECRET=<ns>/<name>:<key>(P4 管理面服务账号)。dry-run 不需要。
# 从非节点机器执行: K8S_CONFIG_ENV=bootstrap/config.hosting.env, bash ≥ 4.2, python3 + PyYAML(+jsonschema)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" &>/dev/null && pwd)/env.sh"

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PY=${PYTHON:-python3}
"$PY" -c 'import yaml' 2>/dev/null || die "需要 python3 + PyYAML(节点自带; Mac 用 uv venv 后 PYTHON=<venv>/bin/python)"

# 离线门禁不需要集群
for a in "$@"; do [[ $a == --check-mapping ]] && exec "$PY" "$TOOLS_DIR/config-center/harvest.py" "$@"; done

comp_require_cluster
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
[[ -r $KUBECONFIG ]] || unset KUBECONFIG   # 非节点机器用调用者的 ~/.kube/config

# 契约: 声明 + 现状核对(有不一致先报, 但外部实例的 ESO 物化在 P1 前允许缺, 由 harvest 按需报错)
CC_CONTRACTS_JSON=$(bash "$TOOLS_DIR/verify-contracts.sh" --json 2>/dev/null) || true
[[ -n $CC_CONTRACTS_JSON ]] || die "没有任何启用的提供方契约(components/*/component.env 的 PROVIDES)"
export CC_CONTRACTS_JSON

# Config Center 地址: 节点上走 ClusterIP; 非节点机器给 CONFIG_CENTER_URL(如 port-forward 到本机)
export CONFIG_CENTER_URL=${CONFIG_CENTER_URL:-}
export CC_OVERRIDES=${CC_OVERRIDES:-$STATE_DIR/config-center/overrides.yaml}
[[ -f $CC_OVERRIDES ]] || { log_info "没有 overrides 文件 $CC_OVERRIDES(casdoor client_id 等非机密固定值), 需要时报错"; export CC_OVERRIDES=""; }
# 服务 schema(决定每个服务要填哪些块 + 写前校验): 开发机用 control-tower 同级仓, 节点用同步过来的副本
_sib="$REPO_ROOT/../control-tower/services/config/internal/schema/schemas"
export CC_SCHEMAS_DIR=${CC_SCHEMAS_DIR:-$([[ -d $_sib ]] && echo "$_sib" || echo "$STATE_DIR/config-center/schemas")}
[[ -d $CC_SCHEMAS_DIR ]] || die "缺少服务 schema 目录 $CC_SCHEMAS_DIR: 从 control-tower 仓同步
  rsync -a <control-tower>/services/config/internal/schema/schemas/ $STATE_DIR/config-center/schemas/"

args=(--env "${ENV:-pre}")
[[ -n ${SERVICES:-} ]] && args+=(--services "$SERVICES")
[[ -n ${ADMIN_TOKEN_SECRET:-} ]] && args+=(--admin-token-secret "$ADMIN_TOKEN_SECRET")
exec "$PY" "$TOOLS_DIR/config-center/harvest.py" "${args[@]}" "$@"
