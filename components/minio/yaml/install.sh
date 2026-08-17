#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -p /home/kubernetes/minio
cd /home/kubernetes/minio

kubectl apply -f single.yaml -n minio
