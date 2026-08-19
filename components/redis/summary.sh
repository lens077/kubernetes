#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
vip=$(kctl -n redis get gateway redis-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
echo "Redis      → 密码 $(get_cred redis-password) (集群内 rediss://redis.redis.svc:6380${vip:+, 局域网 $vip:6380}; TLS, CA 见 secret redis-tls 的 ca.crt)"
