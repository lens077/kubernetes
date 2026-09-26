# vmalert —— 告警规则评估（VictoriaMetrics → Alertmanager）

## 1. 定位

读 `rules/*.yml`，每 10s 对 VictoriaMetrics 求值，firing 的告警发给 Alertmanager；同时把
`ALERTS` / `ALERTS_FOR_STATE` 写回 VM（元规则 `AlertFiringTooLong` 靠它）。
2026-09-03 从 node3 Pigsty 收割回集群：那边 869 条规则里真正属于这个项目的是 4 个
`ecommerce-*.yml`（14 条），原样迁入；PG 的 16 条按 CNPG 指标重写成 `cnpg.yml`；
新增 `observability-pipeline.yml` 回答「告警系统坏了谁来告警」。

## 2. 上游最佳实践

来源：[vmalert 文档](https://docs.victoriametrics.com/victoriametrics/vmalert/)、
chart `victoria-metrics-alert` 0.47.0（app v1.150.0）

- `-datasource.url` 读、`-remoteWrite.url` 写回、`-remoteRead.url` 重启后恢复 `for` 状态，三者都指向 VM。
- `-rule` 支持通配符与目录；当前安装器等 ConfigMap 投影后显式 POST `/-/reload`。仅修改 ConfigMap 不证明进程已加载，必须检查 `/api/v1/rules`。
- `-external.url` 让通知里的链接指向可访问的地址；`-external.label` 给所有告警加集群标签。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| chart 子 chart 里带 Alertmanager | `alertmanager.enabled=false`，用独立 `alertmanager` 组件 | 一个组件一件事；Alertmanager 还要接 bugsink 之外的来源 |
| 规则写在 values 里 | 规则是 `rules/*.yml` 文件，install.sh 装进 ConfigMap `vmalert-rules` | 规则要 diff、要 review、要能单独跑 YAML 校验 |
| evaluationInterval 1m | 10s（Pigsty 同款） | 小集群评估很便宜；`for:` 才是去抖动的手段，不是拉长评估间隔 |
| 不写 remoteWrite | **必开** | 没有它 `ALERTS_FOR_STATE` 不存在，`AlertFiringTooLong` 永远查不到 |

**规则三条规矩**（来自 `rules/ecommerce-k8s.yml` 头部，install.sh 会校验第一条）：

1. 每条规则必须有 `for:`（唯一例外 `Watchdog`）。缺 `for:` 的规则一波动就红，长期挂红等于没有告警。
2. 每条采集链路配一条 `absent()` 兜底（`K8sClusterMetricsMissing`、`CNPGMetricsMissing`、
   `HubbleFlowTelemetryMissing`、`AlertmanagerMetricsMissing`）：采集断了要**变红**而不是安静变成「无数据」。
3. 写指标名前先在 VM 查到 series（`https://metrics.${CLUSTER_DOMAIN}/vmui`）。VM 开了
   `usePrometheusNaming`：OTLP 点号名变下划线、counter 带 `_total`、带单位的加 `_seconds/_bytes`。
   2026-08-31 点号规则整体断供且不报错的事故就是这么来的。

**应用层告警的 annotation 约定**（`rules/ecommerce-app.yml`，2026-09-24）：除 `summary`/`description` 外必须带
`dashboard`（`https://` 开头，alert-bridge 转成 ntfy 的 `Click`；目前指向预填了该服务错误查询的 Grafana Explore，用 `queryEscape` 拼，因为 APM 盘还没在重建后的 Grafana 里）和 `logs_query`
（可直接粘进 VictoriaLogs 的 LogsQL）。只有 summary 的告警，值班者得自己去找服务、对时间窗，定位慢在这一步。
主机名用 Grafana 的 `root_url`（`components/grafana/values.yaml`，公网 `grafana.apikv.com`），**不要**用 `{{ $externalLabels.cluster }}` 拼——那是内网域 `dev.test`，手机点开解析不了（2026-09-24 第一版就这么错过）。改规则后先在 vmalert Pod 里跑
`/vmalert-prod -dryRun -rule=<文件>`：它会同时解析 MetricsQL 和模板，坏一处就 rc≠0。

## 2026-09-26 非实时通知策略

- 可自愈的主机/服务不可用、CDC 连接/任务与错误率至少持续 10m 才 firing；对应规则 `keep_firing_for: 5m` 延迟恢复，减少闪断。
- Pod 重启必须同时未就绪且 phase=Running；已恢复或 Completed 的 Job 不因为重启窗口残留发通知。
- Deployment 全部不可用（desired>0、available=0）是 critical，部分可用副本不足是 warning。
- Vector DaemonSet 与自身 desired 比较，不写死 3；采集缺失另报，不用无数据生成多条零副本告警。
- 备份/安全规则保留，慢性 `AlertFiringTooLong` 进入低优先级待办并退避，不再高优先级重复打扰。
- 手机优先级与分主题在 bridge 中处理，规则数量和评估频率不是推送频率。

## bridge 指标规则与阈值

`rules/observability-pipeline.yml` 包含三条 bridge 规则，继续走现有 Alertmanager → bridge 分流，不另建 Grafana-managed 副本。

| 规则 | 条件 | 首先检查 |
|---|---|---|
| `AlertBridgeMetricsMissing` | 状态或决策指标缺失持续 10m；容忍短时重启及采集延迟 | bridge Ready、`/metrics`、OTel 的 `alert-bridge` 抓取。 |
| `AlertBridgePublishFailures` | 10m 窗口有失败且条件持续 5m | bridge 发布失败与 AM 失败计数、ntfy 健康和 publisher 配置。滑动窗口保留失败，不等于连续失败 5m；恢复后可能仍需等待窗口清空。 |
| `AlertBridgeNotificationFlood` | 非测试发布超过 20/h 且持续 15m | 先区分真实事件变化与重复，再核对 groupKey、退避状态和 PVC。20/h 是试运行噪声预算，不是故障定论，需观察 24–48h 后校准。 |

三条规则均带 `dashboard` 和 `runbook_url`，指向公网 Grafana 的 `ntfy-alerting-overview` 及其排查说明面板。同链路故障可能阻断这些通知，外部独立 dead-man 仍须另行建设。发布失败不要通过删除状态 PVC 处理，也不要把 token 输出到日志。

## 4. 暴露方式

- 集群内：`http://vmalert.observability.svc.cluster.local:8880`（`/api/v1/rules`、`/api/v1/alerts`）
- 宿主网：`https://vmalert.${CLUSTER_DOMAIN}`（只读页面）

## 5. 验证

```bash
kubectl -n observability rollout status deploy/vmalert
kubectl -n observability get configmap vmalert-rules -o jsonpath='{.data}' | head -c 300
# 规则是否加载 / 有无解析错误
kubectl -n observability logs deploy/vmalert | grep -iE 'error|loaded'
# Watchdog 到达 Alertmanager = vmalert→AM 这段活着
kubectl -n observability exec deploy/vmalert -- wget -qO- 'http://alertmanager:9093/api/v2/alerts?filter=alertname=Watchdog'
# 元数据写回 VM
curl -sG "https://metrics.${CLUSTER_DOMAIN}/api/v1/query" --data-urlencode 'query=ALERTS{alertname="Watchdog"}'
```

## 6. 踩坑

- 改了 `rules/*.yml` 只需重跑 `install.sh`（更新 ConfigMap），不用滚动 Pod；kubelet 同步 ConfigMap 有最长 ~1 分钟延迟。
- `cnpg.yml` 依赖 opentelemetry 组件 values 里的 `cnpg` 抓取 job；没装 CNPG 时只有 `CNPGMetricsMissing` 会 firing，
  这是预期——不想看到就在 Alertmanager 静默它，不要删规则。
- Collector 0.158.0 不再暴露 `otelcol_exporter_send_failed_*`。`observability-pipeline.yml` 使用现场存在的
  `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` 检测持续积压；升级 Collector 时必须先在 VictoriaMetrics 枚举实际 series，再调整规则。
