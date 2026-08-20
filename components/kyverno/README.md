# Kyverno（audit 先行）

**定位**：K8s 准入 policy + 未来镜像验签（TECH-RADAR §11 定稿：verifyImages 承担 cosign 验签，不引 Ratify）。
**上游**：kyverno/kyverno chart 3.8.2 / app v1.18.2（实测 2026-08-20；graduated）。
**本集群取舍**：4 控制器各 1 副本资源压最小；webhook 排除 kube-system/argocd（防控制面互锁）；**只跑 Audit**——14 天零误报才逐条 Enforce（本集群节点重启史频繁，enforce 前必须先做「签名纪元」处理：存量运行 digest 补签 + 删 pod 强制重建演练，见 ecommerce 对抗第 3 轮 R3-C C1 补丁）。
**验证**：`kubectl run audit-no-limits --image=busybox -- sleep 60` → `kubectl get policyreport -A | head`（出现 fail 记录即 audit 生效，pod 不被拒）。
