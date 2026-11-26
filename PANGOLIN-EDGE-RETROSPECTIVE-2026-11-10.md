# 86 万条 broken pipe：Pangolin 边缘这套东西的来路、坑和下一步

2026-11-10 03:55，我在 node1 上敲了句 `docker logs traefik 2>&1 | grep -c "error in detection"`，返回 **862121**。

这是 SafeLine 插件写进 Traefik 日志的检测失败行数。近 10 分钟还有 358 次，同期 726 个请求。插件出错时走的是 `s.next.ServeHTTP(rw, req)`，直接放行。所以这台机器上装了 42 天的雷池，从 11 月 7 日早上起接近三天没拦过东西。同一条链上的 CrowdSec 一直在干活，巡检时读到的 4 条活跃 ban、AppSec 累计 151 次拦截都是它的。gatus 探针全程是绿的，没有一条告警指向「雷池还拦不拦」。

起因只是想弄明白「我记得用了两个安全插件，具体忘了」。查故障顺手把架构的来路翻了一遍，发现比看上去拧巴：架构文档明明写着 WAF 该放云边缘，实际只有 blog 一个域名在 CDN 后面；配置里留了一堆踩坑注释，却没有一份说明当初为什么这么选。这篇补上，顺便把 11-10 这次修复里我自己判断错的地方也记下来。

> 口径说明：862121 是当时容器日志里 `error in detection` 首行的累计计数，包含重启前的历史，不能拿它推断「坏了多久」；判断当下状态看的是 10 分钟窗口那 358 次。726 个请求里有 359 个是 `crowdsec.apikv.com`，被 `excludeHosts` 跳过，所以待检请求约 367 个、失败 358 次。下面所有数字都标了采集时间和来源，没标的我不写。

---

## 没有公网 IP，这事就没得选

先把最硬的一条摆出来：机房侧没有入向公网条件。

`components/newt/README.md:5` 第一句就是「集群在局域网里，没有公网 IP」。`HOSTING-READINESS-2026-09-03.md:65-68` 记着 `10.10.21.0/24` 有 82 个在用地址，是机房多租户共享 VLAN，不是自家局域网；`:47` 写的是出口 `211.144.221.226`，只有出口。`CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md:96-98` 更直接：从 node0/node3/node4/node6 ping `10.10.21.161` 全部 unreachable，没有任何路由，`CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md:102` 补了句「现在是公网 NAT，只有 6443 映射着」。

所以 Ingress、NodePort、把 frp 服务端放机房这类方案，在第一条约束上就死了。`components/newt/README.md:15-16` 给了唯一一处明确的选型对比：

> **关键性质：局域网侧全程只出不进** —— newt 不监听任何端口，路由器不需要做端口映射，也不需要公网 IP。这是选它而不是 frp/nps 之类的主要原因。

`archive/pangolin/README.md:28` 把它说得更白：「集群不需要 LoadBalancer/NodePort/防火墙放行」。拓扑是公网用户打到 node1 的 Traefik，Traefik 经 WireGuard 隧道把请求交给集群侧的 newt，newt 再转给 Cilium Gateway 的固定 VIP `10.10.31.240:443`，最后落到 HTTPRoute。隧道由集群侧发起。

集群内那一层是 Gateway API，不是 Ingress。`微服务架构/微服务架构.md:532-534` 的理由是 Ingress API 已冻结、ingress-nginx 2026-03-31 退役，`bootstrap/config.env:191` 里 `CILIUM_ENABLE_INGRESS="false"` 也钉死了。但 Gateway API 只管集群内的 L7 路由，`HOSTING-READINESS-2026-09-03.md:199-201` 说得很清楚：那批 `.240/32`、`.241-.249` 是「跨网段集群内 VIP，Pod/newt 走 eBPF Service，普通 LAN 主机不直达」。L2 宣告的 VIP 只在本地二层有效，`CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md:114-120` 算过账：leader 一旦落到云节点，VIP 会在腾讯 VPC 里被 ARP，机房侧直接失联，漏了就是全站 502。

公网入口只能落在有公网 IP 的云主机上。node1 就这么成了边缘，`CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md:46` 的那行结论是「**不可动**」。

顺便说一句，`HANDOFF-2026-09-22.md:213-215` 解释了为什么整个集群只用一个 newt site：所有 k8s 资源的 target 都是同一个共享 Gateway VIP，一个 newt Pod 就够，多副本共用同一份凭据会互相顶替。冗余交给 Gateway VIP 和 k8s 调度。这条到现在还成立，11 个站点全 online 的时候也是这么跑的。

## 9 月 29 日：两件事撞在了同一天

架构文档里其实主张 WAF 放云边缘。`微服务架构/微服务架构.md:658` 写的是「WAF、Bot 与大流量 DDoS 清洗放在云边缘，不由自研网关承担」，`:114` 画的链路是「CDN / 云 WAF → Pangolin 公网入口 → Cilium Gateway API」。

实际只覆盖了一个域名。`components/gatus/endpoints.yaml:245` 点名「blog 前面是 EdgeOne，探到的是 CDN 回源后的结果」。`apikv.com` 主站、lyrapass、Pangolin 控制面、`crowdsec.apikv.com` 这些静态 websecure 路由直连 node1 的 Traefik，还有 `HANDOFF-2026-09-22.md:361-364` 那批 PG / Dragonfly / Kafka / OTLP 的 L4 入口（`:30001`、`:30004`、`:30005`），云 WAF 一个都够不着。

同一天出了一起事故。`components/vmauth/README.md:5-7` 和 `git show 0560cfb8` 的提交正文都记着：`metrics.apikv.com` 当时直通 VM，公网任何人都能查询、写入，还能调 `/api/v1/admin/tsdb/delete_series`、`/snapshot/*`、`/flags`。`components/victoriametrics/README.md:28` 把它缩成一句「2026-09-29，之前直通导致公网可写、可删数据」。`HANDOFF-2026-09-22.md:273` 那句更早的提醒也应验了：「无鉴权的公网写入口等于任人灌数据」。

当天加了 vmauth 只读代理，也上了 CrowdSec + SafeLine。

**这里得标一下：仓库里没有一份「为什么上 WAF」的决策备忘录。** 全库 git log 用 `waf|crowdsec|safeline|雷池` 检索是 0 条，9-29 当天本仓的提交全是 vmauth / gatus / vmalert / grafana。WAF 的部署本体在 node1 上，`PROVENANCE.txt` 也在那儿。所以「因为云 WAF 覆盖不全 + 当天出了直通事故，所以必须在 Traefik 入口点自建兜底」这条因果是我从时间线和覆盖缺口拼出来的，不是哪份文档明写的。写在这儿，免得下一个人把它当成定论。

## 两个插件，加一个不算 WAF 的

| | CrowdSec | SafeLine（雷池） | badger |
|---|---|---|---|
| 插件 | `maxlerebourg/crowdsec-bouncer-traefik-plugin` v1.7.1，原版未改 | `chaitin/traefik-safeline` main@bc2258c，**打了本地补丁** | `fosrl/badger` v1.7.0，Pangolin 官方 |
| 本体 | 同一 compose 里的 `crowdsec:v1.8.1`，LAPI :8080 + AppSec :7422 | 独立项目 `/data/safeline`，7 容器 9.4.2，华为云 SWR 镜像 | Pangolin 资源级 SSO 登录墙 |
| 干什么 | IP 信誉 ban、虚拟补丁、SSH/主机日志采集，各主机 firewall bouncer 都来拉决策 | 单请求体特征检测，`safeline-detector:8000` 走 T1K 私有协议 | 认证，不是安全检测 |
| 加载 | `experimental.localPlugins`，磁盘 | `experimental.localPlugins`，磁盘 | `experimental.plugins`，远程 |

三者都挂在 `websecure` 入口点那条链上，顺序是 `crowdsec@file` → `safeline@file` → `compress@file`，Pangolin 下发的每个 router 再带自己的 `badger`。

为什么必须从磁盘加载，node1 上 `plugins-local/PROVENANCE.txt` 第一行就写了：「2026-09-29 vendored as Traefik localPlugins (no runtime download; cf. pangolin#3435 transient plugin fetch => all routers 404)」。插件运行时下载一旦失败，Traefik 会把插件禁掉，所有路由 404。9-29 就把两个 WAF 插件搬到了本地盘。

SafeLine 那份补丁有三处，都在 `PROVENANCE.txt` 里：`excludeHosts`（放掉 `pangolin.apikv.com` 和 `crowdsec.apikv.com`，控制面被误杀等于集群入口断）、`maxBodyBytes: 1MiB`（上游 `io.ReadAll` 无界）、去掉 `X-Chaitin-waf` 响应头。

两个插件都是 fail-open。CrowdSec 的 `crowdsecAppsecFailureBlock` / `UnreachableBlock` / `UnreadableBodyBlock` 三个全设 `false`，`dynamic_config.yml:3-4` 的注释写了原因：上游默认 fail-closed，crowdsec 容器一挂整站 403。SafeLine 插件出错也放行。这个取舍我认，代价后面会讲到。

## 配置里留着的疤

`docker-deploy/pangolin/README.md:68` 有个标题叫「升级（四个坑，每个都真实踩到过）」，那篇里我最喜欢的是坑 4：

> **这个坑的真正危险不是行为变更本身，而是它诱导你改错监控配置。** 当天的真实过程：升级后手动 `curl https://ps.apikv.com/` 得到 401（升级前是 302），据此判定「探针契约变了」，把 gatus 里 6 个端点的断言从 302 改成 401 —— 而 gatus 实际一直拿到 302，6 个检查从未失败。

那条讲的是 badger v1.7.0 按 User-Agent 分流：CLI 类 UA 返 401，浏览器和 Gatus 返 302。触发条件是 UA 不是 `Accept` 头。11-10 我踩的坑跟它是同一类，只是换了个地方。

先把能列的列一下，都是配置注释或文档里写着的：

| 坑 | 位置 | 后果 / 处理 |
|---|---|---|
| Badger v1.8.0 过不了 Traefik 完整性校验 | `components/newt/README.md:145-152`、`UPGRADE-RECORD-2026-10-24.md:151-181` | 插件被禁 → 全路由 404。钉死 v1.7.0 |
| Pangolin 1.25 会自动改写 Badger 版本 | 同上 | 配置深度定制时自动改写静默失败，属「碰巧安全」，每次升级前 `grep` 复核 |
| 升服务端必然断隧道几秒 | `components/newt/README.md:159-163` | 客户端报 502 后自愈，别手动重启客户端 |
| 服务端 / 客户端是两条独立版本线 | `components/newt/README.md:99-111` | 只升一边会刷 `Newt ping with outdated config version: 2 (current: 0)` |
| schema 迁移不可降级 | `components/newt/README.md:164-167` | 升级前用 `.backup` API 做一致性快照，别只 `cp` |
| XFF 可伪造 | `dynamic_config.yml:20-22` | 插件的 `forwardedHeadersCustomName` 不校验 TCP peer，9-29 实测可伪造；改用 `websecure.forwardedHeaders.trustedIPs` 只信任 EdgeOne 回源段 |
| HTTP/2 流式 body 被 403 | `dynamic_config.yml:19` | `crowdsecAppsecUnreadableBodyBlock` 默认 true，无 Content-Length 直接 403 |
| AppSec 规则重复 | `crowdsec/etc/acquis.d/appsec.yaml:1` | `appsec-default` 已含 generic-rules，再加一遍 duplicated rule id |
| OTLP 明文 protobuf 被 WAF 拦成 403 | `hosts/observability/roles/host_otel/templates/config.yaml.j2:185-186` | 9-29 node4 实测；gzip 过的请求体 WAF 不解析 |
| 仓库副本没同步线上 | `docker-deploy/pangolin/config/traefik/traefik_config.yml:13-20` | 那份只有 badger，没有 `localPlugins` / crowdsec / safeline。按 `docker-deploy/pangolin/README.md:99-102` 的规矩（升级后要把实际值同步回仓库），照它重装会退回到没有 WAF 的状态 |

最后一条是我这次翻仓才发现的，之前没人提。它不影响线上跑，但哪天真按仓库重装，边缘就裸了。

还有几条散在别处：`archive/pangolin/README.md:51-60` 的「target 走 80 得到 envoy 404」、`components/newt/README.md:132-135` 的 Pod `1/1 Running` 但版本号其实是 `1.5.0` 不是 `1.15.0`、`HANDOFF-2026-09-22.md:219-222` 删 site 会连带删 target、`HANDOFF-2026-09-22.md:279-283` PostgreSQL 客户端先发明文 SSLRequest 撞上 TLS Passthrough 返 400。这些跟 WAF 无关，但都是同一条边缘链路上的疤。

## 我判断错的那次

11-10 第一遍看运行时配置，我在 Traefik 的 `/api/http/routers` 里看到 `10-casdoor-router@http` 挂着四个中间件：`crowdsec@file`、`safeline@file`、`compress@file`、`badger@http`。而 `traefik_config.yml` 的 `websecure` 入口点也挂着前三个。

当时的结论是「挂了两遍，删掉一份」，还写进了巡检报告。差点就动手了。

后来拉了配置源对比：Pangolin 的 `/api/v1/traefik-config` 里 `10-casdoor-router` 只有 `badger`，72 个 router 里带 badger 的 36 个；file provider 的静态路由也一个都没挂 WAF，`crowdsec-lapi@file` 只有 `crowdsec-lapi-allowlist`，`apikv-site-router@file` 干脆没有 middlewares。运行时 API 显示的那四个，是 Traefik 把入口点中间件**合并进最终链**之后的展示，不是重复声明。

又发了 10 次探针验证，检测调用约 10 次。10 分钟窗口的 726 请求 / 358 次报错（扣掉 359 个被 `excludeHosts` 排除的）也是 1:1。

真删了入口点那份，静态 websecure 路由就全裸了 —— `apikv.com`、lyrapass、Pangolin 控制面、`crowdsec-lapi` 本来就只靠它获得 WAF 覆盖。这跟 `docker-deploy/pangolin/README.md` 坑 4 是同一类错：拿一个间接信号当契约，然后照它改配置。现在 `traefik_config.yml:547-554` 写了段注释，把「runtime API 是合并展示、删这里会让静态路由裸奔」钉在那儿。

## 清理 bouncer 翻车

第二个死胡同更疼一点。

`cscli bouncers list` 里堆了 42 条，同一批 bouncer 因为容器 IP 变化被反复注册成 `k1-fw@172.25.0.2`、`k1-fw@172.25.0.7`、`k1-fw@172.25.0.10` …… 最后拉取时间从 9-28 排到 11-09。按 11-09 之前的 35 条判定为陈旧，一条 `xargs docker exec crowdsec cscli bouncers delete` 删下去。

结果只剩 1 条。

`cscli` 展示名里的 `@IP` 后缀不是记录的真实名字，按基础名删会把同名活跃实例一起带走。LAPI 立刻对 Traefik 插件和 k1/k2/k3/node2/node3 的决策流返回 403，插件日志刷 `updateFailure` 从 0 涨到 13。

恢复靠各主机上还留着的原 key：`/etc/crowdsec/bouncers/*.yaml` 里的 `api_key`，Traefik 那份在 `config/traefik/secrets/crowdsec-lapi.key`。用 `cscli bouncers add <name> --key <key>` 重建 6 条，20 秒后决策流回 200。最终 7 条干净记录，而且都是手动建的 `auto_created=false`，不会再自动长出 `@IP` 副本。

顺带把 LAPI 的 `crowdsec.db` 先 `cp` 了一份到备份目录 —— 这次是删完才补的，顺序反了，运气好才没出更大事。

## 11-10 修了什么，验到什么程度

`docker restart traefik` 一次做完两件事：注释改动生效，连接池重建。

根因对上了时间线：Traefik 在 `2026-11-06T23:00:49Z` 启动，`safeline-detector` 的日志到 `23:01:12Z` 才 `init done`，中间还有一条 `wait command failed, wait to retry` / `signal: killed`。那一批 100 条连接全建到了马上要被 kill 的旧进程上，之后三天每次写都是 `write tcp 172.25.0.4:xxxxx->172.25.0.10:8000: write: broken pipe`。t1k-go 的 `conn.onErr` 其实会重连，但整池一起坏的时候没能自愈。

重启后的验证，都在 node1 上跑过：

```
# 检测失败归零
docker logs traefik --since 5m 2>&1 | grep -c "error in detection"     # 0

# WAF 真拦，不是不报错就算好
curl -sk -H "Host: gorse.apikv.com" https://127.0.0.1/.git/config
# 403，响应体带 "blocked by Chaitin SafeLine Web Application Firewall" 和 event_id
curl -sk -H "Host: gorse.apikv.com" https://127.0.0.1/                # 302，不误杀
```

XSS 和 SQLi 载荷同样 403。终态：4 个 compose 容器健康、11/11 站点 online、88 条路由、入口点链仍是 3 个中间件、Badger 仍钉 v1.7.0、CrowdSec 4 条活跃 ban、Traefik 的 CrowdSec 插件近 2 分钟 0 个 403 WARN、`blog.apikv.com` 公网 200。AppSec 累计送检 31.68k / 拦截 151 是巡检时读到的累计值，不是这三天的数。

注释漂移顺手修了三处：`config.yml` 头部的 `1.22.2` 改成 `1.25.3`，`dynamic_config.yml` 开头那句「No CDN in front, forwarded headers are NOT trusted」改成实配的 EdgeOne 口径，加上上面那段入口点防误删说明。备份在 node1 `/root/backup-pangolin-waf-20261110/`。

## 下一步，按我会先做哪个排

**先解决重启顺序。** detector 和 Traefik 一起重启时，等 detector 日志出现 `init done` 再起 Traefik。这条不用改代码，写进 runbook 就行。现在这个「重启一下就好了」的修法只是把池子重建了一遍，下次两台一起重启还会复发。

**然后给 WAF 加一条「它到底在不在拦」的告警。** 这是我的判断，也是这篇文章里最想说的一句：fail-open 本身是对的，但一个 fail-open 的组件没有任何存活之外的观测，等于没装。这三天里容器健康、站点 online、gatus 全绿、CrowdSec 还在出 ban，只有 Traefik 日志里那 86 万行在喊。`node1-watchdog/README.md` 里有句话该贴在这儿：「没验证过的告警通道等于没有。」 那条 watchdog 当初补的是「容器崩了但 gatus 还是绿」的盲区，WAF fail-open 是同一类盲区，只是又往里缩了一层。

如果只能做一件，做这条，别再加检测层。如果你的入口全都老老实实在 CDN 后面，这套自建双 WAF 其实可以直接不要 —— 我们之所以留着，是因为那批静态路由和 L4 入口根本不经过 CDN。

再往下才是 P2 的几件：把仓库里那份没同步 WAF 段的 `traefik_config.yml` 补上；评估把 SafeLine 的 `PoolSize` 从 100 降到 t1k-go 默认的 8（插件每个 router 实例化一次，detector 侧的连接数我没测过，得先量）；清掉 `config/db/` 里那 9 份 447MB 的 sqlite 备份（3 份 upgrades 备份 + 6 份手工 `.bak`，正在用的 `db.sqlite` 不算）。这些都还没动。

还有个我没验证完的：`pool_size` 这个 yaml tag 在 Traefik 插件的 mapstructure 解析里到底认不认。不认的话改了配置也不会生效，得先拿一个非生产路由试。下次 detector 重启我大概会先盯那行 `init done`，再决定要不要动池子。
