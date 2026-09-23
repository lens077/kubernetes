#!/usr/bin/env bash
# Kyverno audit 冒烟: 建一个同时违反两条 audit 策略(无 limits + :latest)的 Pod,
# 断言 (1) Pod 没被拒(Audit 语义) (2) PolicyReport 出现两条 fail。隔离 ns, 结束即删。
set -Eeuo pipefail
ns=kyverno-smoke
cleanup() { kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl get clusterpolicy require-requests-limits disallow-latest-tag >/dev/null \
  || { echo "FAIL: audit 策略未安装(先跑 install.sh)" >&2; exit 1; }
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=60s >/dev/null

kubectl create namespace "$ns" >/dev/null
# Audit 模式: 违规 Pod 必须能建出来
kubectl -n "$ns" run audit-violator --image=busybox:latest --restart=Never -- sleep 300 >/dev/null \
  || { echo "FAIL: Audit 策略拒绝了 Pod —— 说明有策略被误设成 Enforce" >&2; exit 1; }

# reports-controller 异步生成 PolicyReport; 给它 90s
for _ in $(seq 1 30); do
  fails=$(kubectl -n "$ns" get policyreport -o json 2>/dev/null \
    | jq -r '[.items[].results[]? | select(.result=="fail") | .policy] | unique | join(",")')
  [[ $fails == *disallow-latest-tag* && $fails == *require-requests-limits* ]] && break
  sleep 3
done
[[ $fails == *disallow-latest-tag* && $fails == *require-requests-limits* ]] \
  || { echo "FAIL: 90s 内 PolicyReport 未出现两条 fail, 实际: [$fails]" >&2
       kubectl -n "$ns" get policyreport -o yaml 2>/dev/null | tail -30 >&2; exit 1; }

printf 'PASS: Audit 模式 Pod 放行, PolicyReport 记录 fail: %s\n' "$fails"
