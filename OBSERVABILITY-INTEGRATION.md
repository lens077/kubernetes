# 观测与告警链路接线手册

三类信号（指标/日志/链路）怎么进后端、告警怎么从规则走到手机、合成监控与死人开关怎么兜底、
错误追踪怎么接进来——以及**每一段怎么证明它通了**。组件本身的取舍写在各自的
`components/<组件>/README.md`，本文只讲它们之间的线。

背景：2026-09-03 之前这套链路的存储与告警侧在 node3 的 Pigsty 上（Victoria 全家桶 + vmalert +
Alertmanager + 自写告警桥 + gatus/healthchecks/bugsink）。node3 重装后这些能力只存在于集群内，
配置参考 `backup/pigsty-node3-20260921/observability/` 中的 Pigsty 规则与观测配置备份；当前组件部署以 `components/` 和 `bootstrap/config.hosting.env` 为准。

## 1. 全景

```text
 ┌──────────── 产生 ─────────────┐   ┌──────── 采集/中继 ────────┐   ┌──────── 存储 ────────┐   ┌──── 门面 ────┐
 Go 服务 / 前端 (OTel SDK) ──OTLP──▶ otel-opentelemetry-collector ─▶ VictoriaMetrics :8428  ─┐
 Cilium/Hubble/Tetragon 指标 ──scrape─▶  (Deployment, opentelemetry ns)  ─▶ VictoriaLogs   :9428  ─┼─▶ Grafana
 CNPG / vmalert / AM / gatus ──scrape─▶  ├ k8s_cluster / k8sobjects      ─▶ VictoriaTraces :10428 ─┘   (数据源: 指标走 ${datasource}
 K8s 对象状态与 Event ────────────────▶  └ prometheus receiver                                          变量按名字选 VictoriaMetrics;
 节点主机指标 ── otel-node DaemonSet ───────────────────────────────▶ VictoriaMetrics                   固定 uid: ds-vlogs/ds-vtraces/
 容器 stdout/stderr ── vector DaemonSet(VRL 脱敏) ───────────────────▶ VictoriaLogs                     ds-alertmanager/ds-pyroscope)

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
   数据是否真的落库另看 §3.3 的 VL/VT **新鲜度探针**（不是只看 HTTP 200）。
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
| VL/VT/Dragonfly/MinIO/ES → VM | `opentelemetry/values.yaml` 的 `prometheus/victoria`、`prometheus/middleware` receiver；MinIO 需 Deployment 上的 `MINIO_PROMETHEUS_AUTH_TYPE=public`，ES 由 `components/elasticsearch-exporter` 提供 | vmui 查 `vl_bytes_ingested_total`、`vt_bytes_ingested_total`、`dragonfly_connected_clients`、`minio_cluster_capacity_raw_total_bytes`、`elasticsearch_cluster_health_status` |

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
| gatus → 「数据到了吗」 | `observability-pipeline` 组：查 VM `k8s_deployment_available`、查 AM `Watchdog`；VL/VT 已在 2026-11-25 换成**新鲜度探针**——VL 直连 `/select/logsql/hits?query=*&step=1m&start=5m` 要求最近 5 分钟有 hits，VT 查 VM 里独立抓取的 `vt_bytes_ingested_total` 在 10 分钟内增长（与 OTLP 写路径无关，停住才是真故障） | 同上；任一探针红 = 对应链路断，先于任何业务告警。端点 `/health` 200 不再当作「数据到了」 |
| gatus → 公网入口 | `public-edge` / `node1-public` 组（`node1-public` 是历史组名，目标现由 node3 边缘承载） | 同上 |
| gatus → ntfy | `gatus/config.yaml` `alerting.ntfy`（凭据来自 `$STATE_DIR/creds/ntfy.env`） | 故意把一个端点的 URL 改错重跑 install.sh，2 次失败后手机收到 |
| CronJob → healthchecks | `healthchecks/examples/cnpg-backup-ping-cronjob.yaml`（`/start` → 成功 ping / `/fail`） | 面板里 check 变绿；把 CronJob `suspend: true` 一天后变红 |
| healthchecks → ntfy | 面板 Integrations → ntfy（同一 token） | 面板 "Send test notification" |
| Bugsink → 桥 | 项目 Alerts → Webhook，URL 见 `/root/.k8s-installer-credentials` | 触发一条测试 issue，手机收到 `bug` 标签的推送 |
| 应用 → Bugsink | Sentry SDK，DSN 来自面板 | issue 出现在项目页 |

### 3.4 门面

`grafana/install.sh` 预置的数据源里**没有 `ds-prometheus`**：VM 数据源（name `VictoriaMetrics`，prometheus 类型，
default）在 `install.sh` 里没设 uid，面板因此统一用 `${datasource}` 变量（按名字 `/VictoriaMetrics/` 选），
不要把面板写死到不存在的 uid。固定 uid 的只有：`ds-vlogs`（VictoriaLogs，插件 `victoriametrics-logs-datasource`
由 chart 启动时下载）、`ds-vtraces`（jaeger 类型指向 VT `/select/jaeger`）、`ds-alertmanager`、
`ds-alert-evidence`（Infinity，在 `triage-values.yaml`）、`ds-pyroscope`（grafana-pyroscope-datasource，
Service 由 `components/profiling` 提供）。

**trace → log 已配置**：`ds-vtraces` 的 `jsonData` 同时写 `tracesToLogs`（旧版）与 `tracesToLogsV2`
（Grafana 13 provisioning 现行字段），目标是 `ds-vlogs`。采样验证过 VictoriaLogs 的 trace id 字段是
`trace_id`（不是 Loki 默认的 `traceID`），OTel 字段保留点号名 `service.name`，因此用 `customQuery`
写 `trace_id:"${__trace.traceId}"` 并把 `service.name` 显式映射为 `service.name`；时间窗前后各放宽 2 秒。
反向的 log → trace 由 `ds-vlogs` 的 `derivedFields` 提供。两边都要求日志/span 真的带这两个字段，否则
「Logs for this span」不出现或查不到——数据前提不成立时不是数据源配错。

**面板清单**（`build-dashboards.py` 生成，ConfigMap + sidecar 发布）：

| UID | 用途 |
|---|---|
| `ops-portal` | 运维控制台：跳转卡片 + 共享 `host:*` 资源 |
| `ntfy-alerting-overview` / `alert-instance-detail` | 问题工作台与实例详情（Alerting 文件夹） |
| `infra-overview` / `infra-cnpg` / `infra-kubernetes` / `infra-cdc` / `infra-observability` | 既有基础设施证据 |
| `control-plane-overview` | 控制面进程证据：四个抓取存活、etcd Leader/Raft、apiserver 请求比例与延迟、scheduler/controller-manager 队列 |
| `middleware-overview` | Dragonfly / MinIO / Elasticsearch 三组 row：容量、健康、命中率 |
| `ecommerce-apm` | ecommerce RED（HTTP server 埋点）、Connect RPC RED（config-center）、Go runtime、copystack/Pyroscope 指引 |

三个新面板都进了 `NAV`，因此 ops-portal 与面板顶部互链可达。实测埋点边界：ecommerce 服务目前只有
`http_server_*` 等 OTel 语义指标，`rpc_server_call_duration_seconds_*` / `rpc_response_status_code`
只在 config-center 的 config-service 上出现；`go_gc_pauses_seconds_bucket` / `go_memstats_*` 只来自控制面组件，
面板保留这些查询但显示「指标缺失」，不把零当健康。

## 4. 与 ecommerce 的接口

| ecommerce 侧 | 值 |
|---|---|
| OTLP 端点（Go OTel SDK） | `http://otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4318`（HTTP）/ `:4317`（gRPC） |
| 前端 Web Vitals / 埋点上报 | 经 newt 暴露的公网 collector 入口（Bearer 鉴权，见 node3 时代 `etc/otelcol/config.yaml` 的 `bearertokenauth`，待迁入 opentelemetry 组件） |
| 错误追踪 DSN | Bugsink 项目页生成，形如 `https://<key>@bugsink.${CLUSTER_DOMAIN}/<id>` |
| 周期任务（goose 迁移 Job、ces-audit CronJob、备份） | 各建一个 healthchecks check，Job 末尾 `curl <ping>`；模板见 healthchecks 组件 examples |
| 业务告警规则 | ecommerce 业务服务放 `components/vmalert/rules/ecommerce-app.yml`；config-service（control-tower）的 RPC 告警真相源在 control-tower 仓 `docs/operations/alerts/control-tower-app.yml`，同内容副本放本仓 `rules/control-tower-app.yml`（两边各一份，改一边必须改另一边）；palcommerce 放 `palcommerce.yml`。与基础设施规则同一套评审规矩 |
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
  直连 Service 会 400。机房版 Gateway 已固定 `10.10.31.240`，可在 CoreDNS 加 rewrite/hosts 把
  `*.dev.test` 指到该 VIP，或让 SDK 用公网域名；VIP 不随重建漂移。
- 公网 OTLP 入口的 Bearer 鉴权（node3 时代 otelcol 的 `bearertokenauth`）尚未迁入 opentelemetry 组件。
- healthchecks 的 Prometheus 指标需要项目 API key，暂未接入 VM；先靠 gatus 探它的 `/api/v3/status/`。
- Pigsty 的 29 个 PGSQL 仪表盘依赖 pg_exporter 指标名，CNPG 自带指标不兼容；可选方案见
  `backup/pigsty-node3-20260921/observability/` 中的 PG exporter 配置（如需保留 PGSQL 仪表盘指标，再部署一个指向 CNPG pg-main 的 pg_exporter）。
