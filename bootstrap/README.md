# K8s 高性能单机集群安装器

面向 Ubuntu 的单控制面 Kubernetes 安装器：containerd 运行时、Cilium eBPF 数据面（**完全移除并替代 kube-proxy**）、OpenEBS LVM 本地存储，并针对数据库/缓存/搜索/MQ 等基础设施负载做了内核与网络调优。

```
kubernetes/bootstrap/
├── start.sh                    # 编排入口(阶段调度/后台并行下载/断点续跑)
├── start.sh.orig               # 重构前的原始脚本备份
├── config.env                  # 唯一配置入口(节点/网段/版本/开关全部在此)
├── lib/common.sh               # 公共库(日志/状态/确认/下载/校验)
├── scripts/
│   ├── 00-preflight.sh         # 预检: OS/内核/cgroup v2/CIDR 冲突; 低内核引导 HWE
│   ├── 10-system-base.sh       # apt/时区/chrony/hosts/可选静态IP/可选 sshd
│   ├── 20-kernel-tuning.sh     # swap/模块/sysctl(eBPF+BBR)/limits/THP/GRUB/IO调度
│   ├── 30-download.sh          # 工件并行下载(版本锁定+sha256, 预检后自动转后台)
│   ├── 40-container-runtime.sh # runc/containerd/crictl + 镜像加速(certs.d)
│   ├── 45-etcd-disk.sh         # etcd 专用磁盘(可选; 支持已运行集群在线迁移)
│   ├── 50-kubernetes.sh        # apt 仓库/kubeadm init(skip kube-proxy)/defrag 定时器
│   ├── 60-cilium.sh            # Cilium(KPR/native路由/BBR/netkit/Hubble/GatewayAPI/L2)
│   ├── 70-storage.sh           # LVM 卷组(交互选盘)+OpenEBS+StorageClass
│   ├── 80-components.sh        # 组件编排器(扫描 ../components/*/component.env,
│   │                           #   拓扑排序后并行调用各 install.sh; 不含任何 values)
│   └── 90-verify.sh            # 全局验收+冒烟测试+报告
└── files/                      # 运行时生成: kubeadm.yml / cilium-values.yaml / 示例
```

## 快速开始

### 控制平面
```bash
cd /root/kubernetes/bootstrap
# 1. 按环境修改配置(至少确认 NODE_NAME/NODE_IP/网段/代理)
vim config.env

# 2. 交互式安装(可选项和危险项会逐一询问)
sudo bash start.sh

# 3. 或全自动: 除"磁盘类决策"外全部按 config.env 静默执行。
#    磁盘项(etcd 盘/存储盘)填 ask/留空时, 只要有终端仍会弹菜单——
#    先输出 lsblk 磁盘总览, 再按编号选择(整盘/空分区/尾部未分配空间划分区)+确认词;
#    真正无终端(systemd/cron)才回退显式配置(盘符 + 对应 WIPE_OK=true), 否则跳过/兜底
sudo bash start.sh --yes
```
重新生成token
```bash
kubeadm token create --print-join-command
```

### 工作负载
自动跳过 etcd 盘/Cilium 安装/helm/全部组件/重型验收

机器跑到"配置静态 IP?"询问时务必选 N

交互式询问
```bash
# 工作负载节点上
cd /root/kubernetes/bootstrap

sudo bash start.sh --worker
```

非交互(需先填 JOIN_*)
```bash
export JOIN_ENDPOINT="192.168.3.202:6443"                 # join 后面那段 = apiserver 地址:端口               # join 后面那段 = apiserver 地址:端口
export JOIN_TOKEN="abcdef.0123456789abcdef"               # --token 后面那段(24 小时有效)               # --token 后面那段(24 小时有效)
export JOIN_CA_CERT_HASH="sha256:95342ee3e7df85aeb85cb40e83737c6add1e50024dd803b5411e5fed8b4f7c41"               # --discovery-token-ca-cert-hash 后面整段, 含 sha256: 前缀

cd /root/kubernetes/bootstrap
bash start.sh --worker --yes
```

常用命令：

| 命令 | 说明 |
|---|---|
| `sudo bash start.sh --list` | 查看阶段与已完成步骤数 |
| `sudo bash start.sh --from 60-cilium` | 从指定阶段开始 |
| `sudo bash start.sh --only 90-verify` / `--verify` | 只跑某阶段/验收 |
| `sudo bash start.sh --reset-state 80-components` | 清某阶段状态(如重新选组件) |
| `sudo bash start.sh --reset-cluster` | kubeadm reset 重置集群(保留系统调优/缓存) |
| `sudo bash start.sh --pack-offline x.tgz` | 打离线包(工件+versions.lock+核心 chart) |
| `sudo bash start.sh --unpack-offline x.tgz` | 目标机展开离线包后正常安装 |

## 节点角色（NODE_ROLE）

同一份目录同时支持控制面与工作节点，由 `config.env` 的 `NODE_ROLE` 分流：

| | control-plane（默认） | worker |
|---|---|---|
| 00/10/20 系统与内核调优 | ✔ | ✔（Cilium agent 会跑在本节点，内核要求相同） |
| 30 下载 | 全部工件 | 仅 runc/containerd/crictl（不下 cilium-cli/helm/GatewayAPI） |
| 40 容器运行时 | ✔ | ✔ |
| 45 etcd 专用盘 | 可选 | 跳过 |
| 50 Kubernetes | kubeadm **init** + defrag 定时器 + kubectl 别名 | kubeadm **join**（仅查 10250 端口） |
| 60 Cilium | helm 安装 | 跳过（agent 由控制面 DaemonSet 自动调度过来） |
| 70 存储 | VG + OpenEBS + StorageClass | 仅可选建同名 VG（无盘可跳过，则本节点不供本地卷） |
| 80 组件 | 可选安装 | 跳过 |
| 90 验收 | 全量 + 冒烟测试 | 轻量（调优/运行时/加入状态/agent 到位软检） |

**加 worker 的流程**：
1. 控制面上：`kubeadm token create --print-join-command`（token 默认 24h 有效）；
2. 拷贝本目录到新机器，`config.env` 改：`NODE_ROLE="worker"`、`NODE_NAME`、`NET_ADDRESS`（JOIN_* 三项可留空）；
3. `sudo bash start.sh` —— 交互模式在 50 阶段直接**粘贴整条 join 命令**即可（自动解析并缓存）；非交互 `--yes` 则必须先填好 `JOIN_ENDPOINT/JOIN_TOKEN/JOIN_CA_CERT_HASH`；
4. 回到控制面 `kubectl get nodes -o wide` 确认 Ready。

token 过期重join：控制面重新生成命令，worker 上 `sudo bash start.sh --reset-state 50-kubernetes`（会连带清掉缓存的旧参数）后重跑。加入 worker 后若想恢复控制面隔离（撤销 SINGLE_NODE 的去污点）：`kubectl taint nodes <控制面节点> node-role.kubernetes.io/control-plane=:NoSchedule`。

## 核心机制

**断点续跑**：每个步骤完成后在 `/var/lib/k8s-installer/state/` 落盘标记；任何一步失败，修复后直接重跑 `start.sh`，已完成步骤自动跳过。下载缓存按 sha256 校验判断，不依赖状态标记。

**版本策略**：`config.env` 留空则解析 GitHub/dl.k8s.io 最新稳定版，结果写入 `/var/lib/k8s-installer/versions.lock` —— 之后每次执行版本恒定（可复现）。想升级：删除 versions.lock 重跑；想固定：在 config.env 显式指定。网络不可达时使用脚本内兜底版本（2026-08-15 快照）。

**重启处理**：安装过程本身不需要中途重启 —— THP/nmi_watchdog 运行时立即生效，GRUB 仅做持久化（结束后建议重启一次）。两个例外会明确提示"重启后重跑即续"：cgroup v1 → v2 切换（20.04 默认 v1）、HWE 内核升级（内核 < 5.10 时引导安装）。

**并行**：预检通过后 `30-download` 自动转入后台，与 10/20 系统配置并行；80 阶段的多个 helm 组件也并行安装。

**原文件保护**：修改非托管系统文件前备份到 `/var/lib/k8s-installer/backups/`（镜像目录结构，只备份一次）；自有配置一律走独立文件（`sysctl.d/`、`limits.d/`、`sshd_config.d/`、`grub.d/`、独立 netplan 文件），或用标记块管理（`/etc/hosts`、`.bashrc`），重复执行不追加、不漂移。

**危险操作**（擦盘、netplan、集群 reset）必须原样输入确认词，**`--yes` 不豁免磁盘类高危操作**：只要有终端，etcd 盘与存储盘的 ask/留空 都会弹出 lsblk 总览 + 编号菜单（整盘 / 空分区 / 尾部未分配空间划分区）+ 确认词；真正无终端（systemd/cron/nohup）时才回退显式配置（盘符 + 对应 `WIPE_OK=true`），否则安全跳过或兜底，绝不静默擦盘。

## 关键设计点

- **kube-proxy 零残留**：kubeadm `skipPhases: addon/kube-proxy` + Cilium `kubeProxyReplacement: "true"` + 兜底删除 DS/ConfigMap + 验收阶段检查 iptables 无 KUBE-SVC 链。
- **Cilium 按内核自动分级**：eBPF Host-Routing(≥5.10)、BBR 带宽管理(≥5.18)、BIG-TCP(≥6.3, 默认关)、**netkit(默认 auto：内核≥6.8 且 CONFIG_NETKIT 已编译时自动启用)**；native 路由 + eBPF masquerade 时启用 `installNoConntrackIptablesRules` 绕过 iptables conntrack。netkit 是 Guest 内核内部特性(替代 veth)，与宿主机/虚拟化平台无关；XDP 加速则依赖网卡驱动，虚拟机保持 disabled。
- **L7/流量控制**：内置 Envoy(L7Proxy) + Gateway API CRD + 带宽管理器(Pod annotation 限速) + maglev 一致性哈希；Hubble(+UI) 提供流量观测。
- **LoadBalancer 可用**：L2 通告 + `CiliumLoadBalancerIPPool`（`CILIUM_LB_POOL_START`/`STOP` 显式 IP 范围，预检拒绝覆盖节点 IP 的范围），局域网内直接访问 LoadBalancer 服务。
- **存储面向数据库**：xfs + WaitForFirstConsumer；宿主机侧 THP=never、IO 调度(none/mq-deadline)、`vm.dirty_*` 平滑刷盘、`fs.aio-max-nr`、`vm.max_map_count`(ES 硬性要求)、`vm.overcommit_memory=1`(Redis/PG fork)。
- **国内网络（四条独立通道）**：① `PROXY_URL` 按需代理——每次执行前 TCP 探活，代理没开自动降级直连，"要用就开、不用就关"无需改配置；只作用于脚本自身下载（GitHub 工件/helm 仓库/版本解析），从不污染 apt 与集群流量。② `GITHUB_PROXY` URL 前缀加速，是没有本地代理时的替代品，与 ① 二选一。③ containerd 拉镜像走 certs.d registry mirror——**支持原样导入你自己维护的完整 certs.d 目录**（`CONTAINERD_CERTS_SRC` 指定路径，或直接放到安装器 `files/certs.d/`，优先级高于 `USE_CN_MIRRORS` 自动生成的 DaoCloud 系）。④ `K8S_IMAGE_REPO` 独立指定 kubeadm 镜像仓库（如阿里云），与 mirror 通道解耦。另有 `PREPULL_VIA_PROXY=auto`：kubeadm init 前的预拉阶段若代理在线，临时给 containerd 挂代理、**拉完即撤**（中断残留会在重跑时自动清理），不留常驻代理配置。

## etcd 维护(45 阶段 + defrag 定时器)

- **专用磁盘**：`ETCD_DEDICATED_DISK=ask`（交互选盘）或直接指定 `/dev/sdX`。etcd 每次写入都要 fsync，单机上与数据库/日志共盘时业务 IO 峰值会直接放大 apiserver 尾延迟；10-20G 小盘即可。已运行的集群支持在线迁移（停 kubelet → 停 etcd 容器 → 搬数据 → 挂载 → 恢复，原数据保留在 `/var/lib/etcd.pre-migration`）。fstab 特意不加 `nofail`：盘缺失宁可停在启动阶段，也不能让 etcd 悄悄落回根盘。
- **defrag 定时器**：apiserver 每 5 分钟做逻辑 compaction，但物理空间只有 `etcdctl defrag` 才归还；长期不整理会顶到 2GB 配额触发 NOSPACE 只读告警。默认每周日 03:17（`ETCD_DEFRAG_CALENDAR`）通过 systemd timer 执行，日志见 `journalctl -u k8s-etcd-defrag.service`，单节点小库阻塞写入通常不到 1 秒。

### 虚拟盘扩容后的"未分配空间"利用（无整块空盘时）

PD/虚拟化层把系统盘扩大后（如 64G→300G），多出的空间是"未分配"状态，选盘逻辑不会碰有分区的盘。两个配置项可从**盘尾未分配空间划出新分区**（自动备份 GPT 分区表到 `backups/`、自动修复扩容后滞留的 GPT 备份头、需输入 `write-partition-table` 确认；恢复：`sgdisk --load-backup=<bak> <盘>`）：

```bash
ETCD_PARTITION_OF="/dev/sda"  ETCD_PARTITION_SIZE="16G"   # 45 阶段(仅控制面)
LVM_PARTITION_OF="/dev/sda"   LVM_PARTITION_SIZE="0"      # 70 阶段, 0=用尽剩余
```

**重要取舍**：同一块虚拟盘上的分区共享同一个 IO 队列与宿主侧文件，etcd 想要的 **IO 隔离在同盘分区上基本不存在**（只有文件系统级隔离——不共享日志、不互相挤爆空间）。业务数据（OpenEBS VG）用同盘分区完全合理；**etcd 优先加一块独立 10-20G 小虚拟盘**，`ETCD_PARTITION_OF` 只是没有加盘条件时的退而求其次。

## HTTPS 全链路(cert-manager + Gateway API)

1. 80 阶段勾选 cert-manager（默认开）→ 自动启用 `enableGatewayAPI`；
2. `kubectl apply -f files/examples/cert-manager-issuers.yaml` 建立局域网自签 CA（`lan-ca`），或按文件内注释启用 Let's Encrypt；
3. `files/examples/gateway-https.yaml`：在 Gateway 上加 `cert-manager.io/cluster-issuer` 注解即自动签发/续期证书，Cilium 内置 Envoy 终结 TLS；
4. 局域网客户端导入根 CA：`kubectl -n cert-manager get secret lan-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d`。

## 日志(Loki + 已有 fluent-bit)

Alloy/Promtail 只是"采集端"，你已有 fluent-bit 就**不需要**再装。80 阶段的 Loki 是"存储/查询后端"（单体模式 + LVM PVC + 7 天保留），fluent-bit 加一段 OUTPUT 即可（模板在 `files/examples/fluent-bit-loki-output.conf`），Grafana 数据源填 `http://loki.logging.svc.cluster.local:3100`。

## mitigations=off 取舍(config.env: MITIGATIONS_OFF, 默认关)

- 收益：关闭 Spectre/Meltdown 等 CPU 漏洞缓解，syscall/上下文切换密集负载（数据库、代理、高 PPS）在 x86 老平台可回收 5-15%。
- 代价：容器里任何不可信代码都可能借侧信道读取内核/其他容器内存——多租户或跑第三方镜像的集群不要开。
- **ARM64(Apple 芯片虚拟机)结论：不建议开**。Apple 核心对多数侧信道有硬件级处理，Linux 在 aarch64 上的缓解开销本就很小，收益接近于零，白白放弃安全边际。

## 回滚要点

| 对象 | 回滚方式 |
|---|---|
| 集群 | `start.sh --reset-cluster` |
| 静态 IP | 删除 `/etc/netplan/99-k8s-static.yaml` 后 `netplan apply` |
| sysctl/limits/sshd/GRUB | 删除对应 `99-k8s*` 托管文件 |
| 被修改的系统文件 | 从 `/var/lib/k8s-installer/backups/` 拷回 |
| LVM 卷组 | `vgremove openebs-vg`（会丢数据，自行确认） |
| etcd 专用盘 | 删 fstab 托管块 + 数据拷回根盘（迁移备份在 `/var/lib/etcd.pre-migration`） |
| defrag/自动更新 | `systemctl disable --now k8s-etcd-defrag.timer` / 删 `52-k8s-unattended.conf` |

## 离线安装

```bash
# 有网机器(同架构): 下载全部工件 + cilium/openebs chart, 打成 tar
sudo bash start.sh --pack-offline k8s-offline-arm64.tgz
# 目标机: 展开后正常安装(30 阶段校验秒过, chart 走本地包)
sudo bash start.sh --unpack-offline k8s-offline-arm64.tgz && sudo bash start.sh
```

包内含 GitHub 二进制工件、versions.lock、cilium/openebs chart；**容器镜像与 apt 仓库不在包内**（目标机仍需 registry mirror 与 apt 源可达；完全断网环境需另建私有 registry 与 apt 镜像）。

## 已知取舍

- 阶段日志(`/var/log/k8s-installer/*.log`)含 ANSI 颜色码，用 `less -R` 查看。
- 80 阶段各组件 chart 版本未锁定（取仓库最新），安装一次后由状态标记保证不重装；如需严格锁定请在对应 install 函数中加 `--version`。
- Helm 已随上游进入 v4 线；如个别第三方 chart 不兼容，在 config.env 固定 `HELM_VERSION="v3.19.x"` 并删 versions.lock 重跑 30/60 阶段即可。
- `bpf.datapathMode: netkit` 等前沿键名随 Cilium 版本演进，若 helm 安装报未知键，请对照所装版本官方 values 调整 `files/cilium-values.yaml`。
