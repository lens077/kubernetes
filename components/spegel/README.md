# Spegel

Spegel 在节点间共享 containerd 已缓存的 OCI layer，作为上游 registry 之前的集群本地 mirror。当前 chart 固定为 `v0.7.4`。

## 本集群取舍

当前 3 节点、containerd 2.3.4，`config_path=/etc/containerd/certs.d`。2026-08-20 已验证：同一镜像 node1 首拉 8.811 秒，node2 P2P 命中 102 毫秒；`spegel_mirror_requests_total{cache="hit"}` 对 docker.io 与 TCR 都出现过命中。

Spegel 保留上游 registry 回退。某个节点没有 layer、P2P 暂时不可达或 Service 没有本地 Ready endpoint 时，containerd 仍可尝试其他 mirror 与上游 registry。

## certs.d 归 bootstrap 40 阶段，Spegel 不接管

`spegel.containerdMirrorAdd` 为 `true` 时，Spegel 会把 `/etc/containerd/certs.d` 里已有的全部 `hosts.toml` 挪进 `_backup/`，只留一个指向本节点 P2P 的 `_default/hosts.toml`；P2P 未命中就回退**上游直连**。机房（2026-09-06）直连 docker.io / registry.k8s.io / quay.io 不通（DNS 污染 + 超时），80 阶段因此大面积 `ImagePullBackOff`。

现在固定 `containerdMirrorAdd: false`，由 `bootstrap/scripts/40-container-runtime.sh` 独占 certs.d：每个 `<registry>/hosts.toml` 在 `server` 行后先注入 `http://<本节点IP>:${SPEGEL_MIRROR_PORT}`（只 `pull`，`dial_timeout=200ms`），再是仓库自带的镜像站列表，最后回源；另写一个只含 Spegel 的 `_default/hosts.toml` 给未列出的 registry。`hosts.toml` 每次拉取时读取，改动不需要重启 containerd。实测 node4 首拉 `nats:2.14.5-alpine` 14 秒（镜像站），node5 同镜像 2 秒且 `spegel_mirror_requests_total{cache="hit"}` 递增。

改了 `files/certs.d/` 或 `SPEGEL_MIRROR_PORT` 后，在每台节点重跑 `sudo bash start.sh --reset-state 40-container-runtime && sudo bash start.sh --only 40-container-runtime`（会重启 containerd，运行中的容器不受影响）。

## PreferSameNode

Spegel v0.7.4 推荐的最小 values：

```yaml
service:
  registry:
    usePreferSameNodeTrafficDistribution: true
```

不要额外设置 `hostPort: 0`。对这个 chart 版本，布尔值本身会：

- 从 DaemonSet 删除 registry `hostPort: 30020`；
- 给 `spegel-registry` Service 设置 `trafficDistribution: PreferSameNode`；
- 从 containerd mirror 配置删除 `http://$(NODE_IP):30020`；
- 保留 NodePort `30021` mirror target。

只写 `hostPort: 0` 不是可靠的禁用方式；在布尔值为 false 时可能渲染出无效的 `NODE_IP:0` target。

Cilium 必须配套启用：

```yaml
loadBalancer:
  serviceTopology: true
```

否则 Kubernetes 虽接受 `trafficDistribution: PreferSameNode`，Cilium 数据面不会按该偏好筛选 endpoint。`PreferSameNode` 不是强制本地：本节点有 Ready endpoint 时优先本节点，没有时回退其他节点。

## 为什么要移除 30020

默认 chart 同时使用：

- registry `hostPort: 30020`；
- Service `NodePort: 30021`。

当前 Kubernetes NodePort 范围为 `30000-32767`。`30020` 落入该范围，Cilium 会记录：

```text
The requested hostPort is colliding with the configured NodePort range. Ignoring.
```

Cilium 忽略 30020 不等于 Spegel 缓存完全失效；30021 仍可工作，历史命中也已证明这一点。切到 `PreferSameNode` 的目的，是删除无效 hostPort 和告警，并用 Kubernetes Service 拓扑表达本节点偏好。

## 部署

```bash
bash components/spegel/install.sh
kubectl -n spegel rollout status ds/spegel --timeout=5m
```

## 验收

确认 DaemonSet 不再渲染 hostPort、Service 带本节点偏好、containerd 只保留 30021：

```bash
kubectl -n spegel get ds spegel -o json \
  | jq '[.spec.template.spec.containers[].ports[]? | select(.hostPort != null)]'

kubectl -n spegel get svc spegel-registry \
  -o jsonpath='{.spec.trafficDistribution}{"\n"}{.spec.ports[0].nodePort}{"\n"}'

for node in node101 node102 node103; do
  kubectl debug "node/$node" -it --image=alpine -- chroot /host \
    grep -R '3002[01]' /etc/containerd/certs.d
 done
```

前两项的期望结果：hostPort 列表为空，`trafficDistribution=PreferSameNode`，NodePort 为 `30021`。节点文件检查不得出现 mirror target `:30020` 或 `:0`。

确认 Cilium 新日志不再出现冲突：

```bash
for pod in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system logs "$pod" -c cilium-agent --since=30m \
    | grep -E 'hostPort=30020|colliding with the configured NodePort range' || true
done
```

最后执行 seed-and-probe：先在一个节点拉取新镜像，再让另一个节点拉同一 digest，并确认 `spegel_mirror_requests_total{cache="hit"}` 递增。Pod 的 `Pulled` 用时只作辅助证据，metrics 命中才是主验收。
