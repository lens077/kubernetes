#!/bin/bash

set -x
#https://github.com/grafana/helm-charts/blob/main/charts/loki-stack/README.md
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm pull grafana/loki-stack
tar -zxvf loki-stack*.tgz

cat > change-values.yml <<EOF
test_pod:
  enabled: false # 不需要测试 pod

loki:
  enabled: true # 启用 Loki
  isDefault: true
  url: http://{{(include "loki.serviceName" .)}}:{{ .Values.loki.service.port }}
  readinessProbe:
    httpGet:
      path: /ready
      port: http-metrics
    initialDelaySeconds: 45
  livenessProbe:
    httpGet:
      path: /ready
      port: http-metrics
    initialDelaySeconds: 45
  # datasource:
  #   jsonData: "{}" # 将由 Grafana sidecar 自动生成
  #   uid: ""

promtail:
  enabled: false # 使用 Fluent-Bit 代替 Promtail

fluent-bit:
  enabled: false # 你已经有独立的 Fluent-Bit DaemonSet，所以这里禁用

grafana:
  enabled: true # 启用 Grafana
  sidecar:
    datasources:
      label: "grafana_datasource"
      labelValue: "true"
      enabled: true
      maxLines: 1000

prometheus:
  enabled: false # 使用 VictoriaMetrics 代替 Prometheus

filebeat:
  enabled: false # 禁用 filebeat

logstash:
  enabled: false # 禁用 logstash
EOF

helm upgrade --install loki ./loki-stack \
--create-namespace \
-n loki-stack

# 获取密码， 账号admin
kubectl get secret --namespace loki-stack loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

set +x

