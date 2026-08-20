# NATS JetStream

**定位**：领域事件底座（TECH-RADAR §1 定稿：替 Kafka 全家桶）。outbox 自写 relay 的下游，CloudEvents 信封。
**上游**：nats helm chart 2.14.5（实测 2026-08-20），仓库 https://nats-io.github.io/k8s/helm/charts/。
**本集群取舍**：3 副本 meta-R3 但当前仅 2 节点——软反亲和，必有一节点承载 2 副本，**不容忍整节点故障**（正确性靠 PG outbox 重放兜底，DR 靠异地备份）；交易域 stream 用 R3、埋点 R1（TECH-RADAR 1.2）。NACK CRD 刻意后补：先验存储/故障恢复，再引声明式控制器。
**暴露**：仅集群内 `nats.nats.svc:4222`。
**验证**：`bash examples/smoke.sh`（建 R3 stream → pub/sub → 杀 nats-0 验选主）。
**踩坑**：openebs-lvm 是本地盘，PVC 钉死首调度节点；删 PVC 才能换节点。
