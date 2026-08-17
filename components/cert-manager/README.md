# cert-manager —— 集群统一证书签发

## 1. 定位

给集群里所有 HTTPS/TLS 端点签证书。本集群没有公网域名，走**自签根 CA**：
`selfsigned` 引导 → 根证书 `global-root-ca` → 集群统一签发者 `global-ca-issuer`。

依赖它的组件：[gateway](../gateway/)（共享网关的泛域名证书）、所有走 HTTPS 的组件路由、
PostgreSQL / Dragonfly 的 TLS passthrough 证书。

## 2. 上游最佳实践

来源：[cert-manager 文档](https://cert-manager.io/docs/)

- CRD 与 controller 同版本安装（`crds.enabled: true`），避免升级时 CRD 落后。
- 生产环境用 ACME（Let's Encrypt）签公网域名；内网/私有 PKI 用 CA Issuer。
- **Gateway API 支持默认关闭**，必须显式开 `enableGatewayAPI: true`，否则 Gateway 上的
  `cert-manager.io/cluster-issuer` 注解会被**静默忽略**。
- ACME HTTP-01 挑战在 Gateway API 下用 `gatewayHTTPRoute` solver（见 `examples/`）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| ACME/Let's Encrypt | 自签根 CA | 没有公网域名，全部服务跑在 `*.app.com` 内网域名下。要换公网域名时把 `examples/acme-letsencrypt.yaml` 里的 ClusterIssuer 换上去即可，下游组件引用的 issuer 名不变。 |
| 引导 issuer 与最终 issuer 同名（旧方案） | **拆成两个名字** | 同名时只有「分步 apply」才成立：一次性 apply 的话，第三步立刻覆盖引导定义，而根证书还没签出 → 证书等 issuer、issuer 等证书，**死锁**。拆开后 `kubectl apply -f issuers/` 一次搞定。 |
| 各 Deployment 默认副本 | 全部 1 副本 | 单控制面集群，多副本只是抢内存。 |
| 根证书默认 90 天 | 10 年（`87600h`） | 内网根证书换一次要重新分发信任链到所有客户端，代价远大于收益。**叶子证书**仍是 90 天 + 提前 15 天自动续期（见 gateway 组件）。 |
| RSA 2048 | ECDSA P-256 | 内网网关场景握手更轻，Cilium Envoy 与所有现代客户端都支持。 |

## 4. 暴露方式

不对外暴露。

客户端信任这套证书（浏览器/curl 不再报警告）：

```bash
kubectl -n cert-manager get secret global-root-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > global-root-ca.crt
# macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain global-root-ca.crt
```

## 5. 验证

```bash
kubectl get clusterissuer                     # selfsigned / global-ca-issuer 都应 READY=True
kubectl -n cert-manager get certificate       # global-root-ca READY=True
```

真验证（证明**能签**，而不只是 issuer 状态好看）——签一张一次性证书再删掉：

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: probe, namespace: default}
spec:
  secretName: probe-tls
  commonName: probe.app.com
  dnsNames: ["probe.app.com"]
  issuerRef: {name: global-ca-issuer, kind: ClusterIssuer}
EOF
kubectl -n default wait --for=condition=Ready certificate/probe --timeout=60s
kubectl -n default get secret probe-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
kubectl -n default delete certificate probe && kubectl -n default delete secret probe-tls
```

## 6. 踩坑

- **Gateway 上的注解没反应、证书不生成、也没有任何报错**：`enableGatewayAPI` 没开。
  这是静默失效，只能靠 `kubectl -n cert-manager get cm cert-manager -o yaml` 确认配置里有这项。
- **刚装完就 apply Issuer 被拒**（`failed calling webhook`）：webhook 还没就绪。
  install.sh 里已经 `rollout status deploy/cert-manager-webhook` 等过，手动操作时也要等。
- **下游证书一直 Pending**：先看根证书。`kubectl -n cert-manager describe certificate global-root-ca`，
  多半是引导 issuer 被覆盖（见第 3 节的死锁）。
