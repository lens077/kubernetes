#!/bin/bash
set -x
# 启用ingress
# 专用模式： ingress.cilium.io/host-listener-port=8080 默认值, 每个ingress都必须指定端口, 可以用来区分相同路径的后端
# 共享模式： ingressController.hostNetwork.sharedListenerPort=8080 默认值, 每个ingress使用该端口, Cilium 根据 Hostname 或 Path 来路由到不同后端服务。
cilium upgrade cilium  \
    --namespace kube-system \
    --reuse-values \
    --set ingressController.enabled=true \
    --set ingressController.hostNetwork.enabled=true \
    --set envoy.securityContext.capabilities.keepCapNetBindService=true \
    --set securityContext.capabilities.ciliumAgent='{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}'

kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium

set +x
