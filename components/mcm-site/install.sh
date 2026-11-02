#!/usr/bin/env bash
# =============================================================================
# mcm-site —— MCM 宣传页(纯静态 Astro 产物, nginx 托管); 幂等; 单独执行:
#   bash components/mcm-site/install.sh
# 2026-10-28: 从 node1 docker(/home/docker/mcm-site)迁入集群, 复刻 blog 的
#   cilium-gateway + HTTPRoute 暴露方式; Pangolin 目标切到 k8s-cluster 后,
#   node1 容器只作回滚备份, 确认无误后下线。
# 内容更新: 改 node1 /home/docker/mcm-site/site → docker build 推新 tag →
#   改本组件 component.env 的 MCM_IMAGE → 重跑 install.sh。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (镜像 ${MCM_IMAGE##*/})"
ns_ensure "$NAMESPACE"

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
