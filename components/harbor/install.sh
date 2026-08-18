#!/usr/bin/env bash
# =============================================================================
# Harbor —— OCI 镜像仓库；幂等；可单独执行：
#   bash components/harbor/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

ver=${HARBOR_CHART_VERSION:-1.19.2}

# Harbor 官方 ARM64 release 从 v2.16.0 开始。用 chart 的 appVersion 判断，避免把
# chart 版本和 Harbor 版本混为一谈；闸门位于所有集群写操作之前。
read -r helm_repo_name helm_repo_url <<<"$HELM_REPO"
[[ -n $helm_repo_name && -n $helm_repo_url ]] \
  || die "harbor component.env 的 HELM_REPO 格式无效"
helm_repo_add "$helm_repo_name" "$helm_repo_url"
app_version=$(helm_cmd show chart "$HELM_CHART" --version "$ver" \
  | awk '$1 == "appVersion:" {gsub(/"/, "", $2); sub(/^v/, "", $2); print $2; exit}')
[[ -n $app_version ]] || die "无法解析 harbor chart $ver 的 appVersion"

node_arches=$(kctl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.architecture}{"\n"}{end}')
if grep -q '=arm64$' <<<"$node_arches" && ! ver_ge "$app_version" "2.16.0"; then
  die "Harbor v$app_version 官方镜像不支持 ARM64；集群节点：
$node_arches
官方 ARM64 release 从 v2.16.0 开始。保持 ADDON_HARBOR=false，升级 HARBOR_CHART_VERSION 后重试"
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (chart $ver / app v$app_version / https://$HOSTNAME)"
ns_ensure "$NAMESPACE"

# get_cred 只在节点状态目录保存随机值；仓库和 values.yaml 不包含凭据。
admin_pass=$(get_cred harbor-admin)
database_pass=$(get_cred harbor-database)
registry_pass=$(get_cred harbor-registry)
secret_key=$(get_cred harbor-secret-key)
secret_key=${secret_key:0:16}

kctl -n "$NAMESPACE" create secret generic harbor-admin \
  --from-literal=HARBOR_ADMIN_PASSWORD="$admin_pass" \
  --dry-run=client -o yaml | kctl apply -f -
kctl -n "$NAMESPACE" create secret generic harbor-secret-key \
  --from-literal=secretKey="$secret_key" \
  --dry-run=client -o yaml | kctl apply -f -

dyn=$(mktemp)
trap 'rm -f "$dyn"' EXIT
chmod 600 "$dyn"
{
  printf 'existingSecretAdminPassword: harbor-admin\n'
  printf 'existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD\n'
  printf 'existingSecretSecretKey: harbor-secret-key\n'
  printf 'database:\n  internal:\n    password: "%s"\n' "$database_pass"
  printf 'registry:\n  credentials:\n    password: "%s"\n' "$registry_pass"
} > "$dyn"

helm_install_component "$DIR" --version "$ver" -f "$dyn"
routes_apply "$DIR"

rm -f "$dyn"
trap - EXIT
log_ok "$ID 安装完成(https://$HOSTNAME；用户 admin；初始密码见 $STATE_DIR/creds/harbor-admin)"
