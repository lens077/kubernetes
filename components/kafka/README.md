# kafka —— Strimzi 算子（Kafka 4.x KRaft）

## 1. 定位

消息队列与 CDC 管道的底座。ecommerce 的 Debezium CDC（PostgreSQL → Kafka → 搜索索引）
跑在它上面。本组件**只装算子**，Kafka 集群按需 apply。

## 2. 上游最佳实践

来源：[Strimzi 文档](https://strimzi.io/documentation/)

- 算子用 helm 安装；YAML bundle 有版本化 URL 与命名空间硬编码的坑。
- Kafka 4.x 起只有 KRaft 模式（无 ZooKeeper），`KafkaNodePool` 定义节点角色。
- 对外访问用 `listeners[].type: loadbalancer|nodeport|ingress`，Strimzi 会**为每个 broker
  生成独立的 bootstrap/broker Service** 并把地址写进 advertised listeners。
- 算子 1.0+ 起 CR 用 `kafka.strimzi.io/v1`（`v1beta2` 已移除）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Gateway/Ingress 暴露 | **不走 Gateway，用 `type: loadbalancer`** | Kafka 客户端先连 bootstrap 拿 broker 列表，再直连各 broker。经网关转发的话客户端拿到的是**集群内部地址**，连不上。这是协议决定的，不是配置问题。 |
| 多 broker + 多副本 | 单节点 KRaft 示例 | 两节点集群，3 副本没有真正的故障域隔离。 |
| `resources: {}` | **必须显式给** | 仓库 TODO.md 里记着：Connect build pod 因为 `resources: {}` → BestEffort → 在 kubelet 驱逐排序里排第一，写满磁盘后又第一个被杀，在节点间反复横跳。**Kafka 相关的每个 Pod 都要给 requests。** |

## 4. 暴露方式

集群内：`my-cluster-kafka-bootstrap.kafka.svc:9092`

> ⚠️ **internal listener 不会生成各自的 bootstrap Service**——所有内部监听器共用
> `<cluster>-kafka-bootstrap`，靠端口区分。只有 external listener 才有
> `<cluster>-kafka-<listener>-bootstrap`。写成 `my-cluster-kafka-plain-bootstrap`
> 这种臆造的名字，DNS 直接解析不了（TODO.md 里踩过）。

局域网：给 Kafka CR 加 external listener（`type: loadbalancer`），Cilium 会从 LB 池分配 IP。

## 5. 验证

```bash
kubectl -n kafka get deploy strimzi-cluster-operator            # READY 1/1
kubectl api-resources | grep kafka.strimzi.io
```

真验证（建集群 → 生产 → 消费）：

```bash
kubectl apply -f components/kafka/examples/kafka-single-node.yaml
kubectl -n kafka wait --for=condition=Ready kafka/my-cluster --timeout=900s
kubectl -n kafka run probe --rm -it --restart=Never --image=quay.io/strimzi/kafka:latest-kafka-4.3.0 -- \
  bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic probe
```

## 6. 踩坑

完整记录在仓库根的 [TODO.md](../../TODO.md)（2026-08-06 的六连问题排查）。要点：

- **bootstrapServers 指向不存在的 Service**：见上方「暴露方式」的警告。
- **Connect build pod 写满磁盘并反复被驱逐**：buildah 的 `--storage-driver=vfs` 不做 CoW，
  每层都是完整副本（实测约 7G）；加上 `resources: {}` → BestEffort → 驱逐排序第一。
- **`binary.handling.mode: utf8` 是无效值且被 NPE 掩盖**：正确值是 `base64`。
- **Debezium 版本与 Connect 运行时错配**：要匹配的是 **Connect 运行时**而非 broker
  （类加载冲突发生在 Connect 的 ConfigDef 上）。Debezium 3.6+ 自带 connect-api 4.3.0。
- **仓库文件写了修复 ≠ 集群里生效**：那次 `resources`/`jvmOptions` 只写进文件没 apply，
  线上仍是 BestEffort + 无 `-Xmx`，正是当初 489 次 OOMKill 的完全相同条件。
  用 `kubectl diff` 逐份对账才发现。
