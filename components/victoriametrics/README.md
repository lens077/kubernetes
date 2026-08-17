# victoriametrics —— 指标后端（单机版）

## 1. 定位

集群的指标存储与查询后端，提供 Prometheus 兼容的查询 API。
[opentelemetry](../opentelemetry/) 的 metrics pipeline 往这里写，
[grafana](../grafana/) 把它当默认数据源。

不装的后果：OTel Collector 的 metrics pipeline 没有 exporter，Grafana 没有指标数据源。

## 2. 上游最佳实践

来源：[VictoriaMetrics Helm 文档](https://docs.victoriametrics.com/helm/victoria-metrics-single/)、
[OpenTelemetry 集成指南](https://docs.victoriametrics.com/guides/getting-started-with-opentelemetry/)

- 单机版（single）在**单节点 + 中小数据量**下是推荐形态；cluster 版是为水平扩展和多租户设计的，
  组件多（vminsert/vmselect/vmstorage）、内存开销大。
- 接 OpenTelemetry 必须开 `opentelemetry.usePrometheusNaming`，否则 OTLP 指标名保留点号分隔，
  PromQL 查不出来。
- 数据保留期用 `-retentionPeriod`（默认 1 个月）；磁盘按 `保留期 × 每秒采样数` 估。
- 查询有 30s 的 `-search.latencyOffset`：**刚写入的数据要等约 30s 才查得到**，这不是故障。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| cluster 版（生产推荐） | **single 版** | 两节点、指标量小，cluster 版三件套要多花 1G+ 内存，换不来任何可用性（存储还是本地 LVM 卷，节点挂了一样没数据）。 |
| Service 默认 ClusterIP | 保持 ClusterIP + HTTPRoute | 集群内组件走 Service，对外只经共享网关（`metrics.app.com`）。不开 LoadBalancer 省一个 LB IP。 |
| 无 resources | `requests 100m/256Mi`，`limits.memory 1Gi` | 只限内存不限 CPU：查询是突发型负载，限 CPU 会让 Grafana 面板卡顿；限内存防止大查询把节点拖垮。 |
| 存储 8Gi | `${VM_STORAGE_SIZE}`（config.env，默认 8Gi） | OpenEBS LVM 本地卷有**节点绑定**特性——扩容要在同一节点上做。 |

## 4. 暴露方式

- 集群内写入（OTLP）：`http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/opentelemetry/v1/metrics`
- 集群内查询：同上主机 `:8428`，`/api/v1/query`
- 对外：`https://metrics.app.com`（共享网关，证书由 global-ca-issuer 签）

## 5. 验证

```bash
kubectl -n victoriametrics get pvc     # Bound
```

真验证（写一条再查回来，绕开"Pod 活着就算好"的假象）：

```bash
VM=vm-single-victoria-metrics-single-server-0
kubectl -n victoriametrics exec $VM -- sh -c \
  'wget -qO- "http://127.0.0.1:8428/api/v1/import/prometheus" --post-data "probe_metric 1"'
sleep 35   # -search.latencyOffset 默认 30s，别急着断定失败
kubectl -n victoriametrics exec $VM -- sh -c \
  'wget -qO- "http://127.0.0.1:8428/api/v1/query?query=probe_metric"'
```

经网关（从局域网其他主机）：

```bash
curl -sk "https://metrics.app.com/api/v1/query?query=up" --resolve metrics.app.com:443:$GW | head -c 200
```

## 6. 踩坑

- **刚写入的指标查不到**：`-search.latencyOffset` 默认 30s。写完立刻查必然为空——
  `90-verify` 的可观测冒烟里给 metrics 留了 100s 轮询窗口就是为这个。
- **OTLP 指标名带点号、PromQL 查不出来**：`opentelemetry.usePrometheusNaming` 没开。
- **PVC Pending**：OpenEBS LVM 卷有节点亲和，只能在有对应 VG 的节点上创建；
  `kubectl describe pvc` 看事件。
