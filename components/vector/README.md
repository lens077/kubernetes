# Vector（Agent 角色）

**定位**：容器 stdout/stderr 采集 → VictoriaLogs（TECH-RADAR §8 定稿；替 fluent-bit）。核心卖点=VRL 脱敏可带反例单测进 CI，正面修「fluent-bit Lua 脱敏静默失效」P0。
**上游**：vector/vector chart 0.57.0（实测 2026-08-20，distroless 多架构）。
**本集群取舍**：双写期与 fluent-bit 并行（各写各的后端）；应用结构化日志仍走 OTLP 直发，Vector 只管容器日志；`read_from: end` 不回灌历史；hostPath checkpoint 防重复采集；`_stream_fields` 显式指定防默认空流。
**验证**：①`kubectl -n logging logs ds/vector | head` 无 error ②在任一 pod 打一条含 `13800138000` 的日志 → port-forward VL 9428 → `curl -G .../select/logsql/query --data-urlencode 'query=_msg:"[PHONE_REDACTED]"'` 命中 ③本地 `vector test examples/vector-test.yaml`。
**踩坑**：kubernetes_logs 的 pod 元数据字段名是 `kubernetes.pod_namespace/pod_name/pod_node_name/container_name`（sink URI 的 _stream_fields 与之对齐）；若改字段先 `vector validate`。
