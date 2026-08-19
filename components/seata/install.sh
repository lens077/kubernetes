#!/usr/bin/env bash
# =============================================================================
# Apache Seata TC(单副本, file store) —— 幂等; 可单独执行:
#   bash components/seata/install.sh
#
# 用自写 manifests 而非 helm: 官方 chart(script/server/helm/seata-server)事实弃养 ——
# apiVersion v1(Helm 2 时代)、appVersion "1.0"、镜像还写 seataio/seata-server:latest、
# 配置靠 hostPath 挂载, 不可用。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (store.mode=file, ${SEATA_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

out=$(mktemp -d)
while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$out/$(basename "$f")"
  kctl apply -f "$out/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$out"

routes_apply "$DIR"
log_ok "$ID 安装完成(集群内 seata-server.$NAMESPACE.svc:8091)"
log_info "客户端配置: registry.type=file + grouplist 指向上面的 Service DNS(见 README)"
