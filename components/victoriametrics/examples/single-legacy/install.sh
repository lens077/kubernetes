#!/bin/bash
set -x

mkdir -pv /home/kubernetes/victoriametrics
cd /home/kubernetes/victoriametrics

# https://docs.victoriametrics.com/helm/victoria-metrics-single/

helm repo add vm https://victoriametrics.github.io/helm-charts/

helm repo update

helm pull vm/victoria-metrics-single
tar -zxvf victoria-metrics-single*.tgz

# otel支持: https://docs.victoriametrics.com/guides/getting-started-with-opentelemetry/
cat << EOF > vm-values.yaml
server:
  extraArgs:
    opentelemetry.usePrometheusNaming: true
EOF

#对于 OpenTelemetry, VictoriaMetrics，写入端点为：
# http://victoria-metrics-victoria-metrics-single-server.default.svc.cluster.local.:8428/opentelemetry/v1/metrics
# http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:30237/opentelemetry/v1/metrics
helm upgrade --install vm-single ./victoria-metrics-single/ \
  -n victoriametrics \
  --create-namespace \
  --reuse-values \
  --set server.persistentVolume.storageClassName=openebs-lvmpv \
  --set server.persistentVolume.size=8Gi \
  --set server.service.type=ClusterIP \
  -f vm-values.yaml

kubectl get pvc -n victoriametrics

# 单机版的URL，直接输入IP+端口即可: https://docs.victoriametrics.com/victoriametrics/integrations/grafana/

set +x
