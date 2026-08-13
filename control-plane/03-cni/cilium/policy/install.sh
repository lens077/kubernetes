#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

cat > lrp-otel.yml <<EOF
apiVersion: cilium.io/v2
kind: CiliumLocalRedirectPolicy
metadata:
  name: lrp-otel-collector
spec:
  redirectFrontend:
    serviceMatcher:
      serviceName: otel-collector-service
      namespace: observability
  redirectBackend:
    localEndpointSelector:
      matchLabels:
        app: opentelemetry
EOF
kubectl apply -f lrp-otel.yml
