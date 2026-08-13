#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

#k8sServiceHost="192.168.3.105"
#k8sServicePort=6443
#podCIDR="10.244.0.0/16"
#devices="enp0s5"
#cilium install cilium cilium/cilium --namespace kube-system \
#	--set nodeinit.enabled=true \
#	--set rollOutCiliumPods=true \
#	--set bpf.masquerade=true \
#	--set bpfClockProbe=true \
#	--set bpf.preallocateMaps=false \
#	--set bpf.tproxy=false \
#	--set bpf.hostLegacyRouting=false \
#	--set bpf.lbExternalClusterIP=true \
#	--set bpf.distributedLRU.enabled=true \
#	--set bpf.mapDynamicSizeRatio=0.08 \
#	--set localRedirectPolicies.enabled=true \
#	--set ciliumEndpointSlice.enabled=false \
#	--set externalIPs.enabled=true \
#	--set hostPort.enabled=true \
#	--set nodePort.enabled=true \
#	--set socketLB.enabled=false \
#	--set annotateK8sNode=true \
#	--set nat46x64Gateway.enabled=false \
#	--set ipv6.enabled=false \
#	--set pmtuDiscovery.enabled=true \
#	--set enableIPv4BIGTCP=false \
#	--set enableIPv6BIGTCP=false \
#	--set sctp.enabled=false \
#	--set wellKnownIdentities.enabled=true \
#	--set hubble.enabled=true \
#	--set hubble.ui.enabled=true \
#	--set hubble.relay.enabled=true \
#	--set ipam.mode=kubernetes \
#	--set k8s.requireIPv4PodCIDR=true \
#	--set autoDirectNodeRoutes=true \
#	--set enableXTSocketFallback=false \
#	--set installNoConntrackIptablesRules=false \
#	--set egressGateway.enabled=false \
#	--set endpointRoutes.enabled=false \
#	--set kubeProxyReplacement=true \
#	--set routingMode="native" \
#	--set ipv4NativeRoutingCIDR=$podCIDR \
#	--set l7Proxy=true \
#	--set gatewayAPI.enabled=true \
#	--set loadBalancer.mode=hybrid \
#	--set loadBalancer.acceleration=disabled \
#	--set loadBalancer.dsrDispatch=opt \
#	--set loadBalancer.algorithm=maglev \
#	--set loadBalancer.l7.backend=envoy \
#	--set sessionAffinity=true \
#	--set config.sessionAffinity=true \
#	--set bandwidthManager.enabled=true \
#	--set bandwidthManager.bbr=true \
#	--set l2announcements.enabled=true \
#	--set k8sClientRateLimit.qps=50 \
#  --set k8sClientRateLimit.burst=100 \
#  --set l2podAnnouncements.interface=$devices \
#	--set devices=$devices \
#	--set operator.rollOutPods=true \
#	--set authentication.enabled=false \
#	--set k8sServiceHost=$k8sServiceHost \
#	--set k8sServicePort=$k8sServicePort \
#	--set bpf.datapathMode=netkit \
#	--set ingressController.enabled=true \
#	--set ingressController.hostNetwork.enabled=false \
#	--set ingressController.default=true \
#	--set envoy.securityContext.privileged=true \
#	--set envoy.securityContext.capabilities.keepCapNetBindService=true \
#	--set securityContext.capabilities.ciliumAgent='{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}'


#服务数量	建议 QPS	建议 Burst
#< 10	10	20
#10~50	30	60
#50~100	50	100
#100~200	100	200
#> 200	200+	400+
#公式参考：QPS = ⌈服务数 / 2⌉，Burst = QPS × 2

# Ubuntu 24.04 LTS 默认内核6.8.0-83-generic+特定内核模块测试
k8sServiceHost="192.168.3.100"
k8sServicePort=6443
podCIDR="10.244.0.0/16"
devices="enp0s5"
cilium install cilium cilium/cilium --namespace kube-system \
	--set nodeinit.enabled=true \
	--set rollOutCiliumPods=true \
	--set bpf.masquerade=true \
	--set bpfClockProbe=true \
	--set bpf.preallocateMaps=true \
	--set bpf.hostLegacyRouting=false \
	--set localRedirectPolicy=true \
	--set ciliumEndpointSlice.enabled=true \
	--set externalIPs.enabled=true \
	--set hostPort.enabled=true \
	--set socketLB.enabled=true \
	--set nodePort.enabled=true \
	--set sessionAffinity=true \
	--set config.sessionAffinity=true \
	--set annotateK8sNode=true \
	--set nat46x64Gateway.enabled=false \
	--set ipv6.enabled=false \
	--set pmtuDiscovery.enabled=true \
	--set enableIPv4BIGTCP=false \
	--set enableIPv6BIGTCP=false \
	--set sctp.enabled=false \
	--set wellKnownIdentities.enabled=true \
	--set hubble.enabled=true \
	--set hubble.ui.enabled=true \
	--set hubble.relay.enabled=true \
	--set ipam.mode=kubernetes \
	--set k8s.requireIPv4PodCIDR=true \
	--set ipv4NativeRoutingCIDR=$podCIDR \
	--set autoDirectNodeRoutes=true \
	--set enableXTSocketFallback=false \
	--set installNoConntrackIptablesRules=true \
	--set egressGateway.enabled=false \
	--set endpointRoutes.enabled=false \
	--set kubeProxyReplacement=true \
	--set routingMode=native \
	--set l7Proxy=true \
	--set gatewayAPI.enabled=true \
	--set gatewayAPI.hostNetwork.enabled=true \
	--set loadBalancer.mode=dsr \
	--set bandwidthManager.enabled=true \
	--set bandwidthManager.bbr=true \
	--set l2announcements.enabled=true \
	--set k8sClientRateLimit.qps=50 \
	--set k8sClientRateLimit.burst=100 \
	--set devices=$devices \
	--set l2podAnnouncements.interface=$devices \
	--set operator.rollOutPods=true \
	--set authentication.enabled=false \
	--set k8sServiceHost=$k8sServiceHost \
	--set k8sServicePort=$k8sServicePort \
	--set bpf.datapathMode=netkit \
	--set ingressController.enabled=true \
	--set ingressController.hostNetwork.enabled=false \
	--set envoy.securityContext.privileged=true \
	--set envoy.securityContext.capabilities.keepCapNetBindService=true \
	--set securityContext.capabilities.ciliumAgent='{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}'

# 通用：
#nodeinit.enabled:启用节点初始化 DaemonSet,false
rollOutCiliumPods: 更新 configmap 时自动推出纤毛代理 Pod，false

# bpf
## 伪装
bpf.masquerade： 在 eBPF 中启用原生 IP 伪装支持，false, 推荐开启, 简单来说，伪装就是一种网络地址转换（NAT）技术。由于Kubernetes集群中的Pod通常使用私有IP地址（例如10.0.0.0/8、172.16.0.0/12、192.168.0.0/16），这些地址在公共互联网上是不可路由的。Cilium的伪装功能会自动将从Pod发出的、离开集群的流量的源IP地址，转换（伪装）为节点的IP地址。因为节点的IP地址在网络上是可路由的，所以外部资源可以将响应流量正确地发送回节点，然后Cilium再将流量路由回相应的Pod。
## 时钟探针
bpfClockProbe=true Cilium 可以探测底层内核，以确定 BPF 是否支持检索 jiffies 而不是 ktime。鉴于 Cilium 的 CT 映射不需要高分辨率，因此 jiffies 效率更高，并且是首选时钟源。要启用探测并可能使用 jiffies，可以设置 bpfClockProbe=true
## map预先分配：
bpf.preallocateMaps：启用 eBPF 映射值的预分配。这会增加内存使用量，但可以减少延迟。默认false
## tproxy
bpf.tproxy: 配置基于 eBPF 的 TPROXY（测试版），以减少对 iptables 规则的依赖来实施第 7 层策略。默认false
## 主机路由
bpf.hostLegacyRouting： 配置直接路由模式是应通过主机堆栈路由流量 （true），还是直接更有效地从 BPF 路由流量 （false）（如果内核支持）。后者意味着它也将绕过主机命名空间中的 netfilter。默认false，推荐false
## bpf.lbExternalClusterIP=true 允许从集群外部访问 ClusterIP 服务: 根据 k8s 服务 ，Cilium 的 eBPF kube-proxy 替换默认不允许从集群外部访问 ClusterIP 服务。这可以通过设置 bpf.lbExternalClusterIP=true 来允许。


--set ipv4NativeRoutingCIDR=$podCIDR: 参数告诉 Cilium 一个特定的 IPv4 CIDR 范围，这个范围内的流量应该被视为“原生可路由”（natively routable）。这意味着 Cilium 会假设：
#这个 CIDR 范围内的所有 IP 地址（包括 Pod IP 和节点 IP）在你的网络中是可路由的。
#
#发送到这个范围的流量不需要进行 SNAT (Source Network Address Translation) 或伪装（masquerading）。
#
#简而言之，它是一个白名单，用于指定哪些流量可以信任底层网络堆栈来直接路由，而无需 Cilium 进行额外的处理。

# autoDirectNodeRoutes 的作用
  #autoDirectNodeRoutes 参数的作用是在 L2 (二层) 网络互通 的节点之间，自动配置 Pod CIDR 的路由。当启用此功能时，Cilium 会确保一个节点上的 Pod 可以直接将数据包发送到另一个节点上的 Pod，而无需经过一个额外的隧道或路由跳。
  #
  #这在物理机部署或使用扁平 L2 虚拟网络的场景中特别有用，因为它可以：
  #
  #减少延迟：数据包可以直接从源节点发送到目的节点，绕过了额外的隧道封装/解封装，从而减少了网络延迟。
  #
  #提高性能：消除了隧道开销，减轻了 CPU 负担。
  #
  #简化网络：避免了复杂的隧道配置（如 VXLAN 或 Geneve）。

# enableXTSocketFallback: 当缺少 xt_socket 内核模块并且数据路径 L7 重定向需要它才能正常工作时，启用回退兼容性解决方案。有关何时可以禁用此功能的详细信息，请参阅文档：https://docs.cilium.io/en/stable/operations/system_requirements/#linux-kernel。

# installNoConntrackIptablesRules
# 根据您提供的文档和集群环境，您不应该启用 installNoConntrackIptablesRules。
  #
  #功能解析
  #installNoConntrackIptablesRules 是一个高度特定的性能优化选项，它通过在 Linux 内核的 iptables 中创建规则，来跳过对 Pod 流量的连接追踪（conntrack）。连接追踪是网络性能瓶颈的潜在来源，但跳过它需要谨慎。
  #
  #该功能的使用有三个严格的前提条件：
  #
  #直连路由模式 (Direct Routing)：你的集群网络是扁平的，Pod 流量可以直接从源节点路由到目标节点，而无需经过隧道。
  #
  #全 KPR 模式 (Full KPR)：你已经使用 kubeProxyReplacement=true 启用了完整的 Cilium eBPF 模式，让 Cilium 接管了服务负载均衡。
  #
  #非托管环境 & 非 CNI 链式模式：这个功能不能在由云服务商管理的 Kubernetes 集群（如 EKS, GKE）中使用，也不能在与其他 CNI 插件配合使用时开启。
  #
  #您的集群环境
  #您的集群是：
  #
  #在单个 Mac 上使用 PD (Parallels Desktop) 虚拟机。
  #
  #由 3 个节点组成。
  #
  #为什么不应该启用
  #尽管你的集群满足了前两个条件（可以配置为直连路由和全 KPR），但由于你在虚拟化环境而非物理机上运行，启用此选项存在重大风险。
  #
  #虚拟化环境的限制：PD 虚拟机为你创建了一个虚拟网络。底层的网络行为是由虚拟机软件而不是由你直接控制。在这种环境中手动修改 iptables 规则，可能与虚拟机软件自身的网络管理机制冲突，导致不可预测的网络问题。
  #
  #不必要的风险：对于一个 3 节点的集群，conntrack 引起的性能开销微乎其微。你不会从这个优化中获得任何可感知的性能提升，但却承担了破坏网络稳定性的高风险。
  #
  #结论：这个功能是为大型、高吞吐量的物理机部署而设计的，旨在解决极端的性能瓶颈。对于您的本地虚拟机环境，它带来的风险远大于收益。因此，请保持此功能为禁用状态。

# egressGateway: Egress Gateway 功能旨在解决一个特定的企业级网络问题：将集群内特定 Pod 的出站（Egress）流量，强制通过一个或一组指定的“网关节点”，并使用一个固定的、可预测的 IP 地址进行 SNAT (源网络地址转换)。

# endpointRoutes: 你好！基于你的集群配置和需求，我来为你分析 endpointRoutes.enabled 这个参数，并告诉你是否需要启用它。
                  #
                  #endpointRoutes.enabled 的作用是什么？
                  #endpointRoutes.enabled 这个参数控制了 Cilium 如何处理 Pod 之间的路由。
                  #
                  #默认行为（禁用 endpointRoutes）：Pod 的流量会通过一个名为 cilium_host 的虚拟接口进行路由。这个接口将 Pod 的网络与宿主机（或虚拟机）的网络连接起来。这种方式简单可靠，但可能会引入一些额外的处理步骤。
                  #
                  #启用 endpointRoutes：Cilium 会为每个 Pod 单独创建一条路由，直接将流量从 Pod 路由到目标地址，而不再通过 cilium_host 接口作为中间跳。这通常被称为“每端点路由”。

# localRedirectPolicies.enabled：启用本地重定向策略。默认false
# ciliumEndpointSlice.enabled: 默认false，启用 Cilium EndpointSlice 功能。简单来说，如果您运行的是一个大型的 Kubernetes 集群，并且担心 API 服务器的性能瓶颈，那么您应该考虑启用 Cilium Endpoint Slice (CES)。对于小型或中型集群，默认设置（即不启用 CES）通常就足够了。该选项和Egress Gateway 功能不兼容。如果你依赖 Egress Gateway 来将 Pod 的出站流量路由到特定的网关，那么你不能同时启用 CES。
# socketLB.enabled: Cilium 的 Socket LB (Socket-based Load Balancing) 是一种基于 eBPF 的负载均衡技术，它在 Linux 内核的 Socket 层面上执行负载均衡。与传统的基于 iptables 或 IP 隧道（如 VXLAN）的负载均衡不同，Socket LB 可以在数据包到达网络层之前，也就是在应用发起连接时，就直接在 Socket 层面决定将流量发送到哪个后端 Pod。
# annotateK8sNode: 在初始化时使用 Cilium 的元数据注释 k8s 节点。
# nat46x64Gateway.enabled: 启用 RFC6052 前缀翻译
# pmtuDiscovery.enabled: 启用路径 MTU 发现以向客户端发送需要 ICMP 分段的回复。是一个重要的网络优化功能。它能显著提升集群内部和外部通信的性能和可靠性。考虑到你的集群使用 PD 虚拟机，网络环境可能比较复杂，强烈建议启用此功能。
# sctp: 一种传输层协议，与我们更熟悉的 TCP 和 UDP 类似。SCTP 的主要作用是提供一种更可靠、更灵活的数据传输方式，尤其适用于需要同时传输多个独立数据流的应用。主要应用于对可靠性和并发性有高要求的专业领域，例如：电信网络：用于信令协议（如 Diameter, SS7 over IP）,VoIP（网络电话）：支持同时传输语音、视频和文本数据流,金融数据传输：确保多个数据流的独立性和可靠性。

# --set loadBalancer.mode=hybrid \对 TCP 流量使用 DSR 模式，对 UDP 使用 SNAT。这是因为 UDP 无法利用 DSR 的优化，使用混合模式可以避免 MTU（最大传输单元）问题。

# loadBalancer.dsrDispatch=opt 路由模式和派发模式
  #路由模式：你已经知道要使用 routingMode=native。这是 DSR 正常工作的前提。
  #
  #派发模式：在原生路由模式下，DSR 可以选择 opt 或 geneve。geneve 模式通常更可靠，因为它避免了 opt 模式可能在某些网络环境中被丢弃的问题。虽然你的 PD 虚拟机环境不太可能遇到这种问题，但选择 geneve 可以提供更好的兼容性和稳定性。
# loadBalancer.algorithm=maglev  random (随机)：默认算法。简单、开销小，但可能导致同一客户端的请求被分散到不同后端，破坏会话粘性。
 #
 #maglev (一致性哈希)：一种基于哈希的算法，能确保特定客户端的请求总是被路由到同一个后端。这对于需要会话粘性的应用（如数据库连接、部分缓存）非常有用，但会占用更多内存。
 #
 #注解模式 (bpf.lbAlgorithmAnnotation=true)：允许你按需为每个服务选择算法，而不是全局应用。


Configure whether direct routing mode should route traffic via host stack (true) or directly and more efficiently out of BPF (false) if the kernel supports it. The latter has the implication that it will also bypass netfilter in the host namespace.
配置直接路由模式是应通过主机堆栈路由流量 （true），还是直接更有效地从 BPF 路由流量 （false）（如果内核支持）。后者意味着它也将绕过主机命名空间中的 netfilter。

bool  布尔语

false

# securityContext.capabilities.ciliumAgent
  #securityContext.capabilities.cilium 代理
  #
  #Capabilities for the cilium-agent container
  #纤毛剂容器的功能
  #
  #list  列表
  #
  #["CHOWN","KILL","NET_ADMIN","NET_RAW","IPC_LOCK","SYS_MODULE","SYS_ADMIN","SYS_RESOURCE","DAC_OVERRIDE","FOWNER","SETGID","SETUID"]

# ingress
# Cilium 可以通过将 --set ingressController.default=true 旗。这将创建入口条目，即使 ingressClass 未设置。
loadbalancerMode
--set ingressController.enabled=true \
--set ingressController.default=true
--set ingressController.hostNetwork.enabled=true \
--set loadBalancer.l7.backend=envoy

# ingressController.enabled=true 当你在 Helm 配置中设置 ingressController.hostNetwork.enabled: true 时，Cilium 就会自动知道你选择了主机网络模式。
#
#作为结果，Cilium 会 忽略 或 禁用 默认的 LoadBalancer 或 NodePort Service 创建逻辑。
#
#你不能同时使用这两种模式，因为它们在设计上就是互相排斥的。选择其中一个，就意味着放弃了另一个。
#
#简单来说，这是一个 安全和设计上的选择，旨在防止配置冲突，确保 Ingress 流量以可预测的方式被处理。
# --set ingressController.enabled=true \

