# metrics-server —— kubectl top / HPA 的指标源

## 1. 定位

给 `kubectl top nodes|pods` 和 HPA 提供 CPU/内存实时用量。它**不是监控系统**（不存历史、
只保留最近一次采样），历史指标由 [victoriametrics](../victoriametrics/) 负责。

不装的后果：`kubectl top` 报 `Metrics API not available`，HPA 无法扩缩容，
`kubectl describe node` 里也看不到实际用量。

## 2. 上游最佳实践

来源：[metrics-server FAQ](https://github.com/kubernetes-sigs/metrics-server/blob/master/FAQ.md#how-to-run-metrics-server-securely)

- **不要用 `--kubelet-insecure-tls`**。正规做法是让 kubelet 的 serving 证书由集群 CA 签发
  （kubeadm 的 `KubeletConfiguration.serverTLSBootstrap: true`），metrics-server 就能正常校验。
- 每 15s 采集一次（`--metric-resolution=15s`），与 HPA 的采样周期匹配；调更小会明显增加 kubelet 负载。
- 大集群（>100 节点）才需要调 `--kubelet-request-timeout` 和副本数；本集群用不上。
- 镜像自 v0.3.7 起是多架构 manifest list，ARM64 直接可用。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 不加 `--kubelet-insecure-tls` | **加了** | kubeadm 默认给 kubelet 签的是自签 serving cert。要走正规路子得开 `serverTLSBootstrap: true`，但那样每次证书轮换都会产生 `kubernetes.io/kubelet-serving` CSR，而集群里没有 cloud-provider 的自动批准器 —— 意味着**证书到期时 `kubectl top` 会静默失效，直到人工 approve**。单机集群里这个运维成本换不来安全收益（kubelet 的 10250 只在内网监听）。要收紧的话见下方「收紧路径」。 |
| chart 默认无 resources | `requests: 100m/200Mi` | 不留 BestEffort。kubelet 驱逐排序里 BestEffort 排最前，指标源被驱逐会让 HPA 直接瞎掉 —— 仓库 [TODO.md](../../TODO.md) 里 Kafka build pod 那次事故就是 BestEffort 被优先驱逐。 |
| `podDisruptionBudget` 可选 | 关闭 | 单副本 + PDB 会让 kured 在维护窗口排空节点时卡死。 |
| `--kubelet-preferred-address-types` | 用 chart 默认（InternalIP 优先） | 节点 hostname 已写进 `/etc/hosts`，但 InternalIP 更直接，chart 默认顺序已正确。 |

**收紧路径**（真要去掉 insecure-tls 时）：在 `bootstrap/scripts/50-kubernetes.sh` 生成的
KubeletConfiguration 里加 `serverTLSBootstrap: true`，并部署一个 CSR 自动批准控制器
（如 `kubelet-csr-approver`），再从 values 里删掉那行 arg。

## 4. 暴露方式

不对外暴露。只通过 APIService `v1beta1.metrics.k8s.io` 提供聚合 API，集群内访问。

## 5. 验证

```bash
kubectl top nodes            # 两个节点都应有 CPU/MEMORY 读数，不能是 <unknown>
kubectl top pods -A | head
```

真验证（证明 APIService 而不只是 Pod 活着）：

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 200
```

## 6. 踩坑

- **`kubectl top` 报 `Metrics API not available`，但 Pod 是 Running**：多半是 APIService
  `v1beta1.metrics.k8s.io` 处于 `False (FailedDiscoveryCheck)`。用
  `kubectl get apiservice v1beta1.metrics.k8s.io -o yaml` 看 conditions，通常是 metrics-server
  连不上 kubelet 的 10250（证书或网络），而不是 metrics-server 本身有问题。
- **Cilium KPR 环境下无需额外放行**：metrics-server → kubelet 10250 是节点本地流量，
  不经过 Service 转发。
