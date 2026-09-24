# K8s 指标链路 ↔ node3/Pigsty VictoriaMetrics 兼容性审计

> **历史审计（2026-09 上旬，node3 时代），场景已不存在。** 2026-09-22 node3 重装为 k3，观测后端全部迁回集群内
> VictoriaMetrics，不再有「Pigsty promscrape 世界」。保留它是因为那条教训仍成立：**OTLP 进来的指标没有 `job` 标签，
> 按 `job`/`instance` 写的面板与规则看不到它们**——集群内 VM 里 OTel 与 prometheus receiver 两套标签体系依旧并存，
> 写规则前先查 `/api/v1/label/__name__/values`。下文的节点名、IP、series 数都是当时的实测值，不代表现状。

审计日期：本轮。方法：只读检查仓库配置 + node4 上渲染后的 Collector ConfigMap + node3 上 VictoriaMetrics 2.24.0 的实际落库数据。未修改任何服务器或集群资源。

## 1. 结论

**协议层已兼容，语义层没有统一。** 同一个 VictoriaMetrics 实例里并存两套互不相通的标签体系：

| 体系 | 来源 | 身份标签 | 示例 |
|---|---|---|---|
| Pigsty/Prometheus 世界 | node3 本机 `victoria-metrics -promscrape.config=/infra/prometheus.yml` 直接抓取 | `job`, `instance`, `ins`, `ip`, `cls`, `nodename`, `service`, `component`, `environment`, `monitor` | `node_cpu_seconds_total{job="node", ins="pg-meta-1", ip="10.10.21.172", cls="pg-meta"}` |
| OTel/K8s 世界 | 集群内 Collector → OTLP/HTTP → `/opentelemetry/v1/metrics` | `k8s_node_name`, `k8s_namespace_name`, `k8s_pod_name`, `service_name`, `service_instance_id`, `scope_name`, `server_address` | `cilium_drop_count_total{service_name="cilium-agent", k8s_node_name="node4"}`；**没有 `job` 标签** |

实测：VM 中 **15 707 个 series 没有 `job` 标签**（全部来自 OTel 链路），是单一 `job` 里最大的一组；Pigsty 侧 `job="infra"` 11 274、`job="pgsql"` 7 768、`job="node"` 5 201。

因此：
- 任何按 `job`/`instance`/`ins` 写的 Grafana 面板或 vmalert 规则，看不到 K8s 侧数据；
- 任何按 `k8s_node_name`/`service_name` 写的规则，看不到 Pigsty 侧数据；
- 同一台 node3 在两套体系里是两个实体（`nodename="node3", ip="10.10.21.172"` vs `k8s_node_name="node3"`，且 K8s 记录其 InternalIP 为 `10.10.21.163`）；
- 主机资源指标在三台 K8s 节点上**名字都不一样**：node3 只有 `node_cpu_seconds_total{mode}`（node_exporter），node4/node5 只有 `system_cpu_time_seconds_total{state}`（otel-node hostmetrics）。一条查询无法画出三台节点。

## 2. 已确认事实（带证据）

### 2.1 采集协议与远端写入 — 兼容

- Collector `otlp_http/remote_metrics` → `https://metrics.apikv.com/opentelemetry/v1/metrics`，gzip + protobuf，retry 5m，queue 1000（node4 渲染后 ConfigMap；仓库 `install.sh:44-62`）。
- node3 VM 启动参数 `-opentelemetry.usePrometheusNaming=true`（`ps` 实测），匹配仓库 `victoriametrics/values.yaml:5`。
- 近 10 分钟 Collector 无 `error|fail|drop|refused` 日志；VM 内 `otelcol_exporter_sent_metric_points_total` 持续存在。
- **不是** Prometheus `remote_write`。`REMOTE_METRICS_URL` 如果换成 `/api/v1/write` 会直接失败。VM 单节点同时支持两者，但当前只用 OTLP。

### 2.2 命名转换 — 兼容，但有单位后缀陷阱

- `usePrometheusNaming` 按 [OTLP→Prometheus 规范](https://github.com/open-telemetry/opentelemetry-specification/blob/v1.33.0/specification/compatibility/prometheus_and_openmetrics.md#otlp-metric-points-to-prometheus) 转换：点号→下划线、补单位后缀、counter 补 `_total`（[VM 文档](https://docs.victoriametrics.com/victoriametrics/integrations/opentelemetry/#label-sanitization)）。
- 实测 counter 后缀保留：`otelcol_*_total` 40 个，`hubble_flows_processed_total`、`cilium_drop_count_total` 均在。
- 实测 histogram 完整：`cilium_endpoint_regeneration_time_stats_seconds_bucket` 432 个 series，无 `_bucket` 的裸名不存在（符合预期）。
- 实测 `k8s_cluster` receiver 输出 `k8s_container_restarts`、`k8s_pod_phase`、`k8s_node_condition_ready`、`k8s_deployment_available`、`k8s_daemonset_ready_nodes` —— 与 `vmalert/rules/ecommerce-k8s.yml` 使用的名字一致。
- ⚠️ `k8s_node_*` 只有 `k8s_node_condition_ready`；节点 allocatable/capacity 指标未启用（k8s_cluster receiver 默认 `allocatable_types_to_report` 为空）。K8s 侧节点容量必须从 hostmetrics 或 node_exporter 取。
- ⚠️ 单位后缀是 OTel 规范行为，只对 OTLP 入口生效。VM 中 418 个 `*_milliseconds*` series 全部来自 Pigsty 直抓（etcd、grafana、frontend），不是 OTel 转换产物；但如果将来把同一个 exporter 改为经 Collector 抓取，名字可能变化（例如 receiver 的 `trim_metric_suffixes`/单位补全），迁移时必须逐名核对。

### 2.3 `job`/`instance` 丢失 — 不兼容（根因）

OTel Prometheus receiver 把 scrape 目标的 `job`→`service.name`、`instance`→`service.instance.id`，并把 `__scheme__`/`__address__` 拆成 `url_scheme`/`server_address`/`server_port` 作为 **resource attributes**（[receiver README: Resource Attribute Mapping](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/prometheusreceiver/README.md#resource-attribute-mapping)）。VM 默认 **promote 所有 resource attributes 为 label**（[VM 文档 Resource Attributes](https://docs.victoriametrics.com/victoriametrics/integrations/opentelemetry/#resource-attributes)），但**不会反向恢复 `job`/`instance`**。

实测 `count by (service_name)` 得到 `cilium-agent`(5258)、`cilium-operator`、`hubble`、`cnpg`、`gatus`、`kafka-exporter`、`vector-security`、`otelcol-contrib`，以及 13 个业务服务（`order-service`、`cart-service`…）；这些在 `job` 维度全部为空。

副作用：
- `up`/`scrape_*` 元指标两套并存：Pigsty 侧 `up{job="node"}`，OTel 侧 `up{service_name="cilium-agent"}`（job 为空 14 个）。"`up==0` by job" 类规则对 K8s 目标失效。
- `service_name` 与 Pigsty 的 `service` 标签名不同、含义也不同（Pigsty `service` 是 PG 服务角色如 `pg-meta-primary`）。

### 2.4 节点身份 — 不兼容

| 节点 | Pigsty 侧 | K8s/OTel 侧 | hostmetrics |
|---|---|---|---|
| node3 | `nodename="node3"`, `ins="pg-meta-1"`, `ip="10.10.21.172"`, `cls="pg-meta"` | `k8s_node_name="node3"`, InternalIP `10.10.21.163` | **无**（otel-node DS 未调度到 node3） |
| node4 | 无 | `k8s_node_name="node4"`, `10.10.21.161` | `k8s_node_name="node4"` |
| node5 | 无 | `k8s_node_name="node5"`, `10.10.21.162` | `k8s_node_name="node5"` |

node3 网卡 `ens160` 同时持有 `10.10.21.163/24` 和 `10.10.21.172/24`；Pigsty 注册用 `.172`，kubelet 注册用 `.163`。两个 IP、三个名字、零共同标签。

原因：node3 带 taint `workload`，`vector` 与 `otel-node` DaemonSet 没有对应 toleration，`desiredNumberScheduled=2`。这是设计选择（node3 由 Pigsty node_exporter 覆盖），但结果是 host 指标名不统一。

### 2.5 告警规则已受影响 — 实证

node3 vmalert 当前 firing：`VectorDaemonSetReadyBelowExpected`。规则 `vmalert/rules/ecommerce-observability-readiness.yml:6` 写死 `k8s_daemonset_ready_nodes{vector} < 3`，而 DS 期望值是 2。**这条告警自部署以来持续误报**，同时 `AlertFiringTooLong` 也因它而 firing。这是"硬编码期望值代替对象自身声明"的直接代价。

### 2.6 `delta_to_cumulative` — 兼容（风险解除）

处理器只转换 delta 样本，cumulative 原样通过（[processor README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/deltatocumulativeprocessor/README.md)："All delta samples are converted to cumulative"）。Prometheus receiver 产出的 counter 本就是 cumulative，不会被二次累积。剩余风险仅为状态性：Collector 单副本重启会丢失 delta 累积状态，`max_stale: 5m` 后序列重建；只影响以 delta 上报的 OTLP 应用指标。

### 2.7 Prometheus receiver 多副本重复抓取 — 当前安全

receiver README 明确：多副本同配置会重复抓取。当前 Collector 为单副本 Deployment，无此问题；**扩副本前必须先引入 Target Allocator 或分片**。

### 2.8 Grafana — 当前无冲突，因为几乎没有 K8s 面板

node3 Grafana 数据源：VM `:8428`、VictoriaLogs `:9428`、VictoriaTraces `:10428/select/jaeger`、PG `:5432`。`/etc/dashboards/` 仅 1 个 provisioned dashboard，引用 `k8s_*` 或 `ins` 的均为 0。Pigsty 自带面板全部基于 `ins/cls/ip/job`。**K8s 数据目前只能靠 Explore 手写查询**，尚未进入任何面板。

### 2.9 日志/链路字段

- 容器 stdout → Vector → VictoriaLogs；应用 OTLP logs + K8s Event → Collector → VictoriaLogs；traces → VictoriaTraces。三条链各自带 `service.name`/`k8s.*` 资源属性；VictoriaLogs 与 VictoriaTraces 不做 `usePrometheusNaming`，字段保持**点号**（`service.name`），而 VM 中是**下划线**（`service_name`）。Grafana 从 metrics 跳 logs 时不能直接复用变量名。
- Pigsty 侧 PG/主机日志经 Pigsty 自己的采集（`job/ins/cls`）进入 VictoriaLogs，与 K8s 侧 `k8s.namespace.name` 同样没有交集字段。

## 3. 兼容性矩阵

| 项 | 状态 | 说明 |
|---|---|---|
| OTLP/HTTP 写入 VM | ✅ 兼容 | 生产链路正常，无丢弃 |
| 指标名转换 | ✅ 兼容 | 点号→下划线、`_total`、histogram 后缀均正确 |
| counter/histogram 类型 | ✅ 兼容 | 实测后缀完整；`delta_to_cumulative` 不影响 cumulative |
| `job`/`instance` | ❌ 不兼容 | OTel 侧全部丢失，改为 `service_name`/`service_instance_id` |
| 节点身份 | ❌ 不兼容 | 三种标识、两个 IP，无共同键 |
| 主机指标名 | ❌ 不兼容 | node3 用 `node_*`，node4/5 用 `system_*` |
| `up` 元指标 | ⚠️ 部分 | 两套并存，无法统一 group by |
| K8s 节点容量指标 | ⚠️ 缺失 | k8s_cluster 未启用 allocatable |
| vmalert 规则 | ⚠️ 已有误报 | Vector DS 硬编码 3，实际 2 |
| Grafana 面板 | ⚠️ 空白 | K8s 数据无面板；Pigsty 面板看不到 K8s |
| 日志/链路字段 | ⚠️ 口径不一 | logs/traces 点号，metrics 下划线 |
| Prometheus receiver 多副本 | ⚠️ 前置条件 | 扩副本前需 Target Allocator |

## 4. 统一方案

原则：**不改动 Pigsty 世界**（它是成熟产品、面板/规则成套），**在 K8s 侧写入前补齐 Pigsty 兼容标签**，并对主机指标用 recording rules 提供统一视图。

### 4.1 写入前补标签（Collector，唯一改动点）

在 metrics pipeline 的 `delta_to_cumulative` 之后、`batch` 之前加 `transform/pigsty_compat`：

```yaml
processors:
  transform/pigsty_compat:
    metric_statements:
      - context: resource
        statements:
          # 1. 恢复 Prometheus 语义：job/instance
          - set(attributes["job"], attributes["service.name"]) where attributes["job"] == nil and attributes["service.name"] != nil
          - set(attributes["instance"], attributes["service.instance.id"]) where attributes["instance"] == nil and attributes["service.instance.id"] != nil
          # 2. 统一节点身份：Pigsty 用 nodename
          - set(attributes["nodename"], attributes["k8s.node.name"]) where attributes["k8s.node.name"] != nil
          # 3. 统一环境/集群
          - set(attributes["environment"], "prod")
          - set(attributes["cls"], "k8s-main") where attributes["cls"] == nil
          - set(attributes["runtime"], "kubernetes")
```

`otel-node`（hostmetrics）同样加 `nodename` 与 `runtime`。这样 K8s 侧数据落库后同时拥有 `job`/`instance`/`nodename`/`environment`，与 Pigsty 面板的 `$job`/`$ins` 变量可交集。

不要覆盖已有的 `service.name`/`k8s.*`，保留 OTel 语义供 logs/traces 关联。

### 4.2 node3 的双 IP

在 Pigsty 侧不动；在 K8s 侧用 4.1 的 `nodename` 对齐即可。**不要**尝试把 `ip` 也对齐——Pigsty 的 `ip` 是其 inventory 主键，K8s 的 InternalIP 是 kubelet 注册值，两者语义不同。Grafana 中以 `nodename` 为主机维度。

### 4.3 主机指标统一视图（vmalert recording rules，node3 `/infra/rules/`）

```yaml
groups:
  - name: host-unified
    interval: 30s
    rules:
      - record: host:cpu_busy:ratio
        expr: |
          1 - avg by (nodename) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
          or
          1 - avg by (nodename) (rate(system_cpu_time_seconds_total{state="idle"}[5m]))
      - record: host:memory_used:ratio
        expr: |
          1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
          or
          sum by (nodename) (system_memory_usage_bytes{state="used"}) / sum by (nodename) (system_memory_usage_bytes)
      - record: host:filesystem_used:ratio
        expr: |
          max by (nodename) (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})
          or
          max by (nodename) (system_filesystem_usage_bytes{state="used"} / on (nodename, device) group_left sum by (nodename, device) (system_filesystem_usage_bytes))
```

依赖 4.1 先落地（否则 `system_*` 没有 `nodename`）。总览面板只查 `host:*` 规则，不再直接查两套原始名。

或者更彻底：给 `otel-node` 与 `vector` 加 `workload` toleration，让 node3 也跑 hostmetrics，然后**在 Pigsty 侧下线 node3 的 node_exporter target** —— 但这会破坏 Pigsty 的 NODE 面板对 node3 的覆盖，不推荐。

### 4.4 修正已知误报

`vmalert/rules/ecommerce-observability-readiness.yml`：

```yaml
# 改前
expr: '(max(k8s_daemonset_ready_nodes{k8s_namespace_name="logging",k8s_daemonset_name="vector"}) or vector(0)) < 3'
# 改后：以 DS 自身声明为准
expr: 'k8s_daemonset_ready_nodes{k8s_namespace_name="logging",k8s_daemonset_name="vector"} < k8s_daemonset_desired_scheduled_nodes{k8s_namespace_name="logging",k8s_daemonset_name="vector"}'
```

同理检查 `ecommerce-k8s.yml` 其它硬编码阈值。

### 4.5 `up` 统一

4.1 恢复 `job` 后，OTel 侧 `up` 自动带 `job`；规则改为 `up == 0` by `(job, instance, nodename)` 两侧通用。

### 4.6 日志/链路跳转口径

Grafana 数据链接中显式映射：metrics `service_name` → logs/traces `service.name`；`k8s_namespace_name` → `k8s.namespace.name`。写在 dashboard 变量层，不要期望后端自动对齐。

### 4.7 补 K8s 节点容量

`opentelemetry/values.yaml` 的 `k8s_cluster` receiver 增加：

```yaml
allocatable_types_to_report: [cpu, memory, ephemeral-storage]
```

产出 `k8s_node_allocatable_cpu`/`k8s_node_allocatable_memory_bytes`，供 requests 占比面板使用。

## 5. 落地顺序

1. `values.yaml` 加 `transform/pigsty_compat`；`install.sh` 把它插进 metrics pipeline；`otel-node` 同步。重新部署，验证 `count({job="cilium-agent"})` 与 `count({nodename="node4"})` 非空。
2. 修 4.4 误报规则，确认 `VectorDaemonSetReadyBelowExpected` 消失。
3. node3 `/infra/rules/` 加 `host-unified` recording rules（经 pigsty-deploy 管理），验证 `host:cpu_busy:ratio` 返回 3 个 `nodename`。
4. 开 `allocatable_types_to_report`。
5. 再开始做 Grafana 总览：主机维度只用 `nodename`，服务维度用 `job`，K8s 对象维度用 `k8s_*`。
6. Collector 扩副本前先接 Target Allocator。

## 6. 验证命令

```bash
# 渲染后的 pipeline（node4）
kubectl -n opentelemetry get cm otel-opentelemetry-collector -o jsonpath='{.data.relay}' | sed -n '/^service:/,$p'

# 落库标签体系（node3）
curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode 'query=count by (job) ({__name__=~".+"})'
curl -sG http://127.0.0.1:8428/api/v1/query --data-urlencode 'query=count by (nodename) ({__name__=~"node_cpu_seconds_total|system_cpu_time_seconds_total"})'
curl -sG http://127.0.0.1:8428/api/v1/labels --data-urlencode 'match[]=cilium_drop_count_total'

# 误报确认
curl -s http://127.0.0.1:8880/api/v1/alerts | python3 -c 'import json,sys;[print(a["state"],a["name"]) for a in json.load(sys.stdin)["data"]["alerts"]]'
```

## 7. 证据来源

- node4：`kubectl -n opentelemetry get cm otel-opentelemetry-collector`、`get deploy`（image `otel/opentelemetry-collector-contrib:0.158.0`）、`get nodes`（taint `workload` on node3）、`get ds`（vector/otel-node desired=2）。
- node3：`ps`（VM/vmalert 启动参数）、`/api/v1/query`、`/api/v1/labels`、`/api/v1/status/buildinfo`（2.24.0）、`:8880/api/v1/alerts`、`ip -4 addr`、`/infra/prometheus.yml`、`/etc/grafana/provisioning`、`/etc/dashboards`。
- 仓库：`components/opentelemetry/{install.sh,values.yaml,README.md}`、`components/opentelemetry-node/{install.sh,values.yaml}`、`components/victoriametrics/values.yaml`、`components/vmalert/rules/ecommerce-{k8s,observability-readiness}.yml`、`components/alertmanager/values.yaml:48`（inhibit 用 `k8s_node_name`，Pigsty 侧告警无此标签，抑制不会跨体系生效）。
- 文档：[OTel Prometheus receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/prometheusreceiver/README.md)、[deltatocumulative processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/deltatocumulativeprocessor/README.md)、[VictoriaMetrics OpenTelemetry 集成](https://docs.victoriametrics.com/victoriametrics/integrations/opentelemetry/)、[OTLP→Prometheus 兼容规范](https://github.com/open-telemetry/opentelemetry-specification/blob/v1.33.0/specification/compatibility/prometheus_and_openmetrics.md)。
