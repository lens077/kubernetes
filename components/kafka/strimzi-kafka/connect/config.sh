#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

kubectl delete secret tcr-registry-secret -n kafka || true
kubectl create secret docker-registry tcr-registry-secret \
  --docker-server=ccr.ccs.tencentyun.com \
  --docker-username= \
  --docker-password= \
  -n kafka
