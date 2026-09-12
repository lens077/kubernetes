# alertmanager —— 告警路由（分组 / 抑制 / 静默 → 告警桥）

## 1. 定位

vmalert 的唯一 notifier。做四件事：按 `alertname` 分组、`K8sNodeNotReady` / 采集断链时抑制下游告警、
人工静默、把结果 webhook 给 `alert-bridge`（再由桥推 ntfy）。**不直接对接 ntfy**：Alertmanager 没有
ntfy receiver，而桥这一层顺便把每条告警落成 JSON 日志（进 VictoriaLogs），这是「告警去了哪」的第二条证据链。
取值沿用 node3 Pigsty（2026-09-03 收割）：`group_wait 30s`、`group_interval 5m`、`repeat_interval 1h`。

## 2. 上游最佳实践

来源：[Alertmanager 文档](https://prometheus.io/docs/alerting/latest/configuration/)、
chart `prometheus-community/alertmanager` 1.42.0（app v0.34.0）

- 路由树：默认 receiver + 少量 `routes`；用 `matchers`（新语法）而不是 `match`/`match_re`。
- 抑制规则要求 `equal` 标签在源与目标上都存在，否则不生效。
- 状态（silences、nflog）落盘，需要持久卷；单副本时 `--cluster.listen-address=` 关闭 gossip。
- 永远 firing 的 `Watchdog` 是判断「告警链路活着」的标准做法，路由到 `null` receiver。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 多 receiver（邮件/Slack/…） | 只有 `alert-bridge` webhook + `null` | 推送渠道统一为 ntfy；桥可换渠道而不动 Alertmanager |
| `repeat_interval 3h`（chart 默认） | 1h | Pigsty 的取值，未处理的告警一小时提醒一次 |
| 高可用多副本 | 单副本 + `ALERTMANAGER_STORAGE_SIZE=200Mi` PVC | 三节点小集群；`AlertmanagerNotificationFailures` 与 gatus 的 watchdog 探针覆盖它自身故障 |
| 抑制 `NodeDown → node 类` | `K8sNodeNotReady → category=kubernetes`（equal `k8s_node_name`）、`K8sClusterMetricsMissing → category=kubernetes` | 节点没了、采集断了，同类别的下游告警都是噪音 |

## 4. 暴露方式

- 集群内：`http://alertmanager.observability.svc.cluster.local:9093`（vmalert notifier、gatus 探针、Grafana 数据源）
- 宿主网：`https://alerts.${CLUSTER_DOMAIN}`——做静默在这里，**不要改规则去消音**。

## 5. 验证

```bash
kubectl -n observability rollout status statefulset/alertmanager
kubectl -n observability exec statefulset/alertmanager -- wget -qO- http://127.0.0.1:9093/-/ready
# 手工打一条测试告警, 看桥的日志是否收到(ntfy 未配置时也会有一行 skipped)
kubectl -n observability exec statefulset/alertmanager -- wget -qO- --post-data \
  '[{"labels":{"alertname":"ManualTest","severity":"warning"},"annotations":{"summary":"手工测试"}}]' \
  --header 'Content-Type: application/json' http://127.0.0.1:9093/api/v2/alerts
kubectl -n observability logs deploy/alert-bridge --tail=5
```

## 6. 踩坑

- webhook 到桥失败会计入 `alertmanager_notifications_failed_total`，vmalert 有对应规则；桥收到但 ntfy 失败会回 502，
  Alertmanager 按退避重试——所以 ntfy 短暂不可用不会丢告警。
- `matchers: ['alertname="Watchdog"']` 是 0.22+ 语法；旧 `match:` 写法在新版本仍能用但会告警废弃。
