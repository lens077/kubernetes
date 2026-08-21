# 选型定稿栈部署验证记录 — 2026-08-20

> 依据 ecommerce 仓 `docs/TECH-RADAR.md`（三轮对抗定稿）在测试集群（node1/node2，arm64 4c6.5G ×2，K8s v1.36.3）落地并逐项验证。
> 新增组件全部按本仓组件契约写入 `components/`（component.env/install.sh/values.yaml/README/examples），开关已登记 `bootstrap/config.env` 尾部。
> 凭据落 `~/.local/state/k8s-installer/creds/`（Mac 执行时的 STATE_DIR 回退路径），不进 git。

## 部署与验证结果

| 组件 | Chart/版本 | 状态 | 验证证据 |
|---|---|---|---|
| NATS JetStream | nats/nats 2.14.5 | ✅ 3/3 | R3 stream 建立；pub/sub 收到 `ok`；杀 nats-0 后选主存活（Leader 迁移，stream info 正常） |
| VictoriaLogs 单机 | vm/victoria-logs-single 0.13.9 | ✅ | 近 1h 入库 29,556 行；LogsQL 查询正常 |
| Vector Agent | vector/vector 0.57.0 | ✅ 2/2 | **PII 端到端**：pod 打 `phone=13800138000` → VL 中为 `[PHONE_REDACTED]/[EMAIL_REDACTED]`；**反证**：原始手机号全库检索 0 命中 |
| ClickHouse 单节点 | 官方镜像 26.6（StatefulSet） | ✅ | `analytics.smoke` 建表/插入/查询通过；内存帽 1.2G/limit 1.5G |
| OpenFGA | openfga/openfga 0.3.12 | ✅ 2/2 | store→model→tuple→check 返回 `{"allowed":true}`；store=CNPG pg-main 独立库（DatabaseRole+Database CR） |
| OpenBao + ESO | openbao/openbao 0.29.2 | ✅ | init/unseal/kv-v2/eso-read 只读 token 全链路；ExternalSecret `Ready=True`，Secret 内容正确 |
| trust-manager | jetstack v0.24.0 | ✅ | 新建 ns 自动收到 `cm/global-root-ca`（源=cert-manager ns 的 `global-root-ca-secret`） |
| Kyverno | kyverno/kyverno 3.8.2 | ✅ | 两条 Audit 策略（requests-limits / no-latest）产出 PolicyReport；策略 `failurePolicy: Ignore` 防阻塞 |
| KEDA | kedacore/keda 2.20.2 | ✅ | cron scaler 实测 0→2 副本，HPA 自动生成 |
| Argo Rollouts | argo/argo-rollouts 2.41.1 | ✅ | 金丝雀两步 demo `phase=Healthy 2/2` |
| Spegel | oci spegel 0.7.4 | ✅ | **P2P 命中实证（2026-08-20 补验）**：同镜像 alpine:3.19.7 node1 首拉 8.811s（公网）→ node2 **102ms**（86×）；指标 `spegel_mirror_requests_total{cache="hit",registry="docker.io"} 1`、**TCR(`ccr.ccs.tencentyun.com`) 自然流量 hit=2**；libp2p resolve ≤5ms |
| ~~OpenKruise~~ | ~~1.9.1~~ | ❌ 已撤除 | 见「事故与裁决」 |

## 事故与裁决（重要）

1. **OpenKruise 撤除**：其全局 fail-closed pod mutating webhook（单副本 manager）在本环境成为集群级单点——manager 崩溃期间**全集群 Pod 创建被冻结**（openfga 迁移 job 卡死 10 分钟即此因），且形成「webhook 挡住自己新 pod」死锁。manager 崩因=200m CPU limit 下 leader lease 5s 续约超时（已修）+ 环境级冻结（见 2）。**裁决：ImagePullJob 收益 < 冻结风险，卸载；第 3 节点加入或 kruise 支持无 webhook 最小安装时再试**（官方兼容表也只到 1.32）。
2. **环境级根因——宿主 Mac 睡眠/暂停冻结客户机**：白天 KCM/scheduler 15-23 次重启风暴，PSI 显示无内存/IO 压力，etcd 日志存在 293s 时间戳断层与 node2 自发重启（uptime 544s），符合「VM 整机冻结→恢复后 lease 已过期→组件自杀重启」。**建议**：测试期间 `caffeinate` 或 pmset 关睡眠；这也是 4 天内控制面重启史的最可能解释。瞬态 RBAC 403（KCM 读自身 lease 被拒一次）记录在案未复现，RBAC 对象与 can-i 均正常。
3. **资源腾挪**：按 ecommerce TODO ⑬ 清理零引用残留（seata ns、cilium-test-1 ns、strimzi、tempo、集群内 minio）；ClickHouse 从 node2 控制面节点收紧（request 512Mi/limit 1.5Gi/server 帽 1.2G）。node2 内存 77%→48%。

## 已知事项 / 待办

- **Spegel 节点确认项——已消解（2026-08-20 补验）**：containerd 2.3.4 实测 `use_local_image_pull=false` 下 hosts.toml mirror 依然生效（P2P 命中实证），无需改节点配置；若未来 containerd 升级后命中掉 0，再查该开关（`components/spegel/README.md`）。
- **OpenBao 重启后需手工解封**：`components/openbao/examples/unseal.sh`（file 存储；init 材料在 creds/openbao-init）。测试期 1-share/1-threshold，生产化清单见其 README。
- **VL 直插小悬案**：`/insert/jsonline` 手工 curl 的行未检索到（生产路径 Vector→VL 已验证无碍）；接 SDK 前按官方示例复核 `_time` 格式与 Content-Type。
- ~~Vector `kubernetes_logs` 文件发现默认约 60s 间隔 + `read_from: end`：短命 pod 的最早几行会错过~~（✅ 2026-08-21 已修：cooldown 10s + `read_from: beginning`，与 VM 官方 log-collectors-benchmark 互证；功能级回归待新集群补验，手法见 vector README）。
- kyverno webhook 已排除 kube-system/argocd；audit 观察 14 天零误报再逐条 Enforce（enforce 前先做签名纪元处理，见 ecommerce 对抗第 3 轮 R3-C）。
- 第 3 台 VM（A9 预算内）加入后：NATS 反亲和自动摊开、Spegel 触发条件真正成立、CH/VL 可迁离控制面节点。
