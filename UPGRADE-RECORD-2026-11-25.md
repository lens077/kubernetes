# 升级与排查记录 2026-11-25

> 操作窗口：2026-11-25 03:00–03:55 CST（凌晨低峰）
> 执行人：WorkBuddy + 用户确认（newt 配套版本 / PG 范围 / 升级方式三项决策）

## 0. 结论速览

| 任务 | 结果 |
|---|---|
| newt 客户端 → 1.20.1 | ✅ 8 个客户端全部完成，隧道握手 OK |
| pangolin 主控 → 1.27.1 | ✅ 迁移 1.26.0→1.27.0→1.27.1 成功，11 站点 online |
| CNPG operator → 1.30.2 | ✅ 已升级（中途处理了一次实例重启卡滞） |
| PG 18.4 → 19（3 集群） | ⚠️ **原地升级两次卡死，已回滚**，三集群恢复 18.4 healthy；见 §4 |
| 全服务最新版检查 | ✅ 清单见 §5 |
| casdoor 慢排查 | ✅ 当前实测不慢（0.15–0.2s）；已定位结构与隐患，见 §6 |
| node3 本地 PG 评估 | ✅ 现状已是本地 PG，给出优化建议，见 §7 |

---

## 1. 版本核实（关键事实）

- **pangolin 1.27.1** 真实存在（2026-11-20 发布），发布说明要求客户端必须是 2026-11-18 之后的版本。
- **newt 无 1.27.1** —— 独立版本线，配套最新是 **1.20.1**（2026-11-19）。故采用「主控 1.27.1 + newt 1.20.1」。
- gerbil 最新 1.6.0；Traefik 最新 v3.8.0；CNPG 最新 v1.30.2；PostgreSQL 19 于 2026-11-19 GA。

## 2. 备份（升级前，全部成功）

- node3：`/home/docker/pangolin.backup-20261125/`（546M，含完整 config），DB 一致性快照 `db.sqlite.snapshot-1.27.1`（447MB，用 `sqlite3.backup()`）。
- k8s：`/root/cnpg-backup-20261125/`（k1 上）— 3 个集群 spec yaml + operator deploy yaml + 9 个库的 `pg_dump -Fc`（最大 pal 504KB）。
- 每台 newt 主机：旧二进制备份为 `/usr/local/bin/newt.bak-1.20.0-20261125`。

## 3. 已完成的升级

### 3.1 newt 客户端 1.20.0 → 1.20.1（8 个）
主机级 7 台：node2 / node4 / node5 / node6 / k1 / k2 / k3（node1 已退役无 newt；node3 是主控自身不带 newt）。
k8s 内 1 个：`pangolin` ns 的 `newt` Deployment（`kubectl set image` + 三节点预拉镜像）。
判据：每台均见 `Newt version 1.20.1` + `Tunnel connection established successfully!`。

### 3.2 pangolin 主控 1.26.0 → 1.27.1（node3）
- `docker-compose.yml` 中 pangolin 镜像由 `:latest` 钉为 `fosrl/pangolin:1.27.1`（gerbil/traefik/crowdsec 保持 `:latest`，用 `--no-deps` 只重建 pangolin，未动其他容器）。
- 迁移日志：`Starting migrations from 1.26.0 → 1.27.0 → 1.27.1 → All migrations completed successfully`，无错误（仅既有的 SMTP 未配置警告）。
- 客户端自愈：抽查 node2/node4/k1/k2 均出现 `Server version: 1.27.1`，无需手动重启。
- 面板 11 站点 online（siteId 1=local 僵尸、19=Windows 长期离线，符合预期）。

### 3.3 CNPG operator 1.30.0 → 1.30.2（k8s）
- Helm：`helm upgrade cnpg cnpg/cloudnative-pg --version 0.29.2`（appVersion 1.30.2）。
- **踩坑**：升级触发实例管理器注入，pg-main / pal-pg 的 Pod 卡在 "Primary instance is being restarted without a switchover" 超过 100s（postgres readiness 500，instance-manager 仍是 1.30.0）。处理：`kubectl delete pod --grace-period=0 --force` 强制重建两个 Pod（PVC 复用、数据完好），重建后 instance-manager 全部 1.30.2，三集群 healthy。

## 4. ⚠️ PG 18.4 → 19 原地升级失败与回滚（重点）

### 现象
- 对 cs2four-pg / pg-main 下发 `imageName: ghcr.io/cloudnative-pg/postgresql:19-system-trixie`（镜像 tag 已验证存在，与原集群同为 trixie 基础，满足同 OS 系列要求）。
- operator 日志出现 `Reconciling in-place major version upgrades ... requestedMajor:19`，集群进入 `Upgrading Postgres major version`，但**始终不创建 `-major-upgrade` Job**。
- 卡住时 Pod 被设 `deletionTimestamp`（优雅关闭），postgres 卡在 `the database system is shutting down (SQLSTATE 57P03)` 无法退出，升级 job 无法启动。

### 根因判断
CNPG 1.30 的 **primary lease 机制 + 单实例集群 + 实例管理器原地更新** 组合下，operator 等待主实例优雅停库，但实例管理器卡在 shutting down 不退出 → 死锁。两次尝试均如此。
- cs2four-pg / pal-pg 另有 ArgoCD（`cs2-four-prod` / `palcommerce`，auto-sync + selfHeal）在 3s 内把 imageName 改回 18.4，属于第二层干扰。
- 这是 CNPG 1.30.x 的兼容性/机制问题，**不是数据问题**（每次强制删 Pod 后数据完好、库可正常查询）。

### 处置
- 强制删除卡住的 Pod + 回滚 imageName 到 18.4 → 三集群全部恢复 `Cluster in healthy state`，pg-main 8 个库、pal、cs2four 数据均完好。
- **当前状态：3 个集群均为 PostgreSQL 18.4-system-trixie + healthy。CNPG operator 已是 1.30.2（保留，无害）。**

### 后续 PG19 升级建议（本次未执行）
1. **蓝绿 dump/restore**（推荐，本项目数据量极小：最大库 16MB）：新建 PG19 集群 → `pg_dump -Fc` 导入 → 校验 → 切换应用连接串（Service 名）。可完全回退，不受 primary lease 卡滞影响。
   - 注意 cs2four-pg / pal-pg 由 ArgoCD 管理，必须改 GitLab 源 chart 的 `values.yaml`（palcommerce 在 `deploy/helm/palcommerce/values.yaml:67`），走 GitOps 同步，不要直接 patch。
2. 原地升级若要再试：先在每个集群上用独立测试集群复现，确认 CNPG 1.30.2 + primary lease 下 `-major-upgrade` Job 能被创建；或等待 CNPG 后续修复版本。
3. 升级前务必重新做逻辑备份（现有备份是 18.4 的，跨大版本 PITR 不可用）。

## 5. 全服务最新版检查（2026-11-25）

### 已升级到最新
- pangolin **1.27.1** ✅ / newt **1.20.1** ✅ / crowdsec **v1.8.2** ✅（:crowdsec:latest 实际就是最新版）

### node3 容器（`:latest` 标签，关注实际版本）
| 服务 | 当前 | 上游最新 | 建议 |
|---|---|---|---|
| traefik | 3.7.18 | **v3.8.0** | 可升，但涉及 vendored 插件（badger/crowdsec/safeline）兼容性，**需单独窗口+回归 WAF 链** |
| gerbil | 1.6.0（:latest） | 1.6.0 | 已最新 |
| casdoor | :latest | v4.30.0 | 用 latest 会自动跟进；当前连接本机 PG 正常 |
| ntfy | :latest | v2.38.2 | latest 自动跟进 |
| postgres | 18-alpine（实际 18.6） | 18.x / 19 GA | 本机库，见 §7 |
| safeline 全家桶 | 9.4.2 | 商业镜像，无公开版本对照 | 不动 |

### k8s 关键组件（普遍落后 1 个版本左右，均为重大基础设施，**本次不动**）
| 组件 | 当前 | 最新 |
|---|---|---|
| cilium | 1.20.1 | 1.20.5 |
| argocd | 3.5.3 | 3.6.3 |
| cert-manager | 1.21.2 | 1.21.3 |
| openfga | 1.21.0 | 1.23.0 |
| keda | 2.20.2 | 2.21.1 |
| gatus | 5.36.0 | 5.38.0 |
| dragonfly | 1.39.0 | 2.1（大版本） |
| elasticsearch | 9.4.5 | 9.5.7 |
| vector | 0.57.0 | 0.62.0 |
| otel-collector | 0.158.0 | 0.166.0 |
| redis (ecr) | 8.6.4 | 8.12.0 |
| umami | pinned digest | 3.5.0 |
| tetragon | 1.7.1 | 1.8.0 |
| external-secrets | 2.10.0 | chart 2.15.0 |
| healthchecks | 4.3 | 5.0.3 |
| strimzi kafka | 1.2.0 | 1.3.1 |
| openbao | 2.6.2 | 2.7.3 |
| spegel | pinned digest | 0.8.1 |
| kyverno | 1.19.1 | 1.20.0 |
| grafana | 13.2.2 | 13.3.2 |

> 说明：多数落后项属"次要版本/补丁"级别，不建议在本次窗口一并升级。业务镜像（ecommerce 1.8.1、cs2-four 1.5.1、scorpius 1.3.0、libra 0.8.0 等）由各自 GitOps 仓库管理，不在本次范围。

## 6. casdoor.apikv.com 响应慢排查

### 实测结论：当前不慢
- 从 Mac：首页/health/login/get-account/swagger 全部 **0.15–0.20s**（code 200）。
- 从 node3 本机 0.04–0.06s；从 k1 0.13s。
- xorm SQL 日志耗时普遍 1–2ms，无 >100ms 慢查询。

### 结构分析：casdoor 已走内网，DB 连接不是慢点
- casdoor 连接串：`host=pg.apikv.com port=52288 sslmode=verify-full`。
- ⚠️ **修正（2026-11-25 二次实测）**：早期判断"pg.apikv.com 解析到公网 IP 走公网回环"是**错的**。casdoor 容器内 `/etc/hosts` 有静态映射 `172.18.0.1 pg.apikv.com`，`compose.yml` 的 `extra_hosts` 早在 **2026-09-01 TLS 迁移时就配好了**（注释原文："域名用于 verify-full 校验 SAN，但解析到本网络网关走内网，容器无法 hairpin 到公网 IP"）。即流量一直走 docker bridge 网关，**DNS 零解析开销、不经过公网网卡**。
- 容器内实测 TCP 连通性（`nc -z`）：`172.18.0.1:52288` ✅ rc=0；`193.112.22.183:52288` ❌ rc=1（改公网 IP 会**直接断库**）；`172.19.0.2:5432` ❌ rc=1（casdoor 在 casdoor_default、postgres 在 postgres_default，跨 bridge 隔离）；`127.0.0.1:52288` ❌ rc=1（端口映射在宿主机不在容器内）。
- 证书是 `*.apikv.com`（ZeroSSL，SAN 无 IP），`sslmode=verify-full` 要求 host 匹配 SAN —— **改 IP 会导致证书校验失败**。结论：**当前连接串已是最佳解，勿改**。

### 隐患（可能导致间歇性慢，建议修）
1. **`socks5Proxy = "127.0.0.1:10808"`**（app.conf:14）但 **10808 无任何监听**。casdoor 配了 4 个 OAuth provider，第三方登录/回调用到出站 HTTP 时会尝试走这个死代理 → 可能超时数秒到数十秒，表现为"登录很慢"。修法：确认不需要代理则清空该值并重启 casdoor（需验证 OAuth 登录路径）。
2. **casdoor pg_dump 备份停在 2026-11-11**（`casdoor-20261111T183110Z.dump`，14 天未更新）。compose 里没有备份 timer，需补一个每日备份（可复用现有 dump 脚本 + cron/systemd timer）。
3. ~~连接串改 127.0.0.1 / 容器网络~~ **已证伪，勿改**：见上节实测，当前 extra_hosts 内网映射已是优化后的最优状态。

## 7. node3 本地 PG 方案评估

**结论：现状已经是"node3 自身部署 PG + casdoor/gorse 内网访问"，无需再迁移。**
- node3 本机 `postgres:18.6`（容器 `postgres:18-alpine`）含 `casdoor`(58 表)、`gorse`(3 表) 两个库，独立 volume `postgres_data` 持久化，TLS + pg_hba 已配，端口 52288（宿主随机化避开 NodePort 段）。
- 相比走 k8s CNPG 隧道（siteId=11），本地 PG 的查询延迟低一个数量级（本机回环 vs 隧道），这也是当前 casdoor 不慢的根本原因。

**待优化（非迁移，是加固）：**
1. 修死代理 socks5Proxy（见 §6.1）。
2. 补 casdoor/gorse 的自动备份（现有 dump 已 14 天未更新）。
3. ~~连接串改走容器网络/127.0.0.1~~ **不需要**：`extra_hosts` 已把域名静态映射到网关走内网且满足证书校验，见 §6 修正说明。
4. 若未来要求 casdoor 库高可用，可在 node3 加一个本机 PG 流复制从库（同机意义有限），或迁回 k8s CNPG 但用 Service 直连（前提是修好 §4 的升级卡滞并规划连接串切换）。

## 8. 回滚信息（如需）
- pangolin：compose 备份 `/home/docker/pangolin.backup-20261125/`，DB 快照同目录 `db.sqlite.snapshot-1.27.1`（schema 变更不建议直接覆盖回滚，优先用快照恢复）。
- newt：`/usr/local/bin/newt.bak-1.20.0-20261125`（每台），换回后 `systemctl restart newt`。
- CNPG：spec 备份 `/root/cnpg-backup-20261125/*-spec.yaml`，逻辑 dump 同目录；operator 回退 `helm rollback cnpg 1 -n cnpg-system`。
- PG：三集群当前即为 18.4 healthy，无需回滚。
- Helm values：全部备份在 k1 `/root/helm-values-backup-20261125/`（含各 release 的 values.yaml、helm-list.yaml、alertmanager-cm-before.yaml）；回滚用 `helm rollback <release> <上revision> -n <ns>`。

## 9. casdoor socks5Proxy 死代理修复（2026-11-25 追加）
- 背景：`app.conf:14 socks5Proxy = "127.0.0.1:10808"` 但宿主/容器均无 10808 监听。核实 4 个 provider（Alipay Payment / Resend Email / provider_balance / provider_captcha_default）的 `enable_proxy` **全为 `f`**，即该代理实际未被任何 provider 使用——原判断"OAuth 登录会走死代理变慢"不成立（且没有 OAuth provider）。
- 处置：备份 `app.conf.bak-socks5fix-20261125` 后把该行改为 `socks5Proxy = ""`，`docker restart casdoor`。验证 healthy、本地 API 200/0.06s、Mac 端 /login 200/0.21s。**属消除隐患，非修复实际故障**。

## 10. k8s 关键组件批量升级（2026-11-25 追加，cilium 最后单独处理）

### 升级方法论（踩坑总结）
- 跨版本升级**必须用 `-f 旧values.yaml`（与 chart 新默认值深度合并），不能用 `--reuse-values`**——后者用旧值整体替换默认值，新 chart 新增字段为 nil 导致模板渲染失败（external-secrets rbac.leaderElection、kyverno upgrade.legacyPolicyCheck、vl networkPolicy、argocd redis.tls/dex.storage、tetragon grpc.tls 全踩过）。
- GitHub 托管的 chart tgz 在机房拉不动（EOF）→ 用 `https://ghfast.top/https://github.com/...` 预下载到本地再 `helm upgrade -f chart.tgz`。
- server-side apply 冲突（kubectl-patch / argocd-controller 管理过字段）→ 加 `--force-conflicts`。
- 大组件（argocd/cilium）的 `--wait` 在 SSH 会话里易超时中断 → 用 background 执行并给足 timeout。

### ✅ 成功升级（15 个）
| 组件 | 从 | 到 |
|---|---|---|
| cert-manager | v1.21.2 | **v1.21.3** |
| external-secrets | 2.10.0 | **2.15.0** |
| argo-rollouts | 2.43.2 | **2.43.12** (app v1.10.2) |
| keda | 2.20.2 | **2.21.1** |
| vpa | 1.7.1 | **1.8.1** (chart 0.17.0) |
| openbao | v2.6.2 | **v2.7.3** |
| vl (victoria-logs) | v1.52.0 | **v1.54.0** |
| vm-single | v1.152.0 | **v1.157.0** |
| vmalert | v1.150.0 | **v1.157.0** |
| vt (victoria-traces) | v0.11.0 | **v0.13.0** |
| alertmanager | v0.34.0 | **v0.35.0** (chart 1.42→2.5.1，自定义 alert-bridge 路由保留) |
| vector | 0.57.0 | **0.62.0** |
| otel / otel-node | 0.158.0 | **0.165.0** (chart 0.183.2) |
| openfga | v1.21.0 | **v1.23.0** (chart 0.3.15→0.4.3，chart 从 GitHub release 下载) |
| **cilium（最后单独处理）** | **1.20.1** | **1.20.5** |

### ⛔ 尝试后回滚/跳过（6 个，均恢复健康旧版）
- **kyverno 3.9.1**：3.10.0 有破坏性变更——cluster 上 2 个 legacy policy（`require-requests-limits`、`ecommerce/ecommerce-image-provenance`）在新版**不再强制执行**，需先迁移到 CEL 才能升。强制升会使安全策略失效，故保留 3.9.1。
- **strimzi 1.2.0**：chart 1.3.1 但 values 无显式 image tag，新 operator Pod 仍用 `quay.io/strimzi/operator:1.2.0` CrashLoopBackOff → rollback（现 rev3/deployed）。需在 values 显式写 `image.tag=1.3.1` 再升。
- **tetragon 1.7.1**：1.8.0 的 Pod 卡在 "Waiting for required CRDs"（TracingPolicy schema 需更新）→ rollback 恢复。
- **argocd 3.5.3**：3.6.3 遇到 tini `Permission denied` + TLS 探针/--insecure 冲突，反复回滚卡住。最终用修正 values（去掉 `server.extraArgs: [--insecure]`）+ chart 10.9.2 恢复 deployed。**顺带修掉了历史上残留的 --insecure 配置漂移**。升 3.6 需单独窗口处理 TLS 探针。
- **grafana 13.2.2 (chart 13.2.5)**：当前 chart 版本比官方 repo 最新（10.5.15）还高，来源特殊，无法用常规 repo 升级 → 保留。
- **dragonfly v1.39.0 / spegel 0.7.4**：上游 release 不提供 Helm chart、chart repo 地址失效；dragonfly 1.x→2.x 还是大版本跳跃（持久化/配置可能不兼容）→ 保留，如需升级走镜像 tag 覆盖 + 单独测试。

### 已知遗留（与本次无关）
- `virgo` release 状态 `failed`（2026-11-22，ArgoCD 与 Helm 争抢 virgo Deployment 管理权），但 Pod 全部 Running/Ready，业务正常。自定义组件，不在本次范围。

### 最终验证
- 28/29 helm release deployed（唯一 failed 为历史遗留 virgo）；3/3 节点 Ready；无 not-ready Pod（仅历史 cdc-reconcile Job 失败）。
- cilium 升级后 HTTPRoute 55/55、Gateway 6/6 与基线一致（未触发 operator 重启后 HTTPRoute 不编程的已知问题），cilium health OK。
- casdoor healthy、登录页 200；node3 pangolin 1.27.1 healthy；站点全 online。

---

## 11. CNPG / PostgreSQL 19 评估 + 蓝绿迁移结论（暂缓）

### 支持矩阵核实
- 集群 CNPG operator **1.30.2**（chart 0.29.2，2026-11-25 03:36 升级），官方文档 `docs/1.30/supported_releases` 明确 **仅支持 PG 15–18**；1.30.2 release notes 将默认镜像升到 18.7-system-trixie。
- PostgreSQL **19.0 已于 2026-11-19 GA**。CNPG **1.31** 才把支持范围扩到 15–19（main 分支 `supported_releases.md` 已写 15–19），但截至 2026-11-25：GitHub releases 最新为 v1.30.2，ghcr.io/cloudnative-pg/cloudnative-pg 无 `1.31.*` tag → **1.31 尚未发布（预览 RC）**。

### 实测 PG19（临时集群，已清理）
- `ghcr.io/cloudnative-pg/postgresql:19-system-trixie`（及 19.0/19beta1/19rc1/19rc2 tag）在 ghcr 均存在（200）。
- 在临时 namespace `pg19-probe` 用最小 Cluster（`instances:1`、`openebs-lvm` 1Gi）跑 PG19：
  - initdb 阶段正常，`starting PostgreSQL 19.0 (Debian 19.0-2.pgdg13+1)`，`database system is ready to accept connections`；
  - 随后 CNPG 1.30.2 instance manager 在 "Configuring new instance" 阶段连接 `/controller/run/.s.PGSQL.5432` **超时**（`failed to receive message: timeout: context deadline exceeded`），CHECKPOINT 失败、`pg_ctl: could not send stop signal ... Permission denied`，initdb Job 连续 3 次 Error。
- 结论：**CNPG 1.30.2 无法完成 PG19 bootstrap**，不是镜像缺失而是 operator/instance manager 与 PG19 不兼容。临时集群与 namespace 已删除。

### 蓝绿 dump/restore 决策
- 用户要求流程：先确认 CNPG 支持再做蓝绿 dump/restore。**前置条件不成立** → 暂缓，不污染生产。
- 三个生产集群保持 `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`、均 healthy（pg-main 92MB / pal-pg 39MB / cs2four-pg 31MB）。
- 备份留存：k1 `/root/cnpg-backup-20261125/`（三集群 spec + `pg_dump -Fc`），可随时恢复。
- 后续路径：等 CNPG 1.31 稳定版发布 → 升 operator → 在同名 namespace 新建 PG19 蓝集群 → `pg_dump -Fc` 导出、`pg_restore` 导入 → 校验行数/对象数 → 切 `*-rw` 端点（注意 ArgoCD `palcommerce`/`cs2-four-prod` 的 selfHeal 会覆盖直接 patch，需在 GitOps 源改）→ 观察后删绿集群。

## 12. node3 边缘组件升级（traefik / casdoor / ntfy / SafeLine）

### 升级前备份
- `/home/docker/{pangolin,casdoor,ntfy}.bak-20261125`、`/data/safeline.bak-20261125`（整目录 cp -a）。

### 精确 tag 升级（均从 :latest 漂移锁到确定版本）
| 服务 | 原版本 | 新版本 | 验证 |
|---|---|---|---|
| traefik | 3.7.18 (`latest`) | **3.8.0**（2026-11-23 构建） | 插件 badger/crowdsec/safeline 全部加载，无错误；`--version` 确认 |
| casdoor | latest@11-10 (老旧) | **4.30.0** | healthy；`/login` 200 / 0.06s |
| ntfy | 2.37.2 (`latest`) | **v2.38.2** | healthy；`/v1/health` 200 / 0.03s |
- compose 改动：`pangolin/docker-compose.yml` → `traefik:3.8.0`；`casdoor/compose.yml` → `casbin/casdoor:4.30.0`；`ntfy/docker-compose.yml` → `binwiederhier/ntfy:v2.38.2`。
- 注意：`binwiederhier/ntfy` 的 tag **带 `v` 前缀**（`v2.38.2` 存在，`2.38.2` 不存在）。

### SafeLine 9.4.2 → 9.4.7
- 官方 `https://waf-ce.chaitin.cn/release/latest/version.json`：`latest_version`/`rec_version` 均为 **v9.4.7**（LTS v9.1.0-lts）。
- 所有 9.4.7 镜像在 Huawei SWR 镜像源可直接 pull（mgt/detector/luigi/fvm/chaos），`safeline-postgres:15.18` 不变（manager.py `POSTGRES_TARGET_VERSION` 仍是 15.18）。
- **未运行官方 upgrade.sh**：它会把 `compose.yaml` 改名并下载新版 `docker-compose.yaml`，丢掉本地关键定制（`pangolin_frontend` external 网络让 Traefik 插件连 detector:8000、mgt 管理页仅 127.0.0.1:9443、tengine profile disabled）。改为手工合并：
  - `.env` 新增 `DETECTOR_AES_KEY`(16位)、`DETECTOR_MGMT_TOKEN`/`MGT_INTERNAL_TOKEN`/`MGT_LICENSE_INTEGRITY_KEY`(各 32 字节 hex)、`DETECTOR_MGMT_AUTH=on`、`DETECTOR_UPDATE_VERIFY=on`，`IMAGE_TAG=9.4.7`（chmod 600）。
  - `compose.yaml`：mgt 的 `/var/run:/app/run` 改为 `${SAFELINE_DIR}/resources/run:/app/run`（新建目录）；mgt/detector/luigi/fvm/chaos 注入新版必需 env；保留本地网络和端口定制；`compose.override.yaml`（tengine disabled）不动。
  - 按 fvm→mgt→detector→luigi/chaos 顺序 `docker compose up -d --no-deps` 重建。
- 验证：mgt/detector healthy，`/api/open/health` `{"status":"ok"}`；攻击探测 `/.git/config` 返回 403 + SafeLine JSON（Gatus liveness 条件仍满足），正常页 200；Traefik access.log 近 2000 条 `DownstreamStatus:403` = 0（fail-open 未被触发）；启动期一次性 proxy/token 告警在 ~15s 内停止，无新增告警；三容器 DETECTOR_MGMT_TOKEN hash 一致。
- 回滚：恢复 `/data/safeline.bak-20261125`（含旧 `.env`/`compose.yaml`），`docker compose up -d --no-deps` 重建容器即可。

---

## 13. 跳过/回滚 6 项的二次攻坚（2026-11-25 08:00 全部解决）

用户提示"本机有 proxy 7890，可先在本机下载拉取好再上传"——全程用本机代理下载 chart/镜像，scp 到 k1 后 helm 升级。**6 项全部升级成功**。

### 13.1 strimzi 1.2.0 → 1.3.1 ✅
- 根因：旧 release user-supplied values 为 null，chart 1.3.1 虽默认 `defaultImageTag: 1.3.1`，但升级时 operator Pod 仍拉旧 tag 导致 CrashLoop。
- 修法：`printf "image:\n  tag: 1.3.1\n" > /tmp/strimzi-fix.yaml`，`helm upgrade strimzi ./strimzi.tgz -n kafka -f /tmp/strimzi-fix.yaml --force-conflicts`。
- chart 从 GitHub release 下载（`strimzi-kafka-operator-helm-3-chart-1.3.1.tgz`，repo index 的 url 字段）；直接拼 repo 路径 404。
- 验证：新 operator `quay.io/strimzi/operator:1.3.1` Running，Kafka CR `my-cluster` READY=True，consumer topics 正常列出。启动期一次 liveness 超时（拉镜像慢）自行恢复。

### 13.2 grafana 13.2.2 → 13.3.2（chart 13.2.5 → 14.5.1）✅
- 根因：**查错 repo**——之前查官方 `grafana/helm-charts`（最新仅 10.5.15），实际 release annotation 指向 `grafana-community/helm-charts`（`https://grafana-community.github.io/helm-charts/`），其 chart 14.5.1 = app 13.3.2。
- chart 从 GitHub release 下载。`helm template -f 旧 values` 通过（grafana.ini 等自定义保留），`helm upgrade --force-conflicts`。
- 验证：`/api/health` 200 且 `version=13.3.2`、login 200。Pod 首次拉 508MB 镜像耗时 ~83s，readiness 告警自行恢复。

### 13.3 tetragon 1.7.1 → 1.8.0 ✅（踩坑最多）
三个独立问题逐个解决：
1. **CRD schema 卡住**：上次失败遗留 CRD annotation `cilium.io.k8s.crd.schema.version=1.8.23`，operator 默认 `forceUpdateCRDs=false` 不刷新 → 用 `tetragonOperator.forceUpdateCRDs=true`（保留 `crds.installMethod=operator`，避免 helm 模式与 operator 争所有权）。CRD 备份在 k1 `/root/tetragon-crd-backup-20261125/`。
2. **OOMKilled**：1.8.0 内存占用更高，原 limits 250Mi 不够 → 提到 `512Mi`/requests `256Mi`。
3. **startup probe NOT_SERVING**：k3 启动慢，默认 grpc startup probe timeout 60s / failureThreshold 3 太严 → 覆盖 `startupProbe: {timeoutSeconds: 60, failureThreshold: 10, periodSeconds: 15, grpc: {port: 6789, service: startup}}`。
- ⚠️ 中间试过官方升级说明推荐的 exec `tetra status` probe，失败（容器被 OOM kill 后 exec 报 container not found），已回退到 grpc probe。
- 最终：3 节点 agent 全部 2/2 Running、0 重启，无 CRD 等待错误。chart 从 `https://helm.cilium.io/tetragon-1.8.0.tgz` 下载。

### 13.4 argocd 3.5.3 → 3.6.3（chart 10.9.2 → 10.19.1）✅
- 根因复查：新 chart 10.19.1 **已无 tini initContainer**（改镜像内置 entrypoint），旧的 tini Permission denied 是旧 chart 残留；`--insecure` 漂移上次已清（用 `argocd-fixed.yaml`，其 `server.extraArgs: []`）。渲染中 4 处 insecure 只是 chart 默认 env 的可选 configmap key（`otlp.insecure`/`server.insecure`），非 `--insecure` 参数。
- `helm upgrade argocd ./argocd.tgz -n argocd -f /root/helm-values-backup-20261125/argocd-fixed.yaml --force-conflicts`。
- 验证：7 组件全 1/1 Running 无权限错误；外部 UI 200 / API 401（需认证，正常）；镜像 v3.6.3。

### 13.5 kyverno 1.19.1 → 1.20.0（chart 3.9.1 → 3.10.0）✅
- **1.20 彻底删除 legacy `kyverno.io` 引擎**：旧 ClusterPolicy/Policy 不再被 admission/background/reports 执行（多个 PR：#18164/#18187/#18195/#18265）。必须先迁 CEL 并越过 Helm gate。
- **镜像**：TCR 原本没有 1.20.0 镜像。本机 `open -a Docker` 启动 Desktop（29.9.3），`docker login ccr.ccs.tencentyun.com` 已配好，逐个 `docker pull --platform linux/amd64 reg.kyverno.io/kyverno/<img>:v1.20.0` → tag → push 到 `ccr.ccs.tencentyun.com/sumery/<img>:v1.20.0`（6 个：kyverno/kyvernopre/background-controller/cleanup-controller/reports-controller/kyverno-cli）。节点 crictl pull 验证 OK。
- **3 条 legacy → CEL**（全部 Audit 语义，均经 `kubectl apply --dry-run=server` 验证）：
  - `disallow-latest-tag` → `policies.kyverno.io/v1 ValidatingPolicy`（用 `object.spec.?containers...map(c,c.image)`；⚠️ `images.*` 变量是 ImageValidatingPolicy 专用，ValidatingPolicy 里用会编译失败）
  - `require-requests-limits` → ValidatingPolicy（CEL `has(c.resources.requests.cpu)...`）
  - `ecommerce-image-provenance` → `NamespacedImageValidatingPolicy`（keyless cosign：`attestors[].cosign.keyless.identities[].subjectRegExp/issuer` + `ctlog.url` + `verifyImageSignatures(image,[attestors.github])`，保留原 identity/rekor，Audit + mutateDigest=false）
  - 官方参考示例：`kyverno/policies` 仓 `other-ivpol/verify-cosign-keyless`（minversion 1.20.0）
- **GitOps 源已同步**：ecommerce 仓 `infrastructure/kyverno/policies/ecommerce-image-provenance.yaml` 改为 CEL 版并提交推 GitLab main（commit `0fd81fc5`）；kubernetes 仓 `components/kyverno/examples/policies-audit.yaml` 改为两条 CEL VP（commit `5269927`），README 补迁移说明（`ec9af33`）。
- **Helm gate**：正确参数是 `upgrade.acknowledgeLegacyPoliciesNotEnforced=true`（不是顶层 `acknowledgeLegacyPoliciesNotEnforced`）。
- 验证：4 控制器 + migrate Job 全健康；3 条 CEL policy 全 READY=true；冒烟测试（nginx:latest 无 limits Pod）被 Audit 放行且 PolicyReport 记录 2 条 fail。legacy Policy 对象被 1.20 标记 `policy is not enforced`（预期，已由 CEL 接管）；手动删掉 legacy Policy + 给 NIVPOL 打 ArgoCD tracking-id。ArgoCD App 显示 OutOfSync/Degraded 是 3.6 对 CEL policy 新 GVK 缺内置 health check 的显示局限，策略本体 READY 且生效。

### 13.6 dragonfly 1.39.0 → 1.40.1 + spegel 0.7.4 → 0.8.1 ✅
- **chart 来源纠偏**：dragonfly 是 dragonflydb（Redis 兼容），不是 dragonflyoss（P2P）。官方 chart 在 GitHub `contrib/charts/dragonfly` 且发布为 **OCI** `oci://ghcr.io/dragonflydb/dragonfly/helm/dragonfly`（之前"无 chart repo"是只查了传统 repo）。本机代理 `helm pull --version v1.40.1` 后 scp 到 k1。
- **保守选版**：OCI tags 只到 v1.40.1（2.x chart 未发到 ghcr），且 1.x→2.x 是大版本跳跃 → 选 v1.40.1 同线小版本升级，不做大跳。镜像 `docker.dragonflydb.io/...:v1.40.1` 节点可直拉。
- 验证：StatefulSet `dragonfly-0` Running，PVC `dragonfly-data-dragonfly-0` 63d 老卷复用（数据保留）。⚠️ 该实例启用 TLS，普通 `redis-cli` 连不上（Bad TLS header），验证要用 `--tls`；redis-cli 6.0.16 不支持 `--insecure`。消费者 `control-tower-gateway` 重连后无 Redis 错误，边缘 `/readyz` `/healthz` 200。
- spegel：`oci://ghcr.io/spegel-org/helm-charts/spegel:0.8.1`（ArtifactHub 确认），本机代理 pull 后上传。镜像为 pinned digest `sha256:bdc1d14e...`（0.8.1），节点可拉。3 节点 DaemonSet 全 Running；启动期 libp2p bootstrap 错误在 ~90s 内收敛归零；`spegel_advertised_keys=2496` 说明镜像索引已建立。
