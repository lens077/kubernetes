#!/usr/bin/env bash
# =============================================================================
# gatus —— 合成监控(探公网入口/集群内服务/观测链路是否真的有数据); 幂等; 可单独执行:
#   bash components/gatus/install.sh
# ntfy 凭据与 alert-bridge 共用同一来源($STATE_DIR/creds/ntfy.env 或环境变量 NTFY_*),
# 没配也能装: install.sh 会去掉 alerting 段与端点里的 alerts 行, 只在面板上红。
# 改端点: 编辑 endpoints.yaml 重跑本脚本(ConfigMap 指纹变化会滚动 Pod)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

creds_file="$STATE_DIR/creds/ntfy.env"
ntfy_url=${NTFY_URL:-} ntfy_topic=${NTFY_TOPIC:-} ntfy_token=${NTFY_TOKEN:-}
if [[ -z $ntfy_url && -f $creds_file ]]; then
  # shellcheck disable=SC1090
  source "$creds_file"
  ntfy_url=${NTFY_URL:-}; ntfy_topic=${NTFY_TOPIC:-}; ntfy_token=${NTFY_TOKEN:-}
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (ntfy: ${ntfy_url:-未配置, 不推送})"
ns_ensure "$NAMESPACE"

kctl -n "$NAMESPACE" create secret generic gatus-ntfy \
  --from-literal=NTFY_URL="$ntfy_url" \
  --from-literal=NTFY_TOPIC="$ntfy_topic" \
  --from-literal=NTFY_TOKEN="$ntfy_token" \
  --dry-run=client -o yaml | kctl apply -f -

# 渲染配置: 未配置 ntfy 时删掉 alerting 段(gatus 对空 url 会校验失败)与端点里的 alerts 行
tmp=$(mktemp -d)
if [[ -n $ntfy_url ]]; then
  cp "$DIR/config.yaml" "$tmp/config.yaml"
  cp "$DIR/endpoints.yaml" "$tmp/endpoints.yaml"
else
  sed '/^alerting:/,$d' "$DIR/config.yaml" > "$tmp/config.yaml"
  sed '/alerts: \[{type: ntfy}\]/d' "$DIR/endpoints.yaml" > "$tmp/endpoints.yaml"
fi
kctl -n "$NAMESPACE" create configmap gatus-config \
  --from-file=config.yaml="$tmp/config.yaml" \
  --from-file=endpoints.yaml="$tmp/endpoints.yaml" \
  --dry-run=client -o yaml | kctl apply -f -
# shellcheck disable=SC2034  # render_tpl 通过间接展开读取
CONFIG_SHA256=$(cat "$tmp/config.yaml" "$tmp/endpoints.yaml" | sha256sum | awk '{print $1}')

while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")" CONFIG_SHA256
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

routes_apply "$DIR"
log_ok "$ID 安装完成: https://$HOSTNAME  (指标: http://gatus.$NAMESPACE.svc:8080/metrics)"
