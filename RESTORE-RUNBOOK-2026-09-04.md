# 三节点复原手册（node3 重装 → node4/node5/node3 重建集群）

回答两个问题：**本仓库的文档与脚本够不够把现有环境复原到机房三台机器**；**node3 重装前还有什么没带走**。
体检结论见 [`HOSTING-READINESS-2026-09-03.md`](HOSTING-READINESS-2026-09-03.md)，
Pigsty 收割见 [`PIGSTY-HARVEST-2026-09-03.md`](PIGSTY-HARVEST-2026-09-03.md)，
观测/告警接线见 [`OBSERVABILITY-INTEGRATION.md`](OBSERVABILITY-INTEGRATION.md)。本文只讲缺口与顺序。

## 0. 满足度矩阵

| 需求 | 状态 | 依据 / 缺口 |
|---|---|---|
| 裸机 → 三节点集群 | ✅ 可一键 | `bootstrap/start.sh` + **新增 `bootstrap/config.hosting.env`**（机房版完整配置，`cp` 覆盖 `config.env` 即用；差异全部标 `# 机房:`） |
| 集群 → 组件层 | ✅ | 80 阶段；观测/告警/运维保障 7 个新组件已入库（2026-09-03） |
| 存储 | ⚠️ 只能回环文件 | 三台根 LV 已吃满 VG、机房不能加盘；`LVM_ALLOW_LOOPBACK=true` 60G/台，70 阶段会弹一次确认 |
| LoadBalancer / 网关地址 | ✅ 集群内固定 VIP | L2 + LB-IPAM 开启；`gateway-pool=.240/32` 专属匹配共享 Gateway，`default-pool=.241-.249` 给其它 LB，避免并行安装抢 VIP。newt/Pangolin target 用 `.240:443`；机房给专属 `.21.x` 后可切成 LAN 直达池 |
| 数据库数据 | ✅ 已备份 | node3 PG 的 `ecommerce` / `bugsink` / `openfga` 三库逻辑备份 + 角色（§4）；PGDATA 冷拷贝与 pgbackrest 仓库作第二份保险 |
| 凭据延续 | ⚠️ 需人工 | 集群凭据在 node101 `/var/lib/k8s-installer/creds/`（node101 当前关机）；ntfy / newt / OTel token / Pigsty CA 已收割到 `raw/_secrets/`（§3） |
| node3 上非 Pigsty 的负载 | ⚠️ 需拍板 | LyraPass 三容器、ecommerce-gatus、host-watchdog、CDC(Debezium+ES)、Kafka、Silo（§5） |
| 应用层（ecommerce 服务 / ArgoCD） | 📎 不在本仓 | ecommerce 仓 TODO「集群重建后 GitOps 重新接线」；`config.env` 重建须知第 3 条 |
| 90 阶段验收 | ✅ | OTel 冒烟支持 VL/VT 查回；LB 冒烟机房版开启，验证 IPAM 分配、BPF Service 与 L2 Lease |

## 1. node3 重装前最终清单

### 1.1 已收割到本地 `archive/pigsty-node3-2026-09-03/raw/`（gitignore，含口令）

| 类别 | 内容 | 位置 |
|---|---|---|
| Pigsty 渲染配置 | patroni/PG 参数、HBA、pgbouncer、haproxy、pgbackrest、vector、pg_exporter、nginx、kafka/redis/etcd/silo、tuned、规则、仪表盘 | `raw/{etc,pg,data/infra,...}` |
| 用户自写运维层 | 4 个 `ecommerce-*.yml` 规则、告警桥、`pg-backup-healthchecked`、gatus/healthchecks/bugsink compose、otelcol | 已迁入 `components/`（2026-09-03） |
| **本次新发现** | `host-watchdog`（脚本 + timer + `watchdog.env`）、**第二个 gatus `/opt/ecommerce-gatus`**（黑盒探测，告警直打 Alertmanager API）、6 个 systemd `memory.conf`（观测栈内存上限实测值）、`pigsty-kafka-provision/health`（上游脚本）、sshd 配置（`Port 22` + `Port 5837`）、netplan、apt 源、ufw 规则、root 的 `.bashrc/.bash_history` | `raw/_extra/` |
| 凭据 | root/dba/redis 的 `.ssh`（含 `pigsty-admin` 私钥、3 把 authorized_keys）、`.pgpass`、`.pg_service.conf`、`.mcli`（sss.pigsty 别名）、newt、ntfy、OTel token、Pigsty CA、kafka SCRAM `secrets.yml`、redis/etcd/kafka TLS、**LyraPass cloud 的 env**、4 个自定义容器的 `docker inspect`（含环境变量明文） | `raw/_secrets/` |
| 数据 | `ecommerce.pgdump`(405K, 33 表) / `bugsink.pgdump`(388K) / `openfga.pgdump`(251K) / `globals.sql`(13 角色)；`lyrapass-cloud-pg.pg_dumpall.sql`（14 表）；LyraPass `vault.db` + healthchecks `hc.sqlite` + `grafana.db` + ecommerce-gatus 历史；CDC 插件目录含 57 个 jar（PR #940 构建产物）；PGDATA 冷拷贝 + pgbackrest 仓库（全备 `20260903-010002F`）+ Silo 对象 | `raw/_data/` |

逻辑备份是在本机用 `postgres:18` 容器挂载冷拷贝导出的（`database system was shut down at 2026-09-03 01:44:20 UTC`，干净停机），
`pg_restore -l` 校验通过。`meta` 库（Pigsty cmdb）依赖 postgis 未导出，不需要。

### 1.2 会随重装消失、**没有**备份的（需要你确认放弃）

| 内容 | 大小 | 说明 |
|---|---|---|
| `/data/infra/{metrics,logs,traces}` | 802M | VictoriaMetrics/Logs/Traces 15 天历史数据。集群内 VM/VL/VT 重新开始积累 |
| Kafka 日志段 `/data/kafka` | 51M | `ecommerce.events`（7 天）与 `ecommerce_cdc.*` 主题。CDC 可从 PG 全量重建（`reindex` 工具） |
| Elasticsearch 索引 | 5M | 由 PG 通过 `reindex` 重建；`index-mappings.json` 在本地仓 |
| 三个本地构建镜像 | 1.6G + 1.8G + 22M | `ecommerce-elasticsearch:9.4.5-ik`、`ecommerce-connect:debezium-3.6.1-es-sink-bf11247`、`ecommerce-reindex:es9`。Dockerfile 在本地仓，构建产物 jar 已收割，可重建 |
| gatus 探测历史（两份 sqlite） | 13M | 无价值 |
| `/data/etcd`、`/data/redis`、`/data/vector`、`/data/venv` | <130M | Pigsty 内部状态 |
| cdc-connect 的匿名卷 | 2.7G | Kafka Connect 运行时缓存 |

### 1.3 重装后必须手工复原的系统项（安装器不管）

1. **sshd**：2026-09-04 从现有 SSH 会话的服务端 socket 实测，公网 `211.144.221.229:44163`
   映射到 `10.10.21.163:22`；不是 5837。重装后默认 22/tcp 即可，**不要**复制 Pigsty 额外开的 5837。
2. **authorized_keys**：3 把公钥（`rcc@vip.qq.com` ED25519、`root@jump` RSA、`pigsty-admin@node3`）。
   `root@jump` 说明有一台跳板机能 root 登录 node3——重装后要不要保留，你定。
3. **静态地址**：`10.10.21.163/24`，网关 `.254`，DNS `.219/.222`（`raw/_extra/etc/netplan/01-netcfg.yaml`）。
   注意旧文件同时写了 `dhcp4: yes`，这就是 `.172` 租约的来源；重装后只写静态。
4. **apt 源**换 `mirrors.cloud.tencent.com`（机房实测 0.1s vs archive.ubuntu.com 3.4s），`reboot` 进最新内核。
5. **不要**再装 pigsty 的 tuned/ufw/docker：安装器的 20 阶段与 Cilium 会接管；docker 与 Cilium 的 iptables 冲突见 HOSTING §8.4。

## 2. 复原顺序

```bash
# ---- Day 0: node3 重装前 ----
# 本地: 确认 raw/ 三份 pgdump 与 _secrets 在, 然后才允许重装
ls -la archive/pigsty-node3-2026-09-03/raw/_data/*.pgdump

# ---- Day 1: 三台系统准备(node3 重装后) ----
# 每台: apt 源、内核、确认 hostname 是 node4/node5/node3；node3 默认 sshd 22 即匹配公网 44163 映射
# node101(内网控制面, 需开机): 带走集群凭据
rsync -a root@node101:/var/lib/k8s-installer/creds/ ~/k8s-creds-backup/

# ---- Day 1: node4 控制面 ----
rsync -a --delete --exclude archive/pigsty-node3-2026-09-03/raw ~/lens077/kubernetes/ node4:/root/kubernetes/
ssh node4 'cp /root/kubernetes/bootstrap/config.hosting.env /root/kubernetes/bootstrap/config.env'
ssh node4 'mkdir -p /var/lib/k8s-installer/creds && chmod 700 /var/lib/k8s-installer/creds'
rsync -a ~/k8s-creds-backup/ node4:/var/lib/k8s-installer/creds/        # 沿用 dragonfly/grafana 等密码
scp archive/pigsty-node3-2026-09-03/raw/_secrets/etc/infra-alerts/ntfy.env node4:/var/lib/k8s-installer/creds/ntfy.env
# newt 组件要求 creds/newt-{id,secret}; 从收割的 config.json 拆出(文件权限必须 600)
jq -r .id archive/pigsty-node3-2026-09-03/raw/_secrets/opt/newt/config.json > /tmp/newt-id
jq -r .secret archive/pigsty-node3-2026-09-03/raw/_secrets/opt/newt/config.json > /tmp/newt-secret
scp /tmp/newt-id /tmp/newt-secret node4:/var/lib/k8s-installer/creds/
ssh node4 'chmod 600 /var/lib/k8s-installer/creds/newt-{id,secret}'
rm -f /tmp/newt-id /tmp/newt-secret
# 控制面只跑到 70-storage: 组件(31 个)必须等 worker 加入后再装, 否则全部挤进 node4 一台。
ssh node4 'cd /root/kubernetes/bootstrap && bash start.sh --dry-run --to 70-storage'   # 先看阶段列表(无需 root)
ssh -t node4 'cd /root/kubernetes/bootstrap && sudo bash start.sh --to 70-storage'     # 交互; 70 阶段回答"用回环文件兜底"

# ---- Day 1: node5 / node3 加入 ----
ssh node4 'kubeadm token create --print-join-command'
for n in node5 node3; do
  rsync -a --delete --exclude archive/pigsty-node3-2026-09-03/raw ~/lens077/kubernetes/ $n:/root/kubernetes/
  ssh $n 'cp /root/kubernetes/bootstrap/config.hosting.env /root/kubernetes/bootstrap/config.env'
  ssh -t $n 'cd /root/kubernetes/bootstrap && sudo bash start.sh --worker'   # 50 阶段粘贴 join 命令; 70 阶段回环确认
done
ssh node4 'kubectl get nodes -o wide'                                        # 三台 Ready 后再继续

# ---- Day 1: node4 收尾: operator 扩 2 副本 → 组件 → 验收 ----
ssh node4 'sed -i "s/^CILIUM_OPERATOR_REPLICAS=\"1\"/CILIUM_OPERATOR_REPLICAS=\"2\"/" /root/kubernetes/bootstrap/config.env && cd /root/kubernetes/bootstrap && sudo bash start.sh --only 60-cilium'
#   values 指纹变化 → 自动 preflight + helm upgrade; l2 步骤每次重跑都重新校验两个池(PoolConflict@当前 generation)
#   config.hosting.env 已设 RUN_CILIUM_CONNECTIVITY_TEST=true, 三节点齐后连通性测试才有意义
ssh -t node4 'cd /root/kubernetes/bootstrap && sudo bash start.sh --from 80-components'   # = 80-components + 90-verify
#   80 阶段按 config.hosting.env 选组件(可观测层全开, loki/jaeger/fluent-bit 关, CNPG 开)
#   90 阶段验收共享 Gateway: 当前 generation Programmed=True, 生成的 Service 请求注解与实际分配都是 .240,
#   IPAMRequestSatisfied=True; LB 冒烟只证明"分配 + eBPF 编程", L2 租约/节点自访是附加观测。
# 90 通过 ≠ 公网路径通: newt Pod → VIP:443 → HTTPRoute 必须从 newt Pod 内实测(要看到业务状态码, 不是 404/502)
ssh node4 'kubectl -n default get gateway cilium-gateway -o wide; kubectl -n default get svc cilium-gateway-cilium-gateway -o wide'
ssh node4 'kubectl -n pangolin exec deploy/newt -- wget -S -qO- --no-check-certificate --header="Host: grafana.dev.test" https://10.10.31.240/api/health'

# ---- Day 2: 数据与接线 ----
# CNPG 恢复(§4) → 观测链路验证(OBSERVABILITY-INTEGRATION §3) → newt 站点与 Pangolin 资源改指向(§3)
# ---- Day 3: 应用层 ----
# ecommerce 仓: GitOps 重新接线; LyraPass / CDC / ES / Kafka 按 §5 拍板后部署
```

本机访问：`ssh -L 6443:10.10.21.161:6443 node4`，kubeconfig 的 server 改 `https://127.0.0.1:6443`
（`config.hosting.env` 的 SAN 已含 `127.0.0.1`/`localhost`/`211.144.221.229`）。

### 2.1 执行记录：2026-09-06 Day 1（node4 + node5，node3 未动）

按上面的顺序在两台空机上跑完，全部非交互（`--yes`，无 TTY → 70 阶段自动回环文件）：

| 步骤 | 结果 |
|---|---|
| node4 `--to 70-storage` | 5 分 22 秒；两池 `PoolConflict=False` |
| node5 `--worker --to 40-container-runtime` → `--from 50-kubernetes --to 70-storage` | 加入 41 秒；回环 VG 60G |
| node4 operator=2 `--only 60-cilium` | 指纹变化 → preflight + helm upgrade；operator 2/2 |
| node4 `--from 80-components` | 三轮才过（见下），最终 31 个组件全 Running |
| node4 `--verify` | 10/10 通过：Gateway `.240` 当前 generation Programmed、LB 冒烟 `.244`（租约存在，节点自访通）、存储冒烟、OTel 冒烟 metrics→VM / logs→VL / traces→VT 打点回查 |
| Pod → `https://10.10.31.240` | node4/node5 各起一个 Cilium 管理的非 hostNetwork 探测 Pod：`metrics.dev.test`/`argocd.dev.test` 200 `server=envoy`，未匹配 Host 404，80→443 301，证书 `CN=dev.test / my-global-root-ca` |

**本次没做**：`ADDON_NEWT` 临时置 `false`——node3 的 newt 仍在线承载 lyrapass 等生产服务，集群里用同一站点 ID 会互踢。
正式的 newt Pod 实测等站点切换方案定下（面板另建站点，或先下线 node3 的 newt）后，把 `ADDON_NEWT` 改回 `true`、`bash components/newt/install.sh`，再跑上面第 107 行那条。

**过程中发现并已修进仓库的安装器问题**（都已在两台机器上验证）：

1. `50-kubernetes` 把 kubelet 1.36 deb 自带的 `/etc/kubernetes/manifests/.kubelet-keep` 当成残留集群 → 判据改为存在 `*.yaml`。
2. `00-preflight` 在 `--to 40-container-runtime` 这种不含 50 的范围里仍要求 worker 的 `JOIN_*` → `start.sh` 导出 `K8S_RUN_LIST`，只在范围含 50 时要求。
3. **Spegel 接管 certs.d**：`containerdMirrorAdd=true` 把 13 个 hosts.toml 挪进 `_backup/`，未命中回退"上游直连"，机房 docker.io/registry.k8s.io/quay.io 直连不通（DNS 污染 + 超时）→ 80 阶段大面积 `ImagePullBackOff`。改为 Spegel 不接管，40 阶段在每个 hosts.toml 里先注入本节点 Spegel（`SPEGEL_MIRROR_PORT`）再镜像站再回源；实测 node4 首拉 14s、node5 P2P 命中 2s。
4. prometheus-community/autoscaler/vector/openbao/open-telemetry 的 chart 包托管在 github.com releases，直连超时 → `helm_install_component` 从本地仓库索引解析 tgz URL，github.com 的经 `GITHUB_PROXY` 缓存到 `$CACHE_DIR/charts/` 再装（失败回退原路径）。
5. `ALERTMANAGER_STORAGE_SIZE=200Mi` 小于 xfs 最小 300MB，mkfs 失败 → 512Mi。
6. bugsink 镜像 uid 14237，xfs PVC 挂上是 root 755 → 加 `fsGroup`。
7. `cilium connectivity test` 的客户端镜像在内核 7.0 上 `nslookup` 崩溃（exit 139，`kill: Permission denied`），DNS 预检就中止，一条数据面用例都没跑；已手工清理它遗留的三个命名空间。这是测试镜像的问题，需换更新的 cilium-cli/测试镜像再验，不能当成数据面证据。

**仍待处理**：node3 重装与加入；newt 站点切换；机房对 `10.10.31.0/24` 的答复；两台机器有 GRUB 持久化变更建议空闲时 reboot 一次；`~/k8s-creds-backup`（node101 关机）未带入，组件密码全部新生成，需按 `config.env` 重建须知同步 Config Center。

### 2.2 执行记录：2026-09-06 应用层复现（对照内网 node101~103 实际状态）

内网集群实际在跑的与 `components.selected` 不一致：VM/Loki/Jaeger/NATS/CNPG 等观测与数据组件**都不在内网集群里**，
实际是基础设施层 + Tetragon + ArgoCD（无 Application）+ `config-center` + `ecommerce`（14 个工作负载，`kubectl apply`
直接部署，非 GitOps）+ newt。机房已是基础设施层的超集，差集只有 Tetragon 与应用层。

| 项 | 结果 |
|---|---|
| Tetragon 1.7.1 | ✅ `ADDON_TETRAGON=true`，两节点 2/2；Go gRPC 测试通过 |
| Go 客户端连通性 | ✅ `tests/go-connectivity` 14 用例全绿（见其 README） |
| `config-center` | ✅ 用 `tools/clone-namespace.sh` 从内网克隆（Secret 经 ssh 管道，不落盘）；`config-api.app.com` / `config.app.com` 经 VIP 200 |
| `control-tower-gateway` | ✅ 2/2；`dragonfly-session` Secret 的 `ca.crt`/`password` 换成机房值（内网 CA 与密码在机房无效） |
| `payment` | ✅ 1.6.3（不用 Redis） |
| 其余 9 个后端服务 | ❌ CrashLoop：Dragonfly 的 CA/密码来自 config-center **dev 环境配置**（存 node3 PG，内网/机房共用一份），写的是内网 Dragonfly 的值 |
| `consumer-next` / `ecommerce-frontend` / `qqbot` | ❌ 缩到 0：TCR 只有 arm64 的 `dev-*`/`sha-*` 标签，机房是 amd64（内网 node101~103 是 Apple 芯片虚拟机）；需 ecommerce CI 出 amd64 |
| 10 个后端镜像 | 内网跑 `sha-c364128`（仅 arm64），机房改用最近发布版 `1.6.3`（双架构）；Deployment 上有 annotation 说明 |

应用层的数据面本来就不在集群里：config-center 与各服务通过 `pg.apikv.com:30001` / `redis.apikv.com:30002`
（node3 Pigsty 经 Pangolin 暴露）访问 PG/Redis，机房照旧可用；切到集群内 CNPG 属于 node3 重装时的迁移决策（§4）。

### 2.3 执行记录：2026-09-11 Pangolin 切流到机房集群

前提变化：三台机房节点（node3/4/5）都以 **systemd** 方式跑 newt（`/etc/newt/newt.env`，站点 node3=7 / node5=9 / node4=10），
集群里不再装 newt 组件；内网集群 node101~103 已删除，Pangolin 上 9 个资源仍指向已离线的站点 4（`k8s-cluster`）。

| 资源 | 原 target（站点 4） | 现 target | 公网结果 |
|---|---|---|---|
| config / config-api / gateway / shop / qqbot / argocd / consul / search / cart-api `.apikv.com` | `10.110.51.106:443`（旧 VIP）或 `192.168.3.121:443` | **站点 10（node4）→ `https://10.10.31.240:443`** | config 200；config-api 401（需 token）；gateway `/healthz` 200；shop/qqbot 503（后端 0 副本，等 amd64 镜像）；argocd/consul/search/cart-api 401 = Pangolin SSO 墙（资源自身策略） |
| node3 Pigsty 相关（站点 7） | 不变 | 不变 | — |
| scorpius.apikv.com | 站点 4 `127.0.0.1:8787` | **未动**，机房无此服务 | 仍 offline，需决定去向 |

操作方式与坑（Pangolin 1.22.2）：
1. API 登录被拒（账号/密码校验失败），改用团队文档的 sqlite 路径：先 `sqlite3 backup` API 备份（`db.sqlite.bak-idc-cutover-<ts>`），再改 `targets.siteId/ip/port/method`。
2. **https target 必须设 `resources.tlsServerName`**（=资源域名），Pangolin 才会给 Traefik 生成带 `insecureSkipVerify` 的 `serversTransport`；否则 Traefik 校验集群自签证书失败 → 502。
3. **直接改库不会推送到 newt**：Pangolin 只在 newt 注册时下发 target 列表。改完要 `docker restart pangolin`，再 **重启对应节点的 newt**（`systemctl restart newt`），才能看到 `Started tcp proxy … to 10.10.31.240:443`。只重启 Pangolin 不够。
4. 新版 API 的 POST/PUT 需要头 `X-CSRF-Token: x-csrf-protection`（固定值，源码 `csrfProtectionMiddleware`）。
5. IDC 的 4 条 HTTPRoute 追加了 `argocd/consul/search/cart-api.apikv.com` hostname（原只有 `*.dev.test`）。

顺带修掉的集群外故障：node3 的 `10.10.21.172` 原是 **DHCP 租约**（netplan 同时写了 `dhcp4: yes` 与静态 `.163`），租约失效后 Pigsty 的
patroni/pgbouncer/redis/dnsmasq 全部绑定失效，`pg.apikv.com`/`redis.apikv.com` 只剩 TCP 通、TLS EOF，config-center 与所有 ecommerce
服务连锁 CrashLoop。已把 `.172` 改为静态第二地址（`dhcp4: false`），重启 patroni/pgbouncer/redis 后恢复。

**待拍板**（config-center 是共享配置，按 control-tower 规矩先征询）：
- A. 机房用独立环境（`pre`）：在管理台为 `pre` 播种各服务的 redis CA/密码等键、签发 machine token、换 `ecommerce-config-source-*` Secret —— 与 control-tower `deploy/pre` 的设计一致，两集群隔离；
- B. 共用 `dev`：把机房根 CA 追加进 dev 环境各服务 `redis.tls.ca_pem`（bundle，对内网无害），机房 Dragonfly 密码改成内网的同一个 —— 快，但两集群继续共享一份可变配置。

### 2.4 执行记录：2026-09-11 ecommerce 后端切到 Config Center `pre` 环境（拍板 A）

`tools/config-center-pre-seed.sh` 一次跑完：10 个服务的 `pre/bootstrap.yaml`（由 dev 复制，只换 `data.cache.redis` 的密码/CA 为本集群
Dragonfly）、10 枚 pre machine token、`ecommerce-config-source-pre` Secret、Deployment 的 `DEPLOYMENT_MODE`/selector 切换。

| 项 | 结果 |
|---|---|
| address / behavior / cart / inventory / merchant / order / payment / product / user | ✅ 9/9 Running（pre） |
| search | ❌ 缩到 0：dev 配置含 `search.catalog`，镜像 1.6.3 不认识；Config Center schema（enforce）又要求该键，pre 里删不掉。等 search 出含 catalog 的 amd64 版本 |
| consumer-next / ecommerce-frontend / qqbot | ❌ 0 副本（TCR 仅 arm64，不变） |
| Go 连通性 | ✅ 14/14，新增 `TestApplicationLayer`（经 VIP 的应用层 + Config Center 数据面 machine token 读取） |

管理 token 的取得：Casdoor 应用 `ecommerce` 没开 password grant；用账号会话走 **authorization_code**（`/api/login?clientId=…&responseType=code&grantType=authorization_code&redirectUri=…` 带 `type:"code"` 的 JSON 体）拿 code，再换 token（900 s）。`is_secret` 必须与 dev 一致为 false，否则管理面读回是 `******`。

**node3 混合节点的教训**：node3 空载（Pigsty + 10 个 docker 容器 + k8s DaemonSet）已用 4.7 G/7.4 G，调度 3 个 ecommerce Pod 后宿主内存耗尽失联，只能机房强制重启。已打 taint `workload=pigsty-host:NoSchedule`（DaemonSet 不受影响），普通 Pod 只在 node4/node5 跑。重启后 OpenBao 重新 sealed（组件设计如此），用 `creds/openbao-init` 的 key 解封。


## 3. 凭据与外部系统（不在仓库，必须带过去）

| 项 | 来源 | 去向 |
|---|---|---|
| 集群组件密码（dragonfly、grafana、meilisearch、consul…） | node101 `/var/lib/k8s-installer/creds/` | node4 同路径；不带则全部重新生成，且要按 `config.env` 重建须知第 1 条同步 Config Center |
| ntfy | `raw/_secrets/etc/infra-alerts/ntfy.env`（也在 gatus/secrets） | node4 `creds/ntfy.env`；alert-bridge 与 gatus 共用 |
| newt 站点 | `raw/_secrets/opt/newt/config.json`（node3 站点） | 拆成 node4 `creds/newt-{id,secret}`；旧 node3 进程必须先下线再由集群接管，避免同 ID 互踢。HTTPRoute 资源 target 统一改 `https://10.10.31.240:443`，节点资源按需 target `.161/.162/.163:<port>` |
| OTel 公网入口 Bearer token | `raw/_secrets/etc/otelcol/otel-tokens` | ecommerce 前端/SDK 继续用；集群 collector 侧鉴权待补（OBSERVABILITY-INTEGRATION §6） |
| Vault AppRole（ESO） | 组件 README | 重装后重新注入（`config.env` 重建须知第 1 条） |
| LyraPass cloud 的 env | `raw/_secrets/data/lyrapass-cloud/env` + `docker-inspect-custom-containers.json` | 见 §5 |
| Pigsty CA | `raw/_secrets/root/pigsty/files/pki/ca` | 不再需要（ecommerce 客户端改信 CNPG CA / cert-manager 根 CA），留档 |
| TCR 拉取凭据（`ccr.ccs.tencentyun.com/sumery/*`） | node3 上没有 `~/.docker/config.json`，镜像是匿名拉的 | 若仓库为私有需在集群加 imagePullSecret |

## 4. 数据恢复到 CNPG

CNPG `pg-main` 就绪、`Database` CR 建好 `ecommerce`（owner `app`）后：

```bash
D=archive/pigsty-node3-2026-09-03/raw/_data
# 角色: Pigsty 的 dbrole_* 层级建议改用 CNPG managed.roles(PIGSTY-HARVEST §4.2); 不要整份灌 globals.sql
# 业务库: 用 --no-owner --role=app, 所有对象归 app
kubectl -n postgresql exec -i pg-main-1 -- pg_restore -U postgres -d ecommerce --no-owner --role=app --exit-on-error < $D/ecommerce.pgdump
# 校验
kubectl -n postgresql exec pg-main-1 -- psql -U postgres -d ecommerce -Atc \
  "select n.nspname, count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname not like 'pg_%' and n.nspname<>'information_schema' group by 1 order by 1"
# 期望: addresses 2, behaviors 1, cart 1, config 3, inventory 2, merchants 3, orders 4, payments 1, products 5, public 11, monitor 1
```

- `ecommerce` 里的 `ecommerce_cdc` publication 会随 dump 恢复；Debezium 的复制槽不会，重新注册 connector 时按
  `publication.autocreate.mode=disabled` 直接用现成 publication。
- `openfga.pgdump`：openfga 组件会自己建库；dev 数据是否回灌可选。
- `bugsink.pgdump`：新 bugsink 组件默认 sqlite；要保留 90 天 issue 历史就把它灌进 CNPG 并给 bugsink 设 `DATABASE_URL`。
- `lyrapass-cloud-pg.pg_dumpall.sql`：随 LyraPass 的去向一起决定（§5）。
- 冷拷贝与 pgbackrest 仓库只作保险，CNPG 不能直接消费。

## 5. node3 上非 Pigsty 负载的去向（需要你拍板）

| 负载 | node3 现状 | 建议 |
|---|---|---|
| **LyraPass**（`lyrapass` :8090、`lyrapass-cloud` :8091、`lyrapass-cloud-pg` postgres:16，`docker run` 起的，无 compose） | 你的产品；数据 `vault.db` 78K + cloud 库 14 表 | LyraPass 仓已有 `deploy/cloud/k8s.yaml` 与 `deploy/node3/{run,cloud}.sh`；建议上集群，cloud 库进 CNPG（`Database` CR），env 从 `_secrets` 迁 Secret |
| **ecommerce-gatus**（第二个 gatus，"outside the Kubernetes failure domain"，告警直打 node3 Alertmanager API） | 端点清单与 `/data/gatus` 部分重叠 | 端点合并进 `components/gatus/endpoints.yaml`；「集群外视角」这一层没有 node3 后可放 node1 VPS（`docker-deploy/gatus` 已有），告警改打集群 Alertmanager 的公网入口或直推 ntfy |
| **host-watchdog**（每 5 分钟巡检容器/单元/磁盘/隧道 → ntfy + healthchecks） | 为 docker 宿主写的 | node3 变 k8s 节点后由 vmalert + gatus 覆盖；脚本保留给 node1/node2 |
| **CDC**（Debezium 3.6.1 → Kafka → ES 9.4.5+IK，自建镜像） | docker compose，依赖 node3 Kafka 与 PG | 需要先定 Kafka 去向（Strimzi 或继续 NATS，PIGSTY-HARVEST §7）；ES 单节点 StatefulSet 复用自建镜像；插件 jar 已收割可免重编 |
| **Kafka**（KRaft 单节点，SCRAM + ACL） | `ecommerce_app` 用户、`ecommerce.events` 主题 | 拍板项；Strimzi 组件在库（`ADDON_STRIMZI`），KafkaUser/KafkaTopic 可按 `pigsty.yml` 原样声明 |
| **Silo**（对象存储） | 3 个桶 136K，几乎没用 | 拍板项；`minio` 组件在库（`ADDON_MINIO`） |
| **otelcol / gatus / healthchecks / bugsink / 告警桥** | docker | ✅ 已成为集群组件 |
| **newt** | systemd | ✅ 集群 `newt` 组件 + Pangolin 资源改指向 |

## 6. 仍缺的代码与决策

- 多环境配置加载：仍靠 `cp config.hosting.env config.env`；内网版改公共键后要同步（文件头有说明）。
- L2/LB-IPAM 已按机房版修正并固定 Gateway VIP；2026-09-06 池与 L2 通告已拆成独立开关（`CILIUM_ENABLE_LB_IPAM` / `CILIUM_ENABLE_L2_ANNOUNCEMENTS`），地址留空时 00 阶段有终端会询问并存到状态目录。
- 共享 VLAN 允许伪造 Pod CIDR 源地址，跨节点流量当前明文；生产前评估现有 IPsec 开关或增加 WireGuard。
- `victoria-logs` 的 `-retention.maxDiskSpaceUsageBytes` / `-insert.maxLineSizeBytes` 未加（回环卷撑满会拒写）。
- `vector` 对 CNPG JSON 日志的解析分支未加（慢查询/错误码字段化，PIGSTY-HARVEST §5.4）。
- 公网 OTLP 入口的 Bearer 鉴权未迁入 opentelemetry 组件。
- Kafka / ES / 对象存储三项拍板（§5）。
