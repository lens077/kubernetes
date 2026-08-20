# KEDA

**定位**：事件驱动扩缩（TECH-RADAR §7 定稿）。大促 cron 预热 + VictoriaMetrics(Prometheus 协议) 指标扩缩先行；NATS 落地后加 nats-jetstream scaler。
**上游**：kedacore/keda chart 2.20.2（实测 2026-08-20）。
**本集群取舍**：三组件各 1 副本、资源压最小；webhook failurePolicy=Ignore（防 webhook 故障阻塞全集群调度）；固定节点没有容量弹性——ScaledObject 必须设 maxReplicaCount；与 VPA 分工（KEDA 管副本数），不同调同一指标。
**验证**：`kubectl apply -f examples/cron-demo.yaml` → keda-cron 副本 0→2；删除即清理。
**踩坑**：官方兼容矩阵未覆盖 k8s 1.36（前瞻版本），以本集群 smoke 为准。
