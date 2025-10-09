# Helm 命令
添加cilium仓库
helm repo add cilium https://helm.cilium.io/
helm repo update

保留原有的参数升级
cilium upgrade cilium  \
--namespace kube-system \
--reuse-values \
--set sessionAffinity=true \


kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium

# 卸载
cilium uninstall



查询

```
kubectl -n kube-system rollout restart ds/cilium

kubectl -n kube-system rollout restart deployment coredns

kubectl -n monitoring rollout restart deployment prometheus-operator
kubectl -n monitoring rollout restart deployment kube-state-metrics
kubectl -n monitoring rollout restart deployment grafana
kubectl -n monitoring rollout restart deployment blackbox-exporter
kubectl -n monitoring rollout restart deployment prometheus-adapter
kubectl -n kube-system exec ds/cilium -- cilium status
kubectl -n kube-system exec ds/cilium -- cilium status | grep Masquerading
kubectl -n kube-system exec po/cilium-8qfj7 -- cilium status
kubectl get daemonsets -n kube-system
kubectl get deployments -n kube-system

cilium status --wait

nohup cilium connectivity test&

watch kubectl get po,svc -n kube-system -owide
```

查看安装的配置和默认的配置
```
kubectl edit configmap cilium-config -n kube-system
kubectl get configmap cilium-config -n kube-system -o yaml
```

Cilium 信息
kubectl -n kube-system exec pod/cilium-79qdl -- cilium status --verbose
kubectl -n kube-system exec pod/cilium-jbrds -- cilium status --verbose
kubectl -n kube-system exec pod/cilium-r4pbz -- cilium status --verbose

检查集群连接运行状况 
kubectl -n kube-system exec pod/cilium-5g2k4 -- cilium-health status

监控数据路径状态 
kubectl -n kube-system exec pod/cilium-5g2k4 -- cilium monitor --type drop

参数搭配


关闭隧道
--set tunnel=disabled \
--set autoDirectNodeRoutes=true \
--set ipam.mode="multi-pool" \
--set ipv4NativeRoutingCIDR="10.10.0.0/16" \
--set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.cidrs='{10.10.0.0/16}' \
--set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.maskSize=24 \

--set bpf.masquerade=true \
--set enableIpv4Masquerade=true \
--set enableIpv6Masquerade=false \
--set endpointRoutes.enabled=true \
--set-string extraConfig.enable-local-node-route=false \
--set ipMasqAgent.config.nonMasqueradeCIDRs='{10.10.0.0/16}' \
--set ipMasqAgent.config.masqLinkLocal=false \
--set devices=$DEVICES \

--set bpf.preallocateMaps=true \

允许群集外部访问InternetIP服务。
--set bpf.lbExternalClusterIP=true \

--set routingMode=native \

--set sessionAffinity=true \

#L2 test
cilium upgrade cilium ./cilium \
--namespace kube-system \
--reuse-values \
--set l2announcements.enabled=true \
--set k8sClientRateLimit.qps=10 \
--set k8sClientRateLimit.burst=20 \
--set kubeProxyReplacement=true \
--set l2podAnnouncements.enabled=true \
--set l2podAnnouncements.interface=ens160 \
--set l2announcements.leaseDuration=3s \
--set l2announcements.leaseRenewDeadline=1s \
--set l2announcements.leaseRetryPeriod=200ms \

[Prometheus](https://docs.cilium.io/en/stable/observability/metrics/#metrics)
# 给cilium的启用指标
--set prometheus.enabled=true
#给cilium的operator启用指标
--set operator.prometheus.enabled=true
指定 Operator 副本数为 1, 默认为 2
--set operator.replicas=1

启用本地路由模式
--set tunnel=disabled \
每个节点都知道所有其他节点的所有 pod IP，
并在 Linux 内核路由表中插入路由来表示这一点。
如果所有节点共享一个 L2 网络，启用下面选项来解决这个问题
--set autoDirectNodeRoutes=true \

配置直接路由模式是否应该通过主机堆栈路由流量（true），
或者如果内核支持，则直接更有效地从BPF路由流量（false）。
false意味着它也将绕过主机命名空间中的netfilter。默认值为false。
--set bpf.hostLegacyRouting=false

设置可执行本地路由的 CIDR
--set ipv4NativeRoutingCIDR=10.10.0.0/16

DSR, 必须以本地路由模式部署(tunnel=disabled)，也就是说，它不能在任何一种隧道模式下工作
--set loadBalancer.mode=dsr \

eBPF IP 地址伪装, Cilium 会自动将离开群集的所有流量的源 IP 地址伪装成 node 的 IPv4 地址
提升网络效率, https://ewhisper.cn/posts/58548/
当前的实现依赖于 BPF NodePort 功能。查看[GitHub问题](https://github.com/cilium/cilium/issues/13732)
未来将移除该依赖关系
bpf.masquerade=true \
#enableIpv4Masquerade=false
#enableIpv6Masquerade=false

默认行为是排除本地节点 IP 分配 CIDR 范围内的任何目的地。
如果 pod IP 可通过更广泛的网络进行路由，则可使用选项: ipv4-native-routing-cidr
指定该网络，在这种情况下，该 CIDR 范围内的所有目的地都 不会 被伪装
ipv4NativeRoutingCIDR=10.10.0.0/16

默认情况下，除了发往其他集群节点的数据包外，
所有从 pod 发往 ipv4NativeRoutingCIDR范围之外 IP 地址的数据包都会被伪装
如果配置文件为空，agent 将提供以下非伪装 CIDR
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
100.64.0.0/10
192.0.0.0/24
192.0.2.0/24
192.88.99.0/24
198.18.0.0/15
198.51.100.0/24
203.0.113.0/24
240.0.0.0/4
从 pod 发送到属于 nonMasqueradeCIDRs 中任何 CIDR 的目的地的数据包都不会被伪装
如果 masqLinkLocal 未设置或设置为 false，则 169.254.0.0/16 会被附加到非屏蔽 CIDR 列表中。
--set ipMasqAgent.config.nonMasqueradeCIDRs='{10.244.0.0/16}'
--set ipMasqAgent.config.masqLinkLocal=false
--set ipMasqAgent.config.masqLinkLocalIPv6=false

[Host-Routing 主机路由](https://ewhisper.cn/posts/56721/)
完全绕过 iptables 和上层主机堆栈，并实现比常规 veth 设备操作更快的网络命名空间切换。
要求
1. Kernel >= 5.10
2. 直接路由 (Direct-routing) 配置或隧道
3. 基于 eBPF 的 kube-proxy
4. 基于 eBPF 的伪装(masquerading)
如上所述, “如果内核支持该选项，它将自动启用”.

[绕过iptables连接跟踪](https://ewhisper.cn/posts/58823/
在无法使用 eBPF 主机路由 (Host-Routing) 的情况下，网络数据包仍需在主机命名空间中穿越常规网络堆栈，iptables 会增加大量成本。
通过禁用所有 Pod 流量的连接跟踪 (connection tracking) 要求，
从而绕过 iptables 连接跟踪器(iptables connection tracker)，可将这种遍历成本降至最低
要求:
1. 内核 >= 4.19.57, >= 5.1.16, >= 5.2
2. 直接路由 (Direct-routing) 配置
3. 基于 eBPF 的 kube-proxy 替换
4. 基于 eBPF 的伪装 (masquerading) 或无伪装
--set installNoConntrackIptablesRules=true

[带宽管理器](https://ewhisper.cn/posts/56757/)
要求:
Kernel >= 5.1
Direct-routing 配置 或 隧道
基于 eBPF 的 kube-proxy 替换
启用带宽管理器, 以更有效地管理网络流量，改善整体应用的延迟和吞吐量
默认情况下会将 TCP 拥塞控制算法切换为 BBR，从而实现更高的带宽和更低的延迟，尤其是面向互联网的流量。
它将内核网络堆栈配置为更面向服务器的 sysctl 设置，这些设置已在生产环境中证明是有益的
还重新配置了流量控制队列规则（Qdisc）层，以便在 Cilium 使用的所有面向外部的网络设备上使用多队列 Qdiscs 和公平队列（FQ）。
切换到公平队列后，带宽管理器还在 eBPF 的帮助下实现了对最早出发时间 Earliest Departure Time（EDT）速率限制的支持，
并且现在原生支持 kubernetes.io/egress-bandwidth Pod 注释
当 eBPF 和 FQ 结合使用时，第 95 百分位的延迟降低了约 20 倍，第 99 百分位的延迟降低了约 10 倍
--set bandwidthManager.enabled=true \

[BBR 拥塞控制](https://ewhisper.cn/posts/50029/)
要求:
内核 >= 5.18
带宽管理器
eBPF 主机路由
--set bandwidthManager.bbr=true \


镜像地址
--set image.repository=registry.cn-shenzhen.aliyuncs.com/liweilun1/cilium \
--set operator.image.repository=registry.cn-shenzhen.aliyuncs.com/liweilun1/operator \

带宽管理器 BBR
--set devices=ens160 \
--set bandwidthManager.enabled=true \
--set bandwidthManager.bbr=true \

hubble设置
--set hubble.enabled=false \
--set hubble.ui.enabled=false \
--set hubble.relay.enabled=false \
--set hubble.relay.service.type=LoadBalancer \
--set hubble.relay.service.nodePort=31234 \

允许ClusterIP对外访问,需要写对应的路由信息, 例如
ip route add 192.168.3.22/32 via 192.168.1.149
--set bfp.lbExternalClusterIP=true \

PBG模式, 不能与L2同时使用
--set bgp.enabled=true \
--set bgp.announce.loadbalancerIP=true

启用externalIPs
--set externalIPs.enable=true \ 启用externalIPs.enable

对于创建服务时默认的 Cluster 策略，存在多个选项来实现外部流量的客户端源 IP 保留，
即，如果后者仅向外界公开基于 TCP 的服务，则在 DSR 或混合模式下操作 kube-proxy 替换。
--set externalTrafficPolicy=Cluster \

负载均衡的磁悬浮哈希
--set loadBalancer.algorithm=maglev \ 启用服务负载均衡的磁悬浮哈希

K8s 服务拓扑感知,允许 Cilium 节点首选位于同一区域中的服务端
--set loadBalancer.serviceTopology=true \ K8s 服务拓扑感知,允许 Cilium 节点首选位于同一区域中的服务端

从集群外部访问 ClusterIP 服务
--set bpf.lbExternalClusterIP=true \ 允许从集群外部访问 ClusterIP 服务,默认为false

带宽管理器 负责更有效地管理网络流量，以改善整体应用程序延迟和吞吐量
--set devices=ens+ NodePort 设备、端口和绑定设置
--set bpf.masquerade=true 用于 Pod 的 IPv4 地址通常是从RFC1918专用地址块分配的，因此不可公开路由。Cilium 会自动将离开集群的所有流量的源 IP 地址伪装到节点的 IPv4 地址 https://docs.cilium.io/en/stable/network/concepts/masquerading/
--set bandwidthManager.enabled=true \ 是否启用带宽管理器, 默认为false
--set bandwidthManager.bbr=true \ #当 Pod 暴露在 Kubernetes 服务后面时，BBR 特别适合，这些服务面向来自 Internet 的外部客户端。BBR 实现了更高的带宽和更低的互联网流量延迟，例如，已经证明 BBR 的吞吐量可以达到比当今最好的基于丢失的拥塞控制高出 2,700 倍，排队延迟可以降低 25 倍
#在现有的cilium时添加必须要重启:
kubectl -n kube-system rollout restart ds/cilium

--set tunnel=disabled \

ipam 这个参数是使用node 节点分配的子网
(IP Address Management), 选择 Cilium 的 IP 管理策略，支持如下选择：
cluster-pool: 默认的IP管理策略，会为每个节点分配一段 CIDR，然后分配 IP 时从这个节点的子网中选择IP，但是不如 calico 一点的是，这并不是动态分配的 IP 池，每个节点的 IP 之后不会自动补充新的 CIDR 进去
crd:用户手动通过 CRD 定义每个节点可用的 IP 池，方便扩展开发，自定义IP管理策略
kubernetes: 从 k8s v1.Node 对象的 podCIDR 字段读取可用 IP 池，不再自己维护 IP 池，在 1.11 使用 cilium 自己集成的 BGP Speaker 宣告 CIDR 时就只支持这种模式

#[多池](https://docs.cilium.io/en/stable/network/kubernetes/ipam-multi-pool/#gsg-ipam-crd-multi-pool)
--set ipam.mode=multi-pool \
--set tunnel=disabled \
--set autoDirectNodeRoutes=true \
--set ipv4NativeRoutingCIDR=10.0.0.0/8 \
--set endpointRoutes.enabled=true \
--set-string extraConfig.enable-local-node-route=false \
--set kubeProxyReplacement=true \
--set bpf.masquerade=true \
--set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.cidrs='{10.10.0.0/16}' \
--set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.maskSize=27 \

Kubernetes池
--set ipv4NativeRoutingCIDR=10.10.0.0/16 \
--set ipv6.enabled=false \
--set ipam.mode=kubernetes \
--set ipam.operator.clusterPoolIPv4PodCIDRList=["10.10.0.0/16"]

BGP
--set bgp.enabled=true \ #在ciilium内部启用BGP支持;为BGP嵌入一个新的ConfigMap
--set bgp.announce.loadbalancerIP=true \ #开启服务负载均衡器ip的分配和通告
--version v1.15.1
--set ipam.mode=kubernetes \
--set tunnel=disabled \
--set ipv4NativeRoutingCIDR="10.0.0.0/8" \
--set bgpControlPlane.enabled=true \
--set k8s.requireIPv4PodCIDR=true \

 hubble.relay
--set hubble.relay.enabled=true \
--set hubble.relay.service.type=NodePort \
--set hubble.relay.service.nodePort=31234 \

仅 DSR 模式的无 kube-proxy-free 环境中
--set tunnel=disabled \
--set routingMode=native \
--set loadBalancer.mode=dsr \
--set loadBalancer.dsrDispatch=opt \

Geneve 的直接服务器返回 （DSR）
--set tunnel=disabled \
--set loadBalancer.mode=dsr \
--set loadBalancer.dsrDispatch=geneve \  启用了 DSR 和 Geneve 调度的无 kube-proxy-free 环境中

DSR 中具有 Geneve 调度和隧道模式
--set tunnel=geneve \
--set loadBalancer.mode=dsr \
--set loadBalancer.dsrDispatch=geneve \

混合 DSR 和 SNAT 模式
--set routingMode=native \
--set kubeProxyReplacement=true \
--set loadBalancer.mode=hybrid \

[Pod 命名空间中的套接字 LoadBalancer 旁路](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-loadbalancer-bypass-in-pod-namespace)
--set routingMode=native \
--set socketLB.hostNamespaceOnly=true

LoadBalancer 和 NodePort XDP 加速
加速是通过XDP加速服务处理的选项, 值可以是:
disabled, 不使用XDP
native, (XDP BPF程序直接通过网络驱动程序的早期接收运行path)，或者尽最大努力(在设备上使用原生模式XDP加速支持它)。
设置为 loadBalancer.acceleration 选项 native 可启用此加速。该选项 disabled 为默认值，并禁用加速。
大多数支持 10G 或更高速率的驱动程序在最近的内核上也支持 native XDP。对于基于云的部署，这些驱动程序中的大多数都具有支持本机XDP的SR-IOV变体。
对于本地部署，Cilium XDP 加速可以与 Kubernetes 的 LoadBalancer 服务实现（如 MetalLB）结合使用。加速只能在用于直接路由的单个设备上启用
https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#advanced-configuration
--set routingMode=native \
--set loadBalancer.acceleration=native loadBalancer 和 NodePort XDP 加速, 默认为disabled

BGP 控制平面, 只有ipam.mode=kubernetes或者
--set bgpControlPlane.enabled=true

多池 IPAM不能与routing-mode: native 本机路由一起使用
--set routing-mode=native \
--set ipv4NativeRoutingCIDR=10.0.0.0/8 \

--set kubeProxyReplacementHealthzBindAddr='0.0.0.0:10256' kube-proxy 替换健康检查服务器

Cilium 的 eBPF kube-proxy 替代品不支持 SCTP 传输协议。目前仅支持 TCP 和 UDP 作为服务的传输
--set sctp.enabled=true \

L2
https://docs.cilium.io/en/stable/network/l2-announcements/
--set devices=ens+ \
--set l2announcements.enabled=true \
--set k8sClientRateLimit.qps=10 \
--set k8sClientRateLimit.burst=20 \
#L2公告
--set l2podAnnouncements.enabled=true
--set l2podAnnouncements.interface=ens+
#L2 续约
--set l2announcements.leaseDuration=3s \
--set l2announcements.leaseRenewDeadline=1s \
--set l2announcements.leaseRetryPeriod=200ms \


是否分配、宣告LoadBalancer服务的IP地址
--set bgp.announce.loadbalancerIP=false

允许集群外部访问ClusterIP服务 default: false
--set bpf.lbExternalClusterIP=true

--set bgpControlPlane.enabled=false
