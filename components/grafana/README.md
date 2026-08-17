# grafana —— 观测数据的统一门面

## 1. 定位

指标（VictoriaMetrics）、日志（Loki）、链路（Jaeger）三个后端的统一查询界面与告警入口。
数据源在安装时按**集群里实际装了哪些后端**自动预置，不用手点。

## 2. 上游最佳实践

来源：[Grafana Helm chart](https://github.com/grafana/helm-charts/tree/main/charts/grafana)

- 数据源用 provisioning（`datasources.yaml`）声明式管理，不要手工在 UI 里加——
  重建实例就丢。
- 管理员密码用 `admin.existingSecret` 或外部 secret 管理，别写进 values 提交到仓库。
- 面板同样走 provisioning（sidecar 按 label 自动加载 ConfigMap）。
- 反向代理后面部署要设 `grafana.ini.server.root_url` 与 `serve_from_sub_path`（仅子路径场景）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 数据源手工配置或写死在 values | **按集群实况生成** | `install.sh` 查各后端 Service 是否存在再决定加哪个数据源。没装 Loki 却预置了 Loki 数据源，面板打开就是一片红。 |
| 密码写 values | **走 creds 机制** | `get_cred grafana-admin` 只生成一次，存在 `/root/.k8s-installer-credentials`（chmod 600），仓库里不出现密码。 |
| 独立域名 + 自己的 Gateway | 共享网关 + `grafana.app.com` | 见 [gateway](../gateway/) 的路由约定。旧仓的 `observability-web-gateway` 硬编码了 IP 和 3000 端口，已废弃。 |
| 无 resources | `limits 0.5c/512Mi` | 面板渲染是突发负载，限住上限避免和数据后端抢内存。 |
| `dataproxy.concurrent_query_count` 默认 | 20 | 后端是单机 VM/Loki，并发放太大只会让它们排队，反而更慢。 |

## 4. 暴露方式

- 对外：`https://grafana.app.com`（共享网关，证书 global-ca-issuer）
- 集群内：`grafana.observability.svc.cluster.local:80`
- 凭据：用户 `admin`，密码见 `/root/.k8s-installer-credentials`

告警规则：带 `grafana_alert` 标签的 ConfigMap 会被 sidecar 自动加载。
告警通知当前只在 Grafana UI 里看，后续接飞书 webhook（规则按 severity 分级，critical 才路由）。

## 5. 验证

```bash
kubectl -n observability get pvc grafana                     # Bound
```

真验证（登录 + 数据源连通性，而不只是 Pod Running）：

```bash
PASS=$(cat /var/lib/k8s-installer/creds/grafana-admin)
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')

# 从局域网其他主机执行
curl -sk -u "admin:$PASS" https://$GW/api/datasources --resolve grafana.app.com:443:$GW \
     -H "Host: grafana.app.com" | python3 -m json.tool | grep -E '"name"|"type"'

# 逐个数据源做健康检查（返回 200 才算真连通）
curl -sk -u "admin:$PASS" -H "Host: grafana.app.com" \
     "https://$GW/api/datasources/name/VictoriaMetrics" | head -c 200
```

## 6. 踩坑

- **数据源列表是空的**：装 Grafana 时后端还没起来。重跑 `bash components/grafana/install.sh`
  即可（幂等，密码不变）。
- **改了 values 但密码没变**：`get_cred` 是"只生成一次"语义，要重置就删
  `/var/lib/k8s-installer/creds/grafana-admin` 再重装。
- **面板里 trace 关联不上日志**：Jaeger 数据源要配 `tracesToLogs`，这块目前没预置，
  需要在 UI 里按实际的 label 映射配置。
