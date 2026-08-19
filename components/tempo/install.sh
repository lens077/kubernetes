#!/usr/bin/env bash
# =============================================================================
# Grafana Tempo(单体, 本地盘) —— 幂等; 可单独执行:
#   bash components/tempo/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (retention ${TEMPO_RETENTION}, ${TEMPO_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

# chart 版本钉在 config.env: 3.x 是大重构(live-store/Kafka 化), 单体形态先不跟
helm_install_component "$DIR" --version "${TEMPO_CHART_VERSION:-2.2.4}"

routes_apply "$DIR"
log_ok "$ID 安装完成(OTLP 集群内 tempo.$NAMESPACE.svc:4317/4318, 查询 https://$HOSTNAME)"
log_info "Grafana 数据源: 重跑 components/grafana/install.sh 会自动探测并预置 Tempo"
