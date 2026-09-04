# 机房三节点(node3/node4/node5)部署就绪评估 — 2026-09-03

只读体检结论。本次**没有**在远程节点执行任何写操作(仅 `ssh` 读取状态、`curl -I` 探测、
`ping` 扫描、node4/node5 上写入并删除一个临时测速文件)。

> **2026-09-03 晚间修订**:拍板 node3 **重装系统后作为第三个节点加入集群**,PostgreSQL 回到集群内 CNPG。
> 因此本文 §4/§5 里「应用层用 pigsty PG、`ADDON_CNPG=false`、`ADDON_OPENFGA=false`」的取舍作废:
> `ADDON_CNPG=true`、`ADDON_OPENFGA=true` 保持内网版原值;§8 关于 node3 的 pigsty/docker/tuned 冲突在重装后不再存在。
> Pigsty 的配置与经验已收割到 [`PIGSTY-HARVEST-2026-09-03.md`](PIGSTY-HARVEST-2026-09-03.md)。
> §5 的键已落成可直接使用的 `bootstrap/config.hosting.env`；复原顺序与 node3 重装前清单见 [`RESTORE-RUNBOOK-2026-09-04.md`](RESTORE-RUNBOOK-2026-09-04.md)。
> 其余结论(存储只能回环、L2 关闭、代理与 GitHub 通道、node4 做控制面、node5 盘慢)不变;
> 三节点时 `CILIUM_OPERATOR_REPLICAS` 首装仍取 1,三节点就绪后改回 2。

## 1. 结论

**安装器代码本身可以跑在这三台机器上(amd64 / Ubuntu 26.04.1 / 内核 7.0 与内网完全同代),
但 `config.env` 是为内网 PD 虚拟机写的,原样执行会在 45 阶段(etcd 盘)和 70 阶段(存储)直接失败;
如果照抄 `--yes`,还会把内网的 LB 地址池 `192.168.3.120-199` 通告到机房共享网段。**

必须先解决的四件事(按阻塞程度排序):

| # | 问题 | 现状 | 处理 |
|---|---|---|---|
| 1 | **没有可用磁盘** | 三台都是单盘 150G;9 月 3 日已 `growpart` + `lvextend -l +100%FREE` 把全部空间给了根 LV(`VFree=0`),盘尾无未分配空间;**机房不能加盘**;ext4 不能在线缩小 | 只剩安装器自带的回环文件兜底 `LVM_ALLOW_LOOPBACK=true`(无需改代码)。备注:若当时保留 VG 空闲空间,直接 `LVM_VG_NAME=ubuntu-vg` 就能让 OpenEBS 用系统 VG,以后重装系统时按此规划 |
| 2 | **LB 地址池 / L2 通告** | `10.10.21.0/24` 是机房共享 VLAN,扫描到 82 台在用主机(含其他租户物理机);我们只有 `.161/.162/.163` | 关闭 L2 通告,或向机房申请专用 VIP 后只把这几个地址放进池 |
| 3 | **代理与 GitHub** | `PROXY_URL=192.168.3.220:7890` 不可达;`CONTAINERD_USE_PROXY=true` 会让 containerd 常驻指向不通的代理,**除 `CONTAINERD_NO_PROXY_EXTRA`(TCR/GHCR)外的镜像全部拉不动**(quay、阿里云、docker 镜像站都走代理);`github.com` 直连三台各测 3 次,成功 1/9 | `PROXY_URL=""`、`CONTAINERD_USE_PROXY=false`、`GITHUB_PROXY="https://ghfast.top"`(实测三台均 200) |
| 4 | **node3 不适合入集群,且 pigsty PG 当前根本没在跑** | 已跑 pigsty(patroni/etcd/kafka/haproxy/nginx)+ docker(ES/CDC/…),内存已用 3.9G+swap 579M;pigsty 仍绑在已不存在的 `10.10.21.172`,**patroni 连不上 DCS,PostgreSQL 5432 未监听**(见 §8.1) | 第一阶段只用 node4+node5 建集群,node3 作为外部基础设施(PG/Kafka/ES/观测后端)被集群访问;**应用切到 pigsty PG 之前必须先修好 node3 的地址问题** |

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
这是机房多租户共享 VLAN,不是自家局域网。当前空闲的 `.160/.164/.168/.169` 随时可能被机房分配给他人,
Cilium L2 通告一旦撞地址会同时影响对方和我们。

## 3. 安装器逐阶段适配结论

| 阶段 | 在机房节点上的行为 | 判定 |
|---|---|---|
| 00-preflight | Ubuntu 26.04 / 内核 7.0 / cgroup v2 / bash 5.3 全部通过;CIDR 检查通过(`10.244/16`、`10.96/12` 与 `10.10.21/24` 不重叠);LB 池检查**不会**拦截 `192.168.3.x` 这种"不在本网段"的错误值 | 可用,但检查有盲区 |
| 10-system-base | `NODE_NAME` 需改为 `node4`;`EXTRA_HOSTS`/`API_CERT_SANS` 全是 192.168.3.x;`CONFIGURE_STATIC_IP=false` 正确(节点已是 netplan 静态地址);`RUN_FULL_UPGRADE=true` 在 node3 会升级 docker-ce → dockerd 重启 → 所有容器重启(无 live-restore) | 改配置 |
| 20-kernel-tuning | 正常。注意 `vm.max_map_count` 会从系统默认 1048576 **降到** 262144(仍满足 ES);node3 上 tuned `oltp` 会在重启后覆盖 `somaxconn/nf_conntrack_max/overcommit/pid_max` 等键,90 阶段校验将报不一致 | 可用;node3 需处理 tuned |
| 30-download | 依赖 GitHub;需 `GITHUB_PROXY`。`--pack-offline` 不能用本地 arm64 机器打包给 amd64 用 | 改配置 |
| 40-container-runtime | node4/5 全新安装。node3 会检测到 docker 的 containerd 2.3.4,判定"版本接近",随后**覆盖** `/etc/containerd/config.toml`(启用 CRI)、写 `/etc/systemd/system/containerd.service` 指向 `/usr/local/bin/containerd` 并至少重启 containerd 3 次;docker 容器通常能存活,但没有验证过 | node3 高风险 |
| 45-etcd-disk | `ETCD_DEDICATED_DISK=/dev/sdb` → `die "不是块设备"` | **阻塞**,改配置 |
| 50-kubernetes | node4 端口全空闲;`K8S_MINOR=1.36` 钉版,`dl.k8s.io stable` 当前已是 v1.37.0(只影响 lock 记录,不影响安装) | 可用 |
| 60-cilium | `devices` 自动取 `ens160` 正确;netkit/BBR 自动启用;`CILIUM_OPERATOR_REPLICAS=2` 在只有 node4 时有 1 个副本因跨节点反亲和 Pending,`cilium status --wait` 可能等满 12 分钟超时〔待验证〕;`hybrid/DSR` 用 IP option 传源地址,VMware 虚拟交换机/NSX 是否放行未验证 | 改配置 |
| 70-storage | `LVM_PARTITION_OF=/dev/sda` → 盘尾 0G → `die`;`LVM_DISKS=()` 无盘;当前 `LVM_ALLOW_LOOPBACK=false` | **阻塞**,改配置 |
| 80-components | 组件本身与架构无关(已 grep,无 arm64 硬编码);Harbor 在 amd64 反而可装。观测三条信号已参数化推 node3(`REMOTE_*_URL`),但写在 `components/opentelemetry*/component.env` 里,走的是公网 Pangolin 域名,机房内可直接改成 `http://10.10.21.163:8428/9428/10428`(node4/5 实测三端口均通) | 可用,建议裁剪 |
| 90-verify | `VERIFY_LB_SMOKE_TEST` 在 L2 关闭时自动跳过;OTel 冒烟只查集群内启用的后端 | 可用 |
| `--worker` 流程 | node5 用 `start.sh --worker --yes` + `JOIN_*` 环境变量,主机名已是 `node5` | 可用 |

## 4. 建议拓扑

```
node4  10.10.21.161  control-plane + 工作负载(SINGLE_NODE=true 去污点)   ← fsync 0.2ms,etcd 放这里
node5  10.10.21.162  worker                                             ← 盘慢(fsync 12.8ms),不放 PG/NATS 这类 fsync 密集负载
node3  10.10.21.163  不入集群;作为外部基础设施被 Pod 直连:
                       PG  haproxy 5433(主)/5434(从)、pgbouncer 6432   ← 端口通,但后端 PostgreSQL 当前未运行(§8.1)
                       VictoriaMetrics 8428 / VictoriaLogs 9428 / VictoriaTraces 10428 / Grafana 3000
                       Kafka 9093 与 ES 9200 当前分别绑在 .172 和 127.0.0.1,LAN 不可达(见 §8)
```

已拍板(2026-09-03):机房不能加盘;应用层用 node3 的 pigsty PG,不装 CNPG。由此:

- `ADDON_CNPG=false`、`PG_CREATE_MAIN_CLUSTER=false`。
- **openfga 必须一起关掉**:`components/openfga/component.env` 的 `DEPENDS_ON="postgres"`,编排器会自动补选 CNPG;
  它的 `install.sh` 直接 `apply manifests/cnpg-db.yaml` 并把连接串写死为 `pg-main-rw.postgresql.svc:5432`。
  改指向 pigsty 属于代码改动(§6),本次不做,先 `ADDON_OPENFGA=false`。
- ecommerce 侧连接串改为 `10.10.21.163:5433`(主)/`5434`(从)或 `6432`(pgbouncer),
  并确认 pigsty 的 `pg_hba` 放行 `10.10.21.161/162`(Pod 出口经 masquerade 为节点 IP)。PG 没起来,本次无法读 `pg_hba`,标记待确认。

node3 第二阶段再决定是否以 worker 身份加入(打 taint 只跑 DaemonSet),前提是 §8 的问题先处理。

**dev/生产混用**:两节点、单控制面,可以按命名空间划分 dev/prod,但 node4 是控制面单点,
且 `config.env` 第 5 条"重建须知"已写明当前不做 etcd/PG 备份、重建即丢数据。要放生产流量,
至少补 etcd 定期快照(defrag 定时器已有,快照没有),并确认 pigsty 的 pgbackrest 备份在 PG 修复后仍有效
(node3 上有 `pgbackrest_exporter` 和 `/data/backups`,内容未核对),这不在安装器范围内。

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

# ---- Cilium ----
CILIUM_ENABLE_L2_ANNOUNCEMENTS="false"             # 共享 VLAN;拿到机房专用 VIP 后再开并只放那几个地址
CILIUM_LB_POOL_START=""; CILIUM_LB_POOL_STOP=""    # L2 关闭时 preflight 不校验、60 阶段不建池;Gateway 拿不到地址(见 §6.2)
CILIUM_OPERATOR_REPLICAS="1"                       # 首装只有 node4;node5 加入后改 2,再 start.sh --only 60-cilium
CILIUM_LB_MODE="hybrid"                            # 若 NodePort 跨节点不通,退 snat(DSR 依赖 IP option)
CILIUM_LB_ACCELERATION="disabled"                  # vmxnet3 保持

# ---- etcd 盘 ----
ETCD_DEDICATED_DISK=""                             # 没有第二块盘;拿到盘后填 /dev/sdb
ETCD_DISK_WIPE_OK="false"                          # 机房环境不要预授权擦盘
ETCD_PARTITION_OF=""

# ---- OpenEBS 存储:机房不能加盘,只能回环文件(安装器已带开机重挂 unit) ----
LVM_DISKS=(); LVM_PARTITION_OF=""; LVM_WIPE_OK="false"
LVM_ALLOW_LOOPBACK="true"
LVM_LOOPBACK_SIZE="60G"                            # 稀疏文件,按需占用;裁剪后 PVC 申明约 16Gi,留余量
LVM_LOOPBACK_FILE="/var/openebs/openebs-lvm.img"   # 落在根 ext4,node4/5 根盘各余 131G

# ---- 组件裁剪(node3 已有同类服务,腾内存) ----
ADDON_VM="false"; ADDON_LOKI="false"; ADDON_JAEGER="false"; ADDON_GRAFANA="false"
ADDON_VICTORIA_LOGS="false"; ADDON_FLUENT_BIT="false"   # OTel/vector 已推 node3
ADDON_CNPG="false"; PG_CREATE_MAIN_CLUSTER="false"      # 已拍板用 pigsty PG
ADDON_OPENFGA="false"                                   # 硬依赖 CNPG pg-main,改指向属代码改动(§6)
VERIFY_LB_SMOKE_TEST="false"
```

改完这些键后,node4 上 `sudo bash start.sh` 只会在 70 阶段停一次,回答"用回环文件兜底";
有终端时 `--yes` 也不豁免这一步,真正无终端(nohup/systemd)才按 `LVM_ALLOW_LOOPBACK=true` 静默建回环 VG。
node5 跑 `--worker --yes` 时 70 阶段同样弹这一次确认。其余键(版本、sysctl、kured 窗口、NTP 池、组件存储大小)可以沿用。

回环方案的代价:xfs 卷 → loop → 根 ext4 两层文件系统,fsync 路径变长;node5 本身 fsync 已 12.8ms,
NATS JetStream / Meilisearch 这类写盘组件优先调度到 node4(nodeSelector,不在安装器范围)。

## 6. 建议改代码的点(都是小改动;2026-09-03 拍板:先不落实)

### 6.1 多环境配置

`lib/common.sh:28` 写死 `source "$K8S_BASE_DIR/config.env"`。同一仓库要同时维护内网与机房两套值,
建议支持 `K8S_CONFIG_ENV` 环境变量或自动叠加 `config.local.env`,避免用 git 分支或手改来回切。
组件层的 `REMOTE_*_URL` 也建议从 `component.env` 提升到 `config.env`。

### 6.2 LB IP 池与 L2 通告解耦

`60-cilium.sh:apply_l2_policy` 把 `CiliumLoadBalancerIPPool` 和 `CiliumL2AnnouncementPolicy` 绑在
`CILIUM_ENABLE_L2_ANNOUNCEMENTS` 一个开关下;`00-preflight.sh:check_config` 只在开关为 true 时校验池地址。
机房场景需要"有池、不通告"(Gateway 才能拿到地址并 `Programmed`,`gateway/install.sh` 目前只告警不阻断〔待验证〕),
或者"不通告也要 Gateway 能用"。建议拆成 `CILIUM_LB_POOL_ENABLED` 与 `CILIUM_ENABLE_L2_ANNOUNCEMENTS` 两个键。
另外 preflight 应校验池地址与 `NODE_IP` **同网段**,而不只是"不包含节点 IP"。

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
- `components/openfga/install.sh` 连接串写死 CNPG,需要改成可配置的外部 PG(pigsty)才能在机房启用。
- 单盘机器的长期方案:OpenEBS LocalPV **hostpath** 引擎(直接用根文件系统目录,无回环层),需要安装器加引擎开关与第二个 StorageClass。

## 7. 资源预算

**内存**(node4+node5 = 14.8G):

| 项目 | 估算 |
|---|---|
| OS + kubelet + containerd(×2) | ~1.4G |
| Cilium agent/envoy/operator(×2) | ~1.4G |
| 控制面(apiserver/etcd/KCM/scheduler/coredns) | ~1.2G |
| OpenEBS | ~0.2G |
| 当前 `config.env` 启用的 28 个组件 `EST_MEM_MI` 合计 | **6.8G**(不含 pg-main 实例本体) |
| 按 §5 裁掉 VM/Loki/Jaeger/Grafana/VictoriaLogs/fluent-bit/CNPG/openfga 后(20 个组件) | **~4.2G** |
| 剩余给 ecommerce 业务 Pod | 裁剪前 ~3.8G,裁剪后 ~6.4G |

**存储**(启用组件 PVC 申明合计):VM 8 + Grafana 5 + Loki 10 + Jaeger 5 + Meili 10 + Consul 3 +
NATS 2 + OpenBao 1 + pg-main 10 + VictoriaLogs 5 = **59Gi**;裁剪后 Meili 10 + Consul 3 + NATS 2 + OpenBao 1 = **16Gi**
(未申明大小的组件不计)。LVM LocalPV 卷绑定在 Pod 所在节点,两台各建 60G 回环 VG;根盘 131G 可用,
稀疏文件按实际写入占用,仍有充足空间给镜像/日志。

## 8. node3 的附带发现(与 k8s 无直接关系,但影响"混合环境"设想)

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

1. 向机房确认:能否预留 2~4 个 `10.10.21.x` 作为 VIP;`10.10.21.172` 是否归我们(决定 node3 修复方式);
   node5 能否换到与 node4 相同的存储(fsync 慢 60 倍)。加盘已确认不可行。
2. **node3:修好 pigsty 的地址问题,让 PostgreSQL 起来**(§8.1)。这一步与建集群无关,但决定应用能不能切到 pigsty PG。
3. node4/node5:换 apt 源到腾讯云,`reboot` 一次进 7.0.0-30 内核(已装待重启)。
4. 按 §5 准备机房版 `config.env`(§6.1 暂不做,先直接改 `bootstrap/config.env` 的副本),`rsync` 整个仓库到 node4 `/root/kubernetes/`。
5. node4:`sudo bash start.sh`(交互模式;70 阶段回答"用回环文件兜底";不要用 `--yes` 首装)。
6. node4:`kubeadm token create --print-join-command`;node5:`export JOIN_*` 后 `sudo bash start.sh --worker --yes`。
7. node4:`CILIUM_OPERATOR_REPLICAS=2` 后 `sudo bash start.sh --only 60-cilium`;`--verify`。
8. 本机:`ssh -L 6443:10.10.21.161:6443 node4`,kubeconfig 的 server 改 `https://127.0.0.1:6443`(SAN 已含)。
9. ecommerce 连接串指向 `10.10.21.163:5433`,确认 pigsty `pg_hba` 放行 `10.10.21.161/162`。
10. node3 是否入集群,等 §8 第 1、2、4 条处理后再评估。
