#!/usr/bin/env bash
# =============================================================================
# Consul —— 服务注册/发现 + KV 配置中心(ecommerce Kratos 服务依赖); 幂等; 可单独执行:
#   bash components/consul/install.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (存储 ${CONSUL_STORAGE_SIZE})"
ns_ensure "$NAMESPACE"

helm_install_component "$DIR"
routes_apply "$DIR"

log_ok "$ID 安装完成(集群内 consul-server.$NAMESPACE.svc:8500; 局域网 API 看 svc consul-expose-servers 的 EXTERNAL-IP)"
