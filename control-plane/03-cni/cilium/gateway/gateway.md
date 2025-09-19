#!/bin/bash
set -x
在 kube-system 命名空间中，为 cilium-envoy 容器添加缺失的 capabilities：
共享模式： --set ingressController.hostNetwork.sharedListenerPort=8080 默认值, 每个ingress使用该端口, Cilium 根据 Hostname 或 Path 来路由到不同后端服务。推荐大多数情况使用
专用模式： --set ingress.cilium.io/host-listener-port=8080 默认值, 每个ingress都必须指定端口, 可以用来区分相同路径的后端
```bash
cilium upgrade cilium \
--namespace kube-system \
--reuse-values \
--set kubeProxyReplacement=true \
--set gatewayAPI.enabled=true

kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```
