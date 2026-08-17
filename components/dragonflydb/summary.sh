#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
vip=$(kctl -n dragonfly get gateway dragonfly-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
echo "Dragonfly  → 密码 $(get_cred dragonfly-password) (集群内 dragonfly/dragonfly:6379${vip:+, 局域网 $vip:6379}; Redis 协议)"
