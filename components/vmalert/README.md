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
- `-rule` 支持通配符与目录；规则文件改动后自动热加载（默认 `-rule.reloadInterval`，chart 用 ConfigMap 挂载）。
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
- `observability-pipeline.yml` 里 `otelcol_exporter_send_failed_*` 三个名字随 collector 版本演进过，上线前先查 series。
