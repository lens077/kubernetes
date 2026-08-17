#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

k8s_postgres_secret_name="postgres-gateway-tls"
k8s_postgres_secret="postgres-gateway-tls-secret"
kubectl get certificate ${k8s_postgres_secret_name} -n postgres
kubectl describe certificate ${k8s_postgres_secret_name} -n postgres
kubectl get secret ${k8s_postgres_secret} -n postgres \
   -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt

kubectl get secret ${k8s_postgres_secret} -n postgres \
   -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key

kubectl get secret ${k8s_postgres_secret} -n postgres \
   -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

openssl x509 -in tls.crt -noout -text
