#!/usr/bin/env bash
# ClickHouse 单节点 —— 埋点 OLAP（选型定稿 §3, 用户拍板）; 幂等; 可单独执行
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pass=$(get_cred clickhouse-app)   # 只生成一次; 重装不换

log_step "安装 $ID → 命名空间 $NAMESPACE (官方镜像 StatefulSet, PVC=${SC_NAME})"
ns_ensure "$NAMESPACE"
kctl -n "$NAMESPACE" create secret generic clickhouse-app \
  --from-literal=password="$pass" \
  --dry-run=client -o yaml | kctl apply -f -

rendered=$(mktemp)
render_tpl "$DIR/manifests/clickhouse.yaml" "$rendered"
kctl apply -f "$rendered"
rm -f "$rendered"
log_ok "$ID 安装完成(svc: $NAMESPACE/clickhouse:8123, 用户 app/凭据在 creds/clickhouse-app)"
