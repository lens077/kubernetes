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
| LoadBalancer / 网关地址 | ⚠️ 无 | 共享 VLAN 关闭 L2；Gateway 拿不到地址，`gateway` 组件只告警。对外走 newt（Pangolin），对内 `kubectl port-forward` / ssh 隧道。机房给专用 VIP 后填 `CILIUM_LB_POOL_*` 并开 L2 |
| 数据库数据 | ✅ 已备份 | node3 PG 的 `ecommerce` / `bugsink` / `openfga` 三库逻辑备份 + 角色（§4）；PGDATA 冷拷贝与 pgbackrest 仓库作第二份保险 |
| 凭据延续 | ⚠️ 需人工 | 集群凭据在 node101 `/var/lib/k8s-installer/creds/`（node101 当前关机）；ntfy / newt / OTel token / Pigsty CA 已收割到 `raw/_secrets/`（§3） |
| node3 上非 Pigsty 的负载 | ⚠️ 需拍板 | LyraPass 三容器、ecommerce-gatus、host-watchdog、CDC(Debezium+ES)、Kafka、Silo（§5） |
| 应用层（ecommerce 服务 / ArgoCD） | 📎 不在本仓 | ecommerce 仓 TODO「集群重建后 GitOps 重新接线」；`config.env` 重建须知第 3 条 |
| 90 阶段验收 | ✅ | OTel 冒烟已支持 VL/VT 查回；LB 冒烟按机房版关闭 |

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

1. **sshd**：node3 现在监听 `Port 22` 与 `Port 5837`；机房端口映射 `44163` 指向其中之一〔待确认是 5837〕。
   重装后先在 `/etc/ssh/sshd_config.d/` 加回端口，否则失联。
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
# 每台: apt 源、内核、sshd 端口(仅 node3)、确认 hostname 是 node4/node5/node3
# node101(内网控制面, 需开机): 带走集群凭据
rsync -a root@node101:/var/lib/k8s-installer/creds/ ~/k8s-creds-backup/

# ---- Day 1: node4 控制面 ----
rsync -a --delete --exclude archive/pigsty-node3-2026-09-03/raw ~/lens077/kubernetes/ node4:/root/kubernetes/
ssh node4 'cp /root/kubernetes/bootstrap/config.hosting.env /root/kubernetes/bootstrap/config.env'
rsync -a ~/k8s-creds-backup/ node4:/var/lib/k8s-installer/creds/        # 沿用 dragonfly/grafana 等密码
scp archive/pigsty-node3-2026-09-03/raw/_secrets/etc/infra-alerts/ntfy.env node4:/var/lib/k8s-installer/creds/ntfy.env
ssh -t node4 'cd /root/kubernetes/bootstrap && sudo bash start.sh'      # 交互; 70 阶段回答"用回环文件兜底"
#   80 阶段按 config.hosting.env 选组件(可观测层全开, loki/jaeger/fluent-bit 关, CNPG 开)

# ---- Day 1: node5 / node3 加入 ----
ssh node4 'kubeadm token create --print-join-command'
for n in node5 node3; do
  rsync -a --delete --exclude archive/pigsty-node3-2026-09-03/raw ~/lens077/kubernetes/ $n:/root/kubernetes/
  ssh $n 'cp /root/kubernetes/bootstrap/config.hosting.env /root/kubernetes/bootstrap/config.env'
  ssh -t $n 'cd /root/kubernetes/bootstrap && sudo bash start.sh --worker'   # 50 阶段粘贴 join 命令; 70 阶段回环确认
done
ssh node4 'sed -i "s/^CILIUM_OPERATOR_REPLICAS=\"1\"/CILIUM_OPERATOR_REPLICAS=\"2\"/" /root/kubernetes/bootstrap/config.env && cd /root/kubernetes/bootstrap && sudo bash start.sh --only 60-cilium && sudo bash start.sh --verify'

# ---- Day 2: 数据与接线 ----
# CNPG 恢复(§4) → 观测链路验证(OBSERVABILITY-INTEGRATION §3) → newt 站点与 Pangolin 资源改指向(§3)
# ---- Day 3: 应用层 ----
# ecommerce 仓: GitOps 重新接线; LyraPass / CDC / ES / Kafka 按 §5 拍板后部署
```

本机访问：`ssh -L 6443:10.10.21.161:6443 node4`，kubeconfig 的 server 改 `https://127.0.0.1:6443`
（`config.hosting.env` 的 SAN 已含 `127.0.0.1`/`localhost`/`211.144.221.229`）。

## 3. 凭据与外部系统（不在仓库，必须带过去）

| 项 | 来源 | 去向 |
|---|---|---|
| 集群组件密码（dragonfly、grafana、meilisearch、consul…） | node101 `/var/lib/k8s-installer/creds/` | node4 同路径；不带则全部重新生成，且要按 `config.env` 重建须知第 1 条同步 Config Center |
| ntfy | `raw/_secrets/etc/infra-alerts/ntfy.env`（也在 gatus/secrets） | node4 `creds/ntfy.env`；alert-bridge 与 gatus 共用 |
| newt 站点 | `raw/_secrets/opt/newt/config.json`（node3 站点） | 集群 `newt` 组件可直接复用这份站点凭据（node3 下线后该站点由集群接管）；Pangolin 面板里 `node3-*.apikv.com`、`bugsink/grafana/metrics.apikv.com` 等资源的目标改成集群内 Service |
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
- LB 池与 L2 解耦（HOSTING §6.2）：拿到机房 VIP 前无影响。
- `victoria-logs` 的 `-retention.maxDiskSpaceUsageBytes` / `-insert.maxLineSizeBytes` 未加（回环卷撑满会拒写）。
- `vector` 对 CNPG JSON 日志的解析分支未加（慢查询/错误码字段化，PIGSTY-HARVEST §5.4）。
- 公网 OTLP 入口的 Bearer 鉴权未迁入 opentelemetry 组件。
- Kafka / ES / 对象存储三项拍板（§5）。
