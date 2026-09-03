# Vector（Agent 角色）

**定位**：容器 stdout/stderr 采集 → VictoriaLogs（TECH-RADAR §8 定稿；替 fluent-bit）。核心卖点=VRL 脱敏可带反例单测进 CI，正面修「fluent-bit Lua 脱敏静默失效」P0。
**上游**：vector/vector chart 0.57.0（实测 2026-08-20，distroless 多架构）。
**本集群取舍**：双写期与 fluent-bit 并行（各写各的后端）；应用结构化日志仍走 OTLP 直发，Vector 只管容器日志；`read_from: beginning` 配合 hostPath checkpoint 补齐短命 Pod 头部日志且不重复回灌；`_stream_fields` 显式指定防默认空流。
**安全支路**：Tetragon 原始 stdout 继续写 VictoriaLogs；VRL 只把 projected-token access 与 ecommerce 可疑工具执行转成低基数 `ecommerce_tetragon_security_events_total{event_type,node}`，由 `prometheus_exporter:9598` 暴露给 OTel Collector。`vector-security-metrics` NetworkPolicy 只允许 `opentelemetry` 中的 Collector Pod 访问该端口；完整 Pod、binary、UID 与 parent chain 不进入指标标签，仍从原始日志调查。
**验证**：①`kubectl -n logging logs ds/vector | head` 无 error；②在任一 Pod 打一条含测试手机号的日志，VictoriaLogs 只命中 `[PHONE_REDACTED]`；③渲染 ConfigMap 后用同版本 Vector 执行 `vector validate --no-environment`；④注入 token access/可疑 exec 后，node3 VictoriaMetrics 对应 counter 增加。
**踩坑**：kubernetes_logs 的 Pod 元数据字段名是 `kubernetes.pod_namespace/pod_name/pod_node_name/container_name`（sink URI 的 `_stream_fields` 与之对齐）；Helm chart 会对 `customConfig` 再执行 `tpl`，Vector 的 `{{ field }}` 模板必须在 values 中转义。改字段或 VRL 后必须先 `vector validate`。
**默认配置陷阱（2026-08-21 已修）**：`glob_minimum_cooldown_ms` 默认 60s——新 Pod 头分钟日志**静默丢失**（本集群 08-20 PII 冒烟实测踩中；VM 官方 [log-collectors-benchmark](https://victoriametrics.com/blog/log-collectors-benchmark-2026/) 独立互证并已提上游）。修法=收紧 10s **且** `read_from: beginning`（end 会让「发现晚于首行」的新文件永远丢头几行；checkpoint 已持久化后 beginning 不会重灌旧文件）。**回归手法**：起一个「启动即打一行 PII、随后 sleep」的 pod，30s 内应能在 VL 查到 `[PHONE_REDACTED]` 版本——2026-08-21 配置级已验（渲染确认双参生效），功能级回归被集群重建打断，**新集群起来后按此手法补验一次**。同报告的轮转断句（上游 issue 已提）与高压 FD 泄漏在本量级风险低，观察即可。
