# tempo —— Grafana Tempo 链路后端（单体，本地盘）

## 1. 定位

**评估期组件，默认不装**（`ADDON_TEMPO=false`）。集群现有的 trace 后端是
[jaeger](../jaeger/)（v2 all-in-one + badger 本地卷），Tempo 是它的候选替代，
装上是为了在真实数据下对比后再决定去留：

| | Jaeger（现役） | Tempo（评估） |
|---|---|---|
| 查询语言 | 标签/服务/操作过滤 | **TraceQL**（结构化查询，可按 span 属性/耗时/嵌套关系筛） |
| 存储 | badger 单文件 KV | 块存储 + compactor，天然可换对象存储（MinIO/S3）横向扩 |
| 与 Grafana | 独立 UI + 数据源 | 原生数据源，与 Loki/VM 的关联跳转是同一套体验 |
| 内存 | ~400Mi | ~600Mi（本配置 limits 1Gi） |

两者**同时接在 OTel Collector 后面互不干扰**（trace 复制两份），
Grafana 里两个数据源并列，对比完再决定是否下掉一个。

## 2. 上游最佳实践

来源：[Tempo Helm 部署文档](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/kubernetes/helm-chart/)、
[grafana-community/helm-charts](https://github.com/grafana-community/helm-charts/tree/main/charts/tempo)（2026-08 复核）

- **单体版 chart 已迁到 `grafana-community`**：旧 `grafana/tempo` chart 在 Artifact Hub
  已标 deprecated（app 停在 2.9.0），**别再 add 旧仓库**。
- 单体 + local backend 的形态**只能 1 副本**，要横向扩必须换对象存储 + distributed chart。
- `persistence.enabled` 默认 **false**——不开等于重启丢全部 trace，是最常踩的一条。
- OTLP receiver（4317/4318）出厂即开；但 Jaeger 的四个 receiver 也默认全开，按需关掉。
- `reportingEnabled` 默认 true（向 stats.grafana.org 上报用量）。
- **3.0 是大重构**（live-store 新写路径、分布式模式 Kafka 化），chart 尚未跟进，先不碰。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| `persistence.enabled: false` | **开启 + `${SC_NAME}`，`${TEMPO_STORAGE_SIZE}`** | 不开的话 Pod 重启 trace 全丢，评估就无从谈起。OpenEBS LVM 本地卷有节点绑定特性。 |
| `retention: 24h` | `${TEMPO_RETENTION}`（默认 168h） | 对齐 jaeger badger 的 `ttl.spans: 168h`，两个后端保留期一致才好对比。 |
| `memBallastSizeMbs: 1024` | **0** | Go ballast 是老 GC 时代的手法，新 runtime 有自适应；内存紧的节点白占 1G。 |
| `reportingEnabled: true` | false | 大陆出不去，只会在日志里刷失败。 |
| Jaeger receivers 全开（6831/6832/14250/14268） | **只留 OTLP** | 采集统一经 OTel Collector（本仓约定），多开的端口是无谓暴露面。 |
| 无 resources | requests 100m/256Mi，limits.memory 1Gi | 只限内存不限 CPU（仓内惯例）：查询与 compaction 是突发负载。 |
| `metricsGenerator` | 关闭 | 它默认把数据写 `/tmp/tempo`（临时盘），要开得先改路径并配 remote_write 到 VM。 |
| chart 自动跟最新 | 钉 `TEMPO_CHART_VERSION`（2.2.4 / app 2.10.8） | 3.x 是 breaking 重构，chart 也未跟进。 |

## 4. 暴露方式

- 集群内写入（OTLP）：`tempo.tempo.svc.cluster.local:4317`(gRPC) / `:4318`(HTTP)
- 集群内查询：`http://tempo.tempo.svc.cluster.local:3200`
- 对外查询 API：`https://tempo.dev.test`（共享网关，证书由 global-ca-issuer 签，80→443 301）
- Grafana：数据源由 `components/grafana/install.sh` **自动探测预置**（`comp_installed tempo tempo`），
  装完 tempo 重跑一次 grafana 的 install.sh 即可

Tempo 没有自己的 UI——查看链路走 Grafana 的 Explore。

## 5. 验证

```bash
kubectl -n tempo get pvc storage-tempo-0     # Bound
kubectl -n tempo get httproute               # tempo / tempo-redirect
```

真验证（打一条 OTLP trace，再按 traceId 从网关查回来）：

```bash
TID=5b8efff798038103d269b633813fc60c; NOW=$(date +%s)
kubectl -n tempo run otlp-probe --image=curlimages/curl --restart=Never --rm -i --quiet --command -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST http://tempo.tempo.svc:4318/v1/traces \
    -H 'Content-Type: application/json' -d '{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"probe-svc\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TID\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"probe-span\",\"kind\":1,\"startTimeUnixNano\":\"${NOW}000000000\",\"endTimeUnixNano\":\"${NOW}500000000\"}]}]}]}'"
# → 200

sleep 10   # 等 ingester 刷块
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk "https://tempo.dev.test/api/traces/$TID" --resolve tempo.dev.test:443:$GW | head -c 200
curl -sk "https://tempo.dev.test/api/search?tags=service.name%3Dprobe-svc" --resolve tempo.dev.test:443:$GW
```

> **实测结论（2026-08-18）**：OTLP HTTP 写入返回 200；10s 后经共享网关按 traceId
> 精确查回该 span，`/api/search` 也按 `service.name` 检索到；`http://` 返回
> 301 → `https://tempo.dev.test:443/`。Grafana 侧已自动出现 Tempo 数据源
> （`/etc/grafana/provisioning/datasources` 内确认）。

## 6. 踩坑

- **旧 chart 仓库**：`grafana/tempo` 已 deprecated 但仍能装，装到的是 app 2.9.0 老版本。
  必须用 `grafana-community/tempo`。
- **刚写完立刻查不到**：trace 先在 ingester 内存里，要等块刷出（本配置约 10s 内）。
  与 VictoriaMetrics 的 `-search.latencyOffset` 是同类现象，不是丢数据。
- **chart 2.0 起默认端口 3100 → 3200**：抄老文档/老 dashboard 的 URL 会连不上
  （3100 现在是 Loki 的端口，更容易混）。
- **`persistence.enabled` 忘了开**：Pod 一重启 trace 全没，且没有任何报错——
  最像「Tempo 不好用」的假象。
- **metricsGenerator 开启后写 `/tmp`**：默认 `storage.path: /tmp/tempo` 在临时盘上，
  Pod 重启即丢，且会与 span metrics 的 remote_write 配置一起漏配。
- **单体只能 1 副本**：`replicas: 2` 会两个实例各写各的本地盘，查询只命中一半数据。
