#!/usr/bin/env bash
# =============================================================================
# Strimzi Kafka 算子 —— 只装算子; Kafka 集群按需 apply(examples/)
#   幂等; 可单独执行: bash components/kafka/install.sh
#
# 用 helm 而不是 YAML bundle: 规避 2026-08-06 笔记里 bundle 的三个坑
# (版本化 URL 404 / myproject 命名空间残留 / CRD 体积超 client-side apply 上限)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID(Strimzi 算子) → 命名空间 $NAMESPACE"
helm_install_component "$DIR"

log_ok "$ID 算子安装完成"
log_info "建集群: kubectl apply -f $DIR/examples/kafka-single-node.yaml (KRaft 单节点)"
log_info "对外暴露: 用 Strimzi 的 external listener(type: loadbalancer), 不要走 Gateway —— 见 README"
