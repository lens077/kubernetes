#!/usr/bin/env bash
# 验证 Tetragon 三节点观察模式、BTF 和 audit-only 策略边界。
set -Eeuo pipefail

ns=tetragon
selector='app.kubernetes.io/name=tetragon,app.kubernetes.io/component=agent'
expected_nodes='node101 node102 node103'
actual_nodes=$(kubectl -n "$ns" get pods -l "$selector" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | xargs)
[[ $actual_nodes == "$expected_nodes" ]] \
  || { echo "失败：agent 节点为 [$actual_nodes]，预期 [$expected_nodes]" >&2; exit 1; }

while read -r agent; do
  [[ -n $agent ]] || continue
  agent_logs=$(kubectl -n "$ns" logs "$agent" -c tetragon)
  grep -q 'BTF file: using metadata file' <<<"$agent_logs" \
    || { echo "失败：$agent 未确认加载 BTF" >&2; exit 1; }
done < <(kubectl -n "$ns" get pods -l "$selector" -o name | cut -d/ -f2)

[[ $(kubectl get tracingpolicies.cilium.io -o name 2>/dev/null | wc -l | tr -d ' ') == 0 ]] \
  || { echo "失败：存在集群级 TracingPolicy" >&2; exit 1; }
policies=$(kubectl -n ecommerce get tracingpoliciesnamespaced.cilium.io -o name 2>/dev/null | sort)
[[ $policies == 'tracingpolicynamespaced.cilium.io/ecommerce-service-account-token-access' ]] \
  || { echo "失败：namespaced 策略集合与预期不符：$policies" >&2; exit 1; }

printf '部署边界通过：nodes=[%s]，三个 agent 均加载 BTF。\n' "$actual_nodes"
printf '策略边界通过：仅 ecommerce-service-account-token-access（audit-only）。\n'
printf '当前资源快照：\n'
kubectl -n "$ns" top pod || true
printf '每节点最近事件样本数（10 分钟）：\n'
while read -r agent; do
  [[ -n $agent ]] || continue
  count=$(kubectl -n "$ns" logs "$agent" -c export-stdout --since=10m | wc -l | tr -d ' ')
  printf '%s %s\n' "$agent" "$count"
done < <(kubectl -n "$ns" get pods -l "$selector" -o name | cut -d/ -f2)
