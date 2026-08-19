# PostgreSQL 的对外暴露（TLS passthrough + SNI 分流）

数据库实例是按需创建的（`examples/pg-cluster.yaml`），所以这里**不放会自动 apply 的清单**，
只给出模板与说明。要暴露时把下面的内容按实际实例名改好再 `kubectl apply`。

## 为什么是 TLS passthrough 而不是 TCPRoute

两种都能把 5432 送出去，区别在于：

| | TCPRoute | TLSRoute (Passthrough) |
|---|---|---|
| 路由依据 | 只有端口 | **SNI 主机名** |
| 一个端口能带几个后端 | 1 | 多个（按 SNI 分流 dev/prod/…） |
| 网关是否解密 | 不解密 | 不解密（passthrough） |
| 客户端要求 | 无 | 必须发 SNI（`sslmode=verify-full` + `host=` 域名） |

PostgreSQL 走 TLSRoute 的价值在于：**一个 IP + 一个 5432 端口，按域名区分多个数据库实例**。
只有一个实例、也不打算加的话，用 TCPRoute 更简单（参考
[dragonflydb/gateway/tcproute.yaml](../../dragonflydb/gateway/tcproute.yaml)）。

## 模板

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: pg-passthrough-gateway
  namespace: postgresql
spec:
  gatewayClassName: cilium
  # 不写 addresses：IP 由 Cilium 从 LB 池自动分配
  listeners:
    - name: pg
      port: 5432
      protocol: TLS        # 必须是 TLS，不是 TCP/HTTPS
      tls:
        mode: Passthrough  # 网关不解密，原样透传给 PostgreSQL
      allowedRoutes:
        kinds:
          - kind: TLSRoute
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1   # ⚠️ 不是 v1alpha2，见下
kind: TLSRoute
metadata:
  name: pg-main
  namespace: postgresql
spec:
  parentRefs:
    - name: pg-passthrough-gateway
      sectionName: pg
  hostnames:
    - "pg.dev.test"          # SNI 域名；换一个实例就换一个 hostname
  rules:
    - backendRefs:
        - name: pg-main-rw  # CNPG 生成的读写 Service
          port: 5432
```

## ⚠️ TLSRoute 必须用 v1

Gateway API v1.6 的 TLSRoute CRD **只 served v1**：

```
kubectl get crd tlsroutes.gateway.networking.k8s.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{"\n"}{end}'
# v1        served=true
# v1alpha2  served=false      ← 旧清单用的就是它
# v1alpha3  served=false
```

仓库里 `components/cert-manager/examples/public-web-gw-legacy/06-tls-route.yml` 等
旧文件仍是 `v1alpha2`，直接 apply 会失败。Cilium 文档也专门警告：
v1.20 之前用过 TLSRoute 的集群，要装 experimental 版 CRD，否则**存量记录 apiserver 读不出来**。

## ⚠️ 客户端必须用直接 TLS（sslnegotiation=direct）

实测（2026-08-18）：passthrough 网关的 Envoy listener 只认**第一个包就是 ClientHello**
的连接。PostgreSQL 传统协商（先发 8 字节明文 `SSLRequest`、等服务端回 `S` 再握手）
在这里握不了手——`openssl -starttls postgres` 和默认参数的 psql 都会失败。

- psql/libpq ≥17：连接串加 `sslnegotiation=direct`（PG 17+ 服务端接受直接握手）
- openssl 验证：**不要**加 `-starttls postgres`，直接 TLS 即可
- 老客户端（libpq <17、各语言老驱动）走不了这条路——要么升驱动，要么放弃 SNI 改用
  TCPRoute（一实例一端口）

同理，证书要过 `verify-full`，需在 Cluster CR 的 `spec.certificates.serverAltDNSNames`
里加上对外域名（CNPG 默认只签内部 Service DNS 名），见 `../examples/pg-cluster.yaml`。

## 验证

```bash
VIP=$(kubectl -n postgresql get gateway pg-passthrough-gateway -o jsonpath='{.status.addresses[0].value}')

# SNI 是否正确分流（看服务端返回的证书是不是这个实例的；注意没有 -starttls）
openssl s_client -connect $VIP:5432 -servername pg.dev.test </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName

# 真连一次（libpq ≥17）
PGPASSWORD=xxx psql "host=pg.dev.test hostaddr=$VIP dbname=app user=app \
  sslmode=verify-full sslnegotiation=direct sslrootcert=<pg-main-ca 的 ca.crt>" -c 'select 1'
```
