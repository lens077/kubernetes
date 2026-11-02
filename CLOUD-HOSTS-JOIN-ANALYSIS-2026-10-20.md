# 把 SSH 配置里的云主机并入 k1/k2/k3 集群 —— 收益 / 代价对比

**结论先说：不建议并入。** 现役 6 台云主机全部实测（2026-10-20），把它们加进 k123 只能换来
**约 +6 GiB 可用内存（+22%）**，代价是 **跨公网 L3 隧道 + CNI/存储/入口三处改造 + 可用性下降**，
而集群当前真正卡脖子的问题（单控制面、单盘无冗余、机房拉不动镜像/Chart）**一个都解决不了**。
若一定要用，只有 `node0`（上海，RTT 6.0 ms）够格，且必须打污点只跑无状态负载。

> 数据来源：本文所有容量/延迟数字均为 2026-10-20 当次 SSH 实测（`kubectl top/describe`、`free`、`df`、
> `ping`、`/dev/tcp` 探测），不是文档抄录。复现命令见 §9。

---

## 1. 现状基线：k123 到底缺什么

| 项 | k1 | k2 | k3 | 合计 / 说明 |
|---|---|---|---|---|
| 角色 | control-plane + 工作负载 | worker | worker | **单控制面**，etcd 只在 k1 |
| CPU | 4C（实占 294m / 7%） | 4C（275m / 6%） | 4C（401m / 10%） | 12C，**实际只用了 8%** |
| 内存 allocatable | 9.11 GiB | 9.11 GiB | 9.11 GiB | **27.3 GiB** |
| 内存实占 | 5.10 GiB（56%） | 5.81 GiB（63%） | 4.80 GiB（52%） | 15.7 GiB（57%） |
| Requests | 3.70 GiB（40%） | 5.77 GiB（63%） | 5.88 GiB（64%） | 15.3 GiB（56%） |
| Limits | 10.2 GiB（**112%**） | 14.3 GiB（**156%**） | 13.1 GiB（**143%**） | 37.6 GiB（**137%** 超卖） |
| Pod 数 | 33 | 31 | 19 | 83 个 / 38 个 namespace |
| 盘 | 146G（用 28G） | 146G（用 33G） | 146G（用 34G） | 各 80G 稀疏 loopback 给 OpenEBS |

**结论一：CPU 完全不是瓶颈（8%），内存才是（57% 实占 + 137% limits 超卖）。**
所以"加机器扩 CPU"这个直觉在本集群不成立，收益必须按**内存**计价。

**结论二：k123 的痛点不在容量，在结构。**

| 真实痛点 | 云主机并入能不能解决 |
|---|---|
| 单控制面 k1，挂了集群就没了 | ❌ 加 worker 不进 etcd；加云控制面反而更糟（§4.4） |
| 存储单盘 + loopback，节点绑定，无副本 | ❌ 本地 PV 不跨节点，云盘也接不上现有 PVC |
| 机房拉不动 GitHub / Docker Hub / Helm 仓 | ❌ 加节点不产生镜像缓存，**但云主机当镜像中转可以** |
| 无异地备份、无恢复演练 | ❌ 加节点不等于备份，**但云主机当备份目标可以** |
| 观测栈单副本，节点故障即丢数据 | ⚠️ 只能缓解，且跨站更慢 |

---

## 2. 候选机器实测（不是按文档抄的）

| host | 云 / 地域 | CPU | 内存总量 | 盘 | RTT→k1 | 现有承载 | 可动性 |
|---|---|---|---|---|---|---|---|
| `node0` | 腾讯 ap-shanghai | 4C | 3.64 GiB | 60G（用 9.4G） | **6.0 ms** | blog(Docker) + newt + otelcol + crowdsec | 有业务，剩 ~2.5G |
| `node1` | 腾讯 ap-guangzhou | 4C | 3.64 GiB | 40G（**用 64%**） | 29.2 ms | **Pangolin 边缘** + casdoor + PG + Redis + SafeLine + ntfy + 6 个站点 | **不可动** |
| `node2` | 阿里 cn-guangzhou | 2C | 1.57 GiB | 40G（用 9.4G） | 29.9 ms | minio(silo) + gorse + newt | 内存太小 |
| `node3` | 腾讯 ap-guangzhou | 4C | 3.63 GiB | 60G（用 23G） | 25.0 ms | 2× GitHub Actions runner | CI 在用 |
| `node4` | 腾讯 **na-siliconvalley** | 2C | 1.92 GiB | 40G（用 6.9G） | **243 ms** | 空闲（只有 docker/otelcol） | 延迟直接出局 |
| `node6` | 腾讯 ap-guangzhou | 2C | 1.92 GiB | 50G（用 5.9G） | 30.4 ms | 空闲 | 唯一干净余量 |

扣掉不可动的 `node1`，可加入池 **14 vCPU / 12.7 GiB / 249 G**。
再扣每节点 kubelet + Cilium agent + OS 开销（≈0.7–0.9 GiB）和各自已在跑的服务，
**真实可调度余量约 6 GiB，分散在 4 个地域、4 个 provider**。

---

## 3. 收益侧：能换来什么（按内存计价）

| 维度 | 加入前 | 全量加入后 | 变化 | 值不值得 |
|---|---|---|---|---|
| CPU | 12C / 实占 8% | 26C | **+117%** | ❌ CPU 已闲置，纯数字 |
| 内存池 | 27.3 GiB | ~33.3 GiB | **+22%** | ⚠️ 唯一真收益，但见下 |
| 可在集群内使用的盘 | 438G 本地 | 438G（云盘接不上） | **≈0** | ❌ 本地 PV 节点绑定 |
| 节点数 | 3 | 8 | 3→8 | ❌ 运维面 ×2.7 |
| 单控制面风险 | 存在 | **依然存在** | 0 | ❌ |
| 跨地域容灾 | 无 | **依然没有**（数据在机房） | 0 | ❌ 别把"异地节点"当灾备 |

**关键约束：能吃到这 6 GiB 的负载非常有限。**

集群内存大户（`kubectl top pods` 实测）与它们能不能搬到云节点：

| Pod | 内存 | 能否搬到 25–30 ms 的云节点 |
|---|---|---|
| kube-apiserver (k1) | 1696 Mi | ❌ 控制面 |
| elasticsearch-0 | 1193 Mi | ❌ 本地 PV + 单节点 + 写密集 |
| kafka my-cluster-dual-role-0 | 805 Mi | ❌ 本地 PV + quorum |
| grafana | 678 Mi | ✅ 无状态（但数据源跨站查询会变慢） |
| kafka connect | 575 Mi | ❌ 依赖本地 Kafka/PG |
| vm-single | 531 Mi | ❌ 本地 PV + 写密集 |
| kafka entity-operator | 479 Mi | ❌ |
| cilium ×3 | ~430 Mi/节点 | ❌ DaemonSet 必在本节点 |
| argocd-application-controller | 352 Mi | ✅ |
| pg-main-1 | 320 Mi | ❌ 本地 PV |
| umami / healthchecks | 287 / 229 Mi | ✅ |

**可迁移的无状态负载合计约 2–3 GiB**，正好等于"把 3 个大户搬走"的量级。
也就是说：**投入 5 个节点的运维复杂度 + 全站网络改造，换来的实际内存腾挪是 ~10% 的池子。**

---

## 4. 代价侧：七条硬约束（都有实测依据）

### 4.1 没有 L3 通路（最硬的一条）

从 `node0/node3/node4/node6` ping `10.10.21.161`：**全部 unreachable**。
云上 VPC 私网（`10.1.0.0/22`、`192.168.2.0/24`）与机房 `10.10.21.0/24` 之间没有任何路由。
Pangolin/newt 现有形态是**L4 反代**（HTTP/TCP target → VIP），**不是 L3 路由**，无法承载 Pod 网络。

要并入就必须自建隧道（WireGuard/IPsec），且：

- 机房侧放通 UDP 端口到指定云 IP（现在是公网 NAT，只有 6443 映射着）；
- 全网 MTU 从 1500 降到 ~1420，而 Cilium 当前 `enable-pmtu-discovery=true` +
  `packetization-layer-pmtud-mode=blackhole`，**大包会被黑洞而不是报错**，表现为偶发连接挂死；
- Pod CIDR 要双向路由（云节点 `10.244.x/24` ↔ 机房 `10.244.0.0/16`），隧道断则该节点所有 Pod 失联。

### 4.2 Cilium 配置把 NIC 名钉死了

实测 `cilium-config`：`devices: ens160`、`datapath-mode: netkit`、`routing-mode: native`、
`ipv4-native-routing-cidr: 10.244.0.0/16`。
云主机网卡是 **`eth0`**，且各 provider 网卡名/MTU 不一致（`10.1.0.8/22`、`192.168.2.32/24`）。
直接 join 会因 device 不存在导致 agent 起不来；改成 `devices: ""` 自动探测则**必须整集群滚动重启 Cilium**。

### 4.3 入口 VIP 只在本段有效

`enable-l2-announcements=true` + LB-IPAM 池 `10.10.31.240-249`，实际分配了 5 个 VIP
（gateway `.240`、pg `.241`、dragonfly `.242`、kafka `.243`、lyrapass `.244`）。
L2 announcement 由 Cilium **本节点在本地二层广播 ARP**。若 leader 落在云节点，VIP 会在腾讯 VPC 里被 ARP，
机房侧直接失联。必须给 `CiliumL2AnnouncementPolicy` 加 nodeSelector 只留 IDC 节点 —— 这是"加节点后必须改"的隐性成本，
漏了就是**全站 502**。

### 4.4 做控制面 HA 是反向收益

想靠云主机解决单控制面？实测 RTT：上海 6.0 / 广州 25–30 / 硅谷 243 ms。etcd 要求成员间 RTT 通常 <10 ms，
跨站写入会放大 fsync 等待、网络抖动触发 leader 频繁切换。而且云主机是**单盘 VPS**，
fsync 延迟远差于 k1 的 0.2 ms（9-03 实测）。**正确做法是 k2/k3 提权成控制面（同交换机 <1 ms），不是拉云主机。**

### 4.5 存储收益 ≈ 0

`openebs-lvm` 是 local PV（`WaitForFirstConsumer`，节点绑定）。云节点的盘只能挂云节点上的 Pod，
现有 10 个 PVC 一个都过不去；云盘 40–60G 且根分区已占用，再叠 loopback 等于双倍写放大。
**"加 249G 盘"在集群视角是不存在的。**

### 4.6 kubelet 前置条件不满足

`failSwapOn: true`，而 `node0/node3/node4/node6` 全部开着 1.9–2.0 GiB swap；内核 `6.8.0`
（集群是 `7.0.0-38`）；`node2` 甚至是 `7.0.0` 但 swap=0、内存 1.57 GiB。
要加入需逐台关 swap、对齐 containerd/kernel、改 `/etc/fstab` —— 对 `node1`（生产边缘）等于停机维护。

### 4.7 安全与费用

- 现状 `211.144.221.229:6443` 已对公网开放（实测从 `node6` 可拉到 `version` 并返回 1.36）。
  加节点还要再开 **10250（kubelet）/ 8472（VXLAN 证据面）/ 51820（WireGuard）**，
  worker 一旦被入侵即可横向到整个集群。**扩集群 = 扩攻击面**。
- 跨云/机房互联是公网流量，按量计费（腾讯云出方向约 0.5–0.8 元/GB）。kubelet 心跳、
  metrics scrape、日志外发、镜像拉取都会持续产生流量。真跑起来"闲置云主机"会变成"每月新增账单"。

---

## 5. 五个方案对比

| 方案 | 容量收益 | 延迟影响 | 可用性 | 存储 | 改造量 | 能否解决 k123 真痛点 | 评价 |
|---|---|---|---|---|---|---|---|
| **A. 全量并入**（node0/2/3/4/6 作 worker） | 内存 +22%、CPU +117%（无用） | 跨站 25–243 ms，全站变慢 | **下降**（隧道/CNI/入口三处新故障点） | ≈0 | 大（隧道+CNI+入口+5 台改机） | ❌ | **不推荐** |
| **B. 只并入 node0**（上海 6.0 ms，加污点） | 内存 +~1.5 GiB | 6 ms，可接受 | 略降（多一个 WAN 节点） | ≈0 | 中 | ❌ | 仅当有明确无状态突发需求 |
| **C. 云主机提控制面做 HA** | 0 | 6–243 ms 拖累 etcd | **下降** | 0 | 大 | ❌（HA 应机房内做） | **明确否决** |
| **D. 不并入，当集群外围**（推荐） | 0（但把 4 类工作移出集群） | 无 | **提升**（外部视角/异地备份） | 0 | 小 | ✅ 备份/镜像/解封/外部探测 | **推荐** |
| **E. 云上独立小集群**（k3s 单节点） | 独立池，不共享 | 无 | 隔离（爆炸半径分开） | 独立 | 中 | ⚠️ 多一套要维护 | 备选 |

---

## 6. 推荐路线：不入集群，按"外围能力"用（每项都对应待办）

按 ROI 排序，全部是现有 `TODO.md` 里挂着的未完成项，云主机恰好是现成资源：

| # | 用途 | 用哪台 | 解决什么 | 为什么比"并入集群"划算 |
|---|---|---|---|---|
| 1 | **异地备份目标**（S3/MinIO + CNPG Barman、OpenBao raft snapshot、VM/VL 快照） | `node4`（硅谷，243 ms 只影响备份吞吐）或 `node6` | TODO「单盘无冗余、异地备份与恢复演练未实施」 | 备份要的是**地理隔离**，慢一点无所谓；延迟 243 ms 对备份是缺点，对"异地"是优点 |
| 2 | **OpenBao transit 自动解封**（外部 Vault） | `node2` 或 `node6`（纯出站 AppRole） | TODO「OpenBao 重启即 sealed」 | 集群内放解封密钥等于没解封；放在独立信任域才有意义 |
| 3 | **镜像 / Chart 中转仓**（TCR + registry mirror + chart tgz） | `node3`（4C/60G，已有 runner） | 机房拉不动 Docker Hub / GitHub / Helm 仓 | 云主机出口好，天然适合做 pull-through cache；这条直接消掉每次部署最大的时间坑 |
| 4 | **集群外黑盒探测**（gatus 第二实例，只探公网入口） | `node0`（上海 6 ms） | 现有 16 条 gatus 探针全在集群内 —— 集群挂了告警也一起挂 | 外部探针才能区分"后端挂"和"集群挂" |
| 5 | **CI / 一次性构建 Job** | `node3`（Runner 已在跑） | 构建占内存、和业务抢资源 | 已在用，保持独立即可 |
| 6 | **告警/观测异地副本**（vmalert + Alertmanager 精简副本，remote-write） | `node6` | 集群内告警自噬 | 独立进程，不需要 Pod 网络 |

**同一笔预算的对照**：若目标是"扩内存"，把 k1/k2/k3 从 10G 提到 16G（+18 GiB allocatable、
0 WAN 风险、0 改造）明显优于"5 台云机 +6 GiB + 全站网络改造"。若目标是"消除单控制面"，
把 k2/k3 提成控制面（<1 ms，etcd 三成员）是唯一正解。

---

## 7. 如果仍然要并入：最小实施清单（前置条件，缺一不可）

按依赖顺序，每条都给了验收判据：

1. **隧道**：k1 ↔ 目标云主机 WireGuard（`wg0`，节点地址 `10.99.0.0/24`，MTU 1420）。
   验收：双向 `ping -M do -s 1400` 通，`iperf3` 稳定 ≥50 Mbps。
2. **路由**：`AllowedIPs` 双向包含 `10.244.0.0/16` 与该节点 `/24`；机房侧加静态路由。
   验收：k1 能 ping 通云节点 Pod IP，反之亦然。
3. **Cilium**：`devices` 加 `eth0`（或改自动探测，**需滚动重启**）；`mtu: 1420`；
   `CiliumL2AnnouncementPolicy` 加 `nodeSelector: kubernetes.io/hostname in (k1,k2,k3)`。
   验收：`cilium status` 全绿；VIP `.240` 仍由机房节点通告（`ip neigh` 在机房侧可见）。
4. **节点准备**：关 swap（`failSwapOn: true` 会直接拒启）、containerd 对齐 2.3.4、内核 ≥7.0、
   时钟 chrony 对齐、`node-labels: topology.kubernetes.io/region=cloud,wan=true`。
5. **调度隔离**：`taint node-role.kubernetes.io/wan=true:NoSchedule`；
   只给无状态 Deployment 加 toleration + `topologySpreadConstraints` 防集中。
6. **不装存储**：不创建 `openebs-vg`，不给云节点 `openebs-lvm` 亲和。
7. **安全**：云安全组只放行 IDC 出口 IP；不开公网 10250/8472；`kubelet --anonymous-auth=false` 复核。
8. **观测**：WAN 节点单独 `nodeNotReady` 容忍（≥5 min），避免隧道抖动触发大批驱逐；
   加跨站 RTT/丢包看板与流量计费看板。
9. **验收红线**：跨站 Pod→Pod P99 < 60 ms；CoreDNS 跨站解析 < 30 ms（现无 node-local DNS，
   每次解析都要回机房，这是最容易被忽略的隐形放大器）；连续 72 h 无 NotReady 抖动。

---

## 8. 一句话回答

> **别并。** k123 缺的不是 CPU 和几 G 内存，而是控制面冗余、可迁移的存储、和可靠的镜像来源；
> 云主机在这三件事上都帮不上，只会把"单机房单控制面"变成"跨公网单控制面"。
> 同一个资源池按 §6 用，能换到备份、自动解封、镜像中转、外部探测四件真正缺的东西。

---

## 9. 复现命令

```bash
# 集群容量与占用
ssh k1 'export KUBECONFIG=/etc/kubernetes/admin.conf; kubectl get nodes \
  -o custom-columns="NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory"; \
  kubectl top nodes; kubectl describe nodes | grep -A4 "Allocated resources"'

# 云主机规格 / 承载
for h in node0 node1 node2 node3 node4 node6; do
  ssh $h 'hostname; nproc; free -m|sed -n 2p; df -h /|tail -1; docker ps --format "{{.Names}}"; \
          uname -r; systemd-detect-virt'
done

# 延迟与可达性
ssh k1 'for ip in 115.159.84.100 114.132.233.129 8.138.194.254 193.112.22.183 170.106.184.3 119.91.233.24; \
        do ping -c4 -q $ip | tail -1; done'
ssh node6 'ping -c2 10.10.21.161'          # → 不可达，证明无 L3 通路

# CNI 现状
ssh k1 'export KUBECONFIG=/etc/kubernetes/admin.conf; kubectl -n kube-system get cm cilium-config -o yaml \
        | grep -E "devices|routing-mode|datapath-mode|enable-l2|ipv4-native|pmtud"'
```
