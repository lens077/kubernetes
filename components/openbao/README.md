# OpenBao（+ ESO 接线）

**定位**：专职凭据后端（TECH-RADAR §4 定稿：ESO+OpenBao；LF 治理，替 BSL 的 Vault）。次序纪律=治理修订(AGENTS.md 硬规则4)合入前，业务凭据不迁入，本部署仅验证链路。
**上游**：openbao/openbao chart 0.29.2 / app v2.6.2（实测 2026-08-20，arm64 有）。
**本集群取舍**：standalone+file 单副本（raft 的价值在多副本 HA，测试不引）；init 1-share/1-threshold（**测试取舍**，生产应提高并离线保管）；init 输出与 ESO token 落 STATE_DIR/creds 不进 git；ESO 用 eso-read 只读 token（root token 只用于初始化）；**pod 重启后需手工解封** `examples/unseal.sh`。
**验证**：`kubectl -n default get externalsecret demo-from-openbao`（Ready=True）+ `kubectl -n default get secret demo-from-openbao -o jsonpath='{.data.username}' | base64 -d` = demo。
**生产化清单**：TLS listener（挂 global-ca-issuer 证书）、kubernetes auth 替 token、auto-unseal、审计日志。

## 2026-09-22 现状：业务凭据已迁入，剩 auto-unseal 一个决策

治理修订已合入，`tools/openbao-seed.sh dragonfly grafana healthchecks` 取集群现值播种到 `k8s/hosting/<组件>`，
三个组件 `install.sh` 重跑后走 `cred_via_eso`：Secret 归属 `ExternalSecret`、值哈希前后一致、`SecretSynced`。
`bugsink` 未部署没播；外部依赖（casdoor/postgres-node3/elasticsearch-node3）要 Config Center 可达才能反向抽取。

- `eso-push` 策略原来少了 `secret/metadata/.../ca/*` 的 `create,update`，PushSecret 写 CA 会 403；install.sh 已补。
- seed 脚本的 `bao status` 检查偶发抖动会误报 sealed（2026-09-22 一次），重跑即可；真 sealed 看 Gatus `openbao-unsealed`。

### 重启即 sealed —— 待决策

shamir + file 的 standalone，Pod 重启后**一定** sealed；ESO 立刻 `SecretSyncedError`，组件退回 `get_cred`。
Gatus 探针 `cluster-origin/openbao-unsealed`（`/v1/sys/health` 非 200 即告警）已加，恢复 = `bash examples/unseal.sh`。

| 选项 | 做法 | 代价 |
|---|---|---|
| A. `seal "static"`（OpenBao ≥2.1，2.6 可用） | 32 字节密钥放 K8s Secret 挂进 Pod，`seal "static" { current_key = "file://..." }`，做一次 `bao operator unseal -migrate` | 解封密钥与数据 PVC 同一 K8s 信任域；能读该 Secret + PVC 的人 = 能打开库。上游文档明说「只在已有第三方信任源时推荐」 |
| B. transit auto-unseal | VPS Vault 做 transit 引擎 | 外部依赖；AppRole 凭据当前没有（TECH-RADAR §4.9 把 VPS Vault 定为可选副本） |
| C. 保持手动 | 探针告警 → 人跑 unseal.sh | 每次重启一段窗口内新 Pod 拿不到凭据；现有 Pod 不受影响（Secret 已在集群里） |

C 是现状；A 最省事但是信任模型的取舍——由人拍板，不在自动轮次里做 seal migration。
