#!/usr/bin/env bash
# =============================================================================
# mapping_test.sh —— 映射门禁: tools/config-center/mapping.yaml 里的每条路径都必须能在
# control-tower 的 JSON Schema(services/config/internal/schema/schemas/<svc>/bootstrap.schema.json)
# 里找到。schema 改字段名时这里先红, 而不是运行时写进一个 Config Center 拒收(或更糟: 收了但服务
# 读不到)的键。离线, 不连集群。
#
#   bash tests/mapping_test.sh
#   CONTROL_TOWER_DIR=/path/to/control-tower bash tests/mapping_test.sh
#   PYTHON=/tmp/ccvenv/bin/python bash tests/mapping_test.sh   # Mac 没有系统 PyYAML 时
# =============================================================================
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CT=${CONTROL_TOWER_DIR:-$HERE/../../control-tower}
SCHEMAS="$CT/services/config/internal/schema/schemas"
[[ -d $SCHEMAS ]] || { echo "找不到 control-tower schema 目录: $SCHEMAS(设 CONTROL_TOWER_DIR)" >&2; exit 2; }
PY=${PYTHON:-python3}
"$PY" -c 'import yaml' 2>/dev/null || { echo "需要 python3 + PyYAML(PYTHON=<venv>/bin/python)" >&2; exit 2; }
exec "$PY" "$HERE/../tools/config-center/harvest.py" --check-mapping --schemas-dir "$SCHEMAS"
