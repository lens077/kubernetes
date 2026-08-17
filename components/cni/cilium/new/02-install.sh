#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# --set bpf.datapathMode=netkit \ 与bpf.tproxy=true 冲突，它是l3级别。性能高

# 更新现有的cilium
# cilium upgrade cilium cilium/cilium --namespace kube-system \
# 更新并保留 --reuse-values \
# 使用新的默认值 --reset-values \

k8sServiceHost="192.168.3.101"
k8sServicePort=6443
podCIDR="10.244.0.0/16"
devices="enp0s5"
cilium install cilium cilium/cilium --namespace kube-system \
	--set nodeinit.enabled=true \
	--set rollOutCiliumPods=true \
	--set bpf.masquerade=true \
	--set bpfClockProbe=true \
	--set bpf.preallocateMaps=false \
	--set bpf.tproxy=true \
	--set bpf.datapathMode=veth \
	--set bpf.hostLegacyRouting=false \
	--set bpf.lbExternalClusterIP=true \
	--set bpf.distributedLRU.enabled=true \
	--set bpf.mapDynamicSizeRatio=0.08 \
	--set localRedirectPolicies.enabled=true \
	--set ciliumEndpointSlice.enabled=false \
	--set externalIPs.enabled=true \
	--set hostPort.enabled=true \
	--set nodePort.enabled=true \
	--set socketLB.enabled=false \
	--set annotateK8sNode=true \
	--set nat46x64Gateway.enabled=false \
	--set ipv6.enabled=false \
	--set pmtuDiscovery.enabled=true \
	--set enableIPv4BIGTCP=false \
	--set enableIPv6BIGTCP=false \
	--set sctp.enabled=false \
	--set wellKnownIdentities.enabled=true \
	--set hubble.enabled=false \
	--set hubble.ui.enabled=false \
	--set hubble.relay.enabled=false \
	--set ipam.mode=kubernetes \
	--set k8s.requireIPv4PodCIDR=true \
	--set autoDirectNodeRoutes=true \
	--set enableXTSocketFallback=false \
	--set installNoConntrackIptablesRules=false \
	--set egressGateway.enabled=false \
	--set endpointRoutes.enabled=false \
	--set kubeProxyReplacement=true \
	--set routingMode="native" \
	--set ipv4NativeRoutingCIDR=$podCIDR \
	--set l7Proxy=true \
	--set gatewayAPI.enabled=true \
	--set gatewayAPI.enableAlpn=true \
	--set loadBalancer.mode=hybrid \
	--set loadBalancer.acceleration=disabled \
	--set loadBalancer.dsrDispatch=opt \
	--set loadBalancer.algorithm=maglev \
	--set loadBalancer.l7.backend=envoy \
	--set sessionAffinity=true \
	--set config.sessionAffinity=true \
	--set bandwidthManager.enabled=true \
	--set bandwidthManager.bbr=true \
	--set l2announcements.enabled=true \
	--set k8sClientRateLimit.qps=50 \
  --set k8sClientRateLimit.burst=100 \
  --set l2podAnnouncements.interface=$devices \
	--set devices=$devices \
	--set operator.rollOutPods=true \
	--set authentication.enabled=false \
	--set k8sServiceHost=$k8sServiceHost \
	--set k8sServicePort=$k8sServicePort \
	--set ingressController.enabled=true \
	--set ingressController.hostNetwork.enabled=false \
	--set ingressController.default=true \
	--set envoy.securityContext.privileged=true \
	--set envoy.securityContext.capabilities.keepCapNetBindService=true \
	--set securityContext.capabilities.ciliumAgent='{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}'
