#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -p /home/kubernetes/gateway-api
cd /home/kubernetes/gateway-api

# 进入到 https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_backendtlspolicies.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml

kubectl apply -f gateway.networking.k8s.io_tlsroutes.yaml
kubectl apply -f gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f gateway.networking.k8s.io_gateways.yaml
kubectl apply -f gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f gateway.networking.k8s.io_backendtlspolicies.yaml

helm upgrade cilium ./cilium \
    --namespace kube-system \
    --reuse-values \
    --set kubeProxyReplacement=true \
    --set gatewayAPI.enabled=true

kubectl rollout restart ds cilium -n kube-system
kubectl rollout restart deploy cilium-operator -n kube-system
