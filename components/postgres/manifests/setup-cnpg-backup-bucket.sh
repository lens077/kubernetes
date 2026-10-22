#!/usr/bin/env bash
# =============================================================================
# pg-main 备份桶与最小权限凭据（Barman Cloud Plugin 的前置，只需跑一次）
#
# 产出：
#   - MinIO 桶 cnpg-backups
#   - 专用服务账号 cnpg-pg-main，权限只覆盖这一个桶（不用 root）
#   - Secret postgresql/cnpg-backup-s3（ACCESS_KEY_ID / ACCESS_SECRET_KEY）
#
# 用法：  bash components/postgres/manifests/setup-cnpg-backup-bucket.sh
# 之后：  kubectl apply -f cnpg-objectstore-pg-main.yaml
#
# 幂等：重复执行会吊销旧凭据并生成新的（轮换语义）。
#
# ⚠️ 轮换后必须重启 pg-main-1，插件 sidecar 才会读到新 Secret：
#      kubectl -n postgresql rollout restart deploy/... （或 delete pod pg-main-1）
#    只更新 Secret 不重启的话，sidecar 仍用旧凭据，WAL 归档会开始失败。
# =============================================================================
set -Eeuo pipefail

NS=postgresql
SECRET=cnpg-backup-s3
BUCKET=cnpg-backups
ACCOUNT=cnpg-pg-main

echo "=== 1. 生成凭据（不回显）==="
# MinIO 要求 access key >= 3 字符、secret >= 8 字符；取 22/40 留足余量。
# ⚠️ 绝不要把这两个值打印到 stdout/日志：mc 的 svcacct add 默认会回显它们，
#    一旦回显就必须当已泄露处理并轮换（2026-10-21 实际踩过，见 audit 报告）。
AK=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 22)
SK=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
[[ ${#AK} -ge 3 && ${#SK} -ge 8 ]] || { echo "凭据长度异常: ak=${#AK} sk=${#SK}" >&2; exit 1; }
echo "生成完成（长度 ak=${#AK} sk=${#SK}，值不显示）"

echo "=== 2. 最小权限策略：只允许操作 $BUCKET 这一个桶 ==="
POLICY=$(mktemp)
trap 'rm -f "$POLICY"' EXIT
cat > "$POLICY" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$BUCKET"]},
    {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts","s3:ListBucketMultipartUploads"],"Resource":["arn:aws:s3:::$BUCKET/*"]}
  ]
}
JSON

echo "=== 3. 建桶 + 建账号（mc 输出全部丢弃，避免回显凭据）==="
# -i 才能把策略文件经 stdin 送进容器，否则 mc 读到空策略直接失败。
# 账号已存在时 svcacct add 会因 access-key 冲突报错，改用先删后建保证幂等。
kubectl -n minio exec -i deploy/minio -- sh -c "
  set -e
  mc alias set local http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1
  mc mb --ignore-existing local/$BUCKET >/dev/null 2>&1
  mc admin user svcacct rm local '$AK' >/dev/null 2>&1 || true
  mc admin user svcacct add local \"\$MINIO_ROOT_USER\" \
    --access-key '$AK' --secret-key '$SK' \
    --policy /dev/stdin --name $ACCOUNT \
    --description 'CNPG pg-main backup, least privilege: $BUCKET only' \
    >/dev/null 2>&1
" < "$POLICY"
echo "桶与账号就绪"

echo "=== 4. 写入 Secret ==="
kubectl -n "$NS" create secret generic "$SECRET" \
  --from-literal="ACCESS_KEY_ID=$AK" \
  --from-literal="ACCESS_SECRET_KEY=$SK" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret $NS/$SECRET 已更新"

echo "=== 5. 验证（只报可用性，不打印凭据）==="
kubectl -n "$NS" get secret "$SECRET" \
  -o jsonpath="{.metadata.name}{'  keys='}{.data.ACCESS_KEY_ID}{'/'}{.data.ACCESS_SECRET_KEY}{'\n'}" \
  | sed 's/[A-Za-z0-9+/=]\{8,\}/<redacted>/g'
echo "完成。下一步：kubectl apply -f cnpg-objectstore-pg-main.yaml"
