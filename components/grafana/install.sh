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

# admin 口令: ESO 从 OpenBao 物化 Secret grafana-admin(externalsecret.yaml, chart 走 admin.existingSecret);
# 降级时 get_cred + 自建同名 Secret。Grafana 只在首次初始化读它, 之后改值不换密码(README §6)。
ns_ensure "$NAMESPACE"
if ! cred_via_eso "$DIR" "$NAMESPACE" grafana-admin; then
  kctl -n "$NAMESPACE" create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(get_cred grafana-admin)" \
    --dry-run=client -o yaml | kctl apply -f -
fi

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
if comp_installed tempo tempo; then
  # 评估期与 Jaeger 并存(ADDON_TEMPO 默认 false); TraceQL 查询走 3200
  ds+="      - name: Tempo
        type: tempo
        url: http://tempo.tempo.svc.cluster.local:3200
"
  sources+=(Tempo)
fi
# ---- 2026-09-03: node3 Pigsty 退役后集群内的 VL/VT/Alertmanager(数据源 uid 固定, 仪表盘 JSON 才能跨环境导入) ----
plugins=()
if comp_installed logging vl-victoria-logs-single-server; then
  # VictoriaLogs 官方数据源插件(不是 loki 类型); 插件由 chart 的 plugins: 在启动时下载
  ds+="      - name: VictoriaLogs
        uid: ds-vlogs
        type: victoriametrics-logs-datasource
        url: http://vl-victoria-logs-single-server.logging.svc.cluster.local:9428
"
  sources+=(VictoriaLogs)
  plugins+=(victoriametrics-logs-datasource)
fi
if comp_installed observability victoria-traces; then
  # VictoriaTraces 提供 Jaeger 兼容查询 API, 用内置 jaeger 数据源即可(与 node3 Pigsty 同款配置)
  ds+="      - name: VictoriaTraces
        uid: ds-vtraces
        type: jaeger
        url: http://victoria-traces.observability.svc.cluster.local:10428/select/jaeger
"
  sources+=(VictoriaTraces)
fi
if comp_installed observability alertmanager; then
  # 告警页(Alerting → Alert rules/Groups)直接看 Alertmanager 里的 firing/silence, 不必再开一个 UI
  ds+="      - name: Alertmanager
        uid: ds-alertmanager
        type: alertmanager
        url: http://alertmanager.observability.svc.cluster.local:9093
        jsonData:
          implementation: prometheus
          handleGrafanaManagedAlerts: false
"
  sources+=(Alertmanager)
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (数据源: ${sources[*]:-无})"

dyn=$(mktemp)
{
  echo "admin: { existingSecret: grafana-admin, userKey: admin-user, passwordKey: admin-password }"
  if (( ${#plugins[@]} > 0 )); then
    echo "plugins:"
    printf '  - %s\n' "${plugins[@]}"
  fi
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
