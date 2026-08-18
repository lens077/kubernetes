#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
lb=$(kctl -n consul get svc consul-expose-servers -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || lb=""
echo "Consul    → https://consul.${CLUSTER_DOMAIN:-dev.test} 无认证; 局域网 API http://${lb:-<待分配>}:8500 (svc: consul/consul-server:8500)"
