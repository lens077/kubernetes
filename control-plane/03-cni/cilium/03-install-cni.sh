#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

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
	--set bpf.tproxy=true \
	--set bpf.hostLegacyRouting=false \
	--set localRedirectPolicy=true \
	--set ciliumEndpointSlice.enabled=true \
	--set externalIPs.enabled=true \
	--set hostPort.enabled=true \
	--set socketLB.enabled=true \
	--set nodePort.enabled=true \
	--set sessionAffinity=true \
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
	--set loadBalancer.mode=dsr \
	--set bandwidthManager.enabled=true \
	--set bandwidthManager.bbr=true \
	--set highScaleIPcache.enabled=false \
	--set l2announcements.enabled=true \
	--set k8sClientRateLimit.qps=30 \
	--set k8sClientRateLimit.burst=40 \
	--set devices=$devices \
	--set l2podAnnouncements.interface=$devices \
	--set operator.rollOutPods=true \
	--set authentication.enabled=false \
	--set k8sServiceHost=$k8sServiceHost \
	--set k8sServicePort=$k8sServicePort \
	--set bpf.datapathMode=netkit \
	--set ingressController.enabled=true \
	--set ingressController.hostNetwork.enabled=true \
	--set envoy.securityContext.capabilities.keepCapNetBindService=true \
	--set securityContext.capabilities.ciliumAgent='{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}'
