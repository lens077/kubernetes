# OpenKruise（仅 ImagePullJob）

> **⚠️ 2026-08-20 部署实测否决，已从集群卸载**：单副本 manager 崩溃期间其 fail-closed 全局 pod
> mutating webhook 冻结全集群 Pod 创建（含挡自己新 pod 的死锁，实测复现）。脚本保留供复试；
> 翻盘条件=第 3 节点加入+manager 稳定性复验，或上游支持无 webhook 最小安装。详见 `DEPLOY-RECORD-2026-08-20.md`。

**定位**：大促镜像预热（TECH-RADAR §7 定稿：ImagePullJob 先用，CloneSet 降为可选）。
**上游**：openkruise/kruise chart 1.9.1（实测 2026-08-20；固定该版，1.9.x 前有 ImagePullJob 级联 reconcile 高 CPU 修复）。
**本集群取舍**：只开 ImagePullJobGate；kruise-daemon 不能省（预拉由它在每节点执行）；官方兼容表到 1.32，本集群 1.36 属前瞻，以 smoke 为准。
**验证**：`kubectl apply -f examples/imagepulljob-demo.yaml && kubectl get imagepulljob busybox-prepull -w`（succeeded=2）。
