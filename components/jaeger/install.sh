#!/usr/bin/env bash
# =============================================================================
# Jaeger v2 all-in-one(badger 本地存储) —— 用仓库里精修的 manifests, 不走 chart
#   幂等; 可单独执行: bash components/jaeger/install.sh
#
# 为什么不用 Helm: 见 README「本集群取舍」——官方 chart 绑 ES/Cassandra 后端,
# badger 单机形态反而是手写 manifest 更清楚(且注释能留在文件里)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (badger 卷 ${JAEGER_STORAGE_SIZE} / SC ${SC_NAME})"
ns_ensure "$NAMESPACE"

tmp=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")"
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

# ConfigMap 不再由 Helm 管理 → 改配置不会自动重启 Pod。这里在配置变更后主动滚动,
# 否则"改了配置却没生效"会静默存在很久。
if kctl -n "$NAMESPACE" get deploy jaeger >/dev/null 2>&1; then
  kctl -n "$NAMESPACE" rollout restart deploy/jaeger >/dev/null
fi

routes_apply "$DIR"
log_ok "$ID 安装完成(OTLP: jaeger.$NAMESPACE.svc:4317(gRPC)/4318(HTTP); UI: https://$HOSTNAME)"
