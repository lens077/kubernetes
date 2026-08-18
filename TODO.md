# TODO

## 2026-08-17(第二批) · L3 硬化 + 明文迁移:审查建议落地

同日下方「GitOps L3 落地」的续篇:四人审查团(改动清单/性能/安全/产品影响)给出的建议按用户拍板执行。

### 已执行

| 项 | 结果 |
|---|---|
| git filter-repo 重写本仓历史 | 抹除 install.sh 曾含的 VPS SSH 坐标;上下文串替换(裸 `34123` 会误伤 archive/citus CSV);重写后 HEAD 树哈希与原 HEAD 逐字节一致;已强推。**教训:从 filter-repo 产物仓直接 push 会因缺旧对象在协商阶段挂死,fetch 回工作仓再推秒过** |
| P1-A 专网隔离 | `vault_backend`(10.66.0.0/24;172.16-31 的 /16 已被本机占满,eth0 是腾讯 VPC 10.1.0.0/22)。gerbil 运行时 `network connect` 接入零中断;vault 重建后只在专网。**验证:pangolin_frontend 里的容器访问 vault:8200 = BLOCKED** |
| P1-B 审计 | `vault audit enable file`(logs/audit.log),开启状态持久于 storage;install.sh 幂等块 |
| P1-C XFF | listener 加 `x_forwarded_for_authorized_addrs=[10.66.0.0/24]`。**验证:audit 里 remote_address = 真实公网 IP 而非 traefik 内网 IP** |
| demo ExternalSecret | 集群实例已删(物化 Secret 随 Owner 联动消失);examples 文件改为 1h 模板 + 分级注释(性能审查:无 reloader 时 1m 纯空转) |
| raft snapshot | 迁移前/后各一份,存 Mac `lens077/vault-backups/`(时序:备份必须先于真实密钥迁入——迁入后「密钥可丢」前提即失效) |
| VPS minio root 轮换 | 旧密码属 msdnmm 家族(见下),已换强随机并写入 Vault `secret/vps/minio`;git 侧 compose 改占位符 |
| 集群 minio → Vault | `secret/k8s/minio`(新随机值)→ `components/minio/externalsecret.yaml` 物化 Secret `minio-root`(同名同键,Deployment 零改动);install.sh Vault 优先 + get_cred 降级;component.env `DEPENDS_ON="external-secrets"`;summary.sh 改读集群 Secret。**验证:Secret ownerRef=ExternalSecret,Pod env 哈希 = Secret 哈希 = Vault 值** |
| 全仓明文置换 | **730 处 / 124 文件**替换为 `<REDACTED-20260817>`:本仓(archive + components/*/examples 的 legacy 拷贝,含本文件 08-06 段的值引用)、cloud-native-deploy 全仓、pipeline 仓、docker-deploy/minio。archive「原样保留」原则为安全让路,特此记录 |

### 迁移中的关键发现:msdnmm 密码家族

审计五处明文时发现真正的问题比清单大:**`msdnmm` 系列密码在公开仓(本仓 + cloud-native-deploy)出现约 700 处**,横跨 casdoor/dragonfly/harbor/juicefs/redis/postgres/kafka-connect 的示例与脚本,而 **VPS 上活着的 minio 用的就是这个家族**(已轮换)。其余状态:

- 老集群消费者(loki S3 四组 key、minio123)已随集群重建死亡 —— 值作废,占位符只是卫生
- **ecommerce 仓(公开)的 20 份 `configs/{dev,pre}.yml` 也在家族里,本次刻意未动**:它有自己的 Config Center 单源迁移轨道(ecommerce TODO §96),混改会破坏其契约;需在该轨道内轮换
- docker-deploy(已转私有)里 casdoor/postgres/redis/gorse/pgsync 等 compose 仍是字面量真值:私有仓风险可控,**但 VPS 上这些服务的活口令与公开仓历史里的家族同源,逐个轮换列为待办**

### 待办(新增)

- [ ] **VPS 存活服务逐个轮换 msdnmm 家族口令**(casdoor/postgres/redis/gorse/consul/kafka…),轮换后写入 Vault `secret/vps/<svc>`,compose 改从环境/文件注入
- [ ] **cloud-native-deploy 与 pipeline 仓的 git 历史仍含明文**(HEAD 已清):值多数已死/已轮换,是否 filter-repo 重写待决策(公开仓、有外链引用,重写会改 hash)
- [ ] ecommerce 仓口令轮换(挂靠其 Config Center 轨道,见上)
- [ ] 安全审查 P1-D 未执行(用户未点名):vault UI 拆 router 挂 badger + traefik rateLimit
- [ ] audit.log 无轮转;raft snapshot 进 cron(当前手动两份)
- [ ] ESO chart 用户拍板**不钉版本**(跟最新),记录在案:重装行为随上游漂移属接受的取舍

## 2026-08-17 · GitOps L3 落地:线上 Vault + External Secrets Operator

### 决策

密钥层(L3)定案为**线上 Vault(真相源) + 集群内 ESO(搬运工)**,替代先前倾向的 Sealed Secrets:
集群处于反复重装期,真相源必须在集群外;VPS 公网可达还让 CI 与 compose 服务未来可共用同一后端。
集群重装后的恢复动作只有一件:重跑 external-secrets 组件并注入 AppRole 凭据,密钥自动流回。

### 部署事实

| 侧 | 内容 |
|---|---|
| VPS(pangolin 机) | `/home/docker/vault/`(docker-deploy 仓 `vault/`):hashicorp/vault:1.21.4,raft 单节点,不发布主机端口,挂 `pangolin_frontend` 网络 |
| 入口 | `https://vault.apikv.com`:traefik file provider 手写路由(**不挂 badger** —— ESO 是机器客户端,过不了 SSO 登录墙),ZeroSSL 泛证书,80→443 跳转 |
| Vault 内 | KV v2 @ `secret/`,AppRole `eso`(策略 `eso-read` 只读 `secret/data/*` + `secret/metadata/*`),凭据在 VPS `approle-eso.json`(0600,不入库) |
| 集群 | `components/external-secrets/`(chart,镜像 v2.9.0):ClusterSecretStore `vault`,roleRef/secretRef 均取自 Secret `vault-approle`(install.sh 从环境变量创建,**Git 里零凭据**);`ADDON_EXTERNAL_SECRETS="true"` 已进 config.env |

认证选 AppRole 而非 kubernetes auth,是反向可达性决定的:后者要 Vault 回连本集群 apiserver,
集群在 LAN 里公网够不着;AppRole 纯出站,方向与 newt 隧道一致。

### 验证(行为,非配置表面)

- 公网:`/v1/sys/health` initialized:true / sealed:false;http 302→https;证书 `*.apikv.com`(ZeroSSL,至 2026-10-27)
- 集群:ClusterSecretStore `Valid/ReadWrite/Ready=True`;`examples/externalsecret-demo.yaml` → Secret `demo-hello` 解码 `hello=world`
- **轮换传播**:Vault 侧 `kv put hello=rotated`(11:44:38Z)→ refreshTime 11:44:56Z → 集群 Secret 变 `rotated`,**18 秒**(refreshInterval=1m 内);注意物化更新不等于 Pod 重启,消费方要热更新需另配 reloader 类工具

### 过程中修掉的三类坑(均已写回文件注释)

1. **`bootstrap/lib/common.sh` 此前兑现不了「Mac 也能跑组件脚本」的承诺**:`getent` 在 macOS 不存在,
   组件脚本 set -eo pipefail 下 source 时 127 静默死(`2>/dev/null` 又吞了报错,`:-/root` 兜底永远走不到);
   `uname -m` 的 macOS 拼法 `arm64` 不在 detect_arch 的 case 里。两处已修。
2. **vault 官方镜像的两个属主坑**:`:ro` 挂载的 config 若是 0600 root,容器内 vault 用户(100:1000)读不了
   (entrypoint 想 chown 也改不动只读挂载);`/vault/data` 不在 entrypoint 的 chown 名单里(它只管自带的
   `/vault/file`),raft 的 bolt 文件直接 permission denied。install.sh 现在在宿主机侧 chmod/chown。
3. **脚本自身三连**:`vault status` 在 sealed 时退出码 2,pipefail 下 `$(v status | jq ... || echo true)`
   会把兜底值拼进捕获结果("true\ntrue");jq 的 `//` 把 false 当"空"(判 sealed 必须 `tostring`);
   `docker exec` 不带 `-i` 吃不到 heredoc(policy write 报 "'policy' parameter not supplied")。

### 环境观察

- **`*.nju.edu.cn` 镜像站当天整站 000**(Mac 与节点皆然,quay/ghcr 前缀同灭)——单点,不能当长期依赖。
- **节点直连 ghcr.io 当天可达**(/v2/ 返回 401 匿名响应,三镜像拉取成功)——上文 08-06「LAN 拉 ghcr
  必须代理」的结论不恒成立,时好时坏;values.yaml 里已留降级路径注释(NJU mirror / 经 Mac 转推 TCR)。

### 测试级取舍(集群重装期,已知且接受;正式化清单)

- [ ] unseal key 单份 + root token 同存 VPS `init.json`(0600)→ 正式化时 `operator rekey` 分片离机
- [ ] VPS/容器重启后 vault 回 sealed,需手动跑 `vault/unseal.sh` → 评估 auto-unseal(上游支持阿里云 KMS,无腾讯云)
- [ ] 无审计日志、无 raft snapshot 备份 → `vault audit enable file` + snapshot 进 cron 异地存
- [ ] secret_id 永不过期 → 怀疑泄漏即在 Vault 侧吊销重发,集群只需更新 Secret `vault-approle`

### 下一步(与 L4 汇合)

- [ ] **把五处明文迁入 Vault**(MinIO root、loki S3 key、streaming-pipeline 的 ES/DB 密码),清单与轮换
      runbook 见上方 08-06「需要修复 · 安全(P0)」——迁移顺便完成 runbook 第 8 步「清仓库为占位符」
- [ ] ExternalSecret CR 随组件清单进 Git,后续由 ArgoCD 同步(L3 与 L4 的汇合点)

## 2026-08-06 · Kafka/Debezium CDC 链路修复 + Strimzi 与 Kafka 升级

### 背景

排查始于一个看似无关的问题:「PD 给虚拟机分配了 256G,为什么只有 30G」。顺着查下去发现是**六个彼此独立的问题叠在一起**,共同导致 Debezium CDC 管道无法工作。按发现顺序:

1. **256G 磁盘并没有丢**。30G 是根分区(`ubuntu-vg/ubuntu-lv`),另有 192G 在 `sda4`/`lvmvg` 上给 OpenEBS,1G EFI + 2G /boot,合计正好 256G。`ubuntu-vg` 里还有 30.47G 从未分配 —— Ubuntu 安装器默认只把 LVM 空间的一半给 root。
2. **KafkaConnect 构建把根分区写满,触发驱逐循环**。Strimzi 生成的 buildah 命令硬编码 `--storage-driver=vfs`,vfs 不做 CoW、每层都是完整副本,实测吃掉约 7G。而 build pod `resources: {}` → ephemeral-storage request=0 → BestEffort → 在 kubelet 驱逐排序里**排第一位**(28 个 Pod 中)。于是它写满磁盘、又第一个被自己触发的驱逐杀掉,在 node2/node3 之间反复横跳。
3. **node1 冷缓存 + quay.io 跨境限速**。untaint node1 后 build pod 调度过去,而 node1 从未跑过这类负载(镜像数 14,node2 有 33),需冷拉 207MB。实测 quay.io 单连接会被逐渐限速到 **34KB/s**,Pod 卡在 `ContainerCreating` 27 分钟。
4. **`bootstrapServers` 指向不存在的 Service**。线上 CR 写的是 `my-cluster-kafka-plain-bootstrap:9092`,DNS 无法解析。Strimzi 的 **internal listener 不会生成各自的 bootstrap service** —— 所有内部监听器共用 `<cluster>-kafka-bootstrap`,靠端口区分;只有 external listener 才有 `<cluster>-kafka-<listener>-bootstrap`。这个名字是臆造的。(仓库文件里本来是对的,是线上漂移了。)
5. **`binary.handling.mode: utf8` 是无效值,且被 NPE 完全掩盖**。详见 `connect/examples/debezium-postgres-connector.yml` 里的注释。
6. **wal2json 残留槽 + pgoutput 需要 publication**。详见 `connect/examples/debezium-postgres-example.sql` 第 5 节。

### 集群变更

| 操作 | 对象 |
|---|---|
| 在线扩容 | 三节点 root LV `ubuntu-vg/ubuntu-lv` 30G → 60G(`lvextend -r -l +100%FREE`) |
| 升级 | Strimzi 算子 1.0.0 → **1.1.0** |
| 升级 | Kafka `my-cluster` 4.2.0 → **4.3.0**,metadataVersion 4.2-IV1 → **4.3-IV0** |
| 升级 | KafkaConnect `my-connect-cluster` 4.2.0 → **4.3.0**(镜像重建并推送 TCR) |
| 修正 | KafkaConnect `bootstrapServers` → `my-cluster-kafka-bootstrap:9092` |
| 修正 | KafkaConnector `binary.handling.mode` utf8 → **base64** |
| 新增 | KafkaConnector `publication.name` / `publication.autocreate.mode=disabled` / `slot.name` |
| 删除 | PostgreSQL 中残留的 wal2json 复制槽 `debezium_slot` |
| 新增 | PostgreSQL publication `dbz_publication FOR ALL TABLES`(超级用户建) |
| 新增 | 三节点 containerd 的 quay.io mirror → `quay.nju.edu.cn` |
| 补齐 | KafkaConnect 的 `resources` / `jvmOptions`(此前只在文件里,从未应用到集群) |
| 清理 | KafkaConnect worker config 里误放的 5 个 `database.*` 与 `topic.prefix` |

### 文件与集群对账时查出的两个问题(已一并处理)

同步仓库文件时用 `kubectl diff` 逐份对账,查出线上两处与文件不符:

**1. Connect 的 OOM 防护从未真正生效。** `debezium-postgres-connector-build.yml` 里那段长注释记录了「补上 resources 和 jvmOptions —— 在此之前它被 OOMKill 了 489 次」,但线上 `spec.resources` 和 `spec.jvmOptions` **都是空的** —— 那次修复只写进了文件,没有应用到集群。Pod 实际是 `qosClass=BestEffort`、`KAFKA_HEAP_OPTS` 只有 `-Xms128M` 而无 `-Xmx`,正是当初导致 489 次 OOMKill 的完全相同条件。当时它恰好跑在 node1(内存 requests 仅 4%)所以没暴露,一旦调度回 node2/node3 就会重演。

已应用,验证:`qosClass` BestEffort → **Burstable**,`KAFKA_HEAP_OPTS=-Xms256m -Xmx768m`,worker 启动日志的 `jvm.args` 确认 `-Xmx768m` 真正生效。

**2. worker config 里混着 5 个连接器级配置。** 线上 KafkaConnect 的 `spec.config` 里有 `database.hostname: postgres-service-host`(明显是没替换的占位符)、`database.user/password/dbname/port` 和 `topic.prefix`。这些属于 KafkaConnector,写在 worker config 里会被忽略,不影响功能,但占位符容易误导,且 `database.password` 明文入库不符合 `SECURITY.md`。仓库文件本来就没有这几行,是线上多出来的。已清除,worker config 现在只剩三个复制因子。

两项一起触发了一次 Connect 滚动重启,重启后连接器 `RUNNING`、task `RUNNING`、复制槽被正常重新接管(`active=true`,滞留 WAL 仍为 12kB)。

**教训**:仓库文件里写了修复并不等于集群里生效了。这次是靠 `kubectl diff` 逐份对账才发现,建议后续把这类对账固定下来(见下方待办)。

**扩容是无损的**:`ubuntu-vg` 只含 `/dev/sda3` 一个 PV,而 OpenEBS 数据在 `sda4`/`lvmvg` 这个**独立 VG** 上,`+100%FREE` 在物理层面就不可能触及。扩容后核对:三节点 lvmvg 容量 192G、free 值(192/155/158)与 LV 数量(0/5/5)逐字节未变,10 个 PVC 全部 Bound。

### 为什么必须升到 4.3.0

Debezium 3.7.0.Alpha1 的插件包自带 `connect-api-4.3.0.jar` / `kafka-clients-4.3.0.jar`,与当时 4.2.0 的 Connect 运行时错配。**需要匹配的是 Connect 运行时,不是 broker** —— 类加载冲突发生在 Connect 的 ConfigDef 上,Kafka 客户端与 broker 之间本就跨版本线兼容。broker 是顺带一起升的。

各版本自带的 connect-api(实测):3.5.1→4.1.1、3.5.2→4.1.2、3.6.0/3.6.1/3.7.0.Alpha1→4.3.0。分界在 3.5.x 与 3.6.x 之间。

### quay.io 镜像加速

直连 quay.io 实测 1.5MB/s 起,**单连接会被逐渐限速**(`ctr` 和 `docker` 都出现过十几分钟无实质进展),而新建连接又是快的。换用**南京大学开源镜像站** `quay.nju.edu.cn`(210.28.130.20,AS4538 CERNET)后达到 **10 MiB/s**,580MB 的两个镜像 44 秒拉完,约 20 倍提升。

手工预拉的做法(拉完重打 quay.io 标签,kubelet 即视为本地已有):

```bash
ctr -n k8s.io images pull --platform linux/arm64 quay.nju.edu.cn/strimzi/<repo>:<tag>
ctr -n k8s.io images tag --force quay.nju.edu.cn/strimzi/<repo>:<tag> quay.io/strimzi/<repo>:<tag>
```

持久配置写在各节点 `/etc/containerd/certs.d/quay.io/hosts.toml`(**不在本仓库**,属节点本地状态):

```toml
server = "https://quay.io"
[host."https://quay.nju.edu.cn"]
  capabilities = ["pull", "resolve"]
[host."https://quay.io"]
  capabilities = ["pull", "resolve"]
```

改完**不需要重启 containerd**,`certs.d` 是每次拉取时动态读取的。`server` 保留了回退路径,镜像站挂掉时只是退回慢速直连,不会拉取失败。

⚠️ **验证时容易踩的坑**:`ctr images pull` **默认不读 `certs.d`** —— 那个 `config_path` 挂在 `io.containerd.cri.v1.images` 插件下,只对经 CRI 的拉取(kubelet / `crictl`)生效,`ctr` 要显式加 `--hosts-dir`。用 `ctr` 验证会得出「mirror 没生效」的错误结论。**必须用 `crictl pull` 验证**,并配合 `ss -tnp` 看 containerd 实际连的对端 IP。

节点上另有 12 个其它 registry 的 `hosts.toml`(docker.io、ghcr.io、registry.k8s.io、docker.elastic.co 等),此前均未生效(实测 containerd 直连 Cloudflare 源站),**本次只修了 quay.io 一个**。

### 验证结果

- 三节点 root 分区 30G → 60G;kubelet summary API 显示驱逐余量从 9.8G 升至 26.6G
  (注:`kubectl get node` 的 `capacity.ephemeral-storage` 仍显示旧值 —— 那是 kubelet 启动时缓存的 machineInfo,**驱逐判断走的是 cadvisor 实时 statfs,不受影响**,无需重启 kubelet)
- Connect 运行时 jar 为 `connect-runtime-4.3.0` / `connect-api-4.3.0` / `kafka-clients-4.3.0`,与插件自带的 4.3.0 完全一致
- 复制槽 `debezium` / plugin=**pgoutput** / active=t / 滞留 WAL 仅 12kB(正常消费中)
- 连接器 `RUNNING`,task 0 `RUNNING`,KafkaConnector `Ready=True`
- CDC 主题从 6 个增至 **13 个**,共约 3566 条消息;抽样确认 `ExtractNewRecordState` 展平生效,中文/JSON/时间戳均正常
- 三节点 `crictl pull` 全部连向 210.28.130.20(南大站),199MB/37.9s ≈ 5.2MB/s

### 过程中的一次误操作(已修正)

应用 Strimzi 1.1.0 清单时只做了 `sed 's/namespace: myproject/namespace: kafka/g'`,但**官方 bundle 里的 Deployment / ServiceAccount / ConfigMap 三个资源根本没写 `namespace:` 字段**,于是落到了 `default` 命名空间,凭空多出一套算子。

影响已核实为零:那套算子的 `STRIMZI_NAMESPACE` 取自 `metadata.namespace`(=`default`),而 `default` 里没有任何 Kafka CR,它没做任何事。已删除三个资源并带 `-n kafka` 重新应用。**这正是 `examples/kafka-single-node.yml` 头部第 1 条警告过的同类陷阱**,避坑要点已写进 `strimzi-kafka/install.sh`。

### 仓库变更

```
kafka/strimzi-kafka/
  ~ install.sh                              补算子 1.0.0→1.1.0 升级步骤 + 命名空间陷阱 + 预拉镜像
  ~ examples/kafka-single-node.yml          version 4.2.0→4.3.0、metadataVersion 4.2-IV1→4.3-IV0
                                            + metadataVersion 不可逆的说明与取值查法
  ~ connect/examples/debezium-postgres-connector-build.yml
                                            version 4.2.0→4.3.0、镜像 tag 3.5.1→latest、
                                            插件 3.6.0.Beta1→3.7.0.Alpha1(与线上对齐)
                                            + vfs 放大和 buildah 不共享缓存两个坑
  ~ connect/examples/debezium-postgres-connector.yml
                                            binary.handling.mode utf8→base64 + NPE 排查路径、
                                            新增 publication.name / autocreate.mode / slot.name
  ~ connect/examples/debezium-postgres-example.sql
                                            更正 3.1 的错误假设(CREATE ON DATABASE 不足以建
                                            FOR ALL TABLES publication)、新增第 5 节
                                            publication 与复制槽治理
```

### CDC 端到端验证(2026-08-07)+ 发现一个静默丢删除的缺陷

对 `postgres-kafka-es-streaming-pipeline` 做了全量与断点续传的实测,两项均通过,但过程中发现**删除事件从未同步到 ES**。

**全量重建**:删掉 `ecommerce_products_spus` 索引后重启,日志出现 `Dynamic creation: index ... not found, creating...` 并重建 4 条,与 DB 一致。6 个索引最终计数 3/3/2/7/4/21,与 PG 逐表吻合。

**断点续传**:为排除全量直连 PG 的干扰,先置 `REINDEX_MODE=false`,使 ES 的写入只可能来自 Kafka。缩容到 0 后写入测试行,Kafka 侧 `LOG-END-OFFSET` 4→5、`CURRENT-OFFSET` 保持 4、`LAG=1`(消息被缓冲、位移被保留),ES 仍为 4 文档;恢复到 1 副本后位移推进到 5、LAG 归零,ES 变 5 文档且内容正确(`_id` 用 DB 主键,幂等)。

**缺陷:`transforms.unwrap` 的删除选项在 Debezium 3.x 已被重命名,旧名被静默忽略。**

| 旧选项(3.x 已移除) | 现选项 |
|---|---|
| `transforms.unwrap.delete.handling.mode` | `transforms.unwrap.delete.tombstone.handling.mode` |
| `transforms.unwrap.drop.tombstones` | 同上(两者合并) |

失败链是完全静默的:**Kafka Connect 对未知的 SMT 配置不发任何告警**(实测 Connect 日志里 `isn't a known config` 告警数为 0)→ 回落到默认值 `tombstone` → 删除事件在 Kafka 里是 **null value 消息** → 而消费者 `internal/kafka/consumer.go:68` 开头就是 `if len(msg.Value) == 0 { return nil }`,空值消息直接跳过并提交位移。

净效果:**删除永远同步不到 ES,而 LAG 归零、无任何报错**,所有监控指标都显示健康。实测复现:DELETE 一行后 ES 文档数不减、`_doc/<id>` 仍 `found: true`。**全量重建也修不掉** —— reindex 只按 DB 现有行写入,不会删除 ES 中多余的文档,孤儿需手工清理(本次已清理 id=6)。

改为 `delete.tombstone.handling.mode: rewrite` 后复测:插入 id=7 → ES 6 文档;删除 id=7 → ES 5 文档且 `found: false`,删除路径打通。

**排查手法值得记**:SMT 的可用配置项可以从 Connect 的 validate 端点问出来,比翻文档可靠 —— 传入含 `transforms` 的完整配置,返回的 `configs` 里会列出所有 `transforms.<别名>.*` 定义,不在列表里的就是会被静默忽略的。这次正是靠它确认两个旧选项已不存在。

测试数据已全部清理,DB 与 ES 最终一致(3/3/2/7/4/21),全部 topic LAG=0。

### 待办

- [x] ~~**`postgres-kafka-es-streaming-pipeline` 的删除处理需要加防御**。~~ **2026-08-07 已完成**。`consumer.go` 现在遇到 tombstone 会从 `msg.Key` 取主键删除 ES 文档;`indexer.go` 的删除改走 BulkIndexer(修掉「先写后删」的顺序竞态与 404 误报);主键解析改用 `UseNumber()`(避免 bigint 经 float64 中转变成科学计数法而删错文档)。新增 7 个单元测试。镜像已重建推送(`sha256:271baa52…` 之后的版本)。

      过程中踩到一个反直觉的点值得记:**tombstone 未必是零长度**。`value.converter` 是 JsonConverter 时,null value 被序列化成**字面量 `null` 这 4 个字节**,`len(msg.Value)==0` 判断不到。第一版修复就因此失效 —— 消息被当普通记录解析成 nil map,落到「No ID found」分支静默跳过,现象与完全没修一模一样。判断需同时覆盖零长度和字面量 `null`。

      验证:把连接器改回 `delete.tombstone.handling.mode: tombstone` 复现 tombstone,日志出现 `Tombstone at offset 11: deleting ecommerce_products_spus/_doc/9`,ES 中该文档 `found: false`。测毕已改回 `rewrite`,孤儿文档已清理,DB 与 ES 最终一致、总 LAG=0。
- [ ] **BulkIndexer 的 `NumWorkers=4` 仍可能导致同文档乱序**。各 worker 独立缓冲刷新,同一文档的 index/delete 可能被分到不同 worker。要彻底按文档有序,需 `NumWorkers=1`,或改用 ES 外部版本控制(`version_type=external`,拿 Kafka offset 或 Debezium LSN 当 version 让 ES 自行丢弃旧版本)。性能与强一致的取舍,待定。
- [ ] **该项目 Makefile 的 `--build-arg GOIMAGE` 与 Dockerfile 的 `ARG GO_IMAGE` 名字对不上**,build-arg 被静默忽略,实际一直用 Dockerfile 的默认值 `golang:1.26.1-alpine3.22`。目前"歪打正着"—— 该默认值恰好匹配 `go.mod` 的 `go 1.26.1`,而 Makefile 里写的 `1.25.8` 若真生效反而编不动。改名字前要先把 Makefile 的版本一并对齐。
- [ ] **该项目的 `deploy.yaml` 没有 `namespace` 字段**。当前实际跑在 `default` 命名空间(57 天),与 `kafka` / `elastic-stack` 等其它组件不一致,且 `kubectl apply` 会随当前 context 漂移。与本文件记录的 Strimzi bundle 是同类陷阱,建议显式写死命名空间。
- [ ] **该项目的 `deploy.yaml` 里 ES 密码和 DB 密码均为明文**,不符合 `SECURITY.md`,应改为 Secret 引用。
- [ ] **ES 索引仍是 yellow**(单节点无处放副本),与本文件上方 elastic-stack 条目是同一问题。
- [ ] **`debezium-postgres-tls-connector-build.yml` 未同步**。该文件同样含 `version: 4.2.0` 和旧的插件 URL,但线上没有对应的 TLS 版部署,未验证过,故本次未改。启用前需一并更新。
- [ ] **KafkaConnect 构建仍未加速**。buildah 读的是容器内 `/etc/containers/registries.conf`,与 containerd 的 certs.d 是两套配置,本次 mirror 改动对构建**无效**。可通过 `spec.template.buildPod.volumes` + `buildContainer.volumeMounts` 挂 ConfigMap 解决(Strimzi 1.1.0 的 CRD 已确认支持这两个字段)。
- [ ] **build pod 缺 ephemeral-storage 的 requests/limits**。目前 `resources: {}` 使其为 BestEffort,永远排在驱逐第一位。扩容到 60G 后余量充足,但这是治标;加上 requests 才能让调度器真正为它预留空间。注意这与上面刚补齐的 `spec.resources` 是**两回事** —— 那个作用于 Connect worker 容器,build pod 的资源要通过 `spec.build` 相关字段单独设置。
- [ ] **缺少「文件 vs 集群」的对账机制**。本次靠人工 `kubectl diff` 才发现 Connect 的 OOM 修复从未应用。整个仓库是 imperative 的 `install.sh` + 示例 YAML,没有任何机制保证文件与集群一致(同样的问题在上文可观测性条目里也记过)。最低成本的改进是加一个对所有关键 CR 跑 `kubectl diff` 的脚本;彻底的做法是纳入 GitOps。
- [ ] **`resources` 的取值待用 VPA 校准**。当前 1Gi / `-Xmx768m` 是 2026-08-06 按实测 RSS 拍的。`debezium-postgres-connector-build.yml` 的注释里提到配套挂了一个 `updateMode: Off` 的 VPA(`vpa/examples/example1/kafka-connect.yml`),原计划一周后取推荐值回来校准 —— 但由于该配置此前根本没应用到集群,**VPA 观察到的是无 limit 状态下的行为**,推荐值需重新积累。
- [ ] **Debezium 用的是 Alpha 版**。3.7.0.Alpha1 若要承载重要 CDC 数据,建议换成 3.6.1.Final(同样自带 4.3.0,与当前 Connect 运行时匹配)。
- [ ] **其余 12 个 registry 的 mirror 仍未生效**。node 上 `certs.d` 里 docker.io、ghcr.io、registry.k8s.io、docker.elastic.co 等的 `hosts.toml` 实测均未起作用(containerd 仍直连源站),本次只修了 quay.io。上面「镜像拉取异常缓慢」提到的 Kibana 拉取慢就属于 `docker.elastic.co` 这一类。

### 已知风险

- [ ] **metadataVersion 已单向提升至 4.3-IV0,无法降回 4.2**。本次因明确不需要保留数据而一步到位;**后续同类升级建议分两步** —— 先只改 `version`(此时仍可回退),观察稳定后再提 `metadataVersion`。
- [ ] **broker 被 PVC 钉在 node3**。`openebs-lvmpv` 是节点本地卷,`my-cluster-dual-role-0` 换不了节点,而 node3 内存 requests 已占 86%。与 jaeger/loki 是同类问题。
- [ ] **node1 已被 untaint,控制平面节点会持续接收普通负载**。这是为了给 build pod 腾地方而做的,但副作用是后续所有工作负载都可能调度上去。需确认这是否是想要的长期状态。
- [ ] **集群存在广泛的重启异常,与本次工作无关**:`entity-operator` 155 次、`openebs-lvm-localpv-controller` 146 次、`strimzi-cluster-operator` 36 次(升级前)、`kafka-ui` 32 次。这个频率不正常,值得单独排查。

---

## 2026-08-06 · 仓库入口与开源协作文档

- [x] 根 `README.md` 已按现有目录和当前 Jaeger / Gateway / OpenTelemetry 部署基线重写为中文入口。
- [x] 已补充贡献指南与安全策略，明确凭据禁止入库、配置说明和安全问题报告方式。
- [ ] 新增或调整组件的实际部署方式时，仍需同步更新根 README、组件 README 和本文件中的部署事实。

## 2026-08-06 · Jaeger 去 Elasticsearch 化 + 失效网关配置清理

### 背景

Jaeger 原先以 Elasticsearch 为 trace 后端。该依赖带来三个实际问题:ES 不可用时 jaeger 跟着退出(pod 累计重启 **112 次**,`exitCode 1`);单节点 ES 上 jaeger 索引产生 50 个永远无法分配的副本分片(占集群 56 个 unassigned 的绝大部分);values 里硬编码了两处明文 ES 密码。

目标是解除 jaeger 对 ES 的依赖。**ES 本身继续保留** —— 其中还有 `ecommerce_orders_*`、`ecommerce_products_*` 业务索引和 Kibana。

### 集群变更

| 操作 | 对象 |
|---|---|
| 卸载 | Helm release `jaeger`(chart `jaeger-4.11.0`)@ `observability` |
| 新建 | ServiceAccount / PVC(`jaeger-badger` 5Gi)/ ConfigMap(`jaeger-config`)/ Deployment / Service |
| 删除 | GRPCRoute `jaeger-grpc-route` @ `observability`(55 天从未生效) |
| 删除 | ES 中 10 个 `ecommerce-jaeger-*` 索引 |

存储后端改为 badger(节点本地 PVC),`ttl.spans: 168h` 对齐原 `esIndexCleaner.numberOfDays: 7`。随 Helm 卸载一并消失的还有 `jaeger-es-index-cleaner` CronJob。

**对外行为保持一致**:Service 名、14 个端口(名称/端口号/appProtocol)、receivers(otlp、jaeger、zipkin)、processors、pipeline、`:8888` 自身指标端点全部逐字未变,otel-collector 与所有路由无需改动。唯一变化是 ClusterIP 重新分配(`10.100.15.3` → `10.109.117.7`),消费方均走 DNS 或 backendRef 名称,不受影响。

ES 中 7 天约 17MB 的历史 trace 已确认无需保留,未做迁移。

### 验证结果

- `install.sh` 三条断言全过:PVC 已挂载 / 后端为 badger 且日志无 ES / Service 端口数为 14
- 端到端:经真实链路 otel-collector → jaeger 打入 trace,再按 traceId 查回成功
- **重启后数据仍在**:`rollout restart` 后 Pod 换名,同一 traceId 依然查得到
- HTTPRoute `jaeger-ui-route` / `jaeger-http-route` 在 Service 重建后仍为 `Accepted` + `ResolvedRefs=True`
- 日志中 error/warn 计数为 0;迁移后运行至今 0 重启
- ES unassigned 分片 **56 → 6**,6 个业务索引完好无损

配置正确性用反证法确认过:故意插入不存在的 key,jaeger 报 `has invalid keys`,证明解析是严格的 —— 因此 `ttl.spans` 是被真正识别的配置项,而非被静默忽略。

### 为什么放弃 Helm

chart 4.11.0 的 Deployment 模板没有 `extraVolumes` / `extraVolumeMounts` 钩子,badger 挂 PVC 只能靠 post-renderer 绕过。实测该路线代价过高:

- node101 是 **Helm v4**,`--post-renderer` 不再接受可执行文件路径,只认 `postrenderer/v1` 插件(机器本地状态,不在仓库里)
- **漏加 `--post-renderer` 会静默丢失持久化**:实测带参数安装时 PVC 挂载数为 1,升级时漏掉参数后 `helm upgrade` 依然成功退出、Pod 照常 Ready,挂载数变成 0,badger 转写容器可写层,全程无任何报错
- **kustomize patch 目标匹配不到时同样静默 no-op**(helm 退出 0、渲染 347 行、patch 内容 0 处),而该 chart 的 NOTES 自称 `EXPERIMENTAL`,资源命名一变 patch 就无声失效

为一份可丢弃的 trace 数据引入两种静默降级故障模式,不划算。

### 仓库变更

```
jaeger/
  + README.md                          目录说明 + 变更记录
  + manifests/                         01-sa / 02-pvc / 03-cm / 04-deploy / 05-svc
                                       + install.sh(含 3 条硬断言)+ README.md
  ~ helm/ → gateway/                   Helm 废弃后其中只剩 Route 清单,更名
  - helm/install.sh                    危险:再次执行会用 ES 装一个 helm release 与现有 Deployment 打架
  - helm/memory.yaml                   旧版 v1 chart 的 values,与 4.x 结构不兼容
  - helm/examples/jaeger-trace-to-es-store.yml
  - helm/{grpc-route,gateway,certificate}.yml   失效的 observability-gateway 三件套
  - helm/gateway.sh                    创建的 elastic-gateway / jaeger-route 均不存在,
                                       且会与现有 jaeger-ui-route 撞域名

opentelemetry/server/helm/collector/examples/
  ~ configs/jaeger-es-loki-vm.yml → jaeger-loki-vm.yml    名字里的 es 已不成立
  - gateway/{gateway,certificate,root-ca,issuer}.yml      整条自签 CA 链从未 apply
  - gateway/get-tls.sh                                    要读的 Secret 不存在,必然报错

elastic-stack/
  - 02-gateway.sh                      见下
  - examples/gateway.yml               elastic-gateway HTTP:80,集群中不存在
  - examples/tls/tls-gateway.yml       elastic-gateway HTTPS:443,同上
  - examples/tls/certificate.yml       引用的 ClusterIssuer selfsigned-issuer 不存在
  ~ examples/kibana-httproute.yml      校正为与线上 kibana-https-route 一致
```

otel-collector 的配置**无需功能性改动** —— 它只与 Jaeger 的 Service 通信,不接触存储后端。只改了文件名和一处注释。

`elastic-stack/02-gateway.sh` 除失效外还有三处会造成实际损害:生成 `es-gateway.yml` 却 `apply -f gateway.yml`;创建的 `elasticsearch-route` 与线上同名同命名空间但 parentRef 指向不存在的网关,跑一次就会打断 `es.dev.test` 的外部访问;还会把 `es-httproute.yml` / `kibana-httproute.yml` 覆盖写到当前目录。

---

## 待办

### 需要验证

- [ ] **真实应用链路未验证**。`ecommerce` 命名空间当前为空(无任何工作负载),迁移后只用合成 trace 验证过。应用恢复后需重新确认业务 trace 能正常写入并查询。
- [ ] **badger TTL 未经时间验证**。`ttl.spans: 168h` 的配置有效性已确认,但"7 天后旧数据确实被清除"需运行满一周后核对 PVC 用量(`kubectl exec deploy/jaeger -- du -sh /badger`)。

### 已知风险

- [ ] **jaeger 被 PVC 钉在单个节点**。`openebs-lvmpv` 是节点本地卷 + `WaitForFirstConsumer`,该节点故障时 Pod 无法漂移。这是换取持久化的代价;trace 属可丢数据,当前判断为可接受,但需要知情。
- [ ] **改 ConfigMap 后必须手动重启**,不再有 Helm 的 checksum 注解自动触发:
      `kubectl rollout restart deployment/jaeger -n observability`。
      可考虑加 checksum 注解或改用 kustomize 的 configMapGenerator。

### 遗留失效配置

- [ ] **`opentelemetry/server/helm/config-otel-collector.sh` 已失效**。它引用 `jaeger-collector.<ns>.svc.cluster.local:4317/4318`,集群中不存在该 Service(只有 `jaeger`)。待修正或删除。
- [ ] **`jaeger/test/grpc/main.go` 指向不存在的端点**。目标为 `otlp-grpc.dev.test:443`,该域名无任何路由。改指 `otel-collector` 的 LoadBalancer(`192.168.3.117:4317`),或补一条路由。
- [ ] **`jaeger/gateway/examples/rbac.yml` 位置不当**。内容是 otel-collector 的 ClusterRole/Binding,与 jaeger 无关,宜移至 opentelemetry 目录下。

### 待决策

- [ ] **ES 集群仍为 yellow**。清理 jaeger 索引后剩 6 个 unassigned,来自 6 个业务索引的副本分片 —— 单节点 ES 无处安放。需决定:把业务索引 `number_of_replicas` 设为 0,或给 ES 加节点。这是 ES 自身的单节点配置问题,与 jaeger 无关。
- [ ] **elastic-stack 的 TLS 方案已随清理移除**。目前 ES / Kibana 仅通过 `cilium-gateway` 的 HTTP listener 暴露(`es.dev.test`、`kibana.dev.test`)。若需要 TLS,需重新规划 —— 原先那套 `elastic-gateway` + 自签证书从未生效过,不要直接照抄。

### 环境观察

- [x] ~~**镜像拉取异常缓慢**。两次独立观察:`curlimages/curl` 在 node3 上超过 5 分钟未拉完;Kibana 滚动更新的新 Pod 在 node2 拉取 `docker.elastic.co/kibana/kibana:9.4.0` 时长时间停留在 `Init:0/1`(无报错事件,纯粹是拉取中)。可能值得排查 registry 连通性或配置镜像加速。~~ **2026-08-06 已定位并解决 quay.io 部分**,见下方「quay.io 镜像加速」条目。`docker.elastic.co` 尚未处理,同样的手法可以照搬。

---

## 2026-08-06 · 可观测性「统一关联底座」评审:基础设施侧待办

### 背景

配套的 ecommerce 仓做了一轮「五维(指标/日志/链路/事件/变更)统一采集·存储·查看·分析」目标达成度的对抗评审(集群实测 + 双模型,全文 `ecommerce/observability/OBSERVABILITY_REVIEW_20260806.md`),其中若干缺陷的根因在**本仓的部署清单**,归到这里。凡涉及集群地址/内部域名/凭据的,均按 `SECURITY.md` 只写文件路径、不复述敏感值。

### 需要修复 · 安全(P0)

- [x] ~~**fluent-bit 手机号脱敏是空操作 + `Keep_Log On` 保留原始明文(PII 泄漏)**。~~ **2026-08-18 已修复**：正式组件改用 Lua 支持的逐位模式，并配置 `Merge_Log On` + `Keep_Log Off`，不再把未脱敏的原始 `log` 字段一并发送到 Loki。
- [x] ~~**脱敏只匹配顶层 `email`/`phone` 两个键**。~~ **2026-08-18 已修复已知值模式**：新 Lua 过滤器递归扫描嵌套 table 中的所有字符串值，统一遮蔽邮箱与 11 位手机号。它不是完整的 DLP 方案，bearer token、银行卡号和业务专有标识仍需按数据分类继续补规则。
- [ ] **对象存储凭据明文入库,违反本仓 `SECURITY.md`**。两处泄漏:①MinIO **root** 凭据明文写在 `minio/yaml/single.yaml:60-63`(`MINIO_ROOT_USER=admin` / `MINIO_ROOT_PASSWORD=<REDACTED-20260817>`,env value);②loki 用的 **S3 access key** 明文散落 4 处——`loki/helm/other/install.sh:43,49,51`、`loki/helm/other/new-values.yaml`、`loki/helm/monolithic mode/install.sh:84-85`、`loki/helm/monolithic mode/examples/minio-values.yml`(值不在此复述)。线上是 `single.yaml` 单副本(minio ns,`deployment/minio`,image `pgsty/minio`,S3 端点 `minio-service.minio.svc:9000`),loki-0 是 monolithic 版、实际用 `install.sh:84-85` 那把 key。按 `SECURITY.md`「凭据泄露处置」——**删文件或补一次「删密码」提交都不足以撤销,旧凭据必须先在 MinIO 侧失效**。执行步骤:

  轮换 + 改 Secret 引用 runbook(逐条勾):

  - [ ] **0. 确认范围**:root(single.yaml)与 S3 key(loki 4 文件)都要换;先确认 loki-0 实际读的是 monolithic 那把(`A3Uh…`),`other/` 那份 key 若无工作负载引用则只作历史泄漏处理。
  - [ ] **1. 进 mc**:`kubectl -n minio run mc --rm -it --image=minio/mc --restart=Never -- sh`,进去后 `mc alias set m http://minio-service.minio.svc:9000 admin <REDACTED-20260817>`(用旧 root 临时登录;或用 console :9090)。
  - [ ] **2. 为 loki 建最小权限账户**:只授 loki bucket 的读写,而非拿 root 当 S3 key。先写一份仅含 `s3:*` on `arn:aws:s3:::loki/*` + `arn:aws:s3:::loki` 的 policy(`mc admin policy create m loki-rw ./loki-rw.json`),再 `mc admin user svcacct add --access-key <新AK> --secret-key <新SK> m admin`(服务账户)或 `mc admin user add m <新AK> <新SK>` + `mc admin policy attach m loki-rw --user <新AK>`。记下新 AK/SK。
  - [ ] **3. 轮换 root**:新建 `minio-root` Secret(`kubectl -n minio create secret generic minio-root --from-literal=MINIO_ROOT_USER=<新root> --from-literal=MINIO_ROOT_PASSWORD=<新强口令≥16位>`),把 `single.yaml:60-63` 的两个 env 改成 `valueFrom.secretKeyRef` 指向它,`kubectl apply` 后 `kubectl -n minio rollout restart deploy/minio`。(pgsty/minio 的 root 来自 env,重启即生效;若已存在其它数据请先确认重启不影响。)
  - [ ] **4. 建 loki 的 S3 Secret**:`kubectl -n loki create secret generic loki-s3 --from-literal=AWS_ACCESS_KEY_ID=<新AK> --from-literal=AWS_SECRET_ACCESS_KEY=<新SK>`。
  - [ ] **5. 改 Loki values 去内联**:删掉 `loki-monolithic-mode-values.yml`(即 `monolithic mode/install.sh` heredoc 写出的那份)里 s3 段的 `accessKeyId`/`secretAccessKey` 两行,改由环境变量注入——`loki.storage.s3` 只留 `endpoint`/`bucketnames`/`s3ForcePathStyle`,并加 `loki.extraEnvFrom: [{secretRef: {name: loki-s3}}]`。Loki 的 S3 SDK 会自动读 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env;若坚持在 config 里写 `${AWS_ACCESS_KEY_ID}` 占位,则必须给容器加 `-config.expand-env=true`(`loki.extraArgs`),否则 `${VAR}` 不展开会当字面量。
  - [ ] **6. 上线并验证**:`helm upgrade` loki + `kubectl -n loki rollout restart statefulset/loki`;写一条日志→按标签查回;`kubectl -n loki logs loki-0 | grep -Ei 'AccessDenied|SignatureDoesNotMatch|InvalidAccessKeyId'` 应为空。
  - [ ] **7. 停用旧凭据**:回 mc `mc admin user svcacct rm m <旧AK>` 或 `mc admin user remove m <旧AK>`,并确认旧 root(`admin/<REDACTED-20260817>`)已随第 3 步重启失效;再观察 loki 仍正常写读。
  - [ ] **8. 清仓库为占位符**:把上述 5 个文件(single.yaml + loki 4 文件)里的真实值全改成 `<SET_VIA_SECRET>` 之类占位,并在各自 README/注释里写明「凭据经 Secret 注入,勿写真值」。
  - [ ] **9. 历史撤销评估**:旧凭据已在第 7 步失效即为主要缓解;若本仓推到公开远端,按 `SECURITY.md` 评估是否 `git filter-repo` 重写历史清除 `A3Uh…`/`z4mY…`/`<REDACTED-20260817>` 等串,否则依赖「已轮换失效」。
- [ ] **遥测端点是否匿名可达需核实(PLAUSIBLE)**。`victoriametrics/single/httproute.yaml`、`jaeger/gateway/*.yml`、`loki/**`、`grafana/helm/httproute.yaml`、`kafka/kafka-ui/**`、`minio/**` 均有 Gateway API 路由。VM-single / Jaeger 默认无鉴权,若网关前未挂 AuthorizationPolicy/认证,LAN 客户端即可查询敏感日志或伪造 metric/log/trace 撑爆存储。`SECURITY.md` 已明确「不要因为示例方便而开放匿名管理接口」,需逐条确认这些路由前是否有认证。

### 管道缺陷

- [x] ~~**fluent-bit k8s 标签失效，日志无法按 pod 下钻**。~~ **2026-08-18 已修复**：正式组件直接使用 `$kubernetes['namespace_name']` 等嵌套 record accessor；namespace/container 作为低基数 Loki 标签，pod/node 写入 Loki 3 structured metadata，避免把 pod 名提升为索引标签。
- [x] ~~**fluent-bit 只采日志、不采指标，与文档「采集应用和系统指标」不符**。~~ **2026-08-18 已澄清职责**：Fluent Bit 仅采集 Kubernetes 容器日志，节点指标继续由既有 OTel Collector `host_metrics` receiver 采集，避免同一指标重复入库。
- [ ] **collector 自监控无人抓,「遥测有没有半路丢」无法回答**。`opentelemetry/server/helm/collector/examples/configs/jaeger-loki-vm.yml` 里 collector 的 `:8888` self-telemetry 是 Prometheus pull,但没有任何 receiver 采它。补 `prometheus` receiver 自采 `127.0.0.1:8888`,基础设施盘补 accepted/sent/send_failed + 队列深度。(与 ecommerce TODO §234 对应,配置改动在本仓。)
- [ ] **fluent-bit 在事故时仍可能静默丢弃超长日志**。**2026-08-18 已完成部分缓解**：移除全局 throttle，启用 hostPath 文件系统缓冲、2 GiB 队列和无限输出重试，并暴露 Fluent Bit Prometheus 指标。为防止单行撑爆内存，超过 2 MiB 的日志仍会由 `Skip_Long_Lines On` 跳过；后续需为该边界补告警或 dead-letter，并完成上一条 collector 自监控。

### 已知风险

- [ ] **可观测存储栈无生产级 HA**。VictoriaMetrics(`victoriametrics/single/`,single + 本地 PV)、Loki(single-binary)、Grafana 均单副本;Jaeger 单副本 + badger 本地盘(已在上文「jaeger 被 PVC 钉在单节点」记过)。承载卷的节点故障时 Pod 无法带数据漂移——恰在需要诊断时丢 trace/metric。需评估各自的多副本/远端存储路径(VM cluster 版、Loki 分布式 + 对象存储、Grafana 多副本 + 外部 DB)。
- [ ] **整个可观测栈在 imperative `install.sh` 里,未纳 GitOps**。collector/fluent-bit/loki/VM/jaeger/grafana 全靠脚本 `helm upgrade`,loki 的 values 还在节点上手改过、fluent-bit 镜像曾被 `kubectl patch` 后又被 `helm upgrade` 冲回(造成约 4 分钟采集中断)。与 ecommerce 应用走 ArgoCD 不一致,漂移无人对账。评估把这些纳入 argo 或至少让 values 成为唯一事实源。

### 待决策

- [ ] **事件/变更两维目前无采集组件**。集群无 kube-state-metrics、无 k8s event exporter,Kubernetes 事件、Pod 状态、部署变更都进不了数据面。是否在本仓补 `k8s_cluster`/`k8s_events` receiver 或独立 event-exporter,与 ecommerce TODO §235「k8s 视角」一并规划(注意基数控制别带 pod 名、DaemonSet 下 `k8s_cluster` 要配 leader elector)。

---

## 2026-08-18 · Harbor ARM64 发布阻塞

- [ ] **等待 Harbor 官方 v2.16.0 ARM64 release 后再启用组件**。两台节点都是 ARM64；实测官方
  `v2.15.2` 镜像启动即报 `exec format error`。Harbor 维护者在
  [#23558](https://github.com/goharbor/harbor/issues/23558) 和
  [#23674](https://github.com/goharbor/harbor/issues/23674) 确认 ARM64 从 v2.16.0 开始发布。
  已卸载失败 release、删除外部路由并保留五个 PVC、管理员 Secret、加密 Secret 与节点凭据；
  `ADDON_HARBOR=false`，安装脚本会在任何集群写操作前检查 chart `appVersion` 和节点架构。
