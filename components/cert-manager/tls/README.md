在 Kubernetes 证书管理中，2 级颁发架构（Root CA -> Intermediate/Issuer -> End-Entity）
是工业级的标准做法。它能彻底解决你之前遇到的“自签名证书既当爹又当妈”导致的逻辑冲突（如 2121 年时间错乱、私钥不匹配等）

2. 为什么需要 2 级颁发？（作用）


| 维度   | 单级自签名               | 2 级颁发架构                         |
|------|---------------------|---------------------------------|
| 信任锚点 | 每个证书都是独立的，          | 需逐一信任只需信任唯一的 Root CA            |
| 安全性  | 根私钥直接暴露在业务 Secret 中 | 根私钥可离线/隔离，业务只接触中继 Issuer        |
| 容错性  | 修改域名需重签整条链，极易出错     | 根证书稳定，业务证书（Consul/Gateway）可灵活轮换 |
| 逻辑清晰 | 证书属性冲突（又是 CA 又是域名）  | 职责分离：Root 负责授权，End-Entity 负责加密  |

# 证书流转流程
1. 自签名工厂 (ClusterIssuer)：作为最初的“种子”，仅用于签发一个根证书。
2. 根证书 (Root CA)：它拥有 isCA: true 属性，是整个集群的最高信任源。
3. 命名空间颁发者 (Issuer)：它拿着根证书的“印章”，专门负责在 consul 命名空间内签发具体的业务证书。
4. 业务证书 (End-Entity)：给 consul.app.com 使用的最终证书。

# 操作步骤
第0步: 创建集群issuer, 仅需执行一次
```yaml
# global-ca-issuer.yml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: global-ca-issuer
spec:
  selfSigned: {}
```

第一步：创建 Root CA 种子由 global-ca-issuer 签发一个持久的根证书。
```yaml
# root-ca.yml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: <namespace>
spec:
  isCA: true # 声明它是 CA
  commonName: internal-root-ca
  secretName: root-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: global-ca-issuer
    kind: ClusterIssuer
```

第二步：创建中继颁发者 (Issuer)让 cert-manager 知道：以后凡是 <namespace> 空间内的证书，都用上面那个“根CA”来颁发。
```yaml
# issuer.yml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: internal-issuer
  namespace: <namespace>
spec:
  ca:
    secretName: root-ca-secret # 引用上面生成的 Secret

```
第三步：签发业务证书 (Gateway/<namespace> 使用)这是你真正配置在 HTTPRoute 或 TLSRoute 里的证书。
```yaml
# internal-issuer.yml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: internal-issuer
  namespace: <namespace>
spec:
  ca:
    secretName: root-ca-secret # 引用上面生成的 Secret

```

1. 清理与验证由于之前的集群环境可能已经“污染”了旧的 Secret:
```Bash
# 删除旧的业务证书和错误的根证书 Secret
kubectl delete secret -n <namespace> <secret-name> <root-ca-name>
```

2. 删除之前所有失败的申请单
```
kubectl delete certificaterequest -n <namespace> --all
```
3. 应用新配置
```shell
kubectl apply -f ./global-ca-issuer.yml -n <namespace>
kubectl apply -f ./root-ca.yml -n <namespace>
kubectl apply -f ./issuer.yml -n <namespace>
kubectl apply -f ./internal-issuer.yml -n <namespace>
```

验证时间戳（2026年 vs 2121年）：
```shell
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 2 "Validity"
```
