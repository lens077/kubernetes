# Cilium v1.20.1 上游查证

本文供中断会话恢复与后续修复使用，只做源码、官方文档和本地配置的有界核对，不代替机房验收。

## 范围与证据边界

- 已读本地 [`scripts/60-cilium.sh`](scripts/60-cilium.sh)、[`config.hosting.env`](config.hosting.env)、[`01-shared-gateway.yaml`](../components/gateway/manifests/01-shared-gateway.yaml) 和 [`CILIUM.md`](CILIUM.md) 的相关配置。检查时配置为 Gateway `default/cilium-gateway`、固定 VIP `10.10.31.240`、专属单地址池、默认池 `.241-.249`；节点 LAN 为 `10.10.21.0/24`。这是仓库状态，不是 live cluster 状态。
- 第一方 Cilium 源码通过 `web_fetch` 直接取得，使用 `v1.20.1` 标签，不以 `main` 替代。所引用 Cilium 官方 `stable` 页面本轮标题显示 `1.20.1`，但该 URL 以后会移动；版本敏感结论以标签源码为准。
- 本轮没有执行 SSH、kubectl、远程探测、集群变更、提交或推送；没有读取或使用日志凭证。本地文档中的历史实测未复测，不应升级为本轮已验证事实。
- 获取边界：引用的主要源码和文档均取得 HTTP 200。补充试读 `operator/pkg/lbipam/pool_store.go` 返回 [HTTP 404](https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/lbipam/pool_store.go)，未作为证据；这不能证明版本不存在，也不是网络连接失败。Kubernetes labels 渲染页被工具截断，未用其截断部分支撑结论。先前会话的网络失败不代表本轮仍失败。

## 1. 生成的 Service 名与 hostNetwork 例外

**结论：在 v1.20.1 的 Gateway 翻译路径中，本例生成的 Service 确为 `default/cilium-gateway-cilium-gateway`；不能把它扩大成「一定生成 LoadBalancer」。**

- `desiredService()` 使用 `ShortenK8sResourceName("cilium-gateway-" + owner.Name)`，namespace 取 `owner.Namespace`。本例名称不足 63 字符，shortener 不改名。长 Gateway 名会缩短并附 hash，因此不能对任意名称只做字符串拼接。[翻译器][translator]、[shortener][shortener]
- `HostNetworkConfig.Enabled=true` 时，`toServiceType()` 返回 **NodePort**，命名逻辑没有改变；未启用时，无 Service 参数默认返回 LoadBalancer，GatewayClass 参数也能改变 Service 类型。这里的 hostNetwork 例外是类型和暴露路径，不是另一个 Service 名。[翻译器][translator]
- 名称公式不保证对象已经存在：GatewayClass 非 Cilium、无有效 listener、地址非法或 reconcile 失败都可能阻止正常生成。仓库 values 模板没有显式启用 Gateway hostNetwork，仍须核对实际 values、Service 类型及 ownerReferences，不能仅凭对象名判定 LB-IPAM 生效。[reconcile][reconcile]、[本地生成器](scripts/60-cilium.sh)

## 2. 专属池、特殊 selector 与默认池

**结论：两个特殊 selector 均受支持；在有效固定请求已经传到 Service 的前提下，默认池无 selector 不会使 `.240` 自动回退成 `.241-.249`。建议排除共享 Service，但这是防配置漂移的加固，不是当前固定请求的必需修复。**

- `io.kubernetes.service.namespace` 和 `io.kubernetes.service.name` 分别匹配 Service 的真实 namespace/name。`svcLabels()` 在内部标签副本上写入元数据值，不要求实际 Service 带同名 label。专属池应同时匹配 `default` 与 `cilium-gateway-cilium-gateway`。[官方 selector 文档][ipam-doc]、[`svcLabels()`][service-store]
- Gateway `spec.addresses` 的 IPAddress 值在 ingestion 中写入 `io.cilium/lb-ipam-ips`，经翻译器成为生成 Service 的注解。已有 `spec.infrastructure.annotations["io.cilium/lb-ipam-ips"]` 时不会覆盖它；因此必须核对实际 Service 的请求注解，不能只验 Gateway spec。[ingestion][ingestion]、[addresses 文档][addresses]
- LB-IPAM 读取 `spec.loadBalancerIP` 和请求 IP 注解；`RequestedIPs` 非空只走 `satisfySpecificIPRequests()`，否则才走 generic 分配。新的指定地址分配必须来自启用且 selector 匹配的池。新的固定地址请求遇到专属池缺失、disabled、冲突、selector 不匹配或 IP 已被别的 Service 分配时保持未满足，**不转去默认池任选一个地址**。单独设置 disabled 不撤销已有分配，不能据此宣称已使用该池的 Service 必然失去地址。可见 reason 包括 `no_pool`、`pool_selector_mismatch`、`already_allocated`。[`getSVCRequestedIPs()`、`satisfyService()`、`findRangeOfIP()`][lbipam]
- 无 selector 的 default-pool 仍匹配共享 Service。若请求注解丢失，或以后删除固定请求，两池都会成为 generic 分配候选，不能依赖专属池名称表示优先级。默认池显式排除共享 Service 可阻止这类漂移。[`allocateIPAddress()`][lbipam]、[官方 selector 文档][ipam-doc]
- 最小加固可用下列 name 排除，但它会排除**所有 namespace 中同名 Service**。若要只排除一对 namespace/name，采用受控的共享 Gateway infrastructure label 再排除该标记，或给默认池改成显式 opt-in；不要把两个独立 `NotIn` 当成「仅排除这一对」。池 selector 的实现交给 Kubernetes LabelSelector 求值。[`LabelSelectorAsSelector()` 调用][lbipam]

```yaml
# default-pool.spec 的建议片段；由主 agent 决定是否采用。
serviceSelector:
  matchExpressions:
    - key: io.kubernetes.service.name
      operator: NotIn
      values: [cilium-gateway-cilium-gateway]
```

这里的「共享 Gateway」指 HTTPRoute 共用入口，不等于启用了 LB-IPAM `sharing-key`。不要为解决安装先后顺序而添加 IP sharing 注解。[Sharing Keys][ipam-doc]

## 3. Newt Pod 到跨子网 VIP 的预期路径

**结论：`.240` 可以作为 Cilium 集群内部 Service VIP 的候选，但源码仅支持路径预期，不证明机房已分配此地址、当前可达或与远端网络无冲突。L2 announcer 不提供跨 VLAN 路由。**

对普通 Cilium-managed、非 hostNetwork 的 Newt Pod，且 `.240:443` 已正确编程为 Gateway L7 Service 时，预期路径是：

```text
Newt 发起到 10.10.31.240:443 的连接
  -> socket eBPF 识别 L7 LB，保留 VIP 给包级数据路径
  -> endpoint 包级 eBPF 的 L7 重定向
  -> 本节点 Envoy（Gateway 文档描述为 TPROXY 路径）
  -> 按 SNI/Host、HTTPRoute 选择业务后端
```

- `bpf_sock.c::__sock4_xlate_fwd()` 对 L7 LB 的非 host netns 路径直接返回，注释说明让包级 eBPF 重定向；host netns 则有重写到 `127.0.0.1:proxyPort` 的特殊处理。因此不能把 Gateway 路径写成「socket LB 直接连接业务 Pod」，也不能从节点 curl 成功推导 Newt 路径成功。[socket 源码][sock]、[Gateway 数据路径文档][gateway-doc]
- 成功的内部路径不要求先向 L2 Lease holder 发 ARP。包级 hook 与 netkit/veth、代理相关运行配置有关；本文没有逐指令验证实际 netkit hook，也不把 `bpf.tproxy=true` 当成运行前提。[socket 源码][sock]、[Gateway 数据路径文档][gateway-doc]
- LB-IPAM 负责分配 IP；L2 Announcements 负责在选定接口回答 ARP/NDP，不把 VIP 配到节点网卡，也不会安装上游路由。Lease 存在只能证明选主的一部分，不能证明跨 VLAN 可达。[LB-IPAM 职责][ipam-doc]、[L2 工作原理][l2-doc]
- 对通常使用 `/24` 路由的外部客户端，跨子网目的地会交给下一跳；但其他主机的掩码、on-link 路由和机房三层配置本轮均未确认。不能写成「同 VLAN 绝不会为 `.31` 发 ARP」或「跨子网所以通告无风险」。私网地址仍须在共同通信域内协调，已有或未来 VPN/机房路由也可能引入重叠。[RFC 1918 第 3、5 节][rfc1918]、[L2 工作原理][l2-doc]
- ping/curl/ARP 无响应只表示在给定探测位置、协议和时间窗内没有观察到应答；不是未占用证明，更不是机房分配凭证。RFC 5227 明确初次探测可因通信中断漏掉冲突，且 ARP 冲突检测只覆盖同一物理链路，需持续检测。[RFC 5227 第 1、1.3、2.4 节][rfc5227]

### 必须分开的真实验收（本轮未执行）

1. **控制面与编程**：核对 Newt Pod 是否受 Cilium 管理、是否 hostNetwork；核对 Service owner/type/请求注解/status VIP，Gateway `Accepted`、`Programmed`、listener/HTTPRoute `ResolvedRefs`，以及 Newt 所在节点的 VIP:80/443 Service/LB map、CEC 与 Envoy 状态。控制面成功不是业务成功。[reconcile][reconcile]、[Gateway 文档][gateway-doc]
2. **Newt 同一网络上下文**：从实际 Newt Pod 发起带正确 SNI/Host、可信 CA 的请求，确认预期业务响应，不把默认 404、503 或只建连成功作为通过。配合 Hubble/包级观测定位 Newt -> Envoy -> backend；逐个覆盖 Newt 可能落点和跨节点后端。临时诊断 Pod 只能提供相近证据，不能完全替代原 Pod 的身份/策略。[Gateway 文档][gateway-doc]
3. **节点本机**：独立测相同 VIP/端口/Host，单独记录成败，不用它代替第 2 项。[socket 源码][sock]
4. **若确实要求 L2 暴露**：先取得地址与 VLAN 使用许可，再在受控同链路客户端观察 ARP/NDP 的目标、应答 MAC、Lease holder、接口和实际 TCP/HTTPS；维护窗口另测 holder 切换。跨 VLAN 客户端还要验证双向路由及 ACL。这些测试证明特定路径，不证明全网无地址占用。[L2 排障文档][l2-doc]、[RFC 5227][rfc5227]

## 4. Pool / L2Policy 验证字段

检查时应等待状态收敛并读取完整对象，不能仅检查 CR 存在和首个 IP block。[Pool API][pool-api]、[L2 API][l2-api]

| 对象 | 至少检查 | 不能据此推断 |
|---|---|---|
| gateway-pool | 所有 `spec.blocks` 合起来恰为固定单地址；`serviceSelector` 同时限制 namespace/name，检查额外 matchExpressions；`spec.disabled` 为 false/默认 false | 仅首个 block 正确，不代表没有额外可分配地址 |
| default-pool | 全部范围与目标一致；与 gateway-pool 及其他存量池不重叠；selector 符合所选排除/opt-in 策略；disabled=false | 两个目标池不重叠，不代表没有第三个旧池冲突 |
| Pool status | `cilium.io/PoolConflict=False`，核对 reason/message、`observedGeneration`；缺失/过期条件先视为未收敛；`IPsTotal/Available/Used` 的数字在 condition.message | `CONFLICTING` 是列名，不是 spec 字段；disabled=false 不代表没有内部冲突禁用；计数 condition 的 `status=Unknown` 是正常表示 |
| 生成 Service | 真实 metadata namespace/name/owner UID、type、请求注解、loadBalancerClass、IPFamilies/IPFamilyPolicy、externalTrafficPolicy、精确 status IP；`cilium.io/IPAMRequestSatisfied=True` 及 generation | 旧 IP 仍存在不证明池可继续分配；disabled 保留已有分配 |
| L2Policy spec | `serviceSelector`（含特殊 namespace/name 条件）、`nodeSelector`、`interfaces` 正则、`loadBalancerIPs`、`externalIPs` 与预期一致；实际节点/接口匹配且接口在 Cilium devices 选择内 | 没有独立 `spec.namespaceSelector` 或 `spec.disabled`；default-l2 当前不设 selector 会覆盖各 namespace，不能盲目改成只选 default 而漏掉其他 LB |
| L2 运行态 | policy 的错误 conditions、匹配 Service 的 loadBalancerClass（未设或 `io.cilium/l2-announcer`）、Lease holder/renewTime/leaseDuration、agent L2 表和 responder map、真实接口应答 | `loadBalancerIPs=true`、一个 Lease 或无错误 condition 都不是业务可达证明 |

来源：[`lbipam.go`][lbipam]、[Pool API][pool-api]、[L2 API][l2-api]、[L2 排障文档][l2-doc]。

两个版本细节需避免误判：

- v1.20.1 Service 条件常量是 `cilium.io/IPAMRequestSatisfied`；本轮 stable LB-IPAM 文档的部分示例仍展示旧 `io.cilium/lb-ipam-request-satisfied`，验证器应以版本源码和实际资源为准。[源码][lbipam]、[文档示例][ipam-doc]
- L2 文档一般性警告与 `externalTrafficPolicy: Local` 不兼容；Gateway 文档又说明其每节点 Envoy 路径不需 Local 来保源地址。当前安装器面向多种 LB，保持 `Cluster` 是一致基线，不应由 Gateway 特例推导其他 Service 都可用 Local。[L2 限制][l2-doc]、[Gateway 源地址说明][gateway-doc]

## 给主 agent 的可执行修复建议

1. **保留并加固地址约束**：保留 `.240` 单地址专属池、namespace/name 双 selector 与 Gateway `spec.addresses`；默认池可加显式排除。验证 live Service 的请求 IP 与最终 IP，区分「固定请求失败」和「没有固定请求」。不要修改生成 Service 的名字以消除重复前缀。[第 1、2 节](#1-生成的-service-名与-hostnetwork-例外)
2. **补全验证器与离线回归**：一次读取完整 Pool/L2 JSON；覆盖 namespace 漂移、额外 blocks、disabled、PoolConflict=True、旧 generation、selector 漂移、无匹配接口/节点、hostNetwork/NodePort 等负例。策略匹配验证与租约/真实流量验证分开，不让 CR 字段比较冒充联网验收。[第 4 节](#4-pool--l2policy-验证字段)
3. **改正地址安全措辞**：把「无响应/无 ARP，所以无冲突或不会冒用」改为有观测范围的历史记录；把 `.240` 标为待通信域地址规划确认、待 Newt 实际路径验收的内部 VIP，不声称已经获得机房授权。[RFC 5227][rfc5227]、[RFC 1918][rfc1918]
4. **将 IP 分配与 L2 暴露解耦**：纯 Newt 内部入口不应为获得 LB-IPAM 地址而强制通告共享 VLAN。可保留池、不给内部 Service 匹配 L2Policy；为未来确需 LAN 暴露的 Service 显式选择通告。当前 `apply_l2_policy()` 在关闭 L2 开关时还会删除两个池，不能直接把开关改 false 充当解耦；应由主 agent 单独改生成、清理和指纹语义。地址更改或池修改可能重分配现有 Service，应用前先审视存量分配。[LB-IPAM 职责与变更警告][ipam-doc]、[本地实现](scripts/60-cilium.sh)

未查证事项：机房地址分配/路由/ACL、现有 VLAN 与其他租户地址、Newt 的运行身份和网络上下文、实际 Envoy/BPF 编程、TLS/Host 配置、节点与 Pod 的可达性，以及任何故障切换结果。后续报告必须保留这些边界。

[translator]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/model/translation/gateway-api/translator.go
[shortener]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/shortener/shortener.go
[reconcile]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/gateway-api/gateway_reconcile.go
[ingestion]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/model/ingestion/gateway.go
[addresses]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/Documentation/network/servicemesh/gateway-api/addresses.rst
[lbipam]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/lbipam/lbipam.go
[service-store]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/operator/pkg/lbipam/service_store.go
[pool-api]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/v2/lbipam_types.go
[ipam-doc]: https://docs.cilium.io/en/stable/network/lb-ipam/
[sock]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/bpf/bpf_sock.c
[gateway-doc]: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
[l2-api]: https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/v2alpha1/l2announcement_types.go
[l2-doc]: https://docs.cilium.io/en/stable/network/l2-announcements/
[rfc5227]: https://www.rfc-editor.org/rfc/rfc5227.html
[rfc1918]: https://www.rfc-editor.org/rfc/rfc1918.html
