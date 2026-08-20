# ClickHouse（单节点）

**定位**：埋点/漏斗/GMV 的 OLAP（TECH-RADAR §3 定稿；用户拍板单节点）。摄入路线=NATS 表引擎直连 JetStream（内建能力）或批量导入；埋点可断代重放，单点可接受。
**上游**：官方 clickhouse/clickhouse-server:26.6（多架构）。**刻意不用** Altinity operator（单节点多余控制面）与 Bitnami chart（2025-08 后免费镜像进 legacy 不维护）。
**本集群取舍**：requests 1Gi / limits 2Gi + `max_server_memory_usage` 1.6GiB 顶格（T2 预算）；与 pg-main 主实例错开节点（当前调度器按 requests 自然分布，落点见验证）；生产化前把镜像 digest pin（25.8.10~25.8.15 有 K8s 新 Pod DDL 回归前科，避浮动 tag 风险）。
**验证**：`kubectl -n clickhouse exec sts/clickhouse -- clickhouse-client --user app --password "$(cat <STATE_DIR>/creds/clickhouse-app)" --queries-file /dev/stdin < examples/smoke.sql`。
**踩坑**：openebs-lvm 本地盘，PVC 钉死首调度节点；`CLICKHOUSE_DB=analytics` 由镜像入口创建。
