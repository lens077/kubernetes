# external-secrets —— ESO(OpenBao → k8s Secret,GitOps L3)

## 1. 定位

把密钥的真相源从「明文 YAML / 脚本」挪到凭据后端。Git 里只放引用(ExternalSecret CR),ESO 把后端的值
物化成普通 k8s Secret —— 现有 chart 的 `envFrom`/`secretKeyRef` 零改动。

**后端定稿(2026-09-11 复审维持 ecommerce TECH-RADAR §4.9)**:集群内 **OpenBao**(`components/openbao`,
`ClusterSecretStore openbao`,路径 `k8s/<CLUSTER_NAME>/<组件>`),`config.env` 的 `ESO_STORE="openbao"`。
OpenBao 是 Vault 的 MPL-2.0 分叉、Linux Foundation 治理,API/引擎与 Vault 相同;本集群用到的
KV v2 + token auth 两边无差别,选型差别只在许可与治理。

VPS 上的 HashiCorp Vault(`https://vault.apikv.com`,docker-deploy 仓 `vault/`)是 08-17 的早期接线,
现在**只作可选的集群外副本**:注入 AppRole 凭据(`VAULT_ROLE_ID/VAULT_SECRET_ID`)时才建
`ClusterSecretStore vault`,否则 install.sh 不建、并删掉残留的死接线。

**集群重装后**:OpenBao 数据随集群亡(本地 PVC),用 `tools/openbao-seed.sh` 从现网(集群 Secret 现值、
Config Center 现值)反向重建,再跑 `components/_external/apply.sh` 与各组件 install.sh;手顺见
`tools/config-center/README.md`。想要「重装后密码不变」需要集群外副本(Velero 10.3 条款③已触发,待做)。

## 2. 上游最佳实践

来源: [ESO 文档](https://external-secrets.io/)

- Vault provider 用 KV v2;`ClusterSecretStore` 免去每命名空间重复定义。
- AppRole 凭据放 Secret,经 `roleRef`/`secretRef` 引用,不写进 CR。
- `refreshInterval` 决定 Vault 侧改值的传播时延;物化后 **Pod 不会自动重启**
  (需要热更新的话配 stakater/reloader 一类注解,或接受手动 rollout)。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| kubernetes auth(Vault 回连 apiserver 验证 SA token) | **AppRole** | 集群在 LAN 内,公网 Vault 反向够不着;AppRole 纯出站,方向与 newt 隧道哲学一致 |
| 每 ns 一个 SecretStore | ClusterSecretStore ×1 | 单人单集群,少一层重复 |
| ghcr.io 官方镜像 | **直连 ghcr.io**(2026-08-17 实测节点可达) | 当日 `*.nju.edu.cn` 镜像站整站故障;「LAN 拉 ghcr 必须代理」的旧结论不恒成立。再遇拉取超时按 values.yaml 注释降级:①NJU mirror ②经 Mac 转推 TCR |
| ESO 配 caProvider 信自签 CA | 系统 CA / 集群内 http | OpenBao 走集群内 `http://openbao.openbao.svc:8200`(TLS listener 在其生产化清单里);VPS Vault 是公共可信泛证书(acme.sh) |
| 凭据进 values/Git | **不入库**:install.sh 从环境变量写 Secret `vault-approle` | secret zero 只存在于 VPS(`approle-eso.json`)与集群内 |

## 4. 暴露方式

无(它只出站访问 Vault)。

## 5. 验证

```bash
kubectl get clustersecretstore vault                        # READY True
kubectl apply -f components/external-secrets/examples/externalsecret-demo.yaml
kubectl -n external-secrets get externalsecret demo-hello   # STATUS SecretSynced
kubectl -n external-secrets get secret demo-hello \
  -o jsonpath='{.data.hello}' | base64 -d                   # world
```

## 6. 踩坑

- **webhook 刚起时 apply ESO 的 CR 会报 TLS 握手失败** —— install.sh 已带 retry;手工操作等十几秒再试。
- ClusterSecretStore 里的 `roleRef`/`secretRef` **必须显式写 namespace**(cluster 级资源没有默认 ns)。
- **Vault 重启后回到 sealed,ESO 会持续同步失败** —— 这不是集群侧故障,先去 VPS 跑 `vault/unseal.sh`。
- 轮换 secret_id 只需更新 Secret `vault-approle`,store 下个刷新周期自动恢复。
- KV v2 下 ExternalSecret 的 `key: demo` 实际读 `secret/data/demo`,策略也要按 data/ 路径授权。
