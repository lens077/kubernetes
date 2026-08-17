#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail
mkdir -p /home/kubernetes/loki
cd /home/kubernetes/loki

helm repo add grafana https://grafana-community.github.io/helm-charts
helm pull grafana/loki
tar -zxvf loki-*.tgz

cat > loki-monolithic-mode-values.yml <<EOF
deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  resources:
    limits:
      memory: 512Mi

# chunksCache是一个 memcached 实例，用来缓存从 MinIO 读取的日志块
chunksCache:
  allocatedMemory: 128 # 实际分配给 memcached 的内存(MB)
  resources:
    requests:
      memory: "64Mi"
      cpu: "10m"
    limits:
      memory: "256Mi"

resultsCache:
  allocatedMemory: 128
  resources:
    requests:
      memory: "64Mi"

loki:
  # 不使用多租户模式
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  pattern_ingester:
    enabled: true
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
  ruler:
    enable_api: true

  minio:
    enabled: false
    replicas: 1
    # Since we only have 1 replica, that means 2 drives must be used.
    drivesPerNode: 2
    buckets:
      - name: chunks
        policy: none
        purge: false
      - name: ruler
        policy: none
        purge: false
    persistence:
      size: 5Gi
      annotations: {}
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
  storage:
    type: s3
    bucketNames:
      chunks: chunks
      ruler: ruler
    s3:
      endpoint: http://minio-service.minio.svc:9000
      secretAccessKey: LWBPpaCEYDnYFX6QUL0v21Dd6LKiWvbk4E5cfBIq
      accessKeyId: A3UhS0icgTX4lEHK9fp6
      s3ForcePathStyle: true
      insecure: false
      http_config: {}
      # -- Check https://grafana.com/docs/loki/latest/configure/#s3_storage_config for more info on how to provide a backoff_config
      backoff_config: {}
      disable_dualstack: false

# Zero out replica counts of other deployment modes
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomPlanner:
  replicas: 0
bloomBuilder:
  replicas: 0
bloomGateway:
  replicas: 0
test:
  enabled: false
lokiCanary:
  enabled: false
sidecar:
  rules:
    enabled: false # 如果暂时不需要告警规则

EOF

helm upgrade --install loki \
  ./loki \
  --create-namespace \
  -n loki \
  -f loki-monolithic-mode-values.yml

