#!/usr/bin/env bash
# =============================================================================
# elasticsearch-exporter —— 把 ES 集群/索引/JVM 指标暴露给 OTel Collector; 幂等。
# 只在集群内 ClusterIP:9114 暴露，不经网关、不进 Pangolin。
#   bash components/elasticsearch-exporter/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

kctl -n elasticsearch get sts elasticsearch >/dev/null \
  || die "elasticsearch 未安装，先 bash components/elasticsearch/install.sh"
kctl -n elasticsearch get secret elasticsearch-auth >/dev/null \
  || die "缺少 elasticsearch-auth Secret，exporter 无法访问 ES /_cluster/stats"

log_step "安装 $ID → 命名空间 $NAMESPACE"
for f in "$DIR"/manifests/*.yaml; do
  kctl apply -f "$f"
done
kctl -n "$NAMESPACE" rollout status deploy/elasticsearch-exporter --timeout=180s >/dev/null \
  || die "elasticsearch-exporter 未就绪，检查 kubectl -n $NAMESPACE logs deploy/elasticsearch-exporter"
log_ok "$ID 安装完成(metrics: elasticsearch-exporter.$NAMESPACE.svc:9114/metrics)"
