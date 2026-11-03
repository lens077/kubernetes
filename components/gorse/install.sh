#!/usr/bin/env bash
# gorse 推荐引擎：ArgoCD(helm chart) 部署，cache=Dragonfly db2，data=CNPG pg-main。
# 前置：dragonfly/postgres/argo 组件已装；ArgoCD 可访问 ${ARGO_REPO_URL}(public, 无需凭据)。
# 凭据不入仓：api-key 沿用 node2 config.toml 的现值（Config Center 同口径），首次部署前
# 由操作者灌入 $STATE_DIR/creds/gorse-api-key（0600）；其余键自动生成/现取。
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

ns_ensure "$NAMESPACE"

# ---- 1. CNPG: database gorse + 独立用户（幂等） ------------------------------
# pg-main 是 CNPG CR，不自动建业务库；用 initdb 的 owner(app) 登录实例建 gorse 专用用户/库。
PG_POD=pg-main-1
gorse_pw=$(get_cred gorse-pg-password)
kctl -n postgresql exec "$PG_POD" -c postgres -- psql -U postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='gorse'" | grep -q 1 || \
kctl -n postgresql exec "$PG_POD" -c postgres -- psql -U postgres -c \
  "CREATE ROLE gorse LOGIN PASSWORD '$gorse_pw'"
kctl -n postgresql exec "$PG_POD" -c postgres -- psql -U postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" | grep -q 1 || \
kctl -n postgresql exec "$PG_POD" -c postgres -- psql -U postgres -c \
  "CREATE DATABASE $PG_DB OWNER gorse"

# ---- 2. Secret gorse-store（幂等；缺键才补，不覆盖人工轮换过的值）-------------
if ! kctl -n "$NAMESPACE" get secret gorse-store >/dev/null 2>&1; then
  dfly_pw=$(kctl -n dragonfly get secret dragonfly-auth -o jsonpath='{.data.password}' | base64 -d)
  api_key=$(get_cred gorse-api-key)
  admin_key=$(get_cred gorse-admin-api-key)
  kctl -n "$NAMESPACE" create secret generic gorse-store \
    --from-literal=cache-store="rediss://default:${dfly_pw}@${CACHE_SVC}:6379/${CACHE_DB_INDEX}" \
    --from-literal=data-store="postgres://gorse:${gorse_pw}@${PG_RW}:5432/${PG_DB}?sslmode=verify-full&sslrootcert=/etc/gorse/ca/pg/ca.crt" \
    --from-literal=api-key="$api_key" \
    --from-literal=admin-api-key="$admin_key"
  unset dfly_pw api_key admin_key
  log_ok "Secret gorse-store 已创建"
else
  log_ok "Secret gorse-store 已存在, 跳过(轮换请手工改)"
fi

# ---- 3. 一次性数据迁移入口（node1 pg → CNPG） --------------------------------
# 迁移后此步是空操作（源库只为文档保留）。用法: bash components/gorse/install.sh --migrate <ssh_alias=pg所在的宿主>
# node1 侧: docker exec postgres pg_dump -h 127.0.0.1 -U root -d gorse
if [[ "${1:-}" == "--migrate" ]]; then
  host="${2:?用法: install.sh --migrate <node1-ssh-alias>}"
  log_ok "从 $host 导出 gorse 库并导入 CNPG..."
  ssh "$host" 'docker exec postgres pg_dump -h 127.0.0.1 -U root -d gorse' \
    | kctl -n postgresql exec -i "$PG_POD" -c postgres -- psql -U gorse -d "$PG_DB" -v ON_ERROR_STOP=1
  log_ok "数据迁移完成"
fi

# ---- 4. ArgoCD Application（chart 即本目录 ./chart） -------------------------
kctl apply -f "$DIR/argocd/application.yaml"
log_ok "Application gorse 已提交, 等待 ArgoCD sync..."
sleep 10
kctl -n argocd wait application/gorse --for=condition=Healthy --timeout=600s 2>/dev/null \
  || kctl -n argocd get application/gorse -o wide

kctl -n "$NAMESPACE" rollout status deployment/gorse --timeout=600s
log_ok "$ID 安装完成(https://$HOSTNAME, cache=${CACHE_SVC}/${CACHE_DB_INDEX}, data=${PG_RW}/${PG_DB})"
