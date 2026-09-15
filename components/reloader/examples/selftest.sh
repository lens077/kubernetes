#!/usr/bin/env bash
# =============================================================================
# Reloader 端到端自检 —— 证明「Secret 改值 → 带注解的 Deployment 真的滚动了」, 不是只看 Pod Running。
#   bash components/reloader/examples/selftest.sh          # 跑完自动清理
#   KEEP=1 bash components/reloader/examples/selftest.sh   # 保留现场
# 判据: Secret 改值后 60s 内 Deployment 的 observedGeneration 递增, 且新 Pod 读到新值。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../_lib" &>/dev/null && pwd)/env.sh" >/dev/null 2>&1

NS=reloader-selftest
cleanup() { [[ ${KEEP:-0} == 1 ]] && { log_info "KEEP=1, 保留命名空间 $NS"; return 0; }; kctl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

ns_ensure "$NS" >/dev/null
kctl -n "$NS" create secret generic demo --from-literal=PASSWORD=v1 --dry-run=client -o yaml | kctl apply -f - >/dev/null
kctl -n "$NS" apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  annotations:
    secret.reloader.stakater.com/reload: "demo"
spec:
  replicas: 1
  selector: { matchLabels: { app: demo } }
  template:
    metadata: { labels: { app: demo } }
    spec:
      containers:
        - name: app
          image: busybox:1.37
          command: ["sh", "-c", "echo PASSWORD=$PASSWORD; sleep 3600"]
          env:
            - name: PASSWORD
              valueFrom: { secretKeyRef: { name: demo, key: PASSWORD } }
YAML
kctl -n "$NS" rollout status deploy/demo --timeout=120s >/dev/null || die "基线 Deployment 没起来(镜像拉不到?)"
gen0=$(kctl -n "$NS" get deploy demo -o jsonpath='{.status.observedGeneration}')
log_info "基线 generation=$gen0, 改 Secret 值 v1 → v2"

kctl -n "$NS" create secret generic demo --from-literal=PASSWORD=v2 --dry-run=client -o yaml | kctl apply -f - >/dev/null
for _ in $(seq 1 30); do
  gen=$(kctl -n "$NS" get deploy demo -o jsonpath='{.status.observedGeneration}')
  [[ $gen -gt $gen0 ]] && break
  sleep 2
done
[[ ${gen:-0} -gt $gen0 ]] || die "60s 内 Deployment 没滚动(generation 仍为 $gen0): kubectl -n reloader logs deploy/reloader-reloader"
kctl -n "$NS" rollout status deploy/demo --timeout=120s >/dev/null
# 滚动刚完成时旧 Pod 还在 Terminating, `logs deploy/` 可能挑到它 —— 按创建时间取最新的那个
newest=$(kctl -n "$NS" get pod -l app=demo --sort-by=.metadata.creationTimestamp -o name | tail -1)
val=$(kctl -n "$NS" logs "$newest" --tail=5 | sed -n 's/^PASSWORD=//p' | tail -1)
[[ $val == v2 ]] || die "新 Pod 读到的是 '$val', 不是 v2"
log_ok "Reloader 自检通过: generation $gen0 → $gen, 新 Pod PASSWORD=v2"
