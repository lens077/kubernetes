# redis —— 官方 OSS Redis 单机（原生 TLS）

> **2026-08-20 已 scale 0 关停留备**：缓存主力切回 dragonflydb（原生 TLS，密码与本组件同值）。
> PVC/证书/Secret 保留，回滚=`kubectl -n redis scale sts redis --replicas=1` + 服务侧 host 换回。

## 1. 定位

**技术验证组件，默认不装**（`ADDON_REDIS=false`）。集群的缓存主力是
[dragonflydb](../dragonflydb/)（Redis 协议、cache_mode LRU），这里补的是它覆盖不到的场景：

- 需要**真 Redis 行为**做兼容性验证（go-redis 新特性、Lua、ACL、模块化数据结构——
  8.x 起 JSON/TS/概率结构/vector sets 已并入 core）；
- 需要**数据语义**而非缓存语义：AOF 持久化 + `noeviction` 满时拒写，重启不丢；
- 作为其他组件的存储后端试验田（如 Seata 的 redis store 评估）。

与 dragonflydb 的暴露方式对照：那边是明文 TCPRoute（README 里明确「跨不可信网络应改用
原生 TLS」），**这里就是那条 TLS 路的落地**——证书由 cert-manager 签，进程终结 TLS，
网关只做 L4 转发，集群内外全程加密。

## 2. 上游最佳实践

来源：[redis.io K8s 路线](https://redis.io/docs/latest/integrate/kubernetes-redis/)、
[CloudPirates charts](https://github.com/CloudPirates-io/helm-charts)、
[AGPLv3 官宣](https://redis.io/blog/agplv3/)（2026-08 复核）

- **官方没有 OSS helm chart**（redis.io 只有 Enterprise operator，要求 ≥3 worker 节点）。
  bitnami 2025-08 起镜像 legacy 受限后，社区主流替代是 **CloudPirates charts**：
  bitnami 式 values，底层用 docker.io 官方 `redis` 镜像并按 **digest 固定**。
- Redis 2026 起快节奏偶数小版本发版（8.2/8.4/…/8.10 五线并行维护），维护窗口短，
  **锁小版本、定期跟安全线**（2026-08-17 曾全线同日修 3 个可 RCE 的 CVE）。
- License：8.0 起 RSALv2 / SSPLv1 / **AGPLv3** 三选一。内部自用不改源码零义务；
  AGPL 网络条款只在「修改 Redis 并对外提供服务」时触发，客户端侧（go-redis）不受影响。
- 单机持久化标配：`appendonly yes`（everysec）+ RDB 快照兜底；`maxmemory` 设为容器
  limit 的 ~70%，给 AOF rewrite / RDB fork 留余量。
- `vm.overcommit_memory=1` 与 THP 关闭是**节点级 sysctl**，Pod 里改不了。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| chart `image.pullPolicy: Always` | `IfNotPresent` | tag 自带 digest，内容不可变，每次重拉纯属浪费大陆带宽。 |
| TLS 关闭 | **开启，`redis-tls` 由 global-ca-issuer 签** | 呼应 dragonflydb README 留下的「跨网络应走原生 TLS」；开启后 chart 关掉 6379 明文口，只听 6380，杜绝「集群内顺手走明文」。 |
| `tls.authClients: true`（mTLS） | `false` | 服务端 TLS + 密码已达验证目的；mTLS 要给每个客户端签证书，验证成本 > 收益。要开时用 global-ca-issuer 再签客户端证书即可。 |
| 淘汰策略随意 | `noeviction` + AOF | 与 dragonfly 的 cache_mode(LRU) 形成语义对照：那边是缓存，这边是数据。 |
| `metrics.enabled` sidecar | 关闭 | 没有 Prometheus Operator 来采，开了白占内存。 |
| replicas/Sentinel | standalone 单副本 | 技术验证定位；两节点集群做 Sentinel 3 副本没有故障域收益。 |
| chart 版本自动跟最新 | **config.env 钉 `REDIS_CHART_VERSION`** | CloudPirates 是 monorepo，GitHub release tag 与单 chart 版本对不上，`resolve_version` 机制失效，只能显式钉（同 fluent-bit）。 |

内存链条：`maxmemory 256mb` → limits 384Mi（约 1.5 倍）→ `EST_MEM_MI=300`。
改 `REDIS_MAXMEMORY` 时 limits 要配套（比例见 values.yaml 注释）。

## 4. 暴露方式

- 集群内：`rediss://redis.redis.svc.cluster.local:6380`（**只有 TLS 口，无明文口**）
- 局域网：Gateway `redis-gateway` 的 TCP listener（端口 6380），IP 由 Cilium 分配：
  `kubectl -n redis get gateway redis-gateway -o wide`
- 证书校验：客户端用集群根 CA（`kubectl -n redis get secret redis-tls -o jsonpath='{.data.ca\.crt}' | base64 -d`）；
  证书 SAN 含 `redis-oss.dev.test` 与 Service 内部 DNS 名
- 密码：`creds/redis-password`（get_cred 机制，重装不变）

## 5. 验证

```bash
kubectl -n redis get certificate redis-tls   # READY=True
kubectl -n redis get gateway redis-gateway -o wide   # PROGRAMMED=True
```

真验证（TLS + AUTH + 写读 + 持久化，经 Gateway VIP；本机没有 redis-cli 就借 pod 里的，
CA 在 pod 内挂载于 `/etc/redis/tls/ca.crt`）：

```bash
PASS=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/k8s-installer/creds/redis-password")  # 节点上是 /var/lib/k8s-installer/creds/
VIP=$(kubectl -n redis get gateway redis-gateway -o jsonpath='{.status.addresses[0].value}')

kubectl -n redis exec redis-0 -c redis -- sh -c "\
  redis-cli --tls --cacert /etc/redis/tls/ca.crt -h $VIP -p 6380 -a '$PASS' --no-auth-warning SET probe hello; \
  redis-cli --tls --cacert /etc/redis/tls/ca.crt -h $VIP -p 6380 -a '$PASS' --no-auth-warning GET probe"

# 持久化: 删 Pod 再读, AOF 应把数据带回来(Pod 重建后给 VIP 几秒 Envoy 收敛时间)
kubectl -n redis delete pod redis-0 && kubectl -n redis wait pod/redis-0 --for=condition=Ready --timeout=120s
kubectl -n redis exec redis-0 -c redis -- sh -c "\
  redis-cli --tls --cacert /etc/redis/tls/ca.crt -h $VIP -p 6380 -a '$PASS' --no-auth-warning GET probe"  # 仍是 hello

# 局域网主机侧最少验证(无 redis-cli 时): TLS 握手能拿到 global-root-ca 签的证书即链路通
openssl s_client -connect $VIP:6380 </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
```

明文旁路应当**失败**（listener 只有 TLS）：

```bash
kubectl -n redis exec redis-0 -c redis -- timeout 5 redis-cli -h $VIP -p 6380 PING
# 期望 Connection reset by peer, 而不是 PONG
```

> **实测结论（2026-08-18）**：经 Gateway VIP 完成 TLS SET/GET；明文连接被 reset；
> Mac 侧握手拿到 `my-global-root-ca` 签发、SAN 含 `redis-oss.dev.test` 的证书；
> 删 Pod 重建后 AOF 把数据完整带回。Pod 重建后 VIP 有约 5-10s 的 Envoy 后端刷新窗口
> （Connection refused），属正常收敛不是故障。

## 6. 踩坑

- **TCPRoute `backendRef.port` 写容器端口会 Connection refused**：chart 的主 Service
  固定暴露 **6379**（TLS 开启时 targetPort 指向容器 6380），backendRef 引用的是
  **Service 端口**，必须写 6379。更阴的是 Cilium 的 `ResolvedRefs=True` 只校验 Service
  存在，端口错了照样绿——别拿路由 conditions 当连通性证据（实测）。
- **chart 与镜像都在 docker.io**：大陆直连拉 chart 会卡死（实测 `helm show values`
  直连 120s 无响应，挂代理秒过）。`helm_cmd` 自带 `with_proxy`（PROXY_URL 探活自动挂）；
  节点拉镜像走 containerd 直连 docker.io，慢但能通，急了按 TODO.md 的 quay 镜像站手法
  给 docker.io 配 certs.d。
- **OCI chart 必须显式 `--version`**：registry 不解析 latest（dragonflydb 同款坑）。
- **`tls.enabled` 后明文口没了**：集群内客户端也必须 `rediss://` + CA。想「集群内明文、
  集群外 TLS」得自己加第二个 Service/端口——特意不做，防止验证组件出现两套行为。
- **数据卷里同时有 AOF 和 RDB**：`appendonly yes` 下恢复以 AOF 为准；`save` 行只是
  兜底快照，别当成主持久化。
- **`maxmemory-policy noeviction` 写满即拒**：这是数据语义的特性不是故障。要缓存语义
  请用 dragonflydb，别来改这里的淘汰策略。
