# OpenTelemetry Node Agent：每节点主机指标

## 1. 定位

DaemonSet，每个节点一份，**只做一件事**：用 `hostmetrics` receiver 采本节点的 CPU、内存、磁盘、网络，打上 `k8s.node.name` 后推到与 [`opentelemetry`](../opentelemetry/) 组件相同的远端入口。

不接收任何 OTLP：应用侧遥测仍然发给 `otel-opentelemetry-collector.opentelemetry.svc:4317/4318`（那份是 Deployment）。本组件的全部监听端口都在 `values.yaml` 里关掉了。

| 采集内容 | 指标前缀 | 消费方 |
|---|---|---|
| 主机 CPU / 内存 / 磁盘 / 网络 | `system_*` | Config Center 控制台「系统」页的主机曲线 |

## 2. 为什么单独一个组件

主机指标必须从**每个节点**采。`opentelemetry` 组件是单副本 Deployment，在它上面开 `hostMetrics` preset 只会得到它所在那一个 Pod 的视角——既不是节点真实值，也只覆盖三分之一的节点。chart 文档本身也写明 `hostMetrics` preset「Best used with mode = daemonset」。

这与 [`opentelemetry/README.md`](../opentelemetry/README.md) 里「小集群用单层 Deployment」的取舍不冲突：那条说的是**应用遥测的 Agent+Gateway 两层**没必要；主机指标是另一类信号，没有 DaemonSet 就采不到。

## 3. 两个容易踩的坑

**① `utilization` 是默认关闭的可选指标。** `hostmetrics` 的 cpu/memory scraper 默认只出累计量（`system.cpu.time`、`system.memory.usage`）。不显式打开 `system.cpu.utilization` 与 `system.memory.utilization`，主机 CPU 与内存两张图永远是空的——而磁盘、网络两张图正常，很容易误判成「采集器坏了一半」。已在 `values.yaml` 里打开。

**② 节点名要自己打。** `hostmetrics` 采出来的资源属性里没有节点名，三个节点的曲线会叠在一起且分不出谁是谁。这里用 `resource/node` 处理器把 chart 提供的 `OTEL_K8S_NODE_NAME` 环境变量写成 `k8s.node.name`，落到指标后端就是 `k8s_node_name` 标签——控制台的主机图正是按它分线的。

## 4. 与指标后端的命名约定

远端 VictoriaMetrics 必须启用 `-opentelemetry.usePrometheusNaming=true`，否则指标名会保持 OTLP 的点号形态（`system.cpu.utilization`），与消费方按 Prometheus 规范写的查询（`system_cpu_utilization_ratio`）对不上，表现为**查询成功但一条序列都没有**。该开关在 node3 的 `/etc/default/vmetrics` 中设置。

## 5. 验收

```bash
kubectl -n opentelemetry get ds otel-node-opentelemetry-collector-agent      # 期望 N/N ready
# 期望三个节点各一条，且数值合理（不是 0，也不是 100 的整数倍）
curl -s "$METRICS_URL/api/v1/query" --data-urlencode \
  'query=avg by (k8s_node_name) (sum by (k8s_node_name, cpu) (system_cpu_utilization_ratio{state!="idle"})) * 100'
```

只看 DaemonSet ready 不够：receiver 起来了但 `utilization` 没开时，Pod 一样是 Running，只有查询才看得出图是空的。
