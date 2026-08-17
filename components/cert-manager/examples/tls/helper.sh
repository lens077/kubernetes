#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 检查集群级别的 Issuer (ClusterIssuer)
kubectl get clusterissuer

# 检查特定命名空间内的 Issuer (Issuer)
kubectl get issuer -n minio

# 观察请求状态
kubectl get certificaterequest -n minio

# 检查secret
kubectl get secret minio-tls-secret -n minio

# 查看cert-manager日志
kubectl logs -n cert-manager deployment/cert-manager
