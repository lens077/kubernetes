#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# https://docs.victoriametrics.com/
# https://github.com/VictoriaMetrics/helm-charts#list-of-charts
mkdir /home/kubernetes/victoria-metrics
cd /home/kubernetes/victoria-metrics

kubectl create ns victoriametrics
helm show values oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-agent > values.yaml
helm install victoriametrics oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-cluster \
-f values.yaml -n victoriametrics \
--set vmstorage.persistentVolume.storageClass=openebs-lvmpv \
--set vmstorage.persistentVolume.size=8Gi

kubectl get po -n victoriametrics

# 集群版本的URL, helm安装的默认是集群版:
# http://victoriametrics-victoria-metrics-cluster-vmselect.victoriametrics:8481/select/0/prometheus

# 集群版 UI
# http://192.168.3.133:8481/select/0/vmui/

# grafana对接: https://docs.victoriametrics.com/victoriametrics/integrations/grafana/
#http://192.168.3.100:30176/select/0/prometheus

# 更多接口: https://docs.victoriametrics.com/cluster-victoriametrics/
# /prometheus/api/v1/query
# /prometheus/api/v1/query_range
# /prometheus/api/v1/series
# /prometheus/api/v1/labels
# /prometheus/api/v1/label/<label_name>/values
# /prometheus/api/v1/status/active_queries
# /prometheus/api/v1/status/top_queries
# /prometheus/api/v1/status/tsdb
# /prometheus/api/v1/export
# /prometheus/api/v1/export/csv
# /vmui
