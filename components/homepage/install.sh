#!/usr/bin/env bash
# =============================================================================
# homepage —— d.apikv.com 总控制台(静态页 + 遥测只读代理); 幂等; 单独执行:
#   bash components/homepage/install.sh
# 2026-10-28: 从 node1 docker(/home/docker/homepage)迁入集群, 复刻 blog 的
#   cilium-gateway + HTTPRoute 暴露方式。
# 遥测代理: 镜像内 nginx 模板把 /t/*.json 反代到 https://metrics.apikv.com
#   (vmauth 只读 token), resolver 已从 docker DNS 改为 kube-dns。
# token 真相源: secret victoriametrics/vmauth-credentials 的 read-token 键,
#   安装时现取写入 homepage-secret —— 与 node1 旧 telemetry.env 同源, 轮换后重跑即可。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (镜像 ${HOMEPAGE_IMAGE##*/})"
ns_ensure "$NAMESPACE"

# VM 只读 token 不进仓库: 安装时从 vmauth-credentials 现取(与 node1 deploy.sh 同源)
kctl -n "$NAMESPACE" create secret generic homepage-secret \
  --from-literal=VM_READ_TOKEN="$(kctl -n victoriametrics get secret vmauth-credentials -o jsonpath='{.data.read-token}' | base64 -d)" \
  --dry-run=client -o yaml | kctl apply -f -

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"
routes_apply "$DIR"

wait_for "deploy/$RELEASE" 120
log_ok "$ID 安装完成: https://$HOSTNAME"
