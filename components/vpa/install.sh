#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 1. 克隆官方仓库
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler

# 2. 运行官方安装脚本
./hack/vpa-up.sh

# 3. 验证安装 (查看 vpa-* Pod 是否为 Running 状态)
kubectl get pods -n kube-system | grep vpa

# ── 4. updater ───────────────────────────────────────────────────────────────
#
# --min-replicas=1 是这里最要紧的一个参数，缺了它整套 VPA 基本等于没装。
#
# updater 的 --min-replicas 默认是 2：副本数低于它的 workload，updater 直接跳过，
# 不做任何调整。而本集群被 VPA 纳管的对象**全部是 replicas=1**
# （argocd 6 个、jaeger、kafka-ui、loki-gateway、otel-operator、cert-manager…）。
#
# 后果是静默的：`kubectl get vpa` 里 PROVIDED=True、推荐值也算得出来，看着一切正常，
# 但 updater 从来没有真正 apply 过。2026-08-06 实测，jaeger 的 VPA target 是
# 50m/250Mi，而它的 Pod 跑了 55 天 requests 仍然是 512Mi。
#
# 唯一的痕迹在 updater 日志里，每 60 秒一轮：
#   "In-place resize failed" ... "not in replicated pods map" reason="InPlaceUpdateError"
# 实测 6 行/分钟 ≈ 8600 行/天，且 100% 是这一条。注意这是 --v=1 就会打的 Info 行，
# **降日志级别治不了它**，只有把 min-replicas 修掉才会消失。
#
# 自查：
#   kubectl -n kube-system logs deploy/vpa-updater | grep -c 'not in replicated pods map'
#   结果应该是 0。
#
# 另注：updateMode: "Initial" 不受本参数影响 —— 它由 admission-controller 在建 Pod
# 时注入，不走 updater。
kubectl patch deployment vpa-updater -n kube-system --patch '
spec:
  template:
    spec:
      containers:
      - name: updater
        args:
        - --v=1
        - --feature-gates=InPlace=true
        - --min-replicas=1
'

# ── 5. admission-controller ──────────────────────────────────────────────────
#
# 支持 updateMode: "InPlace" 需要 InPlace feature gate。
#
# 这里用 replace 整个 args 数组，不用 `add` + `/args/-`：原来那种写法每跑一次就往
# 数组尾部追加一个 --feature-gates=InPlace=true，重复执行会累积。2026-08-06 实测
# 线上这个 Deployment 上确实挂了两个一模一样的 --feature-gates=InPlace=true。
#
# 顺带把 --v 从 4 降到 1（之前只降了 updater 和 recommender，漏了它）。
kubectl patch deployment vpa-admission-controller -n kube-system --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
        "--v=1",
        "--stderrthreshold=info",
        "--reload-cert",
        "--feature-gates=InPlace=true"
      ]}]'

# ── 6. recommender ───────────────────────────────────────────────────────────
#
# 6a. 降低日志级别。
#
# 上面 updater 的 --v 原来是 4(实测 --v=2 几乎没用,要压到 1:56 行/120s → 12 行/120s)。加上 recommender 走镜像默认(压根没有 args),
# 两者合计占了写进 Loki 的全部日志行数的 29.7%(2026-08-06 用 Loki volume API
# 按 pod 归类实测)—— 一个用来「右调资源」的组件,自己成了 top-3 日志产出方。
#
# recommender 的噪音主要是每轮把每个 VPA 对象的 checkpoint 各打一行
# (checkpoint_writer.go:97,当时集群里有 63 个 aggregateContainerState)。
#
# 6b. 下调全局推荐地板 —— 不改这个，各 VPA 里的 minAllowed 改了也白改。
#
# recommender 有两个全局下限，低于它的推荐值一律被顶上来：
#   --pod-recommendation-min-cpu-millicores  默认 25
#   --pod-recommendation-min-memory-mb       默认 250
#
# 而本集群的真实用量普遍远低于这个地板（2026-08-06 kubectl top 实测）：
#   argocd-redis 4m/5Mi   jaeger 2m/33Mi   otel-operator 2m/24Mi
#   argocd-server 2m/27Mi  cert-manager 2m/23Mi  dragonfly 14m/13Mi
# 表现出来就是：几乎每个 VPA 的 uncappedTarget 都恰好等于 25m/250Mi。
# 那不是测量结果，那是地板 —— VPA 在这个集群里根本没法给出有意义的推荐。
#
# 降到 10m/32Mi 之后，推荐值才开始反映真实用量。安全性由各 VPA 自己的 minAllowed
# 兜底（例如 loki 的 512Mi、elasticsearch 的 1Gi、postgres 的 1Gi 都是有书面理由的）。
kubectl patch deployment vpa-recommender -n kube-system --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
        "--v=1",
        "--pod-recommendation-min-cpu-millicores=10",
        "--pod-recommendation-min-memory-mb=32"
      ]}]'

# 注意：recommender 镜像默认没有 args 字段。首次执行时 replace 会失败，
# 需要先 add 一个空数组。这里做成幂等的：
#   kubectl patch deployment vpa-recommender -n kube-system --type='json' \
#     -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": []}]'
# 再执行上面的 replace。

# ── 7. 纳管各组件 ────────────────────────────────────────────────────────────
#
# 这一步的清单必须和 ../argocd-application.yml 里的 include 列表保持一致，
# 否则手工 apply 和 ArgoCD 会互相覆盖。
#
# 刻意排除的三个文件：
#   examples/example1/ecommerce.yml       ecommerce 命名空间是空的，8 个目标都不存在
#   examples/example1/ecommerce-comm.yml  是模板样例（shopping-cart），不是真实对象
#   examples/operator.yml                 是讲解 Initial 模式的样例，且与
#                                         certManager.yml / kafka.yml 重名冲突
cd ..
kubectl apply \
  -f examples/example1/argocd.yml \
  -f examples/example1/certManager.yml \
  -f examples/example1/kafka.yml \
  -f examples/example1/postgres.yml \
  -f examples/example1/dragonfly.yml \
  -f examples/example1/openTelemetry-collector.yml \
  -f examples/example1/minio.yml \
  -f examples/example1/elastic-stack.yml \
  -f examples/example1/seata.yml \
  -f examples/example1/postgres-kafka-es-streaming-pipeline.yml \
  -f examples/example1/loki.yml \
  -f examples/example1/loki-gateway.yml \
  -f examples/ui/ui.yml \
  -f examples/ui/grafana.yml

# 8. 验收：这三条都应该是 0 / 空
kubectl -n kube-system logs deploy/vpa-updater --since=5m | grep -c 'not in replicated pods map' || true
kubectl get vpa -A -o json | jq -r '.items[] | select((.status.conditions//[])[]? | select(.type=="ConfigUnsupported" and .status=="True")) | "targetRef 失效: \(.metadata.namespace)/\(.metadata.name)"'
kubectl get vpa -A
