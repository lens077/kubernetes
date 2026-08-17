#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail
# https://docs.kafka-ui.provectus.io/configuration/helm-charts/quick-start

mkdir -pv /home/kubernetes/kafka
cd /home/kubernetes/kafka

kubectl create ns kafka
wget 'https://strimzi.io/install/latest?namespace=kafka'

kubectl create -f 'latest?namespace=kafka' -n kafka

# ══ 2026-08-06 算子升级 1.0.0 → 1.1.0 ═══════════════════════════════════════════
#
# 起因：要把 Kafka 升到 4.3.0 以匹配 Debezium 插件自带的 jar，而 1.0.0 的
# STRIMZI_KAFKA_IMAGES 最高只到 4.2.0。各版本支持范围（实测）：
#   1.0.0 / 1.0.1 → 4.1.0 4.1.1 4.1.2 4.2.0
#   1.1.0         → 4.2.0 4.2.1 4.3.0   （并**移除** 4.1.x 支持）
# 查法：kubectl -n kafka get deploy strimzi-cluster-operator \
#         -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="STRIMZI_KAFKA_IMAGES")]}{.value}{end}'
#
# 前置条件：从 1.0.0 起 CRD 只支持 v1 API，v1beta2/v1beta1/v1alpha1 均已移除。
# 本集群的 CRD 已是 v1-only，无需迁移。
#
# ⚠️ 坑：`https://strimzi.io/install/<版本>?namespace=kafka` 这个带命名空间参数的
#    URL **只对 latest 有效**，指定具体版本号会 404。要用 GitHub release 的 bundle：
#      curl -sL -o strimzi-1.1.0.yaml \
#        https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml
#
# ⚠️⚠️ 更大的坑（实际踩到了）：bundle 里默认命名空间是 `myproject`，但
#    **Deployment / ServiceAccount / ConfigMap 这三个资源根本没写 `namespace:` 字段**。
#    只做 `sed 's/namespace: myproject/namespace: kafka/g'` 是不够的 —— 那三个会落到
#    当前 context 的默认命名空间（default），**凭空多出一套算子**。
#    必须 sed 之后再显式带 `-n kafka`：
#      sed 's/namespace: myproject/namespace: kafka/g' strimzi-1.1.0.yaml > strimzi-1.1.0-kafka.yaml
#      kubectl apply -n kafka --server-side=true --force-conflicts -f strimzi-1.1.0-kafka.yaml
#
#    用 --server-side 是因为 CRD 体积超过 client-side apply 的
#    last-applied-configuration 注解上限。
#
#    误建到 default 的后果有限（那套算子的 STRIMZI_NAMESPACE 取自 metadata.namespace
#    = default，而 default 里没有任何 Kafka CR，它不会做任何事），但要清理干净：
#      kubectl -n default delete deploy/strimzi-cluster-operator \
#        sa/strimzi-cluster-operator cm/strimzi-cluster-operator
#
# 升级顺序（重要）：先升算子，此时集群仍跑 4.2.0（1.1.0 依然支持），确认算子
# Ready 且无报错后，再单独 patch Kafka 的 version / metadataVersion。
# 这样把「算子升级」和「Kafka 升级」两类风险拆开，出问题时容易定位。
# 具体 patch 命令见 examples/kafka-single-node.yml 的注释。
#
# 镜像预拉取：quay.io 跨境很慢且会被逐渐限速（实测从 1.5MB/s 掉到 34KB/s，
# 导致 kubelet 的 image_pull_progress_timeout=5m 触发、拉了一半失败重来）。
# 建议先用国内镜像站把 operator:1.1.0 和 kafka:1.1.0-kafka-4.3.0 拉到各节点：
#   ctr -n k8s.io images pull --platform linux/arm64 quay.nju.edu.cn/strimzi/<repo>:<tag>
#   ctr -n k8s.io images tag --force quay.nju.edu.cn/strimzi/<repo>:<tag> quay.io/strimzi/<repo>:<tag>
# 详见 TODO.md 同日「quay.io 镜像加速」条目。

wget https://strimzi.io/examples/latest/kafka/kafka-single-node.yaml
kubectl apply -f kafka-single-node.yaml -n kafka

kubectl patch svc my-cluster-kafka-bootstrap -p '{"spec":{"type":"LoadBalancer"}}' -n kafka
# test
# send
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:0.51.0-kafka-4.2.0 --rm=true --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic

# 接收， 打开新终端：
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:0.51.0-kafka-4.2.0 --rm=true --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning

#helm repo add kafka-ui https://provectus.github.io/kafka-ui-charts
#helm repo update
#helm pull kafka-ui/kafka-ui
#
## 将kafka-cluster-broker-endpoints:9092替换
#cat > helm-kafuka-ui-values.yml <<EOF
#ApplicationConfig:
#  kafka:
#    clusters:
#      - name: yaml
#        bootstrapServers:  my-cluster-kafka-brokers.kafka.svc.cluster.local:9092
#  auth:
#    type: disabled
#  management:
#    health:
#      ldap:
#        enabled: false
#EOF
#
#helm install kafka-ui . -f helm-kafuka-ui-values.yml
#
## https://strimzi.io/docs/operators/latest/deploying#deploying-cluster-operator-helm-chart-str
##指定为 internal 或 cluster-ip（使用每个代理的 Kafka IP 服务公开 Kafka）或外部侦听器的类型，
## 如 route（仅 OpenShift），loadbalancer，nodeport 或 ingress（仅 Kubernetes）。
#
#cat > example.yml <<EOF
#apiVersion: kafka.strimzi.io/v1beta2
#kind: KafkaNodePool
#metadata:
#  name: dual-role
#  labels:
#    strimzi.io/cluster: my-cluster
#spec:
#  replicas: 1
#  roles:
#    - controller
#    - broker
#  storage:
#    type: jbod
#    volumes:
#      - id: 0
#        type: persistent-claim
#        size: 10Gi
#        deleteClaim: false
#        kraftMetadata: shared
#---
#
#apiVersion: kafka.strimzi.io/v1beta2
#kind: Kafka
#metadata:
#  name: my-cluster
#  annotations:
#    strimzi.io/node-pools: enabled
#    strimzi.io/kraft: enabled
#spec:
#  kafka:
#    version: 4.0.0
#    metadataVersion: 4.0-IV3
#    listeners:
#      - name: plain
#        port: 9092
#        type: loadbalancer
#        tls: false
#      - name: tls
#        port: 9093
#        type: loadbalancer
#        tls: true
#    config:
#      offsets.topic.replication.factor: 1
#      transaction.state.log.replication.factor: 1
#      transaction.state.log.min.isr: 1
#      default.replication.factor: 1
#      min.insync.replicas: 1
#  entityOperator:
#    topicOperator: {}
#    userOperator: {}
#EOF
