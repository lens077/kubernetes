#!/usr/bin/env bash
# =============================================================================
# profiling —— 持续剖析: Pyroscope v2 server + Grafana Alloy eBPF 采集器; 幂等; 可单独执行:
#   bash components/profiling/install.sh
# 采集器是 privileged DaemonSet(要求 hostPID), 需在可运行特权 Pod 的集群使用。
# 业务服务无需改代码: eBPF 直接抓进程 CPU 栈; Go 符号通过 .gopclntab 解析。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

log_step "安装 $ID → 命名空间 $NAMESPACE (Pyroscope v2 + Alloy eBPF)"
ns_ensure "$NAMESPACE"

while read -r f; do
  [[ -n $f ]] || continue
  kctl apply -n "$NAMESPACE" -f "$f"
done < <(manifest_files "$DIR/manifests")

kctl -n "$NAMESPACE" rollout status statefulset/pyroscope --timeout=300s
kctl -n "$NAMESPACE" rollout status daemonset/alloy-pyroscope --timeout=300s

log_ok "$ID 安装完成: Service http://pyroscope.$NAMESPACE.svc.cluster.local:4040 (数据源 uid ds-pyroscope)"
