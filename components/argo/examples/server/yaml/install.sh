#!/bin/bash

set -x
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# argocd-redis 的镜像必须换掉，上游默认值在本集群拉不动。
#
# 上游 install.yaml 里 argocd-redis 用的是
#   ecr-public.aws.com/docker/library/redis:8.2.3-alpine
# 这个地址的 CDN 只解析出 IPv6，而集群节点没有 IPv6 出口，拉取直接失败：
#   failed to do request: dial tcp [2600:9000:2707:...]:443: connect: network is unreachable
#
# 危险之处在于它是**静默**的：老 Pod 靠本地镜像缓存能一直跑（本集群跑了 55 天），
# 直到某次重建才暴露，那时已经拉不回来了。2026-08-06 就是这么踩到的 ——
# VPA 驱逐 argocd-redis 之后它起不来，只能临时 nodeSelector 钉到还有缓存的 node2。
#
# docker.io 在本集群是通的，换成官方库同版本即可。
kubectl -n argocd set image deployment/argocd-redis redis=redis:8.2.3-alpine

# https://github.com/argoproj/argo-cd/releases
VERSION="v2.10.0"
OS="linux"
ARCH="amd64"
wget https://github.com/argoproj/argo-cd/releases/download/${VERSION}/argocd-${OS}-${ARCH}
chmod +x ./argocd-${OS}-${ARCH}
mv ./argocd-${OS}-${ARCH} /usr/local/bin/argocd

# 使用 CLI 登录
argocd admin initial-password -n argocd
# hv0uqcQpbwGhsiwN
PASSWORLD="0WOLHw-nJgkpfOGb"

# 登录, port为argocd-server的80端口
# 默认的账号是admin
argocd login 192.168.2.100:30618

# 更改密码
# 第一次要求输入原密码
# 第二次和第三次是重新新的密码
argocd account update-password

set +x
