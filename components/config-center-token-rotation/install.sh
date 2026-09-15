#!/usr/bin/env bash
# config-center-token-rotation —— pre 环境 service token 每周轮换(CronJob); 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_require_cluster
kctl -n config-center get secret config-center-operator >/dev/null 2>&1 \
  || die "缺少 config-center/config-center-operator(先 tools/config-center-operator-token.sh); CronJob 没有它跑不了也不该装"
kctl -n config-center get secret tcr-pull >/dev/null 2>&1 || die "缺少 config-center/tcr-pull: 镜像在 TCR, 没有拉取凭据"
kctl apply -f "$DIR/rbac.yaml" -f "$DIR/cronjob.yaml"
log_ok "config-center-token-rotation 已就绪(CronJob $(kctl -n config-center get cronjob config-center-service-token-rotation -o jsonpath='{.spec.schedule}'), suspend=$(kctl -n config-center get cronjob config-center-service-token-rotation -o jsonpath='{.spec.suspend}'))"
