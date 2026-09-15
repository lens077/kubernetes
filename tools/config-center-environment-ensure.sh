#!/usr/bin/env bash
# Idempotently prepare a Config Center environment from a non-secret declaration.
# This command never accepts an admin password and never creates an operator token.
# A pre-issued operator token must exist in ADMIN_TOKEN_SECRET.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" && pwd)/env.sh"
TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DECLARATION=${ENVIRONMENT_FILE:-$TOOLS_DIR/config-center/environments/${ENVIRONMENT:-staging}.yaml}
[[ -r $DECLARATION ]] || die "缺少环境声明 $DECLARATION"
PY=${PYTHON:-python3}
readarray -t meta < <("$PY" - "$DECLARATION" <<'PY'
import sys,yaml
x=yaml.safe_load(open(sys.argv[1]))
print(x['environment']); print(x.get('strategy','pre')); print(' '.join(x['services']))
print((x.get('delivery') or {}).get('namespace','ecommerce')); print(x['delivery']['selector_secret'])
PY
)
ENVIRONMENT=${meta[0]}; STRATEGY=${meta[1]}; SERVICES=${meta[2]}; SECRET_NS=${meta[3]}; SELECTOR=${meta[4]}
[[ -n ${ADMIN_TOKEN_SECRET:-} ]] || die "需要预先签发的 operator token: ADMIN_TOKEN_SECRET=<ns>/<name>:token"
export ENVIRONMENT STRATEGY SERVICES ECOMMERCE_NAMESPACE=$SECRET_NS
EXTRA=(); [[ ${1:-} == --dry-run ]] && EXTRA+=(--dry-run)
# harvest 负责模板合成、Schema 校验、契约填充、写回与 service token 读回验证。
"$TOOLS_DIR/config-center-harvest.sh" --strategy "$STRATEGY" --require-schema "${EXTRA[@]}"
"$TOOLS_DIR/config-center-harvest.sh" --consumer config-center --strategy pre "${EXTRA[@]}"
log_info "环境 $ENVIRONMENT 已幂等收敛; selector Secret=$SECRET_NS/$SELECTOR"
