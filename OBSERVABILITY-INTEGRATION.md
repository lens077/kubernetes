# 观测与告警链路接线手册

三类信号（指标/日志/链路）怎么进后端、告警怎么从规则走到手机、合成监控与死人开关怎么兜底、
错误追踪怎么接进来——以及**每一段怎么证明它通了**。组件本身的取舍写在各自的
`components/<组件>/README.md`，本文只讲它们之间的线。

背景：2026-09-03 之前这套链路的存储与告警侧在 node3 的 Pigsty 上（Victoria 全家桶 + vmalert +
Alertmanager + 自写告警桥 + gatus/healthchecks/bugsink）。node3 重装后这些能力只存在于集群内，
配置由 [`PIGSTY-HARVEST-2026-09-03.md`](PIGSTY-HARVEST-2026-09-03.md) 收割而来。

## 1. 全景

```text
 ┌──────────── 产生 ─────────────┐   ┌──────── 采集/中继 ────────┐   ┌──────── 存储 ────────┐   ┌──── 门面 ────┐
 Go 服务 / 前端 (OTel SDK) ──OTLP──▶ otel-opentelemetry-collector ─▶ VictoriaMetrics :8428  ─┐
 Cilium/Hubble/Tetragon 指标 ──scrape─▶  (Deployment, opentelemetry ns)  ─▶ VictoriaLogs   :9428  ─┼─▶ Grafana
 CNPG / vmalert / AM / gatus ──scrape─▶  ├ k8s_cluster / k8sobjects      ─▶ VictoriaTraces :10428 ─┘   (数据源 uid 固定:
 K8s 对象状态与 Event ────────────────▶  └ prometheus receiver                                          ds-prometheus/ds-vlogs/
 节点主机指标 ── otel-node DaemonSet ───────────────────────────────▶ VictoriaMetrics                    ds-vtraces/ds-alertmanager)
 容器 stdout/stderr ── vector DaemonSet(VRL 脱敏) ───────────────────▶ VictoriaLogs

 ┌──────────────────────────── 告警 ─────────────────────────────┐
 VictoriaMetrics ◀─read/write─ vmalert(rules/*.yml, 10s) ─▶ Alertmanager ─▶ alert-bridge ─▶ ntfy (手机)
                                                                 :9093        :9099     └─▶ stdout JSON ─▶ vector ─▶ VictoriaLogs
 Bugsink(issue webhook) ───────────────────────────────────────────────────▶ alert-bridge :9199/bugsink/<token>
 gatus(合成探测) ───────────────────── 失败直推 ────────────────────────────▶ ntfy          (不经 Alertmanager)
 healthchecks(死人开关) ◀── CronJob / 备份 ping ──── 到期没 ping ───────────▶ ntfy(面板里配 integration)
```

三个设计选择：

1. **告警链路有两条独立的「活着」证据**：vmalert 永远 firing 的 `Watchdog` 必须出现在 Alertmanager 里
   （gatus 查 `/api/v2/alerts`），以及 `vmalert_alerts_send_errors_total` /
   `alertmanager_notifications_failed_total` 两条自检规则。链路坏了自己会红。
2. **gatus 与 healthchecks 不经过 Alertmanager**。它们守的正是「Alertmanager 那条路坏了」的场景，
   所以直接推 ntfy。
3. **每条告警都落日志**。告警桥把 Alertmanager 的每条告警写成一行 JSON，Vector 采进 VictoriaLogs：
   手机上没收到、ntfy 抽风、想复盘上周红了什么，都查 `kubernetes.container_name:alert-bridge`。

## 2. 安装顺序

`config.env` 里这些开关默认全开，`sudo bash bootstrap/start.sh --only 80-components` 按依赖分层并行安装；
单独装按下面顺序（依赖关系：`vmalert → victoriametrics, alertmanager`；`alertmanager → alert-bridge`；
`bugsink → alert-bridge`；`grafana → victoriametrics, victoria-logs, victoria-traces, alertmanager`）：

```bash
# 0. 凭据(可选, 没有也能装, 桥与 gatus 只记日志不推送)
export NTFY_URL=https://ntfy.apikv.com NTFY_TOPIC=<topic> NTFY_TOKEN=<token>

# 1. 存储层
bash components/victoriametrics/install.sh
bash components/victoria-logs/install.sh
bash components/victoria-traces/install.sh
# 2. 告警层(先桥, 再 AM, 再 vmalert)
bash components/alert-bridge/install.sh
bash components/alertmanager/install.sh
bash components/vmalert/install.sh
# 3. 采集层(它们按"集群里实际装了哪些后端"生成 pipeline, 所以放在存储层之后)
bash components/opentelemetry/install.sh
bash components/opentelemetry-node/install.sh
bash components/vector/install.sh
# 4. 门面与保障层
bash components/grafana/install.sh
bash components/gatus/install.sh
bash components/healthchecks/install.sh
bash components/bugsink/install.sh
# 5. 端到端冒烟(打一条 metric/log/span 到 collector, 从 VM/VL/VT 查回)
sudo bash bootstrap/start.sh --verify
```

存储层先装、采集层后装不是洁癖：`components/opentelemetry/install.sh` 与 `grafana/install.sh` 都用
`comp_installed` 查集群，后端不存在就不生成对应 exporter/数据源。顺序反了要重跑一次采集层脚本。

## 3. 逐段接线与验证

### 3.1 信号 → Collector → 后端

| 线 | 配置在哪 | 怎么验证 |
|---|---|---|
| 应用 OTLP → collector | 应用 `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-opentelemetry-collector.opentelemetry.svc:4318` | `90-verify` 冒烟；或 Grafana Explore 按 `service.name` 查 |
| collector → VM（metrics） | `opentelemetry/install.sh` 自动生成 `otlp_http/victoriametrics` | `curl -sG https://metrics.dev.test/api/v1/query --data-urlencode 'query=up'` |
| collector → VL（logs） | 同上 `otlp_http/victorialogs`（`logs_endpoint` 带 `/insert` 前缀） | `https://logs.dev.test` 不存在时用 Grafana 的 VictoriaLogs 数据源查 `object.kind:=Event` |
| collector → VT（traces） | 同上 `otlp_http/victoriatraces` | Grafana 数据源 VictoriaTraces → Search 出现 service |
| otel-node → VM | `opentelemetry-node/component.env` 的 `REMOTE_METRICS_URL` 留空 | vmui 查 `system_cpu_time_seconds_total` |
| vector → VL | `vector/values.yaml` sink `victorialogs.uri` | Grafana VictoriaLogs 查 `kubernetes.pod_namespace:=kube-system` |
| CNPG/vmalert/AM/gatus → VM | `opentelemetry/values.yaml` 的 `prometheus/cilium` receiver 新增 4 个 job | vmui 查 `cnpg_collector_up`、`vmalert_alerts_send_errors_total`、`alertmanager_build_info`、`gatus_results_total` |

指标命名口径（VM 开了 `usePrometheusNaming`）：OTLP 点号变下划线（`k8s.container.restarts` →
`k8s_container_restarts`），单调计数加 `_total`，带单位加 `_seconds`/`_bytes`（`system.cpu.time` →
`system_cpu_time_seconds_total`）。collector 里配置仍写点号名，**只有查询和规则用下划线**。

### 3.2 规则 → Alertmanager → 桥 → ntfy

| 线 | 配置在哪 | 怎么验证 |
|---|---|---|
| vmalert 读/写 VM | `vmalert/values.yaml` 的 `datasource/remoteWrite/remoteRead` | `ALERTS{alertname="Watchdog"}` 能在 VM 查到 |
| vmalert → AM | `vmalert/values.yaml` 的 `notifier.url` | `kubectl -n observability exec deploy/vmalert -- wget -qO- 'http://alertmanager:9093/api/v2/alerts?filter=alertname=Watchdog'` 非空 |
| AM → 桥 | `alertmanager/values.yaml` 的 receiver `alert-bridge` | 打一条手工告警（alertmanager README §5），`kubectl -n observability logs deploy/alert-bridge` 出现该行 |
| 桥 → ntfy | `alert-bridge/install.sh`（`NTFY_*` → Secret） | 桥 README §5 的直连测试；`/healthz` 里 `"ntfy": true` |
| 告警历史 → VL | 桥的 stdout 经 vector | Grafana VictoriaLogs 查 `kubernetes.container_name:=alert-bridge` |

规则怎么写（`components/vmalert/README.md` §3）：必须有 `for:`；每条采集链路配 `absent()` 兜底；
指标名先在 vmui 查到 series 再写。改完 `rules/*.yml` 重跑 `bash components/vmalert/install.sh`。

### 3.3 保障层

| 线 | 配置在哪 | 怎么验证 |
|---|---|---|
| gatus → 集群内后端 | `gatus/endpoints.yaml` `cluster-origin` 组 | `https://status.dev.test` 全绿 |
| gatus → 「数据到了吗」 | `observability-pipeline` 组：查 VM `k8s_deployment_available`、查 VL 容器日志与 Event、查 AM `Watchdog` | 同上；任一探针红 = 对应链路断，先于任何业务告警 |
| gatus → 公网入口 | `public-edge` / `node1-public` 组（沿用 node3 清单） | 同上 |
| gatus → ntfy | `gatus/config.yaml` `alerting.ntfy`（凭据来自 `$STATE_DIR/creds/ntfy.env`） | 故意把一个端点的 URL 改错重跑 install.sh，2 次失败后手机收到 |
| CronJob → healthchecks | `healthchecks/examples/cnpg-backup-ping-cronjob.yaml`（`/start` → 成功 ping / `/fail`） | 面板里 check 变绿；把 CronJob `suspend: true` 一天后变红 |
| healthchecks → ntfy | 面板 Integrations → ntfy（同一 token） | 面板 "Send test notification" |
| Bugsink → 桥 | 项目 Alerts → Webhook，URL 见 `/root/.k8s-installer-credentials` | 触发一条测试 issue，手机收到 `bug` 标签的推送 |
| 应用 → Bugsink | Sentry SDK，DSN 来自面板 | issue 出现在项目页 |

### 3.4 门面

Grafana 数据源由 `grafana/install.sh` 按集群实际后端预置，uid 固定：`ds-prometheus`（VM，默认）、
`ds-vlogs`（VictoriaLogs，插件 `victoriametrics-logs-datasource` 由 chart 启动时下载）、`ds-vtraces`
（jaeger 类型指向 VT `/select/jaeger`）、`ds-alertmanager`。uid 固定的意义：仪表盘 JSON 里的数据源引用
跨环境不用改——Pigsty 那 67 个仪表盘用的就是这套 uid（`ds-prometheus/ds-vlogs/ds-vtraces`）。

## 4. 与 ecommerce 的接口

| ecommerce 侧 | 值 |
|---|---|
| OTLP 端点（Go OTel SDK） | `http://otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4318`（HTTP）/ `:4317`（gRPC） |
| 前端 Web Vitals / 埋点上报 | 经 newt 暴露的公网 collector 入口（Bearer 鉴权，见 node3 时代 `etc/otelcol/config.yaml` 的 `bearertokenauth`，待迁入 opentelemetry 组件） |
| 错误追踪 DSN | Bugsink 项目页生成，形如 `https://<key>@bugsink.${CLUSTER_DOMAIN}/<id>` |
| 周期任务（goose 迁移 Job、ces-audit CronJob、备份） | 各建一个 healthchecks check，Job 末尾 `curl <ping>`；模板见 healthchecks 组件 examples |
| 业务告警规则 | 放 `components/vmalert/rules/ecommerce-*.yml`，与基础设施规则同一套评审规矩 |
| 合成探测 | 新域名/新服务加进 `components/gatus/endpoints.yaml` 的 `public-edge` 或 `cluster-origin` |
| 指标标签 | 禁止用户/订单/SKU 等高基数标签（`STACK.md §2.7`）；同样适用于 VL 的 `_stream_fields` |

## 5. 故障排查顺序

1. 手机没收到告警 → 先看 gatus 的 `alert-pipeline-watchdog` 与 `alert-bridge` 探针；再看
   `kubectl -n observability logs deploy/alert-bridge`：有 `skipped: ntfy not configured` 是凭据没配，
   有 `error` 是 ntfy 拒收。
2. 告警页面一片「无数据」→ 采集断了：对应的 `*MetricsMissing` 规则应当在红；不红说明 vmalert 自己也停了，
   查 `kubectl -n observability logs deploy/vmalert`。
3. Grafana 查不到日志/链路 → 先确认 collector pipeline 里有那条 exporter
   （`kubectl -n opentelemetry get cm otel-opentelemetry-collector -o yaml | grep -A3 exporters`），
   没有就是装 collector 时后端还不存在，重跑 `components/opentelemetry/install.sh`。
4. VL/VT 写入失败 → 多半是 PVC 满：`VT_DISK_CAP` / VL 的 `-retention.maxDiskSpaceUsageBytes` 是兜底，
   `OTelCollectorExportFailures` 规则会先红。
5. 一切都绿但你不信 → `sudo bash bootstrap/start.sh --verify`，OTel 冒烟会真打一条 metric/log/span 再查回。

## 6. 已知缺口

- 集群内 Pod 解析 `*.${CLUSTER_DOMAIN}`：Bugsink 的 `ALLOWED_HOSTS` 只认 `BASE_URL` 域名，SDK 从 Pod 内
  直连 Service 会 400。要么 CoreDNS 加一条 rewrite 把 `*.dev.test` 指到网关地址，要么 SDK 用公网域名。
  机房环境关闭 L2 通告后网关没有地址，这条先挂着（见 `HOSTING-READINESS-2026-09-03.md` §6.2）。
- 公网 OTLP 入口的 Bearer 鉴权（node3 时代 otelcol 的 `bearertokenauth`）尚未迁入 opentelemetry 组件。
- healthchecks 的 Prometheus 指标需要项目 API key，暂未接入 VM；先靠 gatus 探它的 `/api/v3/status/`。
- Pigsty 的 29 个 PGSQL 仪表盘依赖 pg_exporter 指标名，CNPG 自带指标不兼容；可选方案见
  `PIGSTY-HARVEST-2026-09-03.md` §5.5（跑一个 pg_exporter Deployment 指向 pg-main）。
