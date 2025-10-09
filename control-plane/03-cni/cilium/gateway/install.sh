#!/bin/bash
set -x

wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
wget https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml

kubectl apply -f gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f gateway.networking.k8s.io_gateways.yaml
kubectl apply -f gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f gateway.networking.k8s.io_grpcroutes.yaml

set +x
