# 边缘核心迁移记录：node1 → node3（2026-11-12/13）

## 结论

apikv.com 边缘核心已**全量迁移**到 node3（`193.112.22.183` / 内网 `10.1.4.10` / 实例 `lhins-883j0dy9`）。
node1（`114.132.233.129` / `10.1.0.8`）所有业务容器已停服并保留数据，作为 15 分钟内的回滚目标。

割接耗时约 20 分钟（23:47 开始准备 → 00:26 全部 newt 重连完成），实际业务中断窗口
**约 6 分钟**（00:20 停 node1 → 00:26 全站恢复）。

## 最终版本矩阵（割接时全部升到 latest）

| 组件 | node1 原版本 | node3 现版本 | 说明 |
|---|---|---|---|
| Pangolin | 1.26.0 | **1.26.0**（latest） | latest 就是 1.26.0，无 schema 迁移 |
| Gerbil | 1.6.0 | **1.6.0**（latest） | latest 就是 1.6.0 |
| Traefik | v3.7.17 | **v3.7.18**（latest） | +1 补丁版 |
| CrowdSec | v1.8.1 | **v1.8.2**（latest） | +1 补丁版 |
| ntfy | v2.11.0 | **2.37.2**（latest） | 跨大跨度升级，配置文件兼容 |
| Casdoor | latest | latest（a0499a9） | — |
| PostgreSQL | 18-alpine | 18-alpine | 同主版本，pg_dumpall 迁移 |
| SafeLine | 9.4.2 | 9.4.2 | 厂商镜像无 latest 语义，保持原版本 |
| Badger 插件 | v1.8.0（远程） | **v1.8.0（本地插件）** | 上游最新即 1.8.0，改为 vendor 本地 |

## 关键决策

### 1. Badger 改为本地插件（根治历史 404 坑）

历史事故：Traefik 启动时从 GitHub 拉 badger 插件 zip + Go 依赖失败 → 全部路由 404。

node3 直连 GitHub 返回 `000`（完全不通），ghfast.top 也 403。做法：

- 从 node1 运行中的 traefik 容器 `docker cp` 出 `/plugins-storage/archives/github.com/fosrl/badger/v1.8.0.zip`
- 解压到 `config/traefik/plugins-local/src/github.com/fosrl/badger/`
- 改 `traefik_config.yml`：badger 从 `experimental.plugins`（远程）移到 `experimental.localPlugins`
- badger 的 `go.mod` 只有 `module` + `go 1.25`，**零外部依赖**，可完全离线编译

验证：`Plugins loaded. plugins=["badger","crowdsec","safeline"]`

### 2. 网络子网必须与 node1 逐一对齐

`casdoor` 的 `extra_hosts: pg.apikv.com:172.18.0.1` 和 `webhook` 的 `172.20.0.1` 是硬编码网关 IP。
Docker 按创建顺序自动分配子网（首次建成了 172.18/19/21/22，全错），必须显式 `--subnet`。

对齐表（两机一致）：

| 网络 | 子网 |
|---|---|
| pangolin_frontend | 172.25.0.0/16 |
| vault_backend | 10.66.0.0/24 |
| ecommerce | 172.31.0.0/16 |
| ntfy_default | 172.29.0.0/16 |
| casdoor_default | 172.18.0.0/16 |
| postgres_default | 172.19.0.0/16 |
| webhook_default | 172.20.0.0/16 |
| redis_default | 172.27.0.0/16 |
| safeline-ce | 172.16.231.0/24（compose 自建，含固定 bridge name） |

`safeline-ce` 不要预建——compose 里有 ipam 和 `com.docker.network.bridge.name`，预建会冲突。

### 3. 只有 3 个 target 绑定 node1 本机

`targets` 表里 `ip=10.1.0.8` 的仅 3 条（ntfy:8080、stream:8889、casdoor:8000），
全部改为 `10.1.4.10`。其余 45 条走 k8s 隧道（10.10.31.x）或各机 newt，与服务端位置无关。

改法（停机窗口内、pangolin 停止时）：直接 SQLite `update targets set ip='10.1.4.10' where ip='10.1.0.8'`。

### 4. 私有 TCR 镜像 node3 无拉取权限

`ccr.ccs.tencentyun.com/sumery/*` 在 node3 报 `not found`（TCR 按 VPC/白名单放通，node3 不在内）。
改用内网 `docker save | ssh | docker load` 流式传输，5 个镜像全部成功。

### 5. DNSPod 免费版最低 TTL = 600s

`ModifyRecordBatch` 把 TTL 改成 60 **静默失败**（返回 success 但值仍是 600），因为账户是 `DP_FREE`。
600 秒可接受：割接后最多 10 分钟全球生效。

各主机 systemd-resolved 有本地缓存，割接后需 `resolvectl flush-caches` 加速。

## 迁移了哪些东西

**容器（24 个，node1 是 25 个，差 safeline-tengine —— 它按 compose.override 的 `profiles: ["disabled"]` 本就不该启动）**

- Pangolin 四件套：pangolin / gerbil / traefik / crowdsec
- SafeLine 六件套：pg / mgt / detector / luigi / fvm / chaos
- 认证数据：casdoor / postgres / webhook / ntfy / redis-gorse
- 站点：apikv-site / lyrapass-site / mcm-site / homepage / blog / blog-reminder
- Scorpius：licensed / licensed-backup / scorpius-web

**数据**

- Pangolin `db.sqlite`：447MB，`sqlite3.backup()` 一致性快照（`pragma integrity_check` = ok，12 站点 / 46 资源 / 48 目标）
- `config/` 全量：`key`（Gerbil 私钥）、`traefik/certs`（通配符证书，有效至 2027-02-04）、`crowdsec/etc` + `crowdsec/data`、`plugins-local`
- PostgreSQL：`pg_dumpall` ×2（业务库 9.9M / 3 库，含 casdoor 49 表 12 用户）
- SafeLine：`/data/safeline` 整体（含 detector 规则库、pg 数据）
- Docker 卷：`scorpius-license_licensed-data`、`licensed-backups`、`blog_reminder_data`

## 割接开关：3 条 A 记录

| 记录 | RecordId | 值 |
|---|---|---|
| `@` | 2280229689 | 193.112.22.183 |
| `*` | 2363487941 | 193.112.22.183 |
| `auth` | 2300445933 | 193.112.22.183 |

全部客户端（11 个 newt、Gerbil `base_endpoint`、各机 CrowdSec bouncer）都用域名，改记录即整体切换。

**不动**：10 条 EdgeOne CNAME（blog/ecommerce/sumery/libra/pale 等，不经 Pangolin）、`img` A 记录、NS/TXT/MX、`qqbot`（DISABLE）。

## 验收结果

| 检查项 | 结果 |
|---|---|
| Traefik 插件 | `Plugins loaded. plugins=["badger","crowdsec","safeline"]` ✅ |
| 路由数 | 98 条，全 enabled ✅ |
| 通配符证书 | 有效至 2027-02-04，直接拷贝可用 ✅ |
| WAF 拦截 | `shop.apikv.com/.git/config` → 403 ✅ |
| WAF fail-open | broken pipe 仅重启瞬间 2 次，60 秒 delta=0 ✅ |
| SafeLine PoolSize | 8（11-10 补丁已带过来）✅ |
| newt 重连 | 8/8 全部 `Tunnel connection established` + `Server version: 1.26.0` ✅ |
| 站点在线 | 10/12 online（`mac` 按既有策略忽略、`Windows` 长期离线）✅ |
| 容器重启/OOM | 全 0 ✅ |
| 内存 | 1.7G / 3.7G，swap 650M / 2G ✅ |
| 磁盘 | 33G / 59G（58%）✅ |

域名验收（公网打 node3）：

```
apikv.com            200      pangolin.apikv.com   200
casdoor.apikv.com    200      ntfy.apikv.com       200
lyrapass.apikv.com   200      shop.apikv.com       200
scorpius.apikv.com   200      config.apikv.com     200
d.apikv.com          401(SSO 墙，预期)
config-api.apikv.com 401(根路径预期) /healthz 200
gateway.apikv.com    404(根路径预期) /readyz 200
blog.apikv.com       404(EdgeOne CNAME，不经 Pangolin)
mcm.apikv.com        404(业务已退役，10-28 起即如此)
```

## 云侧变更

**node3 防火墙**（`CreateFirewallRules`，版本 3 → 4，2 条 → 9 条）

新增 7 条入站：TCP 80/443、UDP 443（QUIC）、UDP 51820/21820（Gerbil）、TCP 30001/30002/30004/30005、UDP 30003。
保留原有 TCP 34125（SSH）、ICMP。

**未开放**（保持最小权限）：52288（postgres）、61246（redis）、8189、9443（SafeLine 控制台，仅 127.0.0.1）、65443。

**DNS**：3 条 A 记录值改为 193.112.22.183（TTL 仍 600s，免费版下限）。

## node1 当前状态（回滚备份）

- 所有业务容器 `exited`（`restart: unless-stopped` + 显式 stop，不会自动拉起）
- `host-watchdog.timer`：**stop + disable**（监控对象已迁走，留着只会误报）
- `compose-stacks.service`：**disabled**（否则 node1 重启会把栈全部拉回来抢 80/443）
- `docker-port-guard.service`：**disabled**（服务对象端口已迁走）
- 监听端口：只剩 DHCP，80/443 全释放
- 数据完整保留：`/home/docker/pangolin/config/db/db.sqlite`、pg 卷、`/data/safeline`
- 备份目录：`/root/migration-backup-20261112/`（db.sqlite 447M、db-final.sqlite、pg-all.sql、pg-final.sql、safeline-pg.sql、各目录 tgz）

## 回滚步骤（15 分钟内）

```bash
# 1. DNS 改回
dnspod ModifyRecordBatch: RecordIdList=[2280229689,2363487941,2300445933], Change=value, ChangeTo=114.132.233.129

# 2. node1 恢复自启单元
systemctl enable --now compose-stacks.service docker-port-guard.service host-watchdog.timer

# 3. node1 拉起全部栈
for d in /home/docker/{pangolin,casdoor,casdoor/webhook,ntfy,redis,postgres,apikv-site,lyrapass-site,mcm-site,homepage,blog} /data/safeline /opt/scorpius-license; do (cd $d && docker compose up -d); done
docker start safeline-tengine

# 4. node3 停服
for d in ...; do (cd $d && docker compose stop); done

# 5. 各机 flush DNS
resolvectl flush-caches
```

**回滚会丢**：割接后（00:20 起）在 node3 面板做的配置变更、新增的审计日志。
node1 的 DB 停在 00:18 快照，pg 停在 00:18 的 `pg-final.sql`。

## 遗留事项

1. **`stream` 资源是僵尸**：`stream.apikv.com` → `10.1.4.10:8889`，但该端口无任何进程监听（node1 时代就没有）。
   照原样迁移，未新增故障。建议后续在面板删除或在退役检查中处理。
2. **`密码管理` 资源指向不存在的 `vaultwarden:80`**：同为僵尸，未在窗口内删除（避免混入割接变量）。
3. **mcm-site**：容器在跑但业务 404（10-28 起），watchdog 只查进程存活所以绿灯，属覆盖盲区。
4. **node3 自身 newt（站点 15）自环**：割接后连本机，已验证正常（`Tunnel connection established`），
   但 hairpin 路径依赖公网回环，需观察。
5. **内存偏紧**：3.7G 上跑 24 容器，峰值 1.7G + swap 650M。当前健康，但如果 SafeLine 规则库增长
   或流量峰值上来，建议升配到 4C/8G（`bundle_starter_mc_lg8_01`）。
6. **CrowdSec 中心 LAPI 在 node3 容器内**，node1 的主机级 `crowdsec` 服务本来就不存在
   （node1 的 agent 一直跑在容器里，主机上只有 firewall bouncer）。node1 的 bouncer 已从
   `http://127.0.0.1:18080/` 改为 `https://crowdsec.apikv.com/`，详见下节。
7. **`siteId=1` 站点名仍叫 `node1-local`**：其 `type=local`（不经 newt，由边缘主机直连），
   语义已随边缘一起搬到 node3，改名只是显示问题，未在割接后动 live DB。

---

## 割接后收尾（2026-11-13 00:30–00:45 CST）

### 1. node1 CrowdSec firewall bouncer 改指中心 LAPI

割接后实测发现 node1 的 bouncer 仍指向已停的本地容器：`api_url: http://127.0.0.1:18080/`，
该端口在 node1 上已 `CLOSED`，bouncer 处于「跑着但什么都拿不到」的假活状态。

先验证 key 是否随 DB 迁移可用（`node1-fw` 记录 `valid=True`）：

```
curl -H "X-Api-Key: 4b1983be…07115" https://crowdsec.apikv.com/v1/decisions
→ 200，tls_verify=0，返回真实决策
```

确认可用后修改并重启：

```bash
F=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
cp -a "$F" "$F.bak-before-central-lapi-20261112"
sed -i 's|^api_url: http://127.0.0.1:18080/|api_url: https://crowdsec.apikv.com/|' "$F"
systemctl restart crowdsec-firewall-bouncer
```

结果（`/var/log/crowdsec-firewall-bouncer.log`，`NRestarts=0`）：

```
Created set and rule for origin CAPI / crowdsec (ipv4_addr + ipv6_addr) in chain crowdsec-chain-input / -forward
14769 decisions added
1409 decisions deleted
```

即 node1 现在与中心共享同一份封禁名单（原来只有本地 1409 条）。**注意 `mode: nftables` 下
bouncer 会重建 `table ip crowdsec`**，重启瞬间 old 表被移除属正常。

### 2. bouncer 列表里的「重复条目」不是脏数据，不要删

`cscli bouncers list` 里每个 bouncer 都有一条 `name@172.25.0.5` 的孪生记录：

```
node1-fw       172.25.0.1  auto_created=False   （持有 api key，创建于 2026-09-28）
node1-fw@172.25.0.5  172.25.0.5  auto_created=True  （本次连接自动生成）
```

- 原因是**所有 bouncer 都经 traefik 反代到达 LAPI**，源 IP 统一成 traefik 容器 IP，
  LAPI 按「名字 + 源 IP」匹配不上就自动登记别名（`auto_created=True`）。
- 时间戳是 UTC：`16:37Z` = 本地 `00:37`，正是改完 bouncer 的时刻。
- **两条都不能删**：无后缀那条才是 key 的持有者，删掉等于吊销该主机凭据；
  带 `@IP` 的删了下次轮询会重建。属 CrowdSec 在反代后方的正常行为，记录在案即可。

### 3. 冒烟结果与两个「像故障但不是」的状态

41 个启用域名全量探测：14×200、3×302（登录跳转）、13×401（SSO/API 鉴权墙）、
2×403、3×404、5×502。

**`crowdsec.apikv.com/health` → 403 不是故障**：该路由挂了 `crowdsec-lapi-allowlist`
（`ipAllowList`，只放行 114.132.233.129 / 115.159.84.100 / 8.138.194.254 / 193.112.22.183 /
211.144.221.226）。从名单外访问时 Traefik 的 ipAllowList 返回 9 字节纯文本 `Forbidden`。
node1 在名单内，所以它能 200 拉决策；本机直连 `crowdsec:8080/health` 也是 200 `{"status":"up"}`。

**`auth.apikv.com` → 404 不是迁移回归**：node1 与 node3 的 `dynamic_config.yml`
md5 完全一致（`e9800f83b6c19c5ce94715ba28571fca`），两边都没有 `auth.apikv.com` 的 router，
Pangolin resources 里也没有该域名 → Traefik 无路由时返回 Go 默认的 `404 page not found`。
casdoor 的实际入口是 **`casdoor.apikv.com`**（→ `10.1.4.10:8000`，200）。
`auth` 这条 A 记录可以删，或补一个 resource 指向 casdoor。

**5 个 502 逐个定性，无一为迁移回归**——`targets.siteId` 说明 `127.0.0.1` 是「该站点的
localhost」，不是边缘主机的 localhost：

| 域名 | siteId | 实际指向 | 结论 |
|---|---|---|---|
| `cat` / `getcat` | 6 = mac | Mac 本机 9528 / 9730 | 开发服务未启动 |
| `pdapi` / `pdsink` | 19 = Windows | 该站点 `online=0` | 机器长期离线 |
| `stream` | 1 = local | 8889 无进程 | 已知僵尸（node1 时代即如此） |
| `minio`（403） | 5 = node2 | node2 的 Silo `:9000` | S3 匿名根目录 `AccessDenied`，正常 |

`siteId=1` 是 `type=local`（不经 newt、由边缘主机直连），所以 casdoor/ntfy 从 node3 直连
`10.1.4.10` 是正常路径，**没有绕回 node1 的 hairpin**。`node1` 的 newt 仍在线但不承载这 3 个 target。

### 4. 收尾命令留档

```bash
# node1：确认真静默
docker ps --format '{{.Names}}'          # 空
ss -lntp | grep -E ':(80|443)\b'         # 空
systemctl is-enabled compose-stacks docker-port-guard   # disabled
systemctl is-active crowdsec-firewall-bouncer           # active（只留这一个）
```

### 5. 证书链（续期 + 分发）迁到 node3 —— 原链路有两个断点

证书是 `*.apikv.com` 通配符，有效至 **2027-02-04**，ZeroSSL 签发，`acme.sh` 用
**DNSPod DNS-01**（`Le_Webroot=dns_dp`）验证——**不依赖 80/443**，所以 node1 释放端口后
续期本身不会失败。但检查发现两个真问题：

1. **`apikv-cert-distribute` 从来没有被自动调用**。`crontab`、`/etc/cron.d`、
   `/usr/local/lib` 里都没有引用，`apikv-cert-renew` 也只是定义了 `MARKER` 变量却从不执行它。
   也就是说 2026-11-07 那次分发是**手工**跑的。只搬脚本不改这里，等于搬了个死代码。
2. **`send_node2` 是空转**。node2 上既无 blog 容器也无 `/home/docker/blog` 目录，
   而且 node3 → node2:34124 不通（node2 只放行 node1）。在 `set -e` 下保留这一步，
   会让整条分发必然失败并触发 rollback。

迁移动作：

```bash
# node1 -> node3（3.2M）
rsync -a /home/acme.sh/            node3:/home/acme.sh/
rsync -a /var/lib/apikv-cert/      node3:/var/lib/apikv-cert/
rsync -a /etc/apikv-cert/          node3:/etc/apikv-cert/
rsync -a /home/docker/lyrapass-routing/ node3:/home/docker/lyrapass-routing/
scp /usr/local/sbin/apikv-cert-{renew,distribute} node3:/usr/local/sbin/
```

node3 版 `apikv-cert-distribute` 的改动：删除 `send_node2` 与 `NODE2_*`；
落盘目标就是本机 pangolin/blog；`reload_local` 的等待从 60s 放宽到 **90s**
（traefik 重启后要重新编译本地 badger/crowdsec/safeline 插件）；末尾写
`/var/lib/apikv-cert/deployed-fingerprint`。

node3 版 `apikv-cert-renew` 的改动：续期后比较 stage 指纹与 `deployed-fingerprint`，
**只有证书真的变了才分发**，避免每天无谓重启 traefik。

验证（两步都实跑）：

```
# 1) 分发演练：12 秒，含 traefik 重启
node3 certificate deployment verified fingerprint=1F0074CA…52BF backup=/var/lib/apikv-cert/backups/20261112T172053Z

# 2) 幂等演练：acme.sh 跳过续期（下次 2027-01-22），指纹相同 → 不分发，traefik StartedAt 未变
Result=success  ExecMainStatus=0
```

⚠️ 踩到一个和 host-watchdog 同源的坑：`/var/lib/apikv-cert/notifications.json` 里写着
`"host": "node1"`，而 node3 的 `HOST_LABEL=node3` → `notify.py` 的 `Config(host=...)`
校验直接抛 `ValueError`，导致首次 `renew` 以 `status=2` 失败。state 里 `incidents` 是空对象，
备份后删除即可（`notifications.json.bak-before-node3-20261113`），重建为 `"host": "node3"`。

定时器归属：node3 `enable --now apikv-cert-renew.timer`（03:17 + 45m 随机延迟），
node1 `stop + disable`。

### 6. `pangolin-strict-route` 每分钟在 node1 上失败

`pangolin-strict-route.timer` 是 `OnUnitActiveSec=60s` 的 reconcile 任务，做的事是：
从 `docker exec pangolin` 取生成的 traefik 配置，提取 **resource 67** 的 newt 隧道端点，
写回 `dynamic_config.yml` 里固定的 `lyrapass-api-strict` router/service
（强制 LyraPass API 走固定端点 + 严格 TLS，`serversTransport: lyrapass-strict@file`）。

割接后 node1 的 pangolin 容器已停 → `docker exec` 失败 → **这个单元每分钟失败一次**，
而真正该做这件事的 node3 上没有它。

先核对两端是否已经一致（避免带病迁移）：

```
node3 dynamic_config.yml : https://100.89.128.12:58619   (serversTransport lyrapass-strict@file)
Pangolin 现生成 resource 67 : https://100.89.128.12:58619
```

一致（WireGuard 隧道 IP 由 Pangolin 分配，重连后不变），所以当前路由是好的，只是没人守着。
迁移后首次运行输出 `already matches current tunnel target`，`dynamic_config.yml` 的 md5
**前后都是 `e9800f83…`**——脚本在无变化时直接返回，不会用 `yaml.safe_dump` 洗掉注释。

node1 `stop + disable` 该 timer，`reset-failed` 清掉残留失败状态。

### 7. otelcol 本来就在 node3，node1 的停用

排查主机级单元时发现 node3 早在 2026-11-03 就装好了 `/etc/otelcol/`（journald + 全部容器
json-file → `https://otlp-dev.apikv.com` → 集群 VictoriaLogs），`otelcol.service` enabled 且
active，近 30 分钟 0 条 error。**不需要迁**，反而 node1 那份会重复采集一个已经没有容器的主机。

node1：`stop + disable otelcol`。停完后 node1 的业务类服务只剩
`crowdsec-firewall-bouncer`（指中心 LAPI）与 `fail2ban`（sshd 保护），符合退役预期。

### 8. 删除多余的 `auth.apikv.com` A 记录

`auth.apikv.com` 从来没有对应的 Traefik router（node1/node3 的 `dynamic_config.yml` md5 相同、
Pangolin resources 里也没有），访问是 Go 默认的 `404 page not found`，casdoor 的真正入口是
`casdoor.apikv.com`。

```bash
tccli dnspod DeleteRecord --Domain apikv.com --RecordId 2300445933
# 27 -> 26 条；@/* 仍是 193.112.22.183
```

删除后 `auth.apikv.com` 由 `*` 泛解析兜底，仍解析到 node3、仍是 404，**行为不变**。
若以后需要该域名，应在面板补一个 resource 指向 casdoor，而不是加回 A 记录。

### 9. 收尾后 node3 的主机级单元清单

| 单元 | 状态 | 作用 |
|---|---|---|
| `apikv-cert-renew.timer` | enabled | 每天 03:17(+45m) 检查续期，变了才分发 |
| `pangolin-strict-route.timer` | enabled | 每 60s 对齐 LyraPass API 隧道端点 |
| `otelcol` | enabled | journald + 容器日志 → VictoriaLogs |
| `host-watchdog` | 已装 | 24 容器巡检 + ntfy 告警 |
| `newt` | enabled | 站点 15（本机自环） |
| `crowdsec-firewall-bouncer` | enabled | 从中心 LAPI 拉封禁名单 |

### 10. 迁后清理两处（2026-11-13 01:55–02:05 CST）

**a) host-watchdog 排除 Windows 站点（siteId 19）**

迁移冒烟时 host-watchdog 唯一 firing 的 `pangolin:19` 是 **Windows 开发机隧道站点离线**（长期离线，迁移前就如此），属覆盖盲区而非故障。按「已知离线」常驻忽略：

```bash
# components/host-watchdog/hosts/node3.env
PANGOLIN_IGNORE_SITES="mac Windows"   # mac=6 / windows=19，均为已知离线站点
bash components/host-watchdog/install.sh node3            # dry-run 确认只动这一行
CONFIRM=yes bash components/host-watchdog/install.sh node3 # 下发（备份 watchdog.env.bak-20261113-015811）
bash components/host-watchdog/retire-check.sh node3 pangolin:19  # 删常驻事件，剩 0 条
bash components/host-watchdog/verify.sh node3            # 结论「一致」
```

`PANGOLIN_IGNORE_SITES` 在 `notify.py` 里按 `ignored.split()`（空格分隔）精确名称匹配，mac=6、Windows=19 已忽略。

**b) otelcol 配置过时注释**

`/etc/otelcol/config.yaml` 有 3 处写「node1」的注释（边缘已迁 node3），纯注释、不影响语义、不需重启：

- `node1 上 gerbil、blog 等 6 个` → `node3…`
- `node1 的 traefik 共用 gerbil 的网络栈` → `node3…`
- `otlp-dev 前面 node1 Traefik 上的 SafeLine WAF` → `node3…`

grep 确认全文件已无 node1 残留（备份 `config.yaml.20261113-*.bak`）。

**现状**：node3 主机侧 incidents=0，可观测性链路（otelcol→otlp-dev / host-watchdog→ntfy / Gatus→edge）全通。
