# gateway —— 共享 L7 入口与全仓路由约定

> 这一份是**全仓的路由规范**。加新组件、写 HTTPRoute 之前先看这里。

## 1. 定位

`default/cilium-gateway` 是集群唯一的 L7 入口：80 端口重定向、443 端口终结 TLS，
所有 HTTP 组件的 HTTPRoute 都挂在它上面。证书是一张 `*.${CLUSTER_DOMAIN}` 泛域名证书，
由 [cert-manager](../cert-manager/) 的 `global-ca-issuer` 签发。

Gateway 本身没有工作负载——数据面是 Cilium 内置的 Envoy。

## 2. 上游最佳实践

来源：[Cilium Gateway API 文档](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)

Cilium 1.20 通过 Core 一致性测试的资源（**含 TCPRoute/UDPRoute**）：

| 资源 | 状态 | 备注 |
|---|---|---|
| GatewayClass / Gateway | ✅ | `gatewayClassName: cilium` |
| HTTPRoute | ✅ | L7 路由主力 |
| GRPCRoute | ✅ | gRPC 服务（OTLP、Jaeger collector） |
| TLSRoute | ✅ | SNI 分流 + Passthrough，L4 组件靠它 |
| BackendTLSPolicy / ReferenceGrant | ✅ | 后者用于**跨命名空间 backendRef** |
| ListenerSet / TCPRoute / UDPRoute | ✅ 但需 CRD | **CRD 不装 Cilium 就关掉该功能**，且不报错 |

前置条件：`kubeProxyReplacement=true`（本集群满足）、`l7Proxy=true`（默认开）。

## 3. 本集群取舍

| 上游/旧清单 | 本集群 | 原因 |
|---|---|---|
| Gateway 写死 `addresses: 192.168.3.110` | **不写 addresses** | 让 Cilium 从 `CiliumLoadBalancerIPPool`（`192.168.3.100-199`）自动分配。写死 IP 一旦与池冲突或换网段就得改一堆文件。查分配结果：`kubectl -n default get gateway cilium-gateway -o wide` |
| 每个组件一个自己的 Gateway | **共享一个** | 旧清单里有 `meilisearch-gateway`、`observability-web-gateway`、`dragonfly-gateway` 三套并存，每套占一个 LB IP、各自签证书。合并成一个之后：一个 IP、一张泛域名证书，加组件只写 HTTPRoute。 |
| Terminate 与 Passthrough 放同一个 Gateway | **拆开** | 旧的 `05-public-web-terminate-gateway.yml` 里同时有 `https:443 (HTTPS/Terminate)` 和 `tls:443 (TLS/Passthrough)` —— 同一 Gateway 里两个 listener 抢同一端口不同协议是非法的，Gateway 会 Programmed=False。共享网关只做 Terminate；Passthrough 场景由 L4 组件各自的 Gateway 用**自己的端口**承担。 |
| TLSRoute `v1alpha2` | **`v1`** | Gateway API v1.6 的 TLSRoute CRD **只 served v1**（`v1alpha2 served=false`）。旧清单里的 `apiVersion: gateway.networking.k8s.io/v1alpha2` 直接 apply 会失败。 |
| 叶子证书跟随根证书长周期 | 90 天 + 提前 15 天续期 | 泛域名叶子证书轮换不影响客户端信任链（客户端信的是根 CA），短周期更稳妥。 |

## 4. 怎么给一个组件加暴露

**选择树**：

```
是 HTTP/HTTPS 吗？
├─ 是 → HTTPRoute 挂 default/cilium-gateway（80 重定向 + 443 业务）  ← 绝大多数组件
├─ 是 gRPC → GRPCRoute，同一个共享网关
└─ 否（TCP）
   ├─ 后端自己有 TLS，要按 SNI 分流 → 独立 Gateway（TLS/Passthrough）+ TLSRoute v1
   ├─ 纯 TCP 明文 → 独立 Gateway（TCP protocol）+ TCPRoute
   └─ 客户端要拿 advertised address（Kafka）→ 别走网关，用 LoadBalancer Service
```

HTTP 组件的标准写法见 [`_template/gateway/httproute.yaml`](../_template/gateway/httproute.yaml)：
两个 HTTPRoute（一个 80→443 重定向、一个业务），`parentRefs` 指到 `default/cilium-gateway`
并写明 `sectionName`（`http` / `https`）。路由放在**组件自己的命名空间**里，
共享网关的 `allowedRoutes.namespaces.from: All` 已经放行。

跨命名空间的 `backendRefs`（路由在 A、Service 在 B）需要在 B 里建 `ReferenceGrant`。
同命名空间不需要——这是最常被误解的一点：`from: All` 管的是**路由能否挂网关**，
ReferenceGrant 管的是**路由能否引用别的命名空间的 Service**。

## 5. 验证

```bash
kubectl -n default get gateway cilium-gateway -o wide        # PROGRAMMED=True，ADDRESS 是池里的 IP
kubectl -n default get certificate global-default-tls-cert   # READY=True
```

真验证（**从局域网其他主机**执行；L2 通告的 VIP 节点自访不通是已知行为）：

```bash
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk -o /dev/null -w "%{http_code}\n" https://$GW/ -H "Host: probe.app.com"   # 无路由时 404 = 网关活着
echo | openssl s_client -connect $GW:443 -servername probe.app.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# 期望: subject=O=sumery-mesh-org, CN=app.com / issuer=CN=my-global-root-ca
```

## 6. 踩坑

- **HTTPRoute 显示 Accepted 但访问 404**：多半是 `sectionName` 写错，或 hostname 与证书的
  泛域名不匹配。`kubectl -n <ns> describe httproute <name>` 看 `parents[].conditions`。
- **Gateway 一直 Programmed=False**：先看 listener 冲突（同端口不同协议），再看
  `certificateRefs` 指的 Secret 是否存在（cert-manager 还没签出时就是不存在）。
- **TLSRoute apply 报 no matches for kind**：用了 `v1alpha2`。改 `v1`。
- **想用 TCPRoute 但不生效、也没有报错**：TCPRoute CRD 没装的话 Cilium 会**静默关掉**
  该功能。`kubectl get crd tcproutes.gateway.networking.k8s.io` 确认（本集群 v1.6.1
  的 `standard-install.yaml` 已经带上了全部 10 个 CRD）。
- **GRPCRoute 显示 Accepted，客户端却连不上**：gRPC 要经 HTTPS listener 就得靠 ALPN 协商
  h2，而 Cilium 默认 `enable-gateway-api-alpn=false`。开启：`bootstrap/config.env` 里
  `CILIUM_GATEWAY_API_ALPN="true"` 后重跑 `--only 60-cilium`。
  确认：`kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-gateway-api-alpn}'`。
  （旧集群那条 55 天从未生效的 jaeger GRPCRoute，根因之一就是它。）
- **节点上 curl VIP 不通**：L2 通告的 ARP 只应答外部主机，节点自访不走该路径，属已知行为。
