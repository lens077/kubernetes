# victoria-traces —— 链路后端（VictoriaTraces 单机版）

## 1. 定位

OTel Collector 的 traces pipeline 直写这里（OTLP/HTTP，路径 `/insert/opentelemetry/v1/traces`），
Grafana 用内置 **jaeger 数据源**读它的 Jaeger 兼容查询 API（`/select/jaeger`）。
与 victoriametrics / victoria-logs 同一家族：同样的单二进制、同样的 `-retentionPeriod` /
按磁盘用量保留、同样的 vmui。2026-09-03 从 node3 Pigsty 收割回集群（那边跑的是
`-retentionPeriod=15d -retention.maxDiskSpaceUsageBytes=50GiB`），替代 jaeger 成为默认链路后端。

## 2. 上游最佳实践

来源：[VictoriaTraces 文档](https://docs.victoriametrics.com/victoriatraces/)、
helm chart `victoria-traces-single` 0.1.11（app v0.11.0，2026-08-17）

- 单机版一个 StatefulSet + PVC；保留期用 `-retentionPeriod`，**并配** `-retention.maxDiskSpaceUsageBytes`
  兜底——PVC 撑满会直接崩。
- 写入走 OTLP/HTTP（`/insert/opentelemetry/v1/traces`），也接受 Jaeger/Zipkin 格式。
- 查询：Jaeger HTTP API 在 `/select/jaeger`，Grafana 直接用 jaeger 类型数据源；vmui 在 `/select/vmui`。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 保留 1 个月 | `VT_RETENTION=7d` | 与 victoria-logs 对齐；PVC 只有 `VT_STORAGE_SIZE=5Gi` |
| 不设磁盘上限 | `VT_DISK_CAP=4GiB`（PVC 的 80%） | 单盘 LVM 卷撑满就是停机；上限到了删旧数据比崩强 |
| chart 生成的长名字 | `fullnameOverride: victoria-traces` | Service 名进 OTel exporter、Grafana 数据源、gatus 探针三处，短名少抄错 |
| 不限资源 | requests 100m/256Mi，limits 只限内存 1Gi | 与 VM/VL 同款：查询是突发负载，只限内存防 OOM 拖垮节点 |
| 与 jaeger 并存 | **OTel 只写 VT**（jaeger 退为次选） | `components/opentelemetry/install.sh` 的优先级：victoria-traces > jaeger；双写没有意义 |

## 4. 暴露方式

- 集群内：`http://victoria-traces.observability.svc.cluster.local:10428`
- 宿主网：`https://traces.${CLUSTER_DOMAIN}`（共享网关 HTTPRoute），vmui 在 `/select/vmui`。

## 5. 验证

```bash
kubectl -n observability rollout status statefulset/victoria-traces
kubectl -n observability exec statefulset/victoria-traces -- wget -qO- http://127.0.0.1:10428/health   # OK
# 端到端: bootstrap 的 90 阶段 OTel 冒烟(打一条 span → /select/jaeger/api/services 查回)
sudo bash bootstrap/start.sh --verify
# Grafana → Explore → 数据源 VictoriaTraces → Search 能列出 service
```

## 6. 踩坑

- **`/insert` 前缀不能省**：collector 的 `otlphttp` exporter 用 `endpoint` 会被自动补成 `/v1/traces` 而 404，
  必须用 `traces_endpoint` 给全路径（node3 时代实测：不带 `/insert` 返回 400）。
- 保留期改小不会立刻释放空间，按分区（天）淘汰；改 `VT_DISK_CAP` 才是即时兜底。
