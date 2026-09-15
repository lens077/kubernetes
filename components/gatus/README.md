# gatus —— 合成监控（黑盒探测 + 「数据真的到了吗」探针）

## 1. 定位

从集群内部周期性探测三类目标：公网入口（经 Pangolin/newt 的 `*.apikv.com`）、集群内各后端的健康端点、
以及**观测链路本身**——不看进程活着，而是查 VictoriaMetrics/VictoriaLogs 里最近几分钟有没有新数据、
Alertmanager 里有没有 vmalert 的 `Watchdog`。失败直推 ntfy（不经 Alertmanager：告警链路坏了它还得能报信）。
配置沿用 node3 Pigsty 时代的 `/data/gatus/config.yaml`（2026-09-03 收割），探测目标改为集群内 Service。

## 2. 上游最佳实践

来源：[gatus 文档](https://github.com/TwiN/gatus)，v5.36.0

- 条件三件套：`[STATUS]`、`[CERTIFICATE_EXPIRATION] > 720h`、`[RESPONSE_TIME] < 5000`；JSON 体用 gjson 路径
  （`[BODY].status == success`、`len([BODY].data.result) > 0`）。
- `failure-threshold` / `success-threshold` 各 2 次再告警/恢复，避免单次抖动。
- `GATUS_CONFIG_PATH` 指向目录时合并目录下所有 YAML；`${VAR}` 从环境变量展开（凭据不进配置文件）。
- `metrics: true` 暴露 `gatus_results_*`，探测结果可进时序库。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 单文件配置 | `config.yaml`（全局）+ `endpoints.yaml`（端点） | 端点清单会频繁改，和全局配置分开 diff |
| 告警渠道必配 | ntfy 未配置时 install.sh 删掉 `alerting` 段和端点的 `alerts` 行 | 空 url 过不了 gatus 校验；先能看面板，凭据后补 |
| 探测公网只看 200 | 保留 node3 清单里的特例（`config-center-api` 401、`vault` 307） | 这些状态码就是「健康」的定义 |
| 只探 HTTP | 加 `observability-pipeline` 组：查 VM/VL API、查 AM `Watchdog` | Pod Ready ≠ 数据在流；这是 Pigsty 时代最有效的一组探针 |
| root 运行 | 非 root、只读根、`tmpfs /tmp`、内存 192Mi | 与 node3 的 compose 加固一致 |

## 4. 暴露方式

- 宿主网：`https://status.${CLUSTER_DOMAIN}`（状态页）
- 集群内：`http://gatus.ops.svc.cluster.local:8080`（`/metrics` 由 opentelemetry 组件抓取）

## 5. 验证

```bash
kubectl -n ops rollout status deploy/gatus
kubectl -n ops logs deploy/gatus | grep -iE 'error|invalid'                  # 配置错误在这里
curl -s https://status.${CLUSTER_DOMAIN}/api/v1/endpoints/statuses | jq '.[] | {group,name,ok:.results[-1].success}'
```

## 6. 踩坑

- `observability-pipeline` 组的查询语句写死了指标名/字段名（`k8s_deployment_available`、`system_cpu_time_seconds_total`、
  `kubernetes.pod_namespace`、`object.kind`）；名字随采集端配置变化会导致假红——红了先在 vmui 核对名字。
- 公网端点从集群内探测走的是节点出口；newt 是出站隧道，探到的是 Pangolin 的公网面，不是集群内路径。
- sqlite 在 PVC 上：`strategy: Recreate`，不要改成多副本。
