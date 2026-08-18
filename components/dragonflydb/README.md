# dragonflydb —— Redis 协议兼容缓存

## 1. 定位

ecommerce 的缓存层。Redis 协议兼容，go-redis 客户端**零改动**即可切过来。
选它而不是 Redis：单进程多线程架构，同样内存下吞吐更高，且 `cache_mode` 满时自动 LRU 淘汰。

## 2. 上游最佳实践

来源：[Dragonfly Helm 安装指南](https://www.dragonflydb.io/docs/getting-started/kubernetes) 与
[运行参数参考](https://www.dragonflydb.io/docs/managing-dragonfly/flags)。

- `--maxmemory` 是硬上限；配 `--cache_mode=true` 后满时按 LRU 淘汰（等价 redis 的 allkeys-lru）。
- **`maxmemory` 必须 ≥ 256MiB × io 线程数**，否则启动直接拒绝。
- 线程数默认取 CPU 核数，可用 `--proactor_threads` 显式指定。
- 持久化（快照）默认关闭；作为纯缓存时不需要开。
- 容器使用非 root 用户、只读根文件系统、`RuntimeDefault` seccomp，并丢弃全部 Linux capabilities。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 线程数 = CPU 核数 | **`--proactor_threads=1` 显式钉死** | 不指定的话 4 核节点会起 4 线程 → 要求 maxmemory ≥ 1GiB，而我们给的是 256mb → 启动即 `Exiting...`，进入崩溃循环。**这两个参数必须配套改**（见 config.env 里的注释）。 |
| Service `LoadBalancer` | **ClusterIP + TCPRoute** | 旧方案每个 TCP 组件各占一个 LB IP。改走 Gateway 的 TCPRoute 后，暴露方式与 HTTP 组件统一，IP 仍由 Cilium 从池里分配。 |
| `limits.cpu: 100m` | **只限内存不限 CPU** | 限 CPU 会造成缓存请求限流抖动——缓存的价值就在于稳定的低延迟。 |
| serviceMonitor | 关闭 | 集群用 VictoriaMetrics + OTel，没有 Prometheus Operator，开了也没人采。 |
| chart 安全上下文为空 | **按官方示例收紧，并补 `RuntimeDefault` seccomp** | Dragonfly 不需要提权、额外 capabilities 或可写根文件系统。 |

## 4. 暴露方式

- 集群内：`dragonfly.dragonfly.svc.cluster.local:6379`
- 局域网：Gateway `dragonfly-gateway` 的 TCP listener（端口 6379），IP 自动分配，
  查看：`kubectl -n dragonfly get gateway dragonfly-gateway -o wide`
- 密码：见 `/root/.k8s-installer-credentials`

TCPRoute 没有 hostname 概念，一个 listener 端口 = 一组后端（等价 L4 端口映射），
所以每个 TCP 组件占一个自己的端口。

当前 TCPRoute 不终结 TLS，密码和缓存流量在局域网内为明文。只在可信网络使用该入口；
不要把 Gateway VIP 暴露到公网。跨不可信网络访问时，应改用 Dragonfly 原生 TLS。

> **实测结论（2026-08-17）**：Cilium 1.20 的 TCPRoute 可用。从局域网另一台机器直连
> Gateway VIP `:6379`，走完 `AUTH → PING → SET → GET` 并拿回正确的值。
> 前提是 TCPRoute CRD 存在——CRD 不装的话 Cilium 会**静默关闭**该功能。

## 5. 验证

```bash
kubectl -n dragonfly get gateway dragonfly-gateway -o wide    # PROGRAMMED=True
kubectl -n dragonfly get tcproute dragonfly -o yaml | grep -A3 conditions
```

真验证（从局域网其他主机经 Gateway 写读一次）：

```bash
PASS=$(cat /var/lib/k8s-installer/creds/dragonfly-password)
VIP=$(kubectl -n dragonfly get gateway dragonfly-gateway -o jsonpath='{.status.addresses[0].value}')
printf 'AUTH %s\r\nSET probe hello\r\nGET probe\r\nQUIT\r\n' "$PASS" | nc -w 5 $VIP 6379
# 期望看到 +OK / +OK / $5 / hello
```

## 6. 踩坑

- **CrashLoopBackOff，日志 `There are 4 threads, so 1.00GiB are required. Exiting...`**：
  `maxmemory` 与线程数不匹配。要么加 `--proactor_threads=1`，要么把 maxmemory 提到 1GiB
  （但 Pod 的 limits 也得跟着涨）。
- **helm upgrade 报字段冲突 `conflict with "kubectl-patch"`**：之前用 `kubectl patch`
  直接改过 Deployment 的 args，字段管理器归属变了，helm 的 server-side apply 会拒绝覆盖。
  处理：`kubectl -n dragonfly delete deploy dragonfly` 后重跑 install.sh（chart 会重建）。
  教训是**别用 kubectl patch 改 helm 管理的对象**，改 values 重装。
- **OCI chart 报 `unable to locate any tags`**：OCI registry 不解析 latest，
  `helm upgrade` 必须带 `--version`。install.sh 里会自动解析最新版并锁进 `versions.lock`。
- **go-redis 连不上但集群内 telnet 通**：检查密码。chart 的 `passwordFromSecret` 指向的
  Secret 若不存在，Pod 会起不来；若密码不匹配，客户端会在 AUTH 阶段失败。
