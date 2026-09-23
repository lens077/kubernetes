#!/usr/bin/env bash
# VPA admission webhook 冒烟(隔离 ns vpa-smoke, 结束即删):
#   1) 匹配 VPA 的新 Pod 必须带 vpaObservedContainers 注解 —— 证明 webhook 真的在拦 Pod 创建
#   2) recommender 给出推荐后, Initial 模式重建的 Pod 必须被注入 requests 且带 vpaUpdates 注解
#   3) 集群里所有非本测试的 VPA 仍是 Off/RequestsOnly —— 装 updater 不等于允许它驱逐业务 Pod
# updater 的驱逐行为不在此验(需要 ≥2 副本 + 推荐值显著漂移, 与一次性冒烟不兼容), 只确认它 Ready。
set -Eeuo pipefail
ns=vpa-smoke
cleanup() { kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

for d in admission-controller recommender updater; do
  kubectl -n kube-system rollout status "deploy/vpa-vertical-pod-autoscaler-$d" --timeout=60s >/dev/null \
    || { echo "FAIL: vpa $d 未 Ready" >&2; exit 1; }
done

# 3) 先查现有 VPA 没有被误改成会驱逐的模式
bad=$(kubectl get vpa -A -o json | jq -r '.items[] | select(.metadata.namespace!="'"$ns"'") | select((.spec.updatePolicy.updateMode // "Auto") as $m | ($m!="Off" and $m!="RequestsOnly")) | "\(.metadata.namespace)/\(.metadata.name)=\(.spec.updatePolicy.updateMode)"')
[[ -z $bad ]] || { echo "FAIL: 存在会自动改 Pod 的 VPA(非 Off/RequestsOnly): $bad" >&2; exit 1; }

kubectl create namespace "$ns" >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: probe, namespace: vpa-smoke}
spec:
  replicas: 1
  selector: {matchLabels: {app: probe}}
  template:
    metadata: {labels: {app: probe}}
    spec:
      containers:
        - name: probe
          image: busybox:1.36
          command: ["sh", "-c", "while true; do :; done"]   # 忙等, 给 recommender 一点 CPU 样本
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata: {name: probe, namespace: vpa-smoke}
spec:
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: probe}
  updatePolicy: {updateMode: Initial}
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed: {cpu: 20m, memory: 40Mi}
YAML
kubectl -n "$ns" rollout status deploy/probe --timeout=180s >/dev/null

# 1) webhook 在场证据
obs=$(kubectl -n "$ns" get pod -l app=probe -o jsonpath='{.items[0].metadata.annotations.vpaObservedContainers}')
[[ $obs == probe ]] || { echo "FAIL: 新 Pod 没有 vpaObservedContainers 注解(实际: [$obs]) —— webhook 没拦到 Pod" >&2; exit 1; }

# 2) 等 recommender 出推荐(每分钟一轮; 新对象通常 1-3 分钟)
rec=""
for _ in $(seq 1 40); do
  rec=$(kubectl -n "$ns" get vpa probe -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null || true)
  [[ -n $rec ]] && break
  sleep 5
done
[[ -n $rec ]] || { echo "FAIL: 200s 内 recommender 没给 probe 出推荐(metrics-server 是否在工作? kubectl top pods -n $ns)" >&2; exit 1; }

# Initial 模式只在 Pod 创建时套用 → 删 Pod 让 Deployment 重建, 新 Pod 应带 requests + vpaUpdates
kubectl -n "$ns" delete pod -l app=probe --wait=true >/dev/null
kubectl -n "$ns" rollout status deploy/probe --timeout=120s >/dev/null
cpu=$(kubectl -n "$ns" get pod -l app=probe -o jsonpath='{.items[0].spec.containers[0].resources.requests.cpu}')
upd=$(kubectl -n "$ns" get pod -l app=probe -o jsonpath='{.items[0].metadata.annotations.vpaUpdates}')
[[ -n $cpu && $upd == *"Pod resources updated by probe"* ]] \
  || { echo "FAIL: 重建 Pod 未被注入推荐值(cpu=[$cpu] vpaUpdates=[$upd])" >&2; exit 1; }

printf 'PASS: webhook 拦截(vpaObservedContainers), 推荐 cpu=%s, 重建 Pod 注入 requests.cpu=%s; 集群其余 VPA 全为 Off/RequestsOnly\n' "$rec" "$cpu"
