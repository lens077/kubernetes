#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
D=${CLUSTER_DOMAIN:-app.com}
echo "MinIO      → 控制台 https://minio-ui.$D / S3 https://s3.$D 用户 admin / 密码 $(get_cred minio-root) (svc: minio/minio-service:9000)"
