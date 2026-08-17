#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -pv /home/kubernetes/kafka/ui
cd /home/kubernetes/kafka/ui

helm repo add kafbat-ui https://kafbat.github.io/helm-charts
helm install kafbat-ui kafbat-ui/kafka-ui

helm pull kafbat-ui/kafka-ui
tar -zxvf kafka-ui-*.tgz

# https://github.com/kafbat/helm-charts/blob/main/charts/kafka-ui/CONFIGURATION.md
# https://github.com/kafbat/helm-charts/blob/main/charts/kafka-ui/values.yaml
cat > kafka-ui-values.yml <<EOF
yamlApplicationConfig:
  kafka:
    clusters:
      - name: my-cluster
        bootstrapServers: my-cluster-kafka-bootstrap:9092
  auth:
    type: disabled
  management:
    health:
      ldap:
        enabled: false
service:
  labels: {}
  type: ClusterIP
  port: 80

resources:
  limits:
    cpu: 200m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi
EOF

helm upgrade --install kafbat-ui \
 ./kafka-ui \
 -f kafka-ui-values.yml \
 --create-namespace \
 -n kafka
