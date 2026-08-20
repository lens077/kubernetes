#!/usr/bin/env bash
# OpenFGA —— ReBAC 授权（选型定稿 §4）; 幂等; 可单独执行
# store = CNPG pg-main 内独立库 openfga(独立 role + 连接池上限 20)
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

pass=$(get_cred openfga-db)

log_step "声明 CNPG 独立库/角色 (postgresql/pg-main → db openfga)"
kctl -n postgresql create secret generic openfga-db \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=openfga --from-literal=password="$pass" \
  --dry-run=client -o yaml | kctl apply -f -
kctl apply -f "$DIR/manifests/cnpg-db.yaml"
kctl -n postgresql wait --for=condition=Ready database/openfga --timeout=120s || true

log_step "安装 $ID → 命名空间 $NAMESPACE"
ns_ensure "$NAMESPACE"
# sslmode=require: 测试环境先加密不验 CA; 生产化改 verify-ca + 挂 pg-main-ca(含 migrate job), 见 README
kctl -n "$NAMESPACE" create secret generic openfga-datastore \
  --from-literal=uri="postgresql://openfga:${pass}@pg-main-rw.postgresql.svc:5432/openfga?sslmode=require" \
  --dry-run=client -o yaml | kctl apply -f -
helm_install_component "$DIR" --version 0.3.12
log_ok "$ID 安装完成(验证见 examples/smoke.sh)"
