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
| Gateway 写死环境 IP | **只写配置变量 `${CILIUM_GATEWAY_LB_IP}`** | VIP 在 `config.env` 单一入口；`gateway-pool` 以 Service 元数据 selector 让它独占 `/32`，Pangolin/newt target 不随重建漂移。内网 `.120`、机房 `10.10.31.240`；preflight 强制它与 default-pool 分离 |
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

真验证分两种池：

- 内网版/机房专属同网段 VIP：从局域网其他主机访问，同时看 ARP 邻居；节点自访不是 L2 路径，只作加分项。
- 机房当前的跨网段集群内 VIP (`10.10.31.240`)：在 newt Pod 内访问，证明 Pangolin 实际路径能到；
  同 VLAN 外部主机**本来就不应直达**，因为它不会为跨网段地址发 ARP。

```bash
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
# 期望等于 config.env 的 CILIUM_GATEWAY_LB_IP
kubectl -n pangolin exec deploy/newt -- wget -qO- --no-check-certificate \
  --header='Host: probe.dev.test' "https://$GW/"            # 无匹配路由时 404 = Envoy 活着
# 有真实 HTTPRoute 后用它的 Host，期望业务状态码而非 404
kubectl -n pangolin exec deploy/newt -- wget -qO- --no-check-certificate \
  --header='Host: grafana.dev.test' "https://$GW/api/health"
echo | openssl s_client -connect $GW:443 -servername probe.dev.test 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# 期望: subject=O=sumery-mesh-org, CN=dev.test / issuer=CN=my-global-root-ca
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
- **节点上 curl VIP 不通**：节点自访、Pod 内访问、外部主机访问是三条不同的数据路径，
  90 阶段把它单独记录为附加观测，不据此判定其它两条的成败；真正的判据是 §5 从 newt Pod 内的实测。
- **Gateway 显示 Programmed=True 但地址不是固定 VIP / 90 阶段报 `IPAMRequestSatisfied=False`**：
  `kubectl -n default get svc cilium-gateway-cilium-gateway -o yaml` 看 `io.cilium/lb-ipam-ips` 注解与
  `status.conditions`；reason `no_pool`/`pool_selector_mismatch` 说明 `gateway-pool` 缺失、disabled 或 selector
  漂移，`already_allocated` 说明 `.240` 已被别的 Service 拿走。固定请求不会退回 default-pool 随机取址。
