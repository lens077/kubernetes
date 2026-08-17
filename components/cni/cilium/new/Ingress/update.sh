#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# https://docs.cilium.io/en/v1.14/network/servicemesh/ingress/#gs-ingress

# Cilium 允许您为 Ingress 资源指定负载均衡器模式：
# dedicated ：Ingress 控制器将为 Ingress 创建专用的负载均衡器。
# shared ：Ingress 控制器将为所有 Ingress 资源使用共享负载均衡器。
# 每种负载均衡模式都有其优缺点。共享模式通过在集群中所有入口资源共享单一负载均衡器配置来节省资源，而专用模式则有助于避免资源间潜在冲突（如路径前缀）。

# 成为默认的入口控制器 --set ingressController.default=true标志。这将创建入口条目，即使ingressClass 未设置。

cilium upgrade \
   --namespace kube-system \
   --reuse-values \
   --set ingressController.enabled=true \
   --set ingressController.loadbalancerMode=dedicated \
   --set ingressController.default=true \
   --set nodePort.enabled=true \
   --set kubeProxyReplacement=true \
   --set l7Proxy=true

kubectl rollout restart ds cilium -n kube-system
kubectl rollout restart deploy cilium-operator -n kube-system
