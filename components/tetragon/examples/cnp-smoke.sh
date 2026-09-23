#!/usr/bin/env bash
# CiliumNetworkPolicy 正反向冒烟: 隔离 ns cnp-smoke, 不碰 ecommerce, 结束即删。
#   正向: client → echo:8080 与 DNS 放行
#   反向: client → 1.1.1.1:80 (未授权公网 egress) 被拒, 且 Hubble 有 Policy denied 记录
set -Eeuo pipefail
ns=cnp-smoke
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cleanup() { kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
# 上次没删干净的 ns 处于 Terminating 时 apply 会被拒("currently being deleted"), 先等它真没了
kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
kubectl apply -f "$base/cnp-smoke.yaml" >/dev/null
kubectl -n "$ns" rollout status deploy/echo --timeout=180s >/dev/null
kubectl -n "$ns" rollout status deploy/client --timeout=180s >/dev/null

# Pod Ready ≠ Cilium endpoint 策略已生效: 新建 Pod 的身份/策略 regen 有几秒滞后,
# 首个 curl 会 "Could not connect"(2026-09-22 实测), 所以正向检查带有界重试
ok=""
for _ in $(seq 1 15); do
  ok=$(kubectl -n "$ns" exec deploy/client -- curl -fsS --max-time 5 http://echo:8080/ 2>/dev/null || true)
  [[ $ok == cnp-ok ]] && break
  sleep 2
done
[[ $ok == cnp-ok ]] || { echo "FAIL: allowed echo request returned [$ok] after 30s" >&2; exit 1; }

# 反向: 策略里没放行的目的地必须被丢(超时, 不是拒绝——Cilium 默认 drop SYN)
if kubectl -n "$ns" exec deploy/client -- curl -sS --max-time 3 http://1.1.1.1/ >/dev/null 2>&1; then
  echo "FAIL: unrestricted egress was allowed" >&2
  exit 1
fi

# 证据: Hubble 里应有那条 1.1.1.1 的 DROPPED(Policy denied), 证明是策略丢的不是网络不通。
# 单个 cilium-agent 只看得到本节点的流, 必须挑 client 所在节点的那个 agent(不是 items[0])。
node=$(kubectl -n "$ns" get pod -l app=client -o jsonpath='{.items[0].spec.nodeName}')
agent=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')
# hubble 的 --to-ip 对 world 目的地不命中(2026-09-22 实测), 拉 DROPPED 流后用 grep 定位
dropped=$(kubectl -n kube-system exec "$agent" -c cilium-agent -- \
  hubble observe --namespace "$ns" --verdict DROPPED --last 50 2>/dev/null | grep '1.1.1.1:80' | grep -c 'Policy denied' || true)
[[ $dropped -ge 1 ]] || { echo "FAIL: 1.1.1.1 未连通但 $node 的 Hubble 没有 'Policy denied' 记录, 不能证明是 CNP 拦的" >&2; exit 1; }

printf 'PASS: CNP 放行 client→echo, 拒绝未授权 egress (Hubble Policy denied ×%s on %s)\n' "$dropped" "$node"
