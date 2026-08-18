#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
D=${CLUSTER_DOMAIN:-dev.test}
# 密码读集群 Secret(Vault/ESO 物化的真相);读不到再退 get_cred(legacy 路径)
p=$(kctl -n minio get secret minio-root -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
[[ -n $p ]] || p="$(get_cred minio-root)(legacy)"
echo "MinIO      → 控制台 https://minio-ui.$D / S3 https://s3.$D 用户 admin / 密码 $p (svc: minio/minio-service:9000)"
