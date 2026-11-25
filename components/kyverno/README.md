# Kyverno（audit 先行）

**定位**：K8s 准入 policy + 未来镜像验签（TECH-RADAR §11 定稿：verifyImages 承担 cosign 验签，不引 Ratify）。
**上游**：kyverno/kyverno chart 3.10.0 / app v1.20.0（2026-11-25 升；graduated）。
**本集群取舍**：4 控制器各 1 副本资源压最小；webhook 排除 kube-system/argocd（防控制面互锁）；**只跑 Audit**——14 天零误报才逐条 Enforce（本集群节点重启史频繁，enforce 前必须先做「签名纪元」处理：存量运行 digest 补签 + 删 pod 强制重建演练，见 ecommerce 对抗第 3 轮 R3-C C1 补丁）。

## 镜像走 TCR（2026-09-22）

`reg.kyverno.io` 在机房侧单个镜像拉 1 小时以上，5 个控制器串起来装不完，改为 TCR 镜像仓兜底。
`values.yaml` 已把五个控制器 + `kyverno-cli`（migrate job）指到 `ccr.ccs.tencentyun.com/sumery/<name>:<tag>`。

升级版本时在 Mac 上重新镜像，**每条命令都必须带 `--platform linux/amd64`**——Mac 是 arm64，
不带就推 arm64 层，节点上 `exec format error` 直接 CrashLoop（2026-09-22 踩过）：

```bash
for c in kyverno kyvernopre background-controller cleanup-controller reports-controller kyverno-cli; do
  docker pull --platform linux/amd64 reg.kyverno.io/kyverno/$c:v1.20.0
  docker tag reg.kyverno.io/kyverno/$c:v1.20.0 ccr.ccs.tencentyun.com/sumery/$c:v1.20.0
  docker push --platform linux/amd64 ccr.ccs.tencentyun.com/sumery/$c:v1.20.0
done
```

拉取凭据：把本机 `docker login ccr.ccs.tencentyun.com` 的 `config.json`（只含 `auths`）放到节点
`/var/lib/k8s-installer/creds/tcr-dockerconfig.json`（chmod 600），`install.sh` 经
`tcr_pull_secret_ensure` 物化成 `kyverno/tcr-pull-secret`。凭据不进 values、不进 git。
换节点缓存里残留的错架构层：`crictl rmi <image>` 后再重启 Pod。

## 验证

```bash
bash components/kyverno/examples/smoke.sh
# PASS: Audit 模式 Pod 放行, PolicyReport 记录 fail: disallow-latest-tag,require-requests-limits
```

冒烟在隔离 ns `kyverno-smoke` 建一个同时违反两条策略的 Pod，断言 Pod **没被拒**（Audit 语义）
且 90s 内 PolicyReport 出现两条 fail；结束即删 ns。手工验：`kubectl run audit-no-limits --image=busybox -- sleep 60`
→ `kubectl get policyreport -A`。

## GitOps

策略本体（`examples/policies-audit.yaml`）由本仓 `install.sh` 装；ecommerce 仓的业务准入策略
（含未来 `verifyImages`）走 ArgoCD，见 ecommerce 仓 `infrastructure/kyverno/`。


## 1.20.0 CEL 迁移（2026-11-25）

Kyverno 1.20 **彻底删除** legacy `kyverno.io` 策略引擎：旧 `ClusterPolicy`/`Policy` 不再被 admission/background/reports 执行。升级前已把 3 条策略迁到 CEL：

- `disallow-latest-tag`、`require-requests-limits` → `policies.kyverno.io/v1 ValidatingPolicy`（见 `examples/policies-audit.yaml`）
- `ecommerce-image-provenance` → `policies.kyverno.io/v1 NamespacedImageValidatingPolicy`（见 ecommerce 仓 `infrastructure/kyverno/policies/`，ArgoCD 管理）

均保持 Audit 语义（不阻断）；镜像验签保留原 keyless identity + rekor。Helm gate 用 `upgrade.acknowledgeLegacyPoliciesNotEnforced=true` 越过（legacy 对象保留但不执行）。旧 legacy 对象可择机删除。CEL 策略的 `images.*` 变量只用于 image policy，ValidatingPolicy 用 `object.spec.containers`。

ArgoCD 3.6 对 `policies.kyverno.io/*` 新 GVK 没有内置 health check，策略本体虽 `ready=true`，App 仍可能显示 Unknown/Missing。已在 `argocd-cm` 补 4 个 `resource.customizations.health.policies.kyverno.io_*` 脚本（按 `status.conditionStatus.ready` 判定 Healthy/Degraded/Progressing），values 源见 `components/argo/values-cel-health.yaml`。ecommerce 项目还需在 AppProject 白名单放行 `policies.kyverno.io/NamespacedImageValidatingPolicy`，否则 `ecommerce-kyverno` 会 SyncError。
