#!/bin/bash

set -x

# 安装 cert-manager
mkdir -p /home/kubernetes/cert-manager
cd /home/kubernetes/cert-manager || exit
VERSION=v1.18.0-alpha.0
wget https://github.com/cert-manager/cert-manager/releases/download/${VERSION}/cert-manager.yaml
kubectl apply -f cert-manager.yaml

set +x
