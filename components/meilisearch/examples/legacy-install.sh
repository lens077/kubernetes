#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# Meilisearch 官方 chart: https://github.com/meilisearch/meilisearch-kubernetes#-documentation
# 选型(2026-08-16): 替代 OpenSearch/ES —— elastic v9 客户端产品头校验连不上 OpenSearch;
# 商品即时搜索场景下 Meilisearch 中文分词开箱、typo 容忍默认开、内存占用约为 ES 的 1/4

mkdir -pv /home/kubernetes/meilisearch
cd /home/kubernetes/meilisearch

helm repo add meilisearch https://meilisearch.github.io/meilisearch-kubernetes
helm repo update meilisearch

kubectl create ns search || true

# master key 至少 16 字节; 生产环境改成随机值并妥善保存
MEILI_MASTER_KEY=${MEILI_MASTER_KEY:-$(openssl rand -hex 16)}
kubectl -n search create secret generic meilisearch-master-key \
  --from-literal=MEILI_MASTER_KEY="$MEILI_MASTER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "master key: $MEILI_MASTER_KEY"

cat > meili-values.yaml <<EOF
environment:
  MEILI_ENV: production
  MEILI_NO_ANALYTICS: "true"
auth:
  existingMasterKeySecret: meilisearch-master-key
persistence:
  enabled: true
  storageClass: openebs-lvm      # 按集群实际 StorageClass 调整
  size: 10Gi
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 1Gi
service:
  type: ClusterIP
  port: 7700
EOF

helm upgrade --install meilisearch meilisearch/meilisearch \
  -n search -f meili-values.yaml

kubectl get po,svc -n search
# 健康检查: kubectl -n search port-forward svc/meilisearch 7700 后 GET /health
