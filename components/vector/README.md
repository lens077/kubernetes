# Vector（Agent 角色）

**定位**：容器 stdout/stderr 采集 → VictoriaLogs（TECH-RADAR §8 定稿；替 fluent-bit）。核心卖点=VRL 脱敏可带反例单测进 CI，正面修「fluent-bit Lua 脱敏静默失效」P0。
**上游**：vector/vector chart 0.57.0（实测 2026-08-20，distroless 多架构）。
**本集群取舍**：双写期与 fluent-bit 并行（各写各的后端）；应用结构化日志仍走 OTLP 直发，Vector 只管容器日志；`read_from: end` 不回灌历史；hostPath checkpoint 防重复采集；`_stream_fields` 显式指定防默认空流。
**验证**：①`kubectl -n logging logs ds/vector | head` 无 error ②在任一 pod 打一条含 `13800138000` 的日志 → port-forward VL 9428 → `curl -G .../select/logsql/query --data-urlencode 'query=_msg:"[PHONE_REDACTED]"'` 命中 ③本地 `vector test examples/vector-test.yaml`。
**踩坑**：kubernetes_logs 的 pod 元数据字段名是 `kubernetes.pod_namespace/pod_name/pod_node_name/container_name`（sink URI 的 _stream_fields 与之对齐）；若改字段先 `vector validate`。
**默认配置陷阱（2026-08-21 已修）**：`glob_minimum_cooldown_ms` 默认 60s——新 Pod 头分钟日志**静默丢失**（本集群 08-20 PII 冒烟实测踩中；VM 官方 [log-collectors-benchmark](https://victoriametrics.com/blog/log-collectors-benchmark-2026/) 独立互证并已提上游）。修法=收紧 10s **且** `read_from: beginning`（end 会让「发现晚于首行」的新文件永远丢头几行；checkpoint 已持久化后 beginning 不会重灌旧文件）。**回归手法**：起一个「启动即打一行 PII、随后 sleep」的 pod，30s 内应能在 VL 查到 `[PHONE_REDACTED]` 版本——2026-08-21 配置级已验（渲染确认双参生效），功能级回归被集群重建打断，**新集群起来后按此手法补验一次**。同报告的轮转断句（上游 issue 已提）与高压 FD 泄漏在本量级风险低，观察即可。
