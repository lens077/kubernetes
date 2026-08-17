#!/usr/bin/env bash
# =============================================================================
# Grafana —— 数据源按"集群里实际装了哪些后端"预置; 幂等; 可单独执行:
#   bash components/grafana/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pass=$(get_cred grafana-admin)     # 只生成一次, 重复执行密码不变

ds="" sources=()
if comp_installed victoriametrics vm-single-victoria-metrics-single-server; then
  # VM 提供 Prometheus 兼容查询 API, 数据源类型就选 prometheus
  ds+="      - name: VictoriaMetrics
        type: prometheus
        url: http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428
        isDefault: true
"
  sources+=(VictoriaMetrics)
fi
if comp_installed logging loki; then
  ds+="      - name: Loki
        type: loki
        url: http://loki.logging.svc.cluster.local:3100
"
  sources+=(Loki)
fi
if comp_installed observability jaeger; then
  ds+="      - name: Jaeger
        type: jaeger
        url: http://jaeger.observability.svc.cluster.local:16686
"
  sources+=(Jaeger)
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (数据源: ${sources[*]:-无})"

dyn=$(mktemp)
{
  echo "adminPassword: \"$pass\""
  if [[ -n $ds ]]; then
    echo "datasources:"
    echo "  datasources.yaml:"
    echo "    apiVersion: 1"
    echo "    datasources:"
    printf '%s' "$ds"
  fi
} > "$dyn"

helm_install_component "$DIR" -f "$dyn"
rm -f "$dyn"

routes_apply "$DIR"
log_ok "$ID 安装完成(https://$HOSTNAME, 用户 admin, 密码见 /root/.k8s-installer-credentials)"
