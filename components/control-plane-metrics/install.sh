#!/usr/bin/env bash
# =============================================================================
# control-plane-metrics —— 控制面进程级指标(apiserver/etcd/scheduler/KCM) → VictoriaMetrics;
# 幂等; 可单独执行:
#   bash components/control-plane-metrics/install.sh
#
# 只部署在 k1，hostNetwork 抓 127.0.0.1 的四个 /metrics 端点，不改静态 Pod manifest。
# 改采集配置: 编辑 manifests/collector-config.yaml.tpl 后重跑本脚本(配置哈希变化会滚动 Pod)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed victoriametrics vm-single-victoria-metrics-single-server \
  || die "victoriametrics 未安装: 控制面指标没有写入目标(先 bash components/victoriametrics/install.sh)"
kctl get node k1 >/dev/null 2>&1 \
  || die "集群里没有节点 k1: 本组件依赖 k1 是唯一控制面且四个静态 Pod 在其本机回环上"

log_step "安装 $ID → 命名空间 $NAMESPACE (k1 → VictoriaMetrics)"

ns_ensure "$NAMESPACE"

# 采集配置单独渲染成 ConfigMap; 文件名不带 .yaml 后缀, 避免被 manifest_files 当清单 apply。
tmp=$(mktemp -d)
render_tpl "$DIR/manifests/collector-config.yaml.tpl" "$tmp/collector.yaml"
CONFIG_SHA256=$(sha256sum "$tmp/collector.yaml" | awk '{print $1}')
kctl -n "$NAMESPACE" create configmap control-plane-metrics-config \
  --from-file=collector.yaml="$tmp/collector.yaml" \
  --dry-run=client -o yaml | kctl apply -f -

while read -r f; do
  [[ -n $f ]] || continue
  render_tpl "$f" "$tmp/$(basename "$f")" CONFIG_SHA256
  kctl apply -f "$tmp/$(basename "$f")"
done < <(manifest_files "$DIR/manifests")
rm -rf "$tmp"

kctl -n "$NAMESPACE" rollout status deploy/control-plane-metrics --timeout=180s >/dev/null \
  || die "control-plane-metrics 未就绪, 查: kubectl -n $NAMESPACE logs deploy/control-plane-metrics"

log_ok "$ID 安装完成(4 个 job 抓 k1 本机端口 2381/6443/10259/10257, 30s 间隔写入 VM)"
log_info "  验收: kubectl -n observability exec deploy/grafana -c grafana -- curl -sG 'http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/query' --data-urlencode 'query=count by (job) (up{job=~\"control-plane-.*\"})'"
