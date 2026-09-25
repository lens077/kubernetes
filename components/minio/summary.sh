#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
D=${CLUSTER_DOMAIN:-dev.test}
# summary 输出可能进入终端录屏或安装日志，禁止回显 root 密码。
echo "Silo       → 控制台 https://silo.apikv.com / S3 https://silo-api.apikv.com（凭据: OpenBao → Secret minio/minio-root；svc: minio/minio-service:9000）"
