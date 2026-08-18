#!/usr/bin/env bash
# 被 80-components.sh 汇总进 /root/.k8s-installer-credentials 的一行摘要
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "Grafana    → https://grafana.${CLUSTER_DOMAIN:-dev.test} 用户 admin / 密码 $(get_cred grafana-admin) (svc: observability/grafana:80)"
