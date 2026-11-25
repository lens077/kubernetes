# 容器 AppArmor 信号拦截：诊断与修复 Runbook

> **TL;DR**：容器里出现"进程明明存在、`kill -0` 能过，但 `kill -INT/-TERM` 全部 `Permission denied`"，且服务卡在某个需要多进程协作的阶段（典型：PostgreSQL 卡 `in crash recovery`、报 `could not signal for checkpoint: Permission denied`）——先查内核 audit 里的 `apparmor="DENIED" operation="signal"`。本集群 k1/k2/k3 的 containerd 2.3.4 默认 profile `cri-containerd.apparmor.d (enforce)` 会拒绝容器进程间信号。止血办法：给该 Pod 的 `securityContext` 加 `appArmorProfile.type: Unconfined` 并重建；根治办法：修节点级 containerd AppArmor profile 的信号规则。

**适用范围**：本集群所有通过 containerd 2.x 运行的容器化工作负载。
**唯一已实证故障案例**：LyraPass `sts/postgres`（2026-11-25，已修复并固化）。
**首次记录**：2026-11-25。详细取证见 `UPGRADE-RECORD-2026-11-25.md` §16–§17、`CHANGELOG-2026-11-25.md` §3.6–§3.7。

---

## 1. 什么时候翻这篇文档（触发条件）

出现以下任一组合，就按本文走，不要先怀疑数据损坏、UID 不匹配或探针配置：

- PostgreSQL 日志 `FATAL: could not signal for checkpoint: Permission denied`，`pg_controldata` 永久停在 `in crash recovery`，redo 每次 0.04s 正常完成但永远不进 ready。
- 容器内 `kill -0 <pid>` 成功，但 `kill -INT <pid>` / `kill -TERM <pid>` / `kill -2 <pid>` 全部 `Permission denied`。
- 多进程服务卡在"主进程要通知子进程做收尾"的阶段（checkpoint、flush、reload、graceful handoff），日志里出现 `EPERM` / `Operation not permitted` / `Permission denied`，而权限位、CapEff、seccomp 看起来都正常。
- `journalctl -k` 里出现 `apparmor="DENIED" operation="signal" ... denied_mask="send"`，profile 为 `cri-containerd.apparmor.d`，peer 带 `//&unconfined`。
- 服务此前长期正常，在**节点重启 / Pod 重建后**突然卡死且反复 CrashLoopBackOff。

---

## 2. 背景：三个概念

### 2.1 AppArmor 与 containerd 默认 profile

AppArmor 是 Linux 内核的强制访问控制（MAC）模块，按**profile**限制进程能做什么（读哪些文件、发哪些信号、ptrace 谁）。容器运行时会给容器进程套一个 profile；本集群 containerd **v2.3.4**（`io.containerd.runc.v2`）默认是：

```
cri-containerd.apparmor.d (enforce)
```

`enforce` 表示拒绝即生效（不是仅告警）。关键行为：**该 profile 拒绝向 `cri-containerd.apparmor.d//&unconfined` 这类 peer 发信号**。容器进程自己的标签就是 `cri-containerd.apparmor.d//&unconfined (enforce)`，于是"容器进程 → 容器进程"的信号被判为跨标签发送，直接 EPERM。

> `//&unconfined` 后缀是反向代理/容器运行时的常见标签形态，**不是配置错误**，不要试图清理它。

### 2.2 什么是"容器进程间信号"

就是普通的 POSIX 信号（`kill(2)`、`SIGINT`/`SIGTERM`/`SIGQUIT`/`SIGUSR1`…），只不过发送方和接收方都在同一个容器里。它和以下两件事**不是一回事**：

| 机制 | 谁发 | 走容器 AppArmor 吗 |
|---|---|---|
| 容器进程 → 容器进程（如 PG 主进程 → checkpointer） | 容器内 PID | **是，会被拦** |
| kubelet → 容器主进程（优雅停机 SIGTERM） | 节点外部 | 否，不经过容器 profile |
| 进程内线程唤醒 / Go 异步抢占（SIGURG） | 同进程内 | 会被拦但**无害**，运行时自动降级 |

### 2.3 什么场景真正依赖它

只有**多进程、且用信号做内部协调**的服务才会因拦截产生实际故障：

- **PostgreSQL**：crash recovery 结束时主进程用 `RequestCheckpoint()` 给 checkpointer 发 SIGINT 做 end-of-recovery checkpoint。发不出去 → 永久卡 `in crash recovery` → 拒绝连接。（本次实例）
- 其他自带 supervisor / 多 worker 且靠信号做 reload、graceful handoff 的守护进程（理论上同风险，本集群暂未实证）。

**不依赖的场景**（不要给它们加豁免）：Go/Java 单进程多线程服务。它们内部是线程调度，不用信号协调；信号只用于优雅停机，而 SIGTERM 由 kubelet 从外部发，不经容器 AppArmor。

---

## 3. 快速判定：30 秒指纹

在出问题的 Pod 里：

```bash
kubectl -n <ns> exec -it <pod> -- sh
# 1) 看进程是否真的存在、PID 是多少
ps -ef | grep <进程名>

# 2) 关键分界线：探测能过，实际信号全挂
kill -0 <pid> && echo "exists: OK"
kill -INT <pid>          # Permission denied -> 高度怀疑 AppArmor
kill -TERM <pid>         # 同上

# 3) 排除能力/UID 误判
grep -E 'Uid|CapEff|NoNewPrivs|Seccomp' /proc/self/status
```

判据：`kill -0` 成功 + `kill -INT/-TERM` 全 EPERM + `CapEff=0` =====> 不是权限位或进程不存在，**是 AppArmor 信号过滤**。

在**节点上**取铁证（k1 为本次实例，按需替换节点）：

```bash
journalctl -k --since '24 hours ago' | grep -i 'apparmor.*DENIED' | grep signal
```

本次实证输出形态：

```
apparmor="DENIED" operation="signal" profile="cri-containerd.apparmor.d"
  ... signal=int peer="cri-containerd.apparmor.d//&unconfined" denied_mask="send"
```

24h 统计：`signal=int` 8437 次（全部 `comm="postgres"`）+ `pg_ctl` 3 次；另有 `signal=urg`（Go runtime 异步抢占）、`ptrace read`（otelcol hostmetrics 2412 次）。**只有 `signal=int` 对应真实故障**，其余是无害噪音（见 §6）。

---

## 4. 诊断 SOP（按序执行，别跳步）

1. **确认症状指纹**：按 §3 做 `kill -0` / `kill -INT` 对照 + 内核 audit。这一步是分水岭，能省掉后面所有弯路。
2. **排除探针过早**：临时把 liveness `initialDelaySeconds` 调大（本次试过 3600）并重建 Pod。若仍卡在同一处 EPERM，说明**不是 liveness 触发**，撤销该改动。本次已验证无效。
3. **排除 UID / 权限位**：确认进程 UID、`PGDATA` 属主、`/var/run/postgresql` 属组一致（本次均为 70）；`chmod` 报错多为 entrypoint 无害告警，别被带偏。
4. **排除数据损坏**：`pg_controldata` 能正常完成 redo（本次 0.04s）、数据目录大小正常、表可列举 =====> 数据没事，问题在"最后一步发信号"。
5. **查版本与命名空间约束**：节点 `containerd --version`；目标命名空间是否有 `pod-security.kubernetes.io/enforce=restricted`（**有则不能直接加 Unconfined**，见 §7）。目标工作负载是否被 ArgoCD 跟踪（有 `argocd.argoproj.io/tracking-id` 则 live patch 会被 selfHeal 覆盖，见 §7）。

---

## 5. 修复方案

### 5.1 止血（推荐）：Pod 级 `appArmorProfile: Unconfined`

只解除**这一个 Pod** 的 AppArmor，其他安全约束全部保留。

**manifest 写法**（K8s 1.37 GA 字段；旧注解 `container.apparmor.security.beta.kubernetes.io/*` 已废弃）：

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        appArmorProfile:
          type: Unconfined          # 仅解除 AppArmor
        seccompProfile:
          type: RuntimeDefault      # 保留
      containers:
        - name: postgres
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]         # 保留
```

**live 紧急修复**（先备份，再 patch，再重建）：

```bash
# 备份
kubectl -n <ns> get sts <name> -o yaml > /root/<name>-sts.bak-$(date +%Y%m%d).yaml

# patch（Pod 级 securityContext）
kubectl -n <ns> patch sts <name> --type=json -p='[
  {"op":"add","path":"/spec/template/spec/securityContext/appArmorProfile",
   "value":{"type":"Unconfined"}}]'

# Pod 不会自动更新模板，需重建
kubectl -n <ns> rollout restart sts/<name>
```

**验证**：`pg_controldata` = `in production`、`database system is ready to accept connections`、重启计数归零、依赖它的 Deployment 全部 Ready、定时任务下一次自然调度成功。

**固化**：必须写回应用仓库的 base manifest（本次为 `/Users/lens/lens077/LyraPass/deploy/cloud/k8s/base/k8s.yaml`），否则下次 GitOps 同步会被还原。

**回滚**：删除 `appArmorProfile` 字段并重建 Pod 即回到 confinement（注意：会再次卡住，除非做 §5.2 根治）。本次原始配置备份在 k1 `/root/lyrapass-postgres-sts.bak-20261125.yaml`。

### 5.2 根治（未实施）：节点级 containerd profile 放行信号

方向：修改节点上 containerd 的 AppArmor profile，允许容器进程向同标签 peer 发送必要信号（至少 `signal,int` / `signal,term`），再 `apparmor_parser -r` 重载。这样所有容器都能正常发信号，无需逐 Pod 豁免。

**状态**：本集群尚未实施。实施前需要：① 在节点上用 `aa-status` / `/etc/apparmor.d/` 确认 profile 文件的真实路径与内容（不要凭本文猜路径）；② 单节点灰度并跑 24h audit 验证无新增拒绝；③ 逐节点滚动；④ 回滚方案是还原原 profile 文件并重载。做完后可移除 §5.1 的 Pod 级豁免。

### 5.3 不要做的事

- ❌ **不要为了绕过它去放宽 liveness/startupProbe**：本次已证伪，白改。
- ❌ **不要改 UID / chmod 数据目录**：UID 全对，属主属组全对，不是权限位问题。
- ❌ **不要把整个集群设成默认 Unconfined**：会显著缩小安全面、降低合规基线（详见 §6 的实测结论）。
- ❌ **不要给 CNPG Cluster CR 加 Unconfined**（在 `restricted` 命名空间下会报错循环，见 §7）。

---

## 6. 适用范围判定：该不该加豁免

**结论（2026-11-25 基于 24h audit 实证）：不预防性扩大，只对已证明故障的服务加。**

| 对象 | 24h audit 实证 | 判定 |
|---|---|---|
| PostgreSQL `signal=int` | 8437 次，全部 `comm="postgres"`（+ `pg_ctl` 3 次） | **真实故障**，Pod 级 Unconfined 已覆盖 |
| Go runtime `signal=urg` | vmalert / virgo-auth 等，Go 异步抢占 | **无害降级**，运行时自动处理，不加豁免 |
| otelcol `ptrace read` | 2412 次，hostmetrics 读宿主进程信息 | **无害降级**，采集器健康，仅宿主进程信息缺失 |
| Go/Java 单进程服务 | 不依赖进程间信号协调 | 不加；加了白白降低安全基线 |
| kubelet → 容器 SIGTERM | 从节点外部发，不经容器 AppArmor | 不受影响，无需处理 |

**判据一句话**：只有"多进程 + 靠进程间信号协调"的服务会产生实际故障；其他服务的 DENIED 都是无害噪音。

---

## 7. 已知陷阱（踩过的坑）

1. **PodSecurity `restricted` 禁止 Unconfined**：本次给 CNPG 三集群（`pg-main`/`cs2four-pg`/`pal-pg`）的 Cluster CR 加 `spec.podSecurityContext.appArmorProfile: Unconfined`，因 `cs2-four` 命名空间有 `pod-security.kubernetes.io/enforce=restricted`，operator 报错循环：`violates PodSecurity "restricted:latest": forbidden AppArmor profile (pod must not set AppArmor profile type to "Unconfined")`。**已全部回滚**，快照在 k1 `/root/apparmor-signal-fix-20261125/*-*.yaml.bak`。遇到这类命名空间，只能走 §5.2 节点级根治。
2. **ArgoCD selfHeal 会覆盖 live patch**：带 `argocd.argoproj.io/tracking-id` 的资源（本次 `pal-pg`）在 live 改配置后会被 selfHeal 还原。改 live 只作临时验证，**最终必须落到 GitOps 源仓库**。
3. **ArgoCD health 缓存**：CNPG 重启期间 application-controller 可能缓存空 health，hard refresh 无效；`kubectl -n argocd rollout restart sts/argocd-application-controller` 后恢复。
4. **旧注解已废弃**：用 `spec.securityContext.appArmorProfile.type`（K8s 1.37 GA），不要用 `container.apparmor.security.beta.kubernetes.io/*`。
5. **节点重启常是触发器不是根因**：本次故障自 11-15 起，k1 在 03:06 重启只是让 Pod 重建重新暴露问题。看到"重启后开始坏"先查 audit，别直接归因于升级/重启。
6. **`name@ip` 类孪生标签不是配置错误**：AppArmor peer 的 `//&unconfined` 后缀同理，别试图"清理"。

---

## 8. 实战案例：LyraPass PG（2026-11-25，已恢复）

- **症状**：`lyrapass-cloud-maintenance` 每小时 :17 连续失败，`lastSuccessfulTime` 停在 `2026-11-15T01:17:06Z`；`deployment/lyrapass-cloud` 0/2，两个 Pod 卡在 init container `migrate`；`pod/postgres-0` CrashLoopBackOff 80+ 次。
- **根因**：containerd 2.3.4 默认 profile 拒绝 PG 向 checkpointer 发 SIGINT，数据库永久卡 `in crash recovery`；migrate 连不上 → cloud 0/2 → 维护端点不可达。
- **取证**：`kill -0` 通过而 `kill -INT/-TERM/-2` 全 EPERM；内核 audit `signal=int` 8437 次 `DENIED`；放宽 liveness 无效。
- **修复**：`sts/postgres` 加 `appArmorProfile.type: Unconfined` 并重建；固化到 `/Users/lens/lens077/LyraPass/deploy/cloud/k8s/base/k8s.yaml`。
- **验证**：`in production` / `ready to accept connections` / 0 重启；17 张业务表零丢失；cloud 2/2 Ready；01:17 UTC 自然调度 Job 自主成功；14 个 ArgoCD 应用全 Healthy。
- **备份**：k1 `/root/lyrapass-postgres-sts.bak-20261125.yaml`（加 Unconfined 前的原配置）。
- **范围评估**：24h audit 后决定不扩大豁免（CNPG 三集群尝试已回滚，详见 §6–§7）。

---

## 9. 命令速查表

```bash
# 容器内：信号对照测试
kubectl -n <ns> exec -it <pod> -- sh -c 'kill -0 <pid>; kill -INT <pid>; kill -TERM <pid>'

# 容器内：能力/身份
kubectl -n <ns> exec <pod> -- grep -E 'Uid|CapEff|NoNewPrivs|Seccomp' /proc/self/status

# 节点上：AppArmor 拒绝日志
journalctl -k --since '24 hours ago' | grep -i 'apparmor.*DENIED' | grep signal

# 节点上：运行时版本
containerd --version

# 命名空间约束（能否加 Unconfined）
kubectl get ns <ns> --show-labels | grep pod-security

# 是否被 GitOps 跟踪
kubectl -n <ns> get <kind> <name> -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'

# 止血 patch + 备份
kubectl -n <ns> get sts <name> -o yaml > /root/<name>-sts.bak-$(date +%Y%m%d).yaml
kubectl -n <ns> patch sts <name> --type=json -p='[{"op":"add","path":"/spec/template/spec/securityContext/appArmorProfile","value":{"type":"Unconfined"}}]'
kubectl -n <ns> rollout restart sts/<name>

# 验证
kubectl -n <ns> exec <pod> -- pg_controldata | grep -i 'cluster state'
kubectl -n <ns> rollout status sts/<name>
```
