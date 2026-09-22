#!/usr/bin/env bash
# Dragonfly cache: TLS + AUTH, ClusterIP plus a dedicated Gateway TCP listener.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

ns_ensure "$NAMESPACE"

if ! kctl -n "$NAMESPACE" get secret dragonfly-auth >/dev/null 2>&1; then
  pw=$(get_cred dragonfly-password)
  kctl -n "$NAMESPACE" create secret generic dragonfly-auth \
    --from-literal=password="$pw" --dry-run=client -o yaml | kctl apply -f -
  unset pw
fi

kctl -n "$NAMESPACE" apply -f "$DIR/manifests/00-certificate.yaml"

chart="${CACHE_DIR:-/var/cache/k8s-installer}/charts/dragonfly-${DRAGONFLY_CHART_VERSION}.tgz"
[[ -s "$chart" ]] || chart="oci://ghcr.io/dragonflydb/dragonfly/helm/dragonfly"
helm upgrade --install dragonfly "$chart" \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$DRAGONFLY_CHART_VERSION" \
  --set replicaCount=1 \
  --set image.repository=docker.dragonflydb.io/dragonflydb/dragonfly \
  --set image.pullPolicy=IfNotPresent \
  --set service.type=ClusterIP \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=250m \
  --set resources.limits.memory=512Mi \
  --set passwordFromSecret.enable=true \
  --set passwordFromSecret.existingSecret.name=dragonfly-auth \
  --set passwordFromSecret.existingSecret.key=password \
  --set tls.enabled=true \
  --set tls.existing_secret=dragonfly-tls \
  --set storage.enabled=true \
  --set storage.storageClassName="$SC_NAME" \
  --set storage.requests=2Gi

kctl apply -f "$DIR/manifests/01-tcp-route.yaml"
kctl -n "$NAMESPACE" rollout status statefulset/dragonfly --timeout=300s
log_ok "$ID 安装完成(TLS+AUTH, ClusterIP, TCPRoute 10.10.31.242:6379)"
