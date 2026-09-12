# 机房三节点(node3/node4/node5)部署就绪评估 — 2026-09-03

只读体检结论。本次**没有**在远程节点执行任何写操作(仅 `ssh` 读取状态、`curl -I` 探测、
`ping` 扫描、node4/node5 上写入并删除一个临时测速文件)。

> **最终修订（2026-09-04）**：node3 重装后作为第三个节点加入，PostgreSQL 回集群内 CNPG；
> `ADDON_CNPG=true`、`ADDON_OPENFGA=true`。§4/§5 里旧的「pigsty PG / node3 不入集群」内容已重写。
> Cilium **保持 L2 Announcements + LB-IPAM**：Gateway 没有池就拿不到地址、`Programmed=False`。
> 机房版用不与共享 VLAN 冲突的集群内 VIP：共享 Gateway 专属 `.240/32`，其它 LB 用 `.241-.249`；
> newt/Pangolin target 用该固定 VIP:443，也可直接 target 节点 `10.10.21.161/.162/.163:<port>`。
> Pigsty 收割见 [`PIGSTY-HARVEST-2026-09-03.md`](PIGSTY-HARVEST-2026-09-03.md)，
> 机房完整配置见 `bootstrap/config.hosting.env`，复原见 [`RESTORE-RUNBOOK-2026-09-04.md`](RESTORE-RUNBOOK-2026-09-04.md)。

## 1. 结论

**安装器代码本身可以跑在这三台机器上(amd64 / Ubuntu 26.04.1 / 内核 7.0 与内网完全同代),
但 `config.env` 是为内网 PD 虚拟机写的,原样执行会在 45 阶段(etcd 盘)和 70 阶段(存储)直接失败;
如果照抄 `--yes`,还会把内网的 Gateway VIP `.120` 与 default-pool `.121-.199` 通告到机房共享网段。**

必须先解决的四件事(按阻塞程度排序):

| # | 问题 | 现状 | 处理 |
|---|---|---|---|
| 1 | **没有可用磁盘** | 三台都是单盘 150G;9 月 3 日已 `growpart` + `lvextend -l +100%FREE` 把全部空间给了根 LV(`VFree=0`),盘尾无未分配空间;**机房不能加盘**;ext4 不能在线缩小 | 只剩安装器自带的回环文件兜底 `LVM_ALLOW_LOOPBACK=true`(无需改代码)。备注:若当时保留 VG 空闲空间,直接 `LVM_VG_NAME=ubuntu-vg` 就能让 OpenEBS 用系统 VG,以后重装系统时按此规划 |
| 2 | **LB 地址池必须有，不能抢共享 VLAN 地址** | GatewayClass cilium 生成 LoadBalancer Service；无 LB-IPAM 池时 Gateway 无地址、`Programmed=False`。`10.10.21/24` 又有 82 台邻居，未分配的 `.160/.164/...` 不能视为我们所有 | 保持 L2 开启；Gateway 专属池 `10.10.31.240/32`，default-pool `.241-.249`（只供集群/newt）。机房以后给专用 `.21.x` VIP 再换成同网段池 |
| 3 | **代理与 GitHub** | `PROXY_URL=192.168.3.220:7890` 不可达;`CONTAINERD_USE_PROXY=true` 会让 containerd 常驻指向不通的代理,**除 `CONTAINERD_NO_PROXY_EXTRA`(TCR/GHCR)外的镜像全部拉不动**(quay、阿里云、docker 镜像站都走代理);`github.com` 直连三台各测 3 次,成功 1/9 | `PROXY_URL=""`、`CONTAINERD_USE_PROXY=false`、`GITHUB_PROXY="https://ghfast.top"`(实测三台均 200) |
| 4 | **node3 原系统不能原地加入** | pigsty 绑旧 IP `.172`、PG 已停；docker/containerd/tuned/ufw 与安装器存在接管冲突 | 已拍板重装 node3；数据/配置已收割。重装后它是干净 worker，CNPG/VM/VL/VT/Kafka/ES 不要求固定在 node3 |

## 2. 三台机器实测

| 项目 | node4 (`10.10.21.161`) | node5 (`10.10.21.162`) | node3 (`10.10.21.163`) |
|---|---|---|---|
| OS / 内核 | Ubuntu 26.04.1, 7.0.0-14(已装 -30,待重启) | 同 node4 | Ubuntu 26.04.1, 7.0.0-30 |
| 平台 | VMware, vmxnet3, Xeon Gold 6338 | VMware, vmxnet3, Xeon **Silver 4216** | VMware, Xeon Gold 6338 |
| CPU / 内存 | 4C / 7.4G(可用 6.8G) | 4C / 7.4G(可用 6.8G) | 4C / 7.4G(**可用 3.4G**,swap 已用 579M) |
| 磁盘 | sda 150G → `ubuntu-vg/ubuntu-lv` 148G ext4 `/`,已用 8.4G | 同 node4 | `ubuntu-lv` 108G `/` + `data-lv` 40G xfs `/data`(pigsty/docker 数据) |
| 未分配空间 / VG 空闲 | **0 / 0** | **0 / 0** | **0 / 0** |
| 顺序写(512M direct) | 1.0 GB/s | **109 MB/s** | 未测(生产负载) |
| fsync 延迟(4k dsync ×1000) | **0.2 ms**(20 MB/s) | **12.8 ms**(320 kB/s,两次复测一致) | 未测 |
| cgroup / swap | v2 / `/swap.img` 4G 启用 | 同 | v2 / 4G 启用且在用 |
| `CONFIG_NETKIT` / BBR / eBPF 模块 | 全部具备 | 同 | 同 |
| 防火墙 | ufw 服务 enabled 但规则 **inactive**;FORWARD ACCEPT | 同 | ufw **active**(放行 10/8、172.16/12、192.168/16、22/80/443);docker 把 FORWARD 置 **DROP** |
| 关键端口 6443/2379/2380/10250/4240/9962/30021 | 全部空闲 | 全部空闲 | 2379/2380 被 pigsty etcd 占用;80/443 nginx;5433-5438 haproxy;6432 pgbouncer;8428/9428/10428 victoria 全家桶 |
| 已有容器运行时 | 无 | 无 | docker-ce 29.7.2 + containerd.io **2.3.4**(与安装器目标版本相同),`disabled_plugins=["cri"]`,live-restore **未开** |
| tuned | 无 | 无 | `oltp` profile 活动(pigsty 装的),会覆盖安装器的 sysctl |
| DNS | 10.10.21.219 / .222(机房) | 同 | 额外还指向不可达的 `10.10.21.172`(pigsty dnsmasq) |
| 出口 | 公网出口 `211.144.221.226`;MTU 1500 全程无分片 | 同 | 同 |

### 2.1 外网通道(三台一致,除特别注明)

| 通道 | 结果 | 对安装器的影响 |
|---|---|---|
| `github.com/*/releases/download` | 9 次仅 1 次成功(node4 一次 200,其余超时) | 30 阶段下载 runc/containerd/crictl/cilium-cli/helm 会反复失败 |
| `https://ghfast.top/https://github.com/...` | 三台均 200,0.7~2s | 设 `GITHUB_PROXY="https://ghfast.top"` 即可 |
| `api.github.com`、`dl.k8s.io`、`pkgs.k8s.io`(含 Release.key) | 通 | 版本解析、apt 仓库正常 |
| `registry.aliyuncs.com/google_containers` | 通,<0.1s | `K8S_IMAGE_REPO` 保持阿里云 |
| `quay.io`(cilium 镜像) | 通,1.5~2.4s;`quay.m.daocloud.io` 通 | 可直拉;`files/certs.d/quay.io` 已配 nju 镜像 |
| `registry-1.docker.io` 直连 | **全部超时** | 必须依赖 `files/certs.d/docker.io` 的国内镜像,实测 `docker.1ms.run`、`docker.m.daocloud.io`、`docker.xuanyuan.me` 均通 |
| `ghcr.io`、`registry.k8s.io`、`helm.cilium.io`、`openebs.github.io` | 通 | 正常 |
| apt 源 | node4/5 用 `archive.ubuntu.com`(3.4s);node3 已换腾讯云源 | 建议 node4/5 先换 `mirrors.cloud.tencent.com`(实测 0.1s),安装器不管理 apt 源 |
| `PROXY_URL=http://192.168.3.220:7890` | 不可达(内网地址) | 脚本自身会探活后降级直连;但 `CONTAINERD_USE_PROXY=true` 写的是**常驻** drop-in,不探活 |

### 2.2 同网段占用(决定 LB 地址池能否用)

从 node4/node5 各做一次 ping+ARP 扫描:`10.10.21.0/24` 有 **82 个在用地址**,MAC 前缀既有 VMware
(`00:50:56`)也有 Dell(`18:66:da`)、Supermicro(`ac:1f:6b`)等物理机,`.165/.166/.167` 都是别人的。
这是机房多租户共享 VLAN,不是自家局域网。当前无 ARP 应答的 `.160/.164/.168/.169/.176-.179`
随时可能被机房分配给他人，不能作为地址所有权依据；Cilium L2 通告一旦撞地址会同时影响对方和我们。

### 2.3 Cilium 机房网络实测（2026-09-04）

| 检查 | 结果 | 结论 |
|---|---|---|
| node4 构造源 `10.244.99.99` 的 UDP 包 → node5，node5 `tcpdump` | 3/3 收到 | vSwitch 未做 SpoofGuard/源 IP 过滤，native routing 可携带 Pod CIDR 源地址 |
| node4 → node5 `ping -R`（IPv4 Record-Route option） | 完整记录 `.161 → .162 → .162 → .161` | VMware/NSX 不丢 IP option，`hybrid + dsrDispatch=opt` 具备条件 |
| `ens160` / MTU / 内核 | vmxnet3 / 1500 / kernel 7.0、`CONFIG_NETKIT=y` | `devices=ens160`、netkit/BBR auto 都会启用；BIG TCP 仍关 |
| `10.10.31.240/.245/.249` 路由与探测 | 走 `.254` 默认网关，无响应、无 ARP（2026-09-04 单次、单点观测） | 与 LAN/Pod/Service 均不重叠，可作为只供 eBPF Service/newt 的集群内 VIP 段候选；「无响应」不是未占用/已分配的证明，仍需机房确认 `10.10.31.0/24` 不会路由到本 VLAN（`bootstrap/CILIUM.md` §8.1） |

这组实测同时暴露安全边界：共享 VLAN 允许任意源 IP，跨节点 Pod 流量当前未加密。先复原基线，
承载生产敏感数据前评估 `CILIUM_ENABLE_IPSEC=true`（安装器已支持）或补 WireGuard 选项。

## 3. 安装器逐阶段适配结论

| 阶段 | 在机房节点上的行为 | 判定 |
|---|---|---|
| 00-preflight | Ubuntu 26.04 / 内核 7.0 / cgroup v2 / bash 5.3 全部通过；CIDR 不重叠；已新增固定 Gateway VIP 格式、不得与 default-pool/节点 IP 重叠的校验 | 可用 |
| 10-system-base | `config.hosting.env` 已给 node4/SAN/hosts/机房网关与 DNS；`CONFIGURE_STATIC_IP=false` 保留云镜像 netplan | 可用；node3 重装时先确保 `10.10.21.163/24` 与 SSH 可达 |
| 20-kernel-tuning | node4/5 正常；node3 重装后无 Pigsty tuned 冲突。`vm.max_map_count` 从系统默认 1048576 降到 262144 的问题仍待改为 max(当前,目标) | 可用，有改进项 |
| 30-download | 依赖 GitHub;需 `GITHUB_PROXY`。`--pack-offline` 不能用本地 arm64 机器打包给 amd64 用 | 改配置 |
| 40-container-runtime | node4/5 全新安装；node3 重装后同样是全新安装，不再接管 Pigsty/Docker 的 containerd | 可用 |
| 45-etcd-disk | `ETCD_DEDICATED_DISK=/dev/sdb` → `die "不是块设备"` | **阻塞**,改配置 |
| 50-kubernetes | node4 端口全空闲;`K8S_MINOR=1.36` 钉版,`dl.k8s.io stable` 当前已是 v1.37.0(只影响 lock 记录,不影响安装) | 可用 |
| 60-cilium | `devices=ens160`、native 路由、netkit/BBR、hybrid DSR 均经 §2.3 实测具备条件；L2/LB-IPAM 开启，Gateway 专属 `.240/32`、其它 LB `.241-.249`；operator 首装 1，三节点后改 2 | 可用，仍需 `cilium connectivity test` 最终验收 |
| 70-storage | 原内网值会因盘尾 0G 失败；`config.hosting.env` 已改为每节点 60G 回环 VG | 可用；交互确认一次，node5 的慢盘不放 fsync 密集负载 |
| 80-components | node3 重装后观测存储回集群内 VM/VL/VT；vmalert/Alertmanager/桥/gatus/healthchecks/bugsink 已有统一组件脚本，CNPG/OpenFGA 保持启用 | 可用 |
| 90-verify | LB 冒烟恢复开启（VIP 分配+BPF Service+L2 Lease）；OTel 冒烟真打一条 metric/log/span 并从 VM/VL/VT 查回 | 可用 |
| `--worker` 流程 | node5、重装后的 node3 都用 `start.sh --worker`；节点名取 hostname，50 阶段粘贴 node4 生成的 join 命令 | 可用 |

## 4. 最终拓扑

```
node4  10.10.21.161  control-plane + 工作负载(SINGLE_NODE=true 去污点)   ← fsync 0.2ms，etcd 与优先状态负载放这里
node5  10.10.21.162  worker                                             ← fsync 12.8ms，不主动调度 PG/NATS 等写同步负载
node3  10.10.21.163  重装后的 worker                                    ← Pigsty/Docker 全部退役，加入统一 k8s 资源池

Cilium LB-IPAM:       gateway-pool=10.10.31.240/32；default-pool=10.10.31.241-249
default/cilium-gateway: 10.10.31.240:80/443（spec.addresses 固定，不会被其它 LB 抢走）
公网: Pangolin/Traefik → newt Pod → 10.10.31.240:443 → HTTPRoute → Service/Pod
节点直通: Pangolin/Traefik → newt Pod → 10.10.21.161|162|163:<显式开放的端口>
```

PostgreSQL 回到 CNPG，`ADDON_CNPG=true`、`PG_CREATE_MAIN_CLUSTER=true`；OpenFGA 继续依赖 `pg-main`
独立库。VM/VL/VT、Kafka、ES 等组件由调度器放到合适节点，不绑定 node3；只有数据库/持久化负载需按
node5 慢盘事实加节点亲和或调度约束。

**dev/生产混用**：三节点、单控制面，可以按命名空间划分 dev/prod，但 node4 仍是控制面单点。
生产前至少补 etcd 快照、CNPG Barman Cloud 异地备份和恢复演练；Pigsty 最近全备只用于这次迁移，
不构成新集群的持续备份方案。

## 5. `config.env` 需要改的键(机房版)

安装器只读 `bootstrap/config.env`,没有多环境机制(见 §6.1)。以下是机房版必须与内网版不同的键:

```bash
# ---- 节点 ----
NODE_NAME="node4"                                  # worker 走 --worker 时自动取 hostname
API_CERT_SANS=(10.10.21.161 10.10.21.162 10.10.21.163 node4 node5 node3
               127.0.0.1 localhost 211.144.221.229)  # 后三项给 ssh -L 隧道 / 机房端口映射 kubectl 用
EXTRA_HOSTS=("10.10.21.161 node4" "10.10.21.162 node5" "10.10.21.163 node3")
RUN_FULL_UPGRADE="true"                            # node4/5 可以;node3 若入集群必须 false

# ---- 网络(沿用 netplan 静态地址,不改) ----
CONFIGURE_STATIC_IP="false"
NET_ADDRESS="10.10.21.161/24"; NET_GATEWAY="10.10.21.254"; NET_DNS=(10.10.21.219 10.10.21.222)

# ---- 代理与下载 ----
PROXY_URL=""                                       # 内网代理在机房不可达
WRITE_PROXY_ALIASES="false"
CONTAINERD_USE_PROXY="false"                       # 否则常驻 drop-in 指向不通的代理,镜像全拉不动
PREPULL_VIA_PROXY="false"
GITHUB_PROXY="https://ghfast.top"                  # 三台实测 200
K8S_IMAGE_REPO="registry.aliyuncs.com/google_containers"   # 不变
CONTAINERD_CERTS_SRC="files/certs.d"               # 不变,docker.io 只能靠它

# ---- Cilium（Gateway 依赖 LB-IPAM 地址；L2 必须开）----
CILIUM_ENABLE_L2_ANNOUNCEMENTS="true"
CILIUM_GATEWAY_LB_IP="10.10.31.240"               # gateway-pool 独占 /32；Pangolin/newt target 不漂移
CILIUM_LB_POOL_START="10.10.31.241"; CILIUM_LB_POOL_STOP="10.10.31.249"  # 其它 LB
CILIUM_OPERATOR_REPLICAS="1"                       # 首装只有 node4；node5/node3 加入后改 2
CILIUM_LB_MODE="hybrid"                            # IP option 已在 node4↔node5 实测可穿过
CILIUM_LB_ACCELERATION="disabled"                  # vmxnet3 保持保守值

# ---- etcd 盘 ----
ETCD_DEDICATED_DISK=""                             # 没有第二块盘;拿到盘后填 /dev/sdb
ETCD_DISK_WIPE_OK="false"                          # 机房环境不要预授权擦盘
ETCD_PARTITION_OF=""

# ---- OpenEBS 存储:机房不能加盘,只能回环文件(安装器已带开机重挂 unit) ----
LVM_DISKS=(); LVM_PARTITION_OF=""; LVM_WIPE_OK="false"
LVM_ALLOW_LOOPBACK="true"
LVM_LOOPBACK_SIZE="60G"                            # 稀疏文件,按需占用;裁剪后 PVC 申明约 16Gi,留余量
LVM_LOOPBACK_FILE="/var/openebs/openebs-lvm.img"   # 落在根 ext4,node4/5 根盘各余 131G

# ---- 组件（node3 重装后全部回集群）----
ADDON_VM="true"; ADDON_VICTORIA_LOGS="true"; ADDON_VICTORIA_TRACES="true"
ADDON_VECTOR="true"; ADDON_GRAFANA="true"; ADDON_VMALERT="true"; ADDON_ALERTMANAGER="true"
ADDON_ALERT_BRIDGE="true"; ADDON_GATUS="true"; ADDON_HEALTHCHECKS="true"; ADDON_BUGSINK="true"
ADDON_LOKI="false"; ADDON_JAEGER="false"; ADDON_FLUENT_BIT="false"   # VL/VT/Vector 取代旧三件套
ADDON_CNPG="true"; PG_CREATE_MAIN_CLUSTER="true"; ADDON_OPENFGA="true"
VERIFY_LB_SMOKE_TEST="true"
```

这些键已落成完整的 `bootstrap/config.hosting.env`。node4 首装与 node5/node3 worker 安装都在 70 阶段
确认一次回环文件；三节点加入后把 operator 副本改 2，重跑 60 阶段与 90 验收。LB 冒烟会验证
`10.10.31.x` 的分配、BPF Service 编程与 L2 Lease；newt Pod 再实测固定 Gateway VIP:443。

回环方案的代价:xfs 卷 → loop → 根 ext4 两层文件系统,fsync 路径变长;node5 本身 fsync 已 12.8ms,
NATS JetStream / Meilisearch 这类写盘组件优先调度到 node4(nodeSelector,不在安装器范围)。

## 6. 建议改代码的点(都是小改动;2026-09-03 拍板:先不落实)

### 6.1 多环境配置

`lib/common.sh:28` 写死 `source "$K8S_BASE_DIR/config.env"`。同一仓库要同时维护内网与机房两套值,
建议支持 `K8S_CONFIG_ENV` 环境变量或自动叠加 `config.local.env`,避免用 git 分支或手改来回切。
组件层的 `REMOTE_*_URL` 也建议从 `component.env` 提升到 `config.env`。

### 6.2 LB IP 池、L2 与固定 Gateway VIP（已修正）

`apply_l2_policy` 当前把 IPPool 与 L2Policy 绑定在同一个开关；本架构正好两者都需要，因此机房版保持
`CILIUM_ENABLE_L2_ANNOUNCEMENTS=true`。关闭它会导致 Gateway 的 LoadBalancer Service 无地址、
`Programmed=False`，不能作为默认配置。

已新增 `CILIUM_GATEWAY_LB_IP`：Gateway `spec.addresses` 固定该值，并创建只匹配
`default/cilium-gateway-cilium-gateway` 的专属 `/32` pool；default-pool 从下一枚 IP 开始。
preflight 拒绝两池重叠和节点 IP 冲突，消除 Consul/独立 Gateway 并行安装时抢走固定 VIP 的竞态。
Pool 有两种合法模式，不应强制和 `NODE_IP` 同网段：

- 专属同网段 VIP：L2 ARP 真正对 LAN 可达，必须由机房明确分配；
- 跨网段集群内 VIP：当前 Gateway `.240/32` + 其它 LB `.241-.249`，Pod/newt 走 eBPF Service，
  普通 LAN 主机不直达，避免共享 VLAN 地址冲突。

若未来需要「有池但完全不创建 L2Policy」，再拆 `CILIUM_LB_POOL_ENABLED`；当前不构成阻塞。

### 6.3 40 阶段对已有 docker 的接管保护

`assess_existing_runtime` 只比对版本,不检查 `docker.service` 是否在跑。建议:检测到 docker 活动时,
默认拒绝覆盖 containerd 配置与 unit,给出 `confirm_danger`,并提示先开 `live-restore`。

### 6.4 防火墙与 tuned 感知

安装器不管理 ufw、不检测 tuned。机房共享 VLAN 上 apiserver 6443、kubelet 10250、Cilium 指标 9962、
Hubble 4244、NodePort 全部对 82 台邻居可见。建议 preflight 至少提示 ufw/tuned 状态,
后续加一个可选的"只放行集群节点与 SSH"的 ufw 步骤(或启用 Cilium host firewall)。

### 6.5 其他

- `20-kernel-tuning.sh` 的 `vm.max_map_count` 取 `max(当前值, 262144)`,不要降级。
- `50-kubernetes.sh:411` 的交互默认值 `192.168.3.201:6443` 换成从 `API_CERT_SANS[0]` 推导。
- 共享 VLAN 上节点间 Pod 流量明文,Cilium 支持 `encryption.type: wireguard`,成本很低,可加开关。
- `70-storage.sh:setup_loopback` 的 `losetup` 未加 `--direct-io=on`,回环卷会经过两层页缓存;顺手补上。
- OpenFGA 继续使用 CNPG `pg-main` 独立库，无需外部 PG 改造。
- 单盘机器的长期方案:OpenEBS LocalPV **hostpath** 引擎(直接用根文件系统目录,无回环层),需要安装器加引擎开关与第二个 StorageClass。

## 7. 资源预算

**内存**（node4+node5+node3 = 约 22.3G）：

| 项目 | 估算 |
|---|---|
| OS + kubelet + containerd（×3） | ~2.1G |
| Cilium agent/envoy（×3）+ operator（×2） | ~2.3G（按 requests，实际会波动） |
| 控制面(apiserver/etcd/KCM/scheduler/coredns) | ~1.2G |
| OpenEBS | ~0.3G |
| `config.hosting.env` 启用的 31 个组件 `EST_MEM_MI` 合计 | **6588Mi**（不含 pg-main 实例本体） |
| pg-main | 1Gi limit（现清单单实例；生产 HA 另算） |
| 粗略剩余给 ecommerce 业务与文件缓存 | ~8.8G；不是调度保证，最终看 requests 与 `kubectl top` |

**存储**：已声明的主要 PVC 约 56Gi（VM 8 + VL 5 + VT 5 + Grafana 5 + Meili 10 + Consul 3 +
NATS 2 + OpenBao 1 + pg-main 10 + gatus 1 + healthchecks 1 + bugsink 5 + Alertmanager 0.2）。
三节点各建 60G 回环 VG，总逻辑容量 180G；LocalPV 不能跨节点，PVC 仍受所在节点单个 60G VG 限制。
稀疏文件按实际写入占根盘空间，必须对根文件系统与 VG 同时设告警。

## 8. node3 重装前的历史发现（已收割；重装后不再适用）

1. **pigsty 配置的地址是 `10.10.21.172`,机器实际是 `.163`,PostgreSQL 因此没有运行**。`pigsty.yml` 里 `admin_ip`、
   pg/etcd/kafka/minio/redis 全部是 `.172`;`/etc/patroni/patroni.yml` 的 `etcd3.hosts`、`restapi.listen`、
   `postgresql.connect_address` 也都是 `.172`。`net.ipv4.ip_nonlocal_bind=1` 让 etcd/dnsmasq/kafka(9093) 仍能绑在 `.172`,
   但从本机和 LAN 都连不上(`.172` 无 ARP 应答,`10.10.21.172:2379` 本机 CLOSED)。实测(2026-09-03 19:31):
   - `patronictl list` 持续报 `HTTPSConnection(host='10.10.21.172', port=2379) ... No route to host`;
   - `ss` 无 5432 监听,`pgrep postgres` 为空,`psql` 报 socket 不存在——patroni 进程是 active 的,但拿不到 DCS 锁,不会拉起 PostgreSQL;
   - haproxy 5433/5434 和 pgbouncer 6432 端口仍开着,但后端没有数据库,应用连上去会失败。

   `/pg/data` 与 `/data/postgres/pg-meta-18`(552M)数据仍在。全网段扫描显示 `.172` 当前无人使用,
   node3 的 netplan 同时写了 `dhcp4: yes` 和静态 `.163`,`.172` 很可能是早先的 DHCP 租约地址——
   直接 `ip addr add 10.10.21.172/24` 有被机房 DHCP 再分配给他人的冲突风险,需先向机房确认该地址归属。
   根治是按 pigsty 流程把节点地址改为 `.163`(pigsty 不支持在线改 IP,通常是 dump 数据后重装),
   这是"应用层用 pigsty PG"的前置条件,不在本安装器范围内。
2. **ES 只监听 `127.0.0.1:9200`,Kafka 监听 `.172:9093`**:集群内 Pod 要用它们,需要改 docker 端口映射到 `0.0.0.0`
   并让 Kafka advertise `.163`。ufw 已放行 `10.0.0.0/8`,Pod 出口经 Cilium masquerade 为节点 IP,能过防火墙。
3. **node3 的 DNS 列表含不可达的 `.172`**,若 node3 入集群,调度到 node3 的 Pod 解析会变慢。
4. **docker 无 live-restore**,`unattended-upgrades`(安装器会开)或 `apt full-upgrade` 升级 docker-ce 都会重启全部容器。
5. **tuned `oltp`** 与安装器 sysctl 冲突的键:`net.core.somaxconn 65535/4096`、`nf_conntrack_max 524288/500000`、
   `vm.overcommit_memory 0/1`、`kernel.pid_max 131072/4194304`、`ip_local_port_range 10000-64999/1024-65535`。

## 9. 建议执行顺序(仅计划,未执行)

1. node3 数据/配置收割完成后重装为 `10.10.21.163/24`；公网上的 `44163` 已实测映射到 node3 **22/tcp**，默认 sshd 即可。
2. node4/node5/node3 换腾讯云 apt 源、统一内核；每台复制 `config.hosting.env → config.env`。
3. node4 跑控制面全流程，70 阶段选择 60G 回环；获取 join 命令。
4. node5、node3 跑 `start.sh --worker`，各自准备同名回环 VG 并加入。
5. operator 副本从 1 改 2，重跑 60；执行 `cilium connectivity test` 与 90 验收。
6. 确认 `Gateway/cilium-gateway ADDRESS=10.10.31.240 PROGRAMMED=True`；从 newt Pod 访问该 VIP:443。
7. Pangolin HTTP 资源 target 统一改 `https://10.10.31.240:443`；节点服务按需 target `.161/.162/.163:<port>`。
8. 恢复 CNPG 数据、验证 VM/VL/VT/告警链，再由 ecommerce 仓重接 GitOps。详见 `RESTORE-RUNBOOK-2026-09-04.md`。
