# fluent-bit —— Kubernetes 容器日志采集器

## 1. 定位

每个节点运行一个 Fluent Bit Pod，采集 `/var/log/containers/*.log`，补充 Kubernetes
元数据并写入 Loki。节点指标继续由 OpenTelemetry Collector 的 `host_metrics` receiver
采集；Fluent Bit 不重复采集指标。

## 2. 上游最佳实践

来源：[Fluent Bit Kubernetes 安装文档](https://docs.fluentbit.io/manual/installation/downloads/kubernetes)、
[buffering 文档](https://docs.fluentbit.io/manual/administration/buffering-and-storage) 与
[Loki output 文档](https://docs.fluentbit.io/manual/data-pipeline/outputs/loki)。

- 使用官方 Helm chart，以 DaemonSet 覆盖所有节点。
- tail offset 和待发送 chunk 使用 filesystem storage，避免 Pod 重建或后端短暂不可用时只依赖内存。
- Loki 输出使用无限重试；namespace/container 作为低基数 stream label，pod/node 放入
  Loki 3 structured metadata。
- Kubernetes 嵌套字段使用 `$kubernetes['pod_name']` 形式的 record accessor。
- 保留 HTTP health/metrics 端点，用于检查积压、重试和输出错误。

## 3. 本集群取舍

| 旧脚本 | 本组件 | 原因 |
|---|---|---|
| `Keep_Log On` | `Keep_Log Off` | JSON 合并成功后不再保留未脱敏的原始 `log` 字符串。非 JSON 日志仍由 Lua 扫描字符串内容。 |
| 手机号 Lua 模式使用 `{n}` | 使用 Lua 原生 `%d` 和 frontier 模式 | Lua pattern 不支持 `{n}`；旧规则不会匹配手机号。 |
| lift 后用 `$k8s.pod_name` | 保持 `kubernetes` map，使用 record accessor | 点号字段会被解析成嵌套路径，旧标签值失效。 |
| pod 名作为 stream label | pod/node 使用 structured metadata | Pod 名高基数，放 label 会持续增加 Loki stream 数。 |
| `Retry_Limit 5` + throttle | filesystem buffer + 无限重试 | Loki 短暂不可用或日志突增时先落盘，不主动丢弃事故日志。 |
| 同时采节点指标 | 只采容器日志 | OTel 已采节点指标，重复采集会产生两套时间序列。 |

## 4. 数据与安全边界

Lua 过滤器会递归处理字符串字段，遮盖常见邮箱地址和连续 11 位数字。该过滤器不是完整的
数据防泄漏（DLP）方案：密码、令牌、地址以及其他格式的个人信息不会自动识别。应用仍然
不得把凭据或敏感数据写入日志。

单行超过 2MB 时，tail input 会跳过该行并继续采集文件，避免一个异常日志永久卡住输入。
这是明确的数据丢弃边界；可通过 Fluent Bit 自身日志和 `:2020` 指标排查。

## 5. 验证

```bash
kubectl -n logging rollout status daemonset/fluent-bit
kubectl -n logging get pods -l app.kubernetes.io/name=fluent-bit -o wide
kubectl -n logging logs daemonset/fluent-bit --tail=100
kubectl -n logging port-forward service/fluent-bit 2020:2020
curl -fsS http://127.0.0.1:2020/api/v2/metrics/prometheus
```

端到端验证需要写入一条带唯一标记的 Pod 日志，再从 Loki `/loki/api/v1/query_range`
查回同一标记。若测试包含邮箱或手机号，还应确认 Loki 只保存遮盖后的值。

## 6. 故障排查

- **Pod 启动失败并提示配置错误**：执行
  `kubectl -n logging logs daemonset/fluent-bit --tail=100`，先修复首个 `[error]`。
- **Loki 没有新日志**：检查 `fluentbit_output_errors_total` 和
  `fluentbit_output_retries_total`，再确认 `logging/loki:3100` 可达。
- **磁盘缓冲持续增长**：检查 Loki 是否 Ready。修复后保持 Fluent Bit 运行，积压会继续重试；
  不要删除节点上的 `/var/lib/fluent-bit`。
- **某个 Pod 无法查询**：Pod 名位于 structured metadata，不是 stream label。先按
  `{job="kube-logs", namespace="<namespace>"}` 选择 stream，再按 `pod` 元数据过滤。
