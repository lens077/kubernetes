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

# 支持updateMode: "InPlace"模式需要
kubectl patch deployment vpa-admission-controller -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--feature-gates=InPlace=true"}]'
kubectl patch deployment vpa-updater -n kube-system --patch '
spec:
  template:
    spec:
      containers:
      - name: updater
        args:
        - --v=1
        - --feature-gates=InPlace=true
'

# 降低日志级别。
#
# 上面 updater 的 --v 原来是 4(实测 --v=2 几乎没用,要压到 1:56 行/120s → 12 行/120s)。加上 recommender 走镜像默认(压根没有 args),
# 两者合计占了写进 Loki 的全部日志行数的 29.7%(2026-08-06 用 Loki volume API
# 按 pod 归类实测)—— 一个用来「右调资源」的组件,自己成了 top-3 日志产出方。
#
# recommender 的噪音主要是每轮把每个 VPA 对象的 checkpoint 各打一行
# (checkpoint_writer.go:97,当时集群里有 63 个 aggregateContainerState)。
# 注意 recommender 原本没有 args 字段,所以这里是 add 而不是 replace。
kubectl patch deployment vpa-recommender -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": ["--v=1"]}]'

# 4. 纳管 Loki(只出推荐,不改实配 —— 理由见 examples/example1/loki.yml 的注释)
kubectl apply -f examples/example1/loki.yml
