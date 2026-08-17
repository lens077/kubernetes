#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

kubectl exec -it myminio-pool-0-0 -n minio-tenant -- cat /tmp/certs/public.crt

vi minio-public.crt

kubectl create secret generic minio-ca-cert \
  -n observability \
  --from-file=ca.crt=minio-public.crt
