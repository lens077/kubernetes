# Cilium 配置、升级与容量调优

本文是 `bootstrap/scripts/60-cilium.sh` 的配置说明与在线运维手册。适用于当前 3 节点、每节点 4 vCPU/约 6.2 GiB 内存、Kubernetes 1.36、Cilium 1.20、原生路由与 netkit 数据面的 dev 集群。

配置入口是 [`config.env`](config.env)，生成实现是 [`scripts/60-cilium.sh`](scripts/60-cilium.sh)。不要直接维护一份与生成器分叉的长期 Helm values。

## 1. 当前目标状态

保留以下已经稳定运行的配置：

- `routingMode=native`、`autoDirectNodeRoutes=true`
- `bpf.datapathMode=netkit` 与 eBPF host-routing
- `bpf.masquerade=true`、`bpfClockProbe=true`，运行态已选中 jiffies
- Bandwidth Manager + BBR
- Maglev
- hybrid DSR + `dsrDispatch=opt`
- PMTU discovery
- IPv4-only
- Gateway API v1.6.1
- `externalTrafficPolicy: Cluster`
- BIG TCP 关闭
- IPsec 关闭；内网 PD 环境是可信 LAN。机房版位于多租户共享 VLAN，当前保持关闭以先复原基线，安全边界见 8.1 节
- Gateway API ALPN 关闭；当前没有 GRPCRoute
- `ciliumEndpointSlice.enabled=true`，暂时保留 CES

目标版本为 Cilium `v1.20.1`。本次补丁版本修复了当前配置会经过的 DSR、L2 Announcements、CES operator 退出和策略恢复路径。Kubernetes 1.36 在 Cilium 1.20 的官方测试范围内，Gateway API v1.6.1 已满足要求。

## 2. 实施顺序

不要把所有调优合成一次 rollout。推荐按以下顺序实施：

1. 接通 Cilium agent/operator 指标，确认指标已经写入 VictoriaMetrics。
2. 留存至少 24 小时基线，覆盖正常业务周期。
3. 运行 Cilium 1.20.1 官方 preflight。
4. 升级 1.20.1，并同时应用安全的滚动策略、资源 requests、`serviceTopology` 和无效键清理；BPF map 比例暂时保持原值。
5. 验证 agent/operator/envoy、Gateway、L2 Lease、Service 和业务入口。
6. 单独升级 Spegel 的 `PreferSameNode` 配置，确认不再渲染 `hostPort: 30020`。
7. 在维护窗口单独把 `bpf.mapDynamicSizeRatio` 改为 `0.01`。这一步会重建 CT/NAT map，可能中断 PostgreSQL、NATS、Dragonfly 等长连接。
8. map 缩容后重新测量容量、内存和压力，不以估算值代替验收。

### 2.1 2026-08-27 在线实施记录

已完成：

- OTel Collector 已部署两个 Cilium scrape job；node3 VictoriaMetrics 能查询到本文列出的六类关键指标。
- Cilium 1.20.1 官方 preflight DaemonSet 为 3/3，CNP validator Deployment 为 1/1；临时资源已清理。
- Cilium Helm revision 2 已升级到 1.20.1；agent 3/3、Envoy 3/3、operator 2/2 Ready。
- `maxUnavailable=1`、`minReadySeconds=10`、资源 requests、operator PDB、`serviceTopology=true`、`lbExternalClusterIP=false` 与 XDP disabled 已生效。
- CES 保持 22 个，包含的 endpoint 合计 70，与 70 个 CEP 一致。
- Spegel Helm revision 3 已切到 `PreferSameNode`；DaemonSet 无 hostPort，三节点 containerd mirror 只包含各自 `:30021`。
- LoadBalancer 从 13 个收敛到 4 个，L2 Lease 同步从 13 个降到 4 个；共享 Gateway、Consul、Dragonfly 与 PostgreSQL Gateway 保留。

尚未在线应用：`bpf.mapDynamicSizeRatio=0.01`。仓库目标值已经更新，但 live cluster 在版本升级阶段刻意保持 `0.08`。原因是 Cilium 指标刚接通，尚未满足「至少 24 小时基线 + 独立维护窗口」前置条件。它不需要重建集群；满足前置条件后单独滚动 agent 即可。

## 3. Cilium 指标采集

`prometheus.enabled=true` 与 `operator.prometheus.enabled=true` 只负责暴露端口，不负责保存数据：

- agent：`:9962`
- operator：`:9963`

[`../components/opentelemetry/values.yaml`](../components/opentelemetry/values.yaml) 中的 `prometheus/cilium` receiver 使用 Kubernetes Pod discovery，只发现 `kube-system` 中：

- `k8s-app=cilium` 且端口名为 `prometheus` 的 agent；
- `name=cilium-operator` 且端口名为 `prometheus` 的 operator。

抓取周期为 30 秒，超时为 10 秒。chart 自带的 `prometheus` receiver 仍只抓 Collector 自身 `:8888`；两者职责分开。现有 ClusterRole 已具备 `pods` 的 `get/list/watch`，无需扩大 RBAC。

必须保存并重点观察以下指标：

| 指标 | 用途 |
|---|---|
| `cilium_bpf_map_pressure` | BPF map 容量压力；map 缩容的主要验收指标 |
| `cilium_controllers_failing` | agent controller 失败数 |
| `cilium_errors_warnings_total` | agent/operator 错误与告警趋势 |
| `cilium_drop_count_total` | 数据面丢包，按 reason/direction 联查 |
| `cilium_endpoint_regeneration_time_stats_seconds` | endpoint regeneration 延迟 |
| `cilium_api_limiter_processed_requests_total` | Kubernetes API 限流器处理结果；L2/CES 调优依据 |

快速验证 Collector 配置：

```bash
kubectl -n opentelemetry get cm otel-opentelemetry-collector \
  -o jsonpath='{.data.relay}' | sed -n '/prometheus\/cilium:/,/zipkin:/p'

kubectl -n opentelemetry logs deploy/otel-opentelemetry-collector --since=10m \
  | grep -iE 'error|warn|drop'
```

VictoriaMetrics 在 node3 本机监听 `127.0.0.1:8428`。公网查询路径受 Pangolin SSO 保护，可经 SSH 验证落库：

```bash
ssh node3 "curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=count(cilium_bpf_map_pressure)'"
```

采集成功的判据不是「Collector 配置里出现 receiver」，而是 VictoriaMetrics 能查到带 `k8s_node_name`、`k8s_pod_name`、`service_name` 标签的新样本。

⚠️ **标签名用下划线**：node3 的 VictoriaMetrics 启动带 `-opentelemetry.usePrometheusNaming=true`〔实测 2026-09-01〕，把 OTel 的点号命名（`k8s.node.name`）转成 Prometheus 下划线命名。Collector 侧配置里写的仍是点号（那是摄入前的 OTel 属性名），**只有查询 VM 时要用下划线**。写错不报错、只是查不到，极易误判成「没采到」。

## 4. 机器与规模相关的旋钮

这些值不能跨机器照抄。统一在 `config.env` 配置，生成器只消费变量。

| 配置 | 当前值 | 依据与调整方法 |
|---|---:|---|
| `CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO` | `0.01`（目标） | 先记录每节点 map 内存、entry 数和 `cilium_bpf_map_pressure` 至少 24 小时。变更后再次执行相同测量；若压力持续上升或接近容量，回调比例。不要只按节点总内存估算。 |
| `CILIUM_BPF_MAP_RESIZE_APPROVED` | `false` | live 比例与目标不同时阻止 Helm rollout。进入维护窗口后显式改为 `true`；升级完成并验收后改回 `false`。 |
| `CILIUM_AGENT_CPU_REQUEST` / `MEMORY_REQUEST` | `100m` / `512Mi` | 结合 `kubectl top pod -n kube-system -l k8s-app=cilium`、重启/OOM 与业务峰值调整。只设 requests，不设严格 limits。 |
| `CILIUM_OPERATOR_CPU_REQUEST` / `MEMORY_REQUEST` | `50m` / `128Mi` | 结合 operator CPU/内存、CES 同步延迟和 leader 稳定性调整。 |
| `CILIUM_ENVOY_CPU_REQUEST` / `MEMORY_REQUEST` | `50m` / `128Mi` | 结合 Gateway/L7 流量、Envoy 重启和延迟调整；不设置严格 memory limit。 |
| `CILIUM_OPERATOR_REPLICAS` | `2` | 当前有 3 个可调度节点，chart 自带跨节点 anti-affinity；两个副本可正常调度。PDB 保证至少一个可用。 |
| `CILIUM_K8S_CLIENT_QPS` / `BURST` | `50` / `100` | 观察 API limiter 结果、L2 Lease 续期、Service 变更率和 CES 同步。没有限流证据时不要继续放大。 |
| `CILIUM_ENABLE_LB_IPAM` | `auto` | 是否创建 LB-IPAM 池（`gateway-pool` + `default-pool`）。`auto` = Gateway API 或 L2 任一开启即开；Gateway API 开或 L2 开时不允许为 `false`。 |
| `CILIUM_ENABLE_L2_ANNOUNCEMENTS` | 环境相关 | 是否在节点网卡上 ARP 通告池地址（`default-l2`）。只经 newt/Pod 访问的集群内 VIP 不需要；开启时池地址必须是网络所有者分配的。 |
| `CILIUM_GATEWAY_LB_IP` | 环境相关 | 独立 `gateway-pool` 的唯一地址，只匹配 Cilium 生成的共享 Gateway Service；`spec.addresses` 固定它，Pangolin target 不漂移。留空时 00 阶段有终端会询问。 |
| `CILIUM_LB_POOL_START/STOP` | 环境相关 | 给其它 LB 的 `default-pool`，不得与 Gateway `/32` 重叠，且用 `NotIn` 排除共享 Gateway 的 Service。内网 `.121-.199`；机房 `.241-.249`。未经所有者确认，不要在共享 VLAN 猜空闲地址。 |
| `CILIUM_LB_ACCELERATION` | `disabled` | 当前 virtio/vmxnet3 的 XDP 未做真实 Service 压测，先保持禁用；换物理网卡或验证 `best-effort` 后再开。 |
| `CILIUM_HUBBLE_EVENT_BUFFER_CAPACITY` | `4095` | 仅在启用 Hubble 后生效。保持 4 vCPU 节点默认 event queue 规模；只有观测到 lost events 才扩大。 |
| `CILIUM_BBR`、`CILIUM_NETKIT`、`CILIUM_BIGTCP` | `auto` / `auto` / `false` | 由内核、NIC 与现有 Pod 数据面决定。运行态必须以 `cilium-dbg status`、内核配置和真实吞吐测试验收。 |

基线命令：

```bash
# 每节点 map 的虚拟内存上限与 pressure
for node in node101 node102 node103; do
  kubectl get --raw "/api/v1/nodes/${node}:9962/proxy/metrics" \
    | grep -E 'cilium_bpf_map_pressure|bpf_maps_virtual_memory_max_bytes'
done

# map 容量、当前 entry 和错误
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg map list

# 组件实际资源
kubectl -n kube-system top pod -l k8s-app=cilium
kubectl -n kube-system top pod -l name=cilium-operator
kubectl -n kube-system top pod -l k8s-app=cilium-envoy
```

当前变更前快照约为每节点 891 MB BPF maps virtual memory，目标指标已经开始采集。`0.01` 下预计释放量只作容量规划参考，最终值必须以升级后的 `cilium-dbg map list`、metrics 和 `bpftool map show` 为准。

## 5. Cilium values 说明

### 5.1 滚动策略

```yaml
minReadySeconds: 10
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
```

3 节点集群每次最多停止一个 agent。`minReadySeconds` 要求新 Pod 连续 Ready 10 秒后才继续，避免短暂 Ready 立即推进下一节点。

### 5.2 BPF map

```yaml
bpf:
  preallocateMaps: false
  distributedLRU:
    enabled: true
  mapDynamicSizeRatio: 0.01
```

`distributedLRU` 保留每 CPU 分片 LRU；`preallocateMaps=false` 保持按需分配。`mapDynamicSizeRatio` 从 `0.08` 调到 `0.01` 会改变 CT/NAT map 容量并触发 map 重建，因此必须独立 rollout。

当前压力很低不等于可以跳过维护窗口：map 重建本身会丢失连接跟踪状态，已有长连接仍可能断开。

满足 24 小时基线并进入维护窗口后，把 `config.env` 中的 `CILIUM_BPF_MAP_RESIZE_APPROVED` 临时改为 `true`，再执行：

```bash
sudo bash bootstrap/start.sh --only 60-cilium
```

验收完成后把授权开关改回 `false`。live 比例已经等于目标值时，`false` 不会阻止后续普通 Cilium 变更。

### 5.3 Service topology 与 Spegel

```yaml
loadBalancer:
  serviceTopology: true
```

这使 Cilium 处理 Kubernetes `trafficDistribution`。配套 Spegel v0.7.4：

```yaml
service:
  registry:
    usePreferSameNodeTrafficDistribution: true
```

不要写 `hostPort: 0`。在 Spegel chart v0.7.4 中，布尔值本身会：

- 省略 Pod 的 registry `hostPort`；
- 给 registry Service 设置 `trafficDistribution: PreferSameNode`；
- 从 containerd mirrors 中移除 `NODE_IP:30020`；
- 保留 NodePort `30021` 作为 mirror target。

`PreferSameNode` 是偏好而不是强制：本节点有 Ready endpoint 时优先本节点，没有时仍可回退其他节点。不要给当前单副本 ecommerce 服务批量设置；没有本地副本时收益有限，还可能造成流量倾斜。

### 5.4 无效键与外部 ClusterIP

Cilium 1.20 chart 已不存在以下显式键，生成器不再输出：

```yaml
externalIPs:
  enabled: true
hostPort:
  enabled: true
nodePort:
  enabled: true
sessionAffinity: true
```

这些能力由 `kubeProxyReplacement=true` 提供。无效键会被静默忽略，保留它们只会误导维护者。`socketLB.enabled` 仍是有效键，继续保留。

当前外部客户端没有到 `10.96.0.0/12` Service CIDR 的专用路由，因此使用：

```yaml
bpf:
  lbExternalClusterIP: false
```

外部入口统一经 LoadBalancer/Gateway。

### 5.5 Cilium 资源 requests

```yaml
resources:
  requests:
    cpu: 100m
    memory: 512Mi

operator:
  replicas: 2
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
    maxUnavailable: null
  resources:
    requests:
      cpu: 50m
      memory: 128Mi

envoy:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
```

agent、operator 和 Envoy 都不设置严格 memory limit。网络关键进程遇到突发流量时，应允许使用节点余量，而不是因 limit 被 OOMKill。

### 5.6 Hubble 安全观测基线

Hubble 已在 dev 集群启用。Relay 汇聚三个节点的 live flow，drop/flow 等低基数指标经 OTel Collector 写入 VictoriaMetrics；UI 与高基数 `httpV2` 继续关闭。

```yaml
hubble:
  enabled: true
  eventBufferCapacity: "4095"
  metrics:
    enableOpenMetrics: true
    enabled:
      - drop
      - dns:query;ignoreAAAA
      - tcp
      - flow
      - icmp
  redact:
    enabled: true
    http:
      urlQuery: true
      headers:
        deny: [Authorization, Cookie, Set-Cookie, X-API-Key]
  relay:
    enabled: true
    tls:
      server:
        enabled: true
  ui:
    enabled: false
```

Relay Service 只开放 TLS 443。客户端必须校验 chart 自动生成的 CA，并使用 `ui.hubble-relay.cilium.io` server name；不要为了方便退回明文端口。2026-08-28 验收为 connected nodes `3/3`，CNP deny 可返回 source/destination/port，`hubble_drop_total{reason="POLICY_DENIED"}` 已进入 VictoriaMetrics。官方给出的 Hubble 开销范围较宽，仍需持续观察 agent CPU/内存、lost events 与远端指标写入量。

## 6. 官方 preflight 与在线升级

60 阶段会在已有 Cilium release 上执行目标版本的官方 preflight：

- DaemonSet 在全部节点预拉目标 agent/Envoy 镜像；
- Deployment 执行 CNP 校验；
- 两者全部 Ready 后删除临时资源；
- 任一失败都停止 Helm upgrade，并保留资源供排障。

手工等价命令：

```bash
helm template cilium-pre-flight cilium/cilium --version 1.20.1 \
  --namespace kube-system \
  --set preflight.enabled=true \
  --set agent=false \
  --set operator.enabled=false \
  --set-string k8sServiceHost=192.168.3.101 \
  --set k8sServicePort=6443 > /tmp/cilium-preflight.yaml

kubectl apply -f /tmp/cilium-preflight.yaml
kubectl -n kube-system rollout status ds/cilium-pre-flight-check --timeout=10m
kubectl -n kube-system rollout status deploy/cilium-pre-flight-check --timeout=5m
kubectl delete -f /tmp/cilium-preflight.yaml
```

升级不要使用 `--reuse-values`。跨 chart 版本时它会忽略新 chart 引入的 defaults。60 阶段始终使用完整生成 values。

## 7. 安装器指纹

旧实现只强制重生 `values`，但 `helm.done` 仍会让 Helm upgrade 被跳过。现在 60 阶段记录：

```text
SHA256(Cilium 目标版本 + 生成 values 的 SHA256)
```

每次执行都会重生 values 并比较指纹。指纹变化时，只使以下步骤失效并重跑：

- `preflight`
- `prepull`
- `helm`
- `wait`
- `l2`
- `conn`

`ipsec` 不会被无条件重置，因此未来启用 IPsec 后不会因普通 values 变更轮换密钥。日常应用变更只需执行 `sudo bash bootstrap/start.sh --only 60-cilium`，无需再先执行 `--reset-state 60-cilium`。若 live BPF map 比例与仓库目标不同，`mapguard` 会在 preflight/Helm 之前停止；这时必须按 5.2 节显式批准维护窗口。若明确需要整阶段重置，原命令仍可用。

## 8. LoadBalancer 收敛

业务微服务没有明确的非 Gateway 客户端时，Service 应为 `ClusterIP`。本轮优先收敛：

- address
- inventory
- merchant
- order
- payment
- product
- search
- user
- control-tower gateway 的重复裸 LoadBalancer 路径

control-tower gateway 仍由共享 `cilium-gateway` 的 HTTPRoute 对外，后端 Service 改为 ClusterIP 不会删除统一入口。

保留的 LoadBalancer 使用 `externalTrafficPolicy: Cluster`。Cilium L2 Announcements 与 `externalTrafficPolicy: Local` 不兼容：宣告 VIP 的节点可能没有本地 backend，进而丢包。

### 8.1 机房三节点：为什么仍开 L2，VIP 为什么不用 `10.10.21.x`

机房节点是 `node4=10.10.21.161`、`node5=.162`、`node3=.163`，位于 VMware `vmxnet3` 的多租户
`10.10.21.0/24`。2026-09-04 在未部署 k8s 前做了三项只读/瞬时网络验证：

1. 从 node4 构造源地址 `10.244.99.99`（Pod CIDR）的 UDP 包，node5 `tcpdump` 收到 3/3；说明
   vSwitch 没有 SpoofGuard/源地址反欺骗，`routingMode=native + autoDirectNodeRoutes` 能携带 Pod 源 IP。
2. node4 → node5 的 `ping -R`（IPv4 Record-Route option）完整往返；`hybrid + dsrDispatch=opt` 依赖的
   IP option 没被 vSwitch/NSX 丢弃。仍需在真实 Service 上跑 `cilium connectivity test` 作最终验收。
3. 两轮扫描看到同 VLAN 至少 82 个地址在用；`.160/.164/.168/.169/.176-.179` 当前无 ARP 应答，
   **但「当前空闲」不等于机房分配给我们**，不能拿来做长期 VIP。

机房版采用两层入口：

```text
公网用户 → Pangolin/Traefik(node1 VPS) → WireGuard/newt Pod
          ├─ HTTPRoute: target=https://10.10.31.240:443 → Cilium Gateway → Service/Pod
          └─ 节点服务: target=10.10.21.161|162|163:<port> → node4|5|3

gateway-pool: CILIUM_GATEWAY_LB_IP = 10.10.31.240/32（只匹配共享 Gateway Service）
default-pool: CILIUM_LB_POOL_START/STOP = 10.10.31.241-249（其它 LoadBalancer）
```

这两个池与 LAN `10.10.21/24`、Pod `10.244/16`、Service `10.96/12` 都不重叠。2026-09-04 从 node4 探测
`10.10.31.240/.245/.249`：走默认网关、无响应、无 ARP——这只是那个时间点、从那台机器的观测记录，
**不是**该段未被占用或已分配给我们的证明（RFC 5227 §1.3：单次探测可能漏掉冲突）。使用前提是机房的地址规划确认
`10.10.31.0/24` 不会被路由到这个 VLAN；这一条尚未取得书面确认，列为待办。

2026-09-06 从 node4/node3 复测（只读，集群尚未部署）：
- `tracepath 10.10.31.240`：`.254`（不回 TTL 超时）→ 第 2 跳 `10.10.19.1` → 之后无回应；
  对照 `tracepath 8.8.8.8`：`.254` → `10.10.19.1` → `211.144.221.225`（公网边界）。
  说明核心路由器 `10.10.19.1` **没有**把 `10.10.31.0/24` 当成公网流量转发，而是黑洞/内部路由/过滤了 ICMP——
  三者从节点侧分不出来。这正是要问机房的问题。
- `ip neigh`、本机地址均无 `10.10.31.x`；`arping` 未安装，没做同链路 ARP 探测。
- 结论不变：可作为集群内 VIP 候选；能否长期使用取决于机房答复，不取决于探测结果。

要问机房的具体问题（拿到答复后写回本节）：
1. `10.10.31.0/24` 在你们的地址规划里是什么状态：未分配 / 保留 / 已分给其它租户或内部系统？
2. `10.10.19.1` 上对 `10.10.31.0/24` 的处理：无路由丢弃、null route，还是转发到某个 VLAN？
3. 我们打算只在 `10.10.21.0/24` 的三台主机内部使用 `10.10.31.240-249` 作为不出网的 Service VIP，且会在 `ens160`
   上做 ARP 通告（跨网段地址，正常情况下 `/24` 邻居不会请求它）；这是否与你们的规划冲突？
4. 若冲突，能否分配一段专属的 `10.10.21.x`（至少 10 个地址）作为 LAN 直达的 LB 池？

安装后 Cilium 在每个节点的 eBPF service map 里编程 VIP。对 Cilium 管理、非 hostNetwork 的 newt Pod，
`.240:443` 是 L7 LB：socket 层 eBPF 不做直连后端的转换，交给 endpoint 数据面重定向到本节点 Envoy，再按 HTTPRoute 选
后端（v1.20.1 `bpf/bpf_sock.c` 与 Gateway 文档，见 [`CILIUM-UPSTREAM-VERIFICATION.md`](CILIUM-UPSTREAM-VERIFICATION.md) §3）。
这条路径**不依赖** L2 announcement，也不需要谁应答 ARP。L2 announcement 只影响「同链路的其它主机」能否直达 VIP；
一般 `/24` 掩码的邻居会把跨网段目的地交给网关而不发 ARP，但邻居的掩码/on-link 路由本轮未核实，
不能写成「绝不会」。

池与通告已解耦（2026-09-06）：`CiliumLoadBalancerIPPool` 由 `CILIUM_ENABLE_LB_IPAM`（默认 `auto` = Gateway API
或 L2 任一开启即开）控制，`CiliumL2AnnouncementPolicy` 由 `CILIUM_ENABLE_L2_ANNOUNCEMENTS` 控制，60 阶段是两个独立步骤
（`pools`、`l2`），各自创建/清理/校验。无池时 Cilium 为 Gateway 建出的 LoadBalancer Service 一直 `<pending>`、
`Programmed=False`，所以 preflight 拒绝「Gateway API 开、池关」与「L2 开、池关」两种组合。只经 newt/Pod 访问集群内 VIP
时 L2 不是必需的：把它改成 `false` 只会删掉 `default-l2`，池与 Gateway 固定 VIP 不受影响（Pod → `.240:443` 路径已实测
不依赖 L2）。机房当前仍保持 L2 开启。

三个地址（Gateway VIP、默认池起止）只有使用者能决定：`config.env` 留空时，00 阶段有终端就逐项询问（校验 IPv4，
答案存到 `/var/lib/k8s-installer/lb-ipam.env`，0600，重跑自动复用；`config.env` 显式写了的永远优先），无终端则报错退出，
不会带着空地址走到 60 阶段。配置校验步骤每次重跑都重新执行，改了地址或开关不会被首次的完成标记跳过。

验收分四层，互相不能替代（状态列为 2026-09-06 node4+node5 两节点集群的实测）：

| 层 | 证明什么 | 由谁验证 | 状态 |
|---|---|---|---|
| 控制面/分配 | 两池 `PoolConflict=False`@当前 generation；Gateway 当前 generation `Programmed=True`；生成的 Service `default/cilium-gateway-cilium-gateway` 请求注解与实际分配都是 `.240`，`IPAMRequestSatisfied=True` | 60 阶段 l2 步骤（每次重跑都重校验）、`components/gateway/install.sh`、90 阶段 | ✅ 60/80/90 三处校验都通过 |
| eBPF 编程 | `cilium-dbg service list` 含该 VIP | 90 阶段 LB 冒烟（L2 租约、节点自访只作附加观测分别记录） | ✅ 冒烟 VIP `.244` 已编程；租约存在；节点自访第一次未通、第二次通（附加观测，不作判据） |
| Pod 路径（newt 的同一条路） | 从 Cilium 管理、非 hostNetwork 的 Pod 内带正确 Host 访问 `https://.240/...` 得到业务状态码（404/502 不算） | 探测 Pod（`curlimages/curl`，node4 与 node5 各一）；正式 newt Pod 待 `ADDON_NEWT` 打开后按 `components/gateway/README.md` §5 复测 | ✅ 两节点都：`metrics.dev.test`/`argocd.dev.test` 200 `server=envoy`；未匹配 Host 404；80→443 301；证书 `CN=dev.test`。newt Pod 本身尚未部署（站点 ID 与 node3 在线 newt 冲突） |
| 同链路外部主机 | 只有拿到机房专属 `10.10.21.x` 池后才有意义 | 人工，需先取得地址授权 | ⏳ 待机房答复（见上文 4 个问题） |

`default/cilium-gateway` 通过 `spec.addresses` 固定在 `CILIUM_GATEWAY_LB_IP`（Cilium 把它写成生成 Service 的
`io.cilium/lb-ipam-ips` 请求注解；若 `spec.infrastructure.annotations` 里已有同名注解则不覆盖，所以验收看的是 Service
上的实际注解）；`gateway-pool` 用 LB-IPAM 特殊 selector 匹配生成的 Service `default/cilium-gateway-cilium-gateway`，
防止 Consul/其它 Gateway 先抢 `.240`。带固定请求的 Service 不会退回 default-pool 随机取址；request 未满足时
Service 保持 pending（`IPAMRequestSatisfied=False`，reason `no_pool`/`pool_selector_mismatch`/`already_allocated`）。
反向也封住：`default-pool` 的 `serviceSelector` 用 `NotIn` 排除 `cilium-gateway-cilium-gateway`，
即使固定请求注解丢失（例如被 `spec.infrastructure.annotations` 覆盖），共享 Gateway 也拿不到 `.241-.249`
里的地址，只会 pending 并被 90 阶段抓出来；60 阶段的 l2 校验同时检查这个排除项。
Pangolin target 不再写每次重建会变化的 ClusterIP。若机房以后明确分配一段专属 `10.10.21.x`，
替换 Gateway VIP 与 default-pool 起止三项；届时 VIP
也会被 ens160 真正 ARP 通告，LAN 其它主机可以直达。**未经机房确认，不要把「无 ARP 应答」的地址当成所有权。**

安全边界：上述 spoof 测试也证明共享 VLAN 允许任意源 IP，跨节点 Pod 流量当前是明文。先按当前
`CILIUM_ENABLE_IPSEC=false` 复原并做吞吐基线；承载生产敏感数据前，应在维护窗口评估 IPsec
（安装器已支持，打开后会自动取消 `installNoConntrackIptablesRules`）或为安装器增加 WireGuard 选项。

## 9. 哪些变更需要重建

| 变更 | 是否重建集群 | 生效方式与风险 |
|---|---|---|
| Cilium 1.20.0 → 1.20.1 | 否 | preflight 后滚动 agent/operator/envoy；L7/Gateway 连接可能 reset |
| `serviceTopology`、资源 requests、XDP 关闭、无效键清理 | 否 | Helm upgrade + 滚动 |
| Spegel `PreferSameNode` | 否 | Helm upgrade + Spegel DaemonSet 滚动 |
| `mapDynamicSizeRatio` | 否 | Cilium agent 滚动；CT/NAT 状态重建，必须维护窗口 |
| 调整 Hubble metrics/Relay TLS | 否 | Cilium 或 Relay 滚动；先 dry-run，再验 3/3 connected 与业务流量 |
| veth ↔ netkit | 不必重建整个集群，但必须逐节点 cordon/drain 并重建 Pod，或只在新节点启用 | CNI 不能原地把既有 Pod 的 veth 换成 netkit；不要把存量配置改成 `auto` 期待无感切换 |
| native ↔ tunnel、IPAM/CIDR 迁移 | 属集群网络迁移/重建级变更 | 会影响既有 Pod 网络；本轮不改 |

当前集群已经运行 netkit，本次必须保持 `bpf.datapathMode=netkit`，因此没有节点或集群重建项。

## 10. CES 暂时保留是什么意思

当前约有 70 个 CEP、22 个 CES。这个规模还没有大到必须依赖 CES；CES 在 Cilium 1.20 仍是 beta，并且与 Egress Gateway 不兼容。

「暂时保留」不是说 CES 对当前规模必不可少，而是说：

1. CES 已稳定运行，22 个 CES 中的 endpoint 总数与 70 个 CEP 一致；当前没有漂移。
2. 关闭 CES 是一次有顺序要求的数据源迁移，不是删除一个无用 values：
   - 必须先让所有 agent 停止读取 CES、重新读取 CEP；
   - 等全部 agent 更新完成后，operator 才能停止生成并删除 CES。
3. 如果顺序反过来，operator 先删 CES，而 agent 仍在读取 CES，中间会出现 endpoint 信息真空，可能造成策略与连接异常。
4. Cilium 1.20.1 修复了 CES operator 关闭路径的死锁，先升级可以降低以后迁移的风险。

因此当前继续使用：

```yaml
ciliumEndpointSlice:
  enabled: true
```

只有准备启用 Egress Gateway 时，才按官方 CES downgrade procedure 分阶段关闭。不能让 CES 与 Egress Gateway 同时启用；这种组合不受支持，可能产生控制面看不到、数据面仍残留的 egress 规则。

## 11. 验收与回滚

升级后至少执行：

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=15m
kubectl -n kube-system rollout status ds/cilium-envoy --timeout=15m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m

kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-service-topology}{"\n"}'
kubectl get gateway,httproute -A
kubectl -n kube-system get lease | grep cilium-l2announce
```

map 缩容后额外验证：

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg map list
for node in node101 node102 node103; do
  kubectl get --raw "/api/v1/nodes/${node}:9962/proxy/metrics" \
    | grep '^cilium_bpf_map_pressure'
done
```

补丁升级回滚优先使用 Helm 历史中的上一 revision，并再次等待全部工作负载就绪：

```bash
helm -n kube-system history cilium
helm -n kube-system rollback cilium <上一版本 revision> --wait --timeout 15m
```

不要用 `git reset --hard`、删除 Cilium CRD 或 `kubeadm reset` 处理普通升级失败。

## 12. 上游依据

- [Cilium v1.20.1 release](https://github.com/cilium/cilium/releases/tag/v1.20.1)
- [Cilium 1.20 upgrade guide](https://docs.cilium.io/en/v1.20/operations/upgrade/)
- [Cilium Kubernetes requirements](https://docs.cilium.io/en/v1.20/network/kubernetes/requirements/)
- [Cilium performance tuning / netkit](https://docs.cilium.io/en/v1.20/operations/performance/tuning/#netkit)
- [CiliumEndpointSlice](https://docs.cilium.io/en/v1.20/network/kubernetes/ciliumendpointslice/)
- [Egress Gateway incompatibilities](https://docs.cilium.io/en/v1.20/network/egress-gateway/egress-gateway/#incompatibility-with-other-features)
- [Cilium Gateway API](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/)
- [Cilium v1.20.1 Gateway `spec.addresses` support](https://raw.githubusercontent.com/cilium/cilium/v1.20.1/Documentation/network/servicemesh/gateway-api/addresses.rst)
- [Cilium L2 Announcements](https://docs.cilium.io/en/v1.20/network/l2-announcements/)
- [Cilium LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Spegel chart v0.7.4](https://github.com/spegel-org/spegel/tree/v0.7.4/charts/spegel)
