#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# CloudNativePG: 取代旧的 bitnami postgresql-ha(pgpool+repmgr) 方案
#   - bitnami 镜像 2025 年起受限(转 bitnamilegacy/hardened)
#   - CNPG 纯 K8s 原生: 无 Patroni/pgpool 附加组件, 实例管理器直接借 K8s API 做主从协调
#   - 自动故障转移 / 滚动小版本升级 / WAL 归档到 S3(MinIO) / PITR / Prometheus 指标
# https://cloudnative-pg.io/documentation/current/

mkdir -pv /home/kubernetes/cnpg
cd /home/kubernetes/cnpg

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

# 操作器(集群级, 装一次)
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace

kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=300s

# 数据库实例按需 apply(规格在 pg-cluster.yaml 里改)
kubectl create ns postgresql || true
kubectl apply -f pg-cluster.yaml

# 连接信息:
#   读写入口: pg-main-rw.postgresql.svc:5432 (只读: pg-main-ro / 任意: pg-main-r)
#   app 用户密码: kubectl -n postgresql get secret pg-main-app -o jsonpath='{.data.<REDACTED-20260817>}' | base64 -d
watch kubectl get cluster,po,svc -n postgresql
