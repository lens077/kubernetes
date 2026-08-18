#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1
echo "Fluent Bit → 每节点一个 DaemonSet Pod；容器日志写入 logging/loki:3100；自身指标 logging/fluent-bit:2020"
