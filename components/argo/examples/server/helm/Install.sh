#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# https://github.com/argoproj/argo-helm/tree/main

mkdir -pv /home/kubernetes/argocd
cd /home/kubernetes/argocd

#git clone --depth 1 https://github.com/argoproj/argo-helm.git
helm repo add argo https://argoproj.github.io/argo-helm
helm pull argo/argo-cd
tar -zxvf argo-cd-*.tgz

helm upgrade --install argocd \
  ./argo-cd \
  -n argocd \
  --create-namespace \
  -f examples/new-values.yml

# 获取初始化的密码, 账号admin
argocd admin initial-password -n argocd
