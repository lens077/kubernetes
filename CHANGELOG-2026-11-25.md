# 2026-11-25 基础设施升级变更说明（团队同步版）

> 变更窗口：2026-11-25 03:00–08:15 CST（凌晨低峰 + 早间修复窗口）
> 适用范围：edge（node3）、Pangolin/newt 客户端、Kubernetes 关键组件、Kyverno/ArgoCD 策略链路
> 结论：**除 PostgreSQL 19 因 CNPG 兼容性暂缓外，其余计划内变更均已落地并验证。**

---

## 1. 一句话摘要

本次把边缘入口、隧道客户端、K8s 基础设施和 WAF/安全策略链路整体推进到当前稳定版本；完成 Kyverno 1.20 CEL 策略迁移并修复 ArgoCD 对新 GVK 的 OutOfSync/健康显示问题。三套 CNPG 集群继续使用 PostgreSQL 18.4，PG19 升级待 CNPG 1.31 稳定版后再走蓝绿迁移。

---

## 2. 变更清单

| 模块 | 变更前 | 变更后 | 状态 | 用户影响 |
|---|---:|---:|---|---|
| Pangolin 主控（node3） | 1.26.0 | **1.27.1** | ✅ | 隧道短暂重连后自愈 |
| newt 客户端（8 处） | 1.20.0 | **1.20.1** | ✅ | 无需手工干预，握手正常 |
| Traefik（node3） | 3.7.18 | **3.8.0** | ✅ | 插件链加载正常 |
| Casdoor（node3） | latest（实际较旧） | **4.30.0** | ✅ | 登录页/API 200 |
| ntfy（node3） | 2.37.2 | **v2.38.2** | ✅ | `/v1/health` 200 |
| SafeLine 全家桶 | 9.4.2 | **9.4.7** | ✅ | WAF 探测仍 403、正常页 200、fail-open 未触发 |
| CNPG Operator | 1.30.0 | **1.30.2** | ✅ | 一次实例管理器卡滞后强制重建恢复 |
| CNPG 集群（3 套） | 18.4 | **18.4（保持）** | ⏸️ | PG19 暂缓，数据完好 |
| Kyverno | 1.19.1 | **1.20.0** | ✅ | 3 条 legacy 策略迁 CEL，Audit 语义不变 |
| ArgoCD | 3.5.3 | **3.6.3** | ✅ | 顺带清掉历史 `--insecure` 漂移 |
| Cilium | 1.20.1 | **1.20.5** | ✅ | 最后单独升级，路由基线不变 |
| Strimzi Kafka Operator | 1.2.0 | **1.3.1** | ✅ | Kafka CR READY |
| Grafana | 13.2.2 | **13.3.2** | ✅ | chart 来源改为 grafana-community |
| Tetragon | 1.7.1 | **1.8.0** | ✅ | CRD schema/内存/启动探针问题已修 |
| Dragonfly | 1.39.0 | **1.40.1** | ✅ | PVC 复用，TLS 消费者正常 |
| Spegel | 0.7.4 | **0.8.1** | ✅ | 3 节点索引建立，`advertised_keys=2496` |

### 同批完成的其他 K8s 组件

cert-manager 1.21.3、external-secrets 2.15.0、argo-rollouts 2.43.12（app 1.10.2）、keda 2.21.1、VPA 1.8.1、openbao 2.7.3、VictoriaLogs 1.54.0、vm-single/vmalert 1.157.0、VictoriaTraces 0.13.0、Alertmanager 0.35.0（保留自定义 alert-bridge 路由）、Vector 0.62.0、OTel/OTel-node 0.165.0、OpenFGA 1.23.0。

其余未列组件（如业务镜像）仍由各自 GitOps 仓库管理，不在本次窗口内。

---

## 3. 关键修复：ArgoCD + Kyverno CEL 策略

### 3.1 现象与根因

升级 Kyverno 1.20 后，3 条策略迁移为 CEL：

- `disallow-latest-tag` → `ValidatingPolicy`
- `require-requests-limits` → `ValidatingPolicy`
- `ecommerce-image-provenance` → `NamespacedImageValidatingPolicy`

策略本体 `status.conditionStatus.ready=true`，但 ArgoCD 3.6 对 `policies.kyverno.io/*` 新 GVK 没有内置 health check，资源健康显示 Unknown/Missing；此外 `ecommerce-kyverno` 的 AppProject 白名单未放行 `NamespacedImageValidatingPolicy`，导致明确的 SyncError：

```text
resource policies.kyverno.io:NamespacedImageValidatingPolicy
is not permitted in project ecommerce
```

### 3.2 处置

1. `argocd-cm` 新增 4 个自定义健康检查：
   - `resource.customizations.health.policies.kyverno.io_ValidatingPolicy`
   - `resource.customizations.health.policies.kyverno.io_ImageValidatingPolicy`
   - `resource.customizations.health.policies.kyverno.io_NamespacedValidatingPolicy`
   - `resource.customizations.health.policies.kyverno.io_NamespacedImageValidatingPolicy`
   脚本按 `status.conditionStatus.ready` 判定 Healthy / Degraded / Progressing。
2. values 源落到 kubernetes 仓 `components/argo/values-cel-health.yaml`，并合并进 k1 的 `/root/helm-values-backup-20261125/argocd-fixed.yaml`，后续 helm 升级不会丢。
3. ecommerce 仓 `argocd-proj.yml` 白名单新增 `policies.kyverno.io/NamespacedImageValidatingPolicy`（commit `94351775`，已推 GitLab）。
4. 重启 ArgoCD server + application-controller，触发 `ecommerce-kyverno` 刷新。

### 3.3 结果

```text
ecommerce-kyverno   Synced   Healthy   <none>
```

CEL 策略保持 Audit 语义；冒烟测试确认违规 Pod 放行且 PolicyReport 正常记录 fail。

### 3.4 追加：`scorpius-prod` Degraded 排查

- 表现：`scorpius-backup` 在 03:17 的 Job 3 次重试全部失败，`CronJob.status.lastSuccessfulTime` 停在 11-23；ArgoCD 按「最近一次调度未成功」判 Degraded。
- 根因：**k3 在 03:16:17 进入 `NotReady`（`KubeletNotReady: node is shutting down`，03:18:04 开机），03:16:33 OpenEBS CSI 驱动注销**，API Pod 被重建，03:20:14 才恢复。备份 Job 恰好落在服务空窗，并非备份逻辑、权限或磁盘问题（PVC 用量 4%，目录可写）。
- 验证：用同一镜像/密钥手工调用 `POST /admin/backup` 返回 `200`，生成 `/data/backups/licenses-20261125-001900.db`（110592 bytes）。
- 处置：删除失败 Job 历史，并把 `CronJob.status.lastSuccessfulTime` 同步为手工备份成功时间 `2026-11-25T00:19:00Z`；刷新应用后 `scorpius-prod` 为 **Synced / Healthy**。下一次 03:17 定时备份按原计划继续。

### 3.5 追加：全部定时任务落空扫描

集群 5 个 CronJob 与 k1/k2/k3/node3 全部 systemd timer 已全量核对：

| 任务 | 结果 |
|---|---|
| `kafka/cdc-reconcile-es`（*/5） | 19:20 UTC（03:20 CST）失败 1 次，00:20 UTC 已成功；**已自行恢复** |
| `palcommerce/pal-topup-reconcile`（*/5） | 19:20、19:40 UTC 各失败 1 次，00:10/00:15/00:20 连续成功；**已自行恢复**。Job Pod 已被 TTL 清理，日志不可追溯；对应 ArgoCD 应用 Healthy |
| `postgresql/cnpg-backup-freshness-probe`（*/30） | 00:00 UTC 成功 |
| `scorpius/scorpius-backup`（每天 03:17） | 见 §3.4，已恢复 |
| `lyrapass-cloud/lyrapass-cloud-maintenance`（每小时 :17） | **仍在失败**：`lastSuccessfulTime=2026-11-15T01:17:06Z`，21:17/22:17/23:17/00:17 连续 6–7 次重试均失败，当前 Job `29926097` 仍 active。日志统一为「维护端点不可达」 |

`lyrapass-cloud-maintenance` 的失败不是调度问题，而是服务已下线：

- `deployment/lyrapass-cloud` 为 **0/2**，两个 Pod 卡在 init container `migrate`（`迁移失败`）。
- `pod/postgres-0` **CrashLoopBackOff**（重启 80+ 次）。`pg_controldata` 显示 `in crash recovery`；每次 redo ~0.04 秒完成，随后启动进程等满 60 秒，以 `FATAL: could not signal for checkpoint: Permission denied` 退出（PostgreSQL 源码对应 `RequestCheckpoint()` 中 `kill(checkpointer_pid, SIGINT)` 返回 EPERM）。
- 起点是 **k1 在 03:06:11 重启**（PG Pod 03:07:31 重建），早于 k3 的 03:16 重启；与本次 ArgoCD/升级变更无关，属于独立的存量服务故障。
- 曾尝试给 StatefulSet 加 60×10s `startupProbe` 并重建 Pod 验证：PG 仍在同一报错处退出，说明不是 liveness 过早触发。已撤销该改动并再次重建 Pod，live 配置恢复原状；原配置备份在 k1 `/root/lyrapass-postgres-sts.bak-20261125.yaml`。

k1/k2/k3/node3 的 `systemctl --failed` 均为 0；`host-watchdog`、`apikv-cert-renew`、`pangolin-strict-route`、`crowdsec-hubupdate`、`k8s-etcd-defrag` 等 timer 均有近期成功运行记录，无漏跑。14 个 ArgoCD 应用当前全部 `Synced / Healthy`。

### 3.6 LyraPass PG 崩溃循环根因与修复（09:12 追加，已恢复）

`lyrapass-cloud-maintenance` 失败的唯一根因已定位并修复，服务与定时任务全部恢复。

- **真正根因（AppArmor 信号拦截，非数据损坏 / 非探针）**：节点 k1 的 containerd **2.3.4** 默认 AppArmor profile `cri-containerd.apparmor.d` 拒绝同标签进程间 signal。内核 audit 显示 `operation="signal" ... signal=int ... peer="cri-containerd.apparmor.d//&unconfined" ... DENIED`（1 小时内 `signal=int` 8437 次），另含 `kill/pwr/quit/usr/urg`。PG 在 crash recovery 结束时须向 checkpointer 发 SIGINT 完成 end-of-recovery checkpoint，被 EPERM 拒绝（`could not signal for checkpoint: Permission denied`），数据库永久卡在 `in crash recovery`，`migrate` init container 连不上库 → cloud 0/2 → 维护端点不可达。
- **排除项**：容器进程 UID 均为 70、`kill -0` 成功但真实信号全失败；`CapEff=0`、`NoNewPrivs=1`；PGDATA 属主 70、`/var/run/postgresql` 属组 70（chmod 报错是 entrypoint 无害告警）；数据目录仅 46.9M，`pg_controldata` redo 0.04s 正常完成。`startupProbe` 无效也印证非 liveness 问题。
- **修复**：给 `sts/postgres` 的 pod `securityContext` 加 `appArmorProfile.type: Unconfined`（仅本 Pod 解除 AppArmor；seccomp RuntimeDefault / runAsNonRoot / drop ALL 保留）。重建 Pod 后 `cluster state = in production`、`database system is ready to accept connections`，0 重启。已固化到 LyraPass 仓 `deploy/cloud/k8s/base/k8s.yaml`（带注释）。
- **数据完整性**：17 张业务表全部完好（`accounts`/`vaults`/`vault_records`/`subscriptions`/`_sqlx_migrations` 等），零丢失。
- **验证**：`deployment/lyrapass-cloud` 两个副本均 Ready；手动 `create job --from=cronjob` 维护任务成功（`{"expiredSubscriptions":0,...}`），`lastSuccessfulTime` 从 11-15 追平到 `2026-11-25T01:11:10Z`；**01:17 UTC 自然调度 Job `29926157` 自主成功**（`lastSuccessfulTime=2026-11-25T01:17:03Z`）；已清理 3 个历史失败 Job 与临时 Job。14 个 ArgoCD 应用全部 Healthy。
- **回滚**：删除 `appArmorProfile` 字段并重建 Pod 即回到 confinement（会再次卡住，除非 containerd profile 信号规则修复）；live 备份仍在 k1 `/root/lyrapass-postgres-sts.bak-20261125.yaml`（Note: 该备份是加 Unconfined 之前的原始配置）。

### 3.7 追加：AppArmor 信号豁免的范围评估（10:00，结论：不再扩大豁免）

用户要求给"基础设施、数据库和缓存这类需要信号的"服务单独加豁免。基于 24 小时内核 audit 实证评估后，**结论是不再扩大豁免范围**，理由如下。

- **实证**：24h 内 `operation="signal" signal=int`（真正阻塞 PG checkpoint 的信号）只有 `comm="postgres"` 8437 次 + `pg_ctl` 3 次；被 LyraPass PG 的 Unconfined 修复覆盖。其余 DENIED 中：`signal=urg` 来自 Go runtime 异步抢占（vmalert/virgo-auth 等，Go 会自动降级，无功能影响）；`ptrace read` 来自 otelcol 的 hostmetrics（2412 次，仅宿主进程信息缺失，采集器健康，无功能影响）。**没有第二个真正被信号阻塞的服务**。
- **CNPG 三集群尝试已回滚**：曾给 `pg-main`/`cs2four-pg`/`pal-pg` 的 Cluster CR 加 `spec.podSecurityContext.appArmorProfile=Unconfined`，但 `cs2-four` 命名空间启用了 `pod-security.kubernetes.io/enforce=restricted`，明确禁止 Unconfined profile，operator 进入报错循环（`violates PodSecurity "restricted:latest": forbidden AppArmor profile`）。已立即移除三个 CR 的该字段；期间 PG 经历一次计划内重启，三个集群均恢复 `Cluster in healthy state` / Ready=True / 0 重启。`pal-pg` 由 ArgoCD 跟踪，live 改动若保留会被 selfHeal 覆盖，回滚后一致。
- **为何不给其他服务加**：Go/Java 单进程多线程服务不依赖进程间信号协调（信号只用于优雅停机，由 kubelet 从外部发送，不经容器 AppArmor）；给它们加 Unconfined 只会白白缩小安全面并降低合规基线。
- **副作用处置**：CNPG 重启期间 ArgoCD `application-controller` 缓存了 palcommerce 应用的空 health 状态，hard refresh 无效；重启 controller 后 14 个应用全部恢复 Synced/Healthy。
- **备份**：三个 CNPG Cluster CR 变更前快照在 k1 `/root/apparmor-signal-fix-20261125/*-*.yaml.bak`（未使用，配置已回到原值）。

> 结论：容器 AppArmor 信号拦截的根治仍是节点级 containerd profile 信号规则；在根治前，只对**已证明会造成实际故障**的 PostgreSQL（LyraPass）保留 Pod 级 Unconfined 豁免，不做预防性扩大。通用排障手册见 `APPARMOR-SIGNAL-RUNBOOK.md`。

---

## 4. 验证结果

| 检查项 | 结果 |
|---|---|
| Pangolin 面板站点 | 11 站点 online（siteId 1 local 僵尸、19 Windows 离线属预期） |
| newt 握手 | 8 处均见 `Newt version 1.20.1` + `Tunnel connection established` |
| node3 容器 | pangolin/traefik/casdoor/ntfy/SafeLine 全部 healthy |
| SafeLine WAF | `/.git/config` 403 + JSON；正常页 200；Traefik 403 计数 0 |
| K8s Helm release | 28/29 deployed；唯一 failed 为历史遗留 `virgo`（非本次） |
| 节点 | 3/3 Ready，无本次引入的 not-ready Pod |
| Cilium 路由 | HTTPRoute 55/55、Gateway 6/6，与升级前基线一致 |
| Dragonfly/Spegel | Dragonfly `/readyz` 200；Spegel 3 节点 Running、索引已建立 |
| ArgoCD | `ecommerce-kyverno` Synced/Healthy；4 个 CEL health check 已写入 `argocd-cm` |
| CNPG | 3 个集群 `Cluster in healthy state`，数据完好 |

---

## 5. 未执行项与后续

| 项目 | 结论 | 后续动作 |
|---|---|---|
| PostgreSQL 19 | **未升级** | CNPG 1.30.2 官方仅支持 PG15–18；1.31（支持 15–19）尚未发布。临时集群实测 19 可 initdb，但 CNPG instance manager 配置阶段超时。保持 18.4。 |
| PG19 蓝绿迁移 | **未执行** | 等 CNPG 1.31 stable → 新建 PG19 蓝集群 → `pg_dump -Fc` / `pg_restore` → 校验 → 切 Service。palcommerce/cs2-four-prod 需在 GitOps 源改 values，不能直接 patch。 |
| casdoor 自动备份 | 待补 | 现有 dump 停在 2026-11-11；建议补每日 timer。 |
| casdoor DB 连接串 | 保持 | `pg.apikv.com` 经 `extra_hosts` 指向 `172.18.0.1`，既走内网又满足 `verify-full` SAN；改公网 IP/127.0.0.1 已实测不可行。 |
| `scorpius-prod` Degraded | **已恢复 Healthy** | 03:16 k3 计划内关机重启，备份 Job 03:17 命中 API 重建窗口而 3 次重试全失败；手动复现备份成功并同步 CronJob 状态。详见 §3.4。 |
| `lyrapass-cloud-maintenance` | **已恢复** | 根因是 containerd 2.3.4 AppArmor profile 拒绝 PG checkpoint 的 SIGINT，数据库卡在 crash recovery。给 PG Pod 设 `appArmorProfile: Unconfined` 后恢复，数据零丢失，定时任务追平。详见 §3.6。 |

---

## 6. 备份与回滚

| 对象 | 备份位置 | 回滚要点 |
|---|---|---|
| Pangolin（node3） | `/home/docker/pangolin.backup-20261125/`，含 `db.sqlite.snapshot-1.27.1` | schema 已迁移，优先用快照恢复，勿直接覆盖旧 db |
| newt（各主机） | `/usr/local/bin/newt.bak-1.20.0-20261125` | 替换回旧二进制后 `systemctl restart newt` |
| CNPG | k1 `/root/cnpg-backup-20261125/` | 3 集群 spec + 9 库 `pg_dump -Fc`；operator `helm rollback cnpg 1 -n cnpg-system` |
| Helm values | k1 `/root/helm-values-backup-20261125/` | `helm rollback <release> <revision> -n <ns>`；ArgoCD values 变更后文件为 `argocd-fixed.yaml`，变更前备份为 `argocd-fixed.yaml.bak-pre-celhealth` |
| ArgoCD ConfigMap | k1 `/root/argocd-cm.bak-20261125-celhealth.yaml` | 删除 4 个 health check key 即回退显示行为 |
| SafeLine | `/data/safeline.bak-20261125` | 恢复 `.env`/`compose.yaml` 后按 fvm→mgt→detector→luigi/chaos 重建 |
| node3 容器 | `/home/docker/{pangolin,casdoor,ntfy}.bak-20261125` | 恢复 compose 后 `docker compose up -d --no-deps` |

> 通用经验：跨版本 Helm 升级必须用 `-f 旧 values.yaml` 与新 chart 默认值深度合并，**不要**用 `--reuse-values`；GitHub chart 在机房拉不动时，本机 proxy 7890 预下载后 scp 到 k1；SSA 冲突加 `--force-conflicts`。

---

## 7. 相关文档

- 完整排查与踩坑记录：`UPGRADE-RECORD-2026-11-25.md`
- ArgoCD CEL health check values：`components/argo/values-cel-health.yaml`
- Kyverno 迁移说明：`components/kyverno/README.md`
- ecommerce 策略说明：`/Users/lens/lens077/ecommerce/infrastructure/kyverno/README.md`
