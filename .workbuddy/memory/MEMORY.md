# 项目长期记忆 —— kubernetes 集群

## 拓扑与操作位置
- SSH（`~/.ssh/config`）：node1–node6 + k1/k2/k3。**边缘核心自 2026-11-12 已从 node1 迁到 node3**（`193.112.22.183`，SSH 端口 34125）。node3 = pangolin+gerbil+traefik+crowdsec（无 newt 客户端）+ SafeLine 七容器 + casdoor/postgres/ntfy/webhook/redis-gorse/licensed + 静态站点。node1 已退役：0 容器、80/443 空闲，仅留 `crowdsec-firewall-bouncer`（指中心 LAPI）+ `fail2ban`。
- 站点 siteId：node1-local=1(local)、node2=5、mac=6、k8s-cluster=11、k1=12、k2=13、k3=14、node3=15、node4=16、node5=17、node6=18、Windows=19(离线)。现存 11 站点全 online，仅 Windows(19) 长期离线。
- 主机 newt：`~/.local/bin`→`/usr/local/bin/newt` + `newt.service`，凭据 `/home/docker/newt/newt.env`；k8s 内 newt Deployment siteId 11。`add|remove|list` 走 `components/newt/newt-host.sh`，面板凭据 `~/.pangolin-admin.env`。
- 云↔机房无 L3 通路；本地 Mac `~/.kube/config` 无 creds；组件安装须在 k1 `/root/kubernetes/`，凭据 `/var/lib/k8s-installer/creds/`，`KUBECONFIG=/etc/kubernetes/admin.conf`。
- 站点 online 直读 node3 `python3 /root/check_sites.py`（读 sites 表）。⚠️ node1 上同名脚本读的是割接时冻结的旧 db，结论过期。

## 版本线（易混）
Pangolin 1.26.0｜newt 1.20.0｜Gerbil 1.6.0｜Traefik v3.7.18｜CrowdSec v1.8.2｜Badger v1.8.0（本地 vendor，零外部依赖，根治「拉不到 zip→全 404」）。升服务端前先升所有客户端，否则 `Newt ping outdated config version`；服务端重启断隧道几秒、客户端 502 自愈，别手动重启客户端。判据：客户端 `Tunnel connection established` + `Server version` 匹配（别拿 Pod Running 当通了）。schema 迁移用 `sqlite3.backup()` 做一致性快照。

## 边缘安全栈（node3）
- 插件 vendored 在 `/home/docker/pangolin/config/traefik/plugins-local/`，`experimental.localPlugins`：badger + crowdsec-bouncer-traefik-plugin v1.7.1 + chaitin/traefik-safeline（本地 patch）。明细 `PROVENANCE.txt`。
- 链序：`websecure` 入口点 crowdsec → safeline → compress（唯一声明处）。CrowdSec `*Block` 均 false、SafeLine 出错均 fail-open。
- ✅ fail-open 根治：safeline.go `PoolSize 100→8`（→~440 连接压 detector），备份 `safeline.go.bak-poolsize100-20261110`。判据：`access.log` 近 3000 条 `DownstreamStatus:403` 为 0 = WAF 全放行。
- Gatus `public-edge/safeline-waf-liveness` 探 `https://shop.apikv.com/.git/config`，条件 `[STATUS]==403`+`[BODY].code==403`+`[BODY].success==false`。
- `cscli bouncers delete "name@IP"` 会连带删同名活跃实例（踩过 6 个一度 403）；`name@<ip>` 孪生记录是反代后方正常行为（auto_created=True），无后缀那条才持 api key，别清。
- `crowdsec.apikv.com` 挂 `crowdsec-lapi-allowlist`（5 个固定 IP），名单外返回 9B `Forbidden` 属正常，别当 WAF 故障。

## 边缘主机级定时任务（全在 node3）
`apikv-cert-renew.timer`（03:17+45m，`*.apikv.com` 续期，变了才分发，acme.sh 走 DNSPod DNS-01 不依赖 80/443）｜`pangolin-strict-route.timer`（每 60s 对齐 LyraPass API 的 resource 67 隧道端点，必须 `docker exec pangolin`）｜`otelcol`（journald+容器日志→`otlp-dev.apikv.com`，node3 11-03 已装好，不用迁）｜`host-watchdog.timer`（24 容器巡检+ntfy）｜`newt`（站点 15 自环）。
- 证书链：`/home/acme.sh`+`/var/lib/apikv-cert`+`/etc/apikv-cert`+`/usr/local/sbin/apikv-cert-{renew,distribute}`（node3 版删了 node2 空转、traefik 重启等待 90s、加 deployed-fingerprint 幂等）。`distribute` 会 `docker restart traefik`。
- ⚠️ `host` 字段陷阱（踩过两次）：`/var/lib/host-watchdog/incidents.json` 与 `/var/lib/apikv-cert/notifications.json` 里的 `"host"` 必须等于 `HOST_LABEL`，否则 `notify.py` 抛 `ValueError`→service `status=2`。迁机时备份后删除重建即可。
- node1 停用：上述 timer/otelcol 全 stop+disable；仅留 `crowdsec-firewall-bouncer`+`fail2ban`。

## 判障速查（避免误报）
- `gateway.apikv.com/` 404 是预期（Connect RPC 网关，探活用 `/readyz`/`/healthz`）。`auth.apikv.com` 404 因从无 router（A 记录已删，由 `*` 兜底）。`crowdsec.apikv.com/health` 403 是 ipAllowList（见上）。
- **判断 502/403 先查 `targets.siteId`**：target 的 `127.0.0.1` 是「该 site 的 localhost」非边缘主机；`siteId=1` 的 `type=local` 才不经 newt、由边缘直连。实测：`cat`/`getcat`(6=mac 本机)/`pdapi`/`pdsink`(19=Windows 离线)/`stream`(1 local 僵尸 8889)/`minio`(5=node2 的 Silo 对匿名根 `AccessDenied` 403，非故障)。
- `silo-api.apikv.com`（Scorpius S3 上传端点）是 resource 69 / target 94 → `siteId=11` 的 k8s MinIO：Cilium Gateway `10.10.31.240:443`（internalPort 62202）→ `minio-s3` HTTPRoute → `minio/minio-service:9000`，**不是 node2 的 MinIO**（同名密钥在 node2 报 InvalidAccessKeyId）。集群内直连网关 ~6.8 MB/s；edge→siteId=11 隧道会间歇降到 ~50 KB/s。minio-go 默认 `ResponseHeaderTimeout=60s` + cosput 5 MiB 分片 → 超时 499 并重试。已兜底：cosput 改 1 MiB 分片 + 5 min 超时，并支持 `S3_DIAL_ADDRESS`；`make comm-push-direct` 经 k1 SSH 转发直连 `minio-service:9000` HTTP 绕开隧道（网关 `10.10.31.240:443` 是 dev.test 自签证书，不能直接校验证书）。匿名 `AccessDenied` XML 是 MinIO 正常响应，不是 WAF。
- 三域名三服务：`config.apikv.com`(前端 200)/`config-api.apikv.com`(API 根 401/`healthz` 200)/`gateway.apikv.com`(RPC 网关)。
- Gatus `public-edge/control-tower-gateway-edge` 探 `/readyz`。
- **容器化 PG `could not signal for checkpoint: Permission denied` 且永久卡 `in crash recovery`**：先查内核 `journalctl -k | grep apparmor.*DENIED`。k1 的 containerd 2.3.4 默认 profile `cri-containerd.apparmor.d` 拒绝容器进程间 signal（`signal=int` 被拒，peer=`cri-containerd.apparmor.d//&unconfined`），PG 的 end-of-recovery checkpoint SIGINT 发不出。判据：`kill -0 <pid>` 成功但 `kill -INT/-TERM` 全 EPERM + CapEff=0。修法：`sts` pod securityContext 加 `appArmorProfile.type: Unconfined`（K8s 1.37 GA，旧注解废弃），重建 Pod；LyraPass `sts/postgres` 已这么修并固化到其仓 base/k8s.yaml。放宽 liveness 无效可排除探针。

## ⚠️ Mac LaunchAgent 坑
`launchctl unload` 后在 WorkBuddy agent 会话无法重新注册（Bootstrap failed: 5: Input/output error）；别为改 plist 而 unload，改把日志指 `/dev/null` 符号链接，或 GUI 终端 `launchctl load -w`。

## gorse（11-03 迁集群）
ArgoCD App + helm 三件套 0.5.11；API gorse-server:8087，Dashboard gorse.apikv.com。cache=Dragonfly db0，data=CNPG pg-main gorse 库。ArgoCD 源 GitLab 镜像 `gitlab.com/sumery/kubernetes`。Cilium gateway 坑：operator 重启后新 HTTPRoute 不编程，重启 operator 恢复。

## 网络与镜像
机房 k1/k2/k3 拉 GitHub 不通→`ghfast.top` 前缀；containerd 国内镜像站非公开路径 401→换版本前逐节点 `crictl pull` 预拉。

## host-watchdog 清单版本管理
`components/host-watchdog/`：`hosts/{node1,node2,node3}.env` + `install.sh`(默认 dry-run, CONFIRM=yes 才写, 只覆盖受管行, 不重启) / `verify.sh`(退出码 1=漂移/僵尸) / `retire-check.sh`(清 incidents 旧事件)。受管键含 `PANGOLIN_IGNORE_SITES`（按精确名称忽略站点，siteId 6=mac、19=Windows 为已知离线，已忽略）。⚠️ 退役顺序：改清单→install→retire-check；直接删 WATCH 行不会删旧事件（notify.py「缺席不合成恢复」），会永久滞留。`status=1` 是「发现问题」约定码，看 `Result=success` 即可。

## 可观测性补全（11-25）
基线报告 `OBSERVABILITY-COVERAGE-BASELINE-2026-11-25.md` §7 是实施状态权威来源。当前 vmalert 16 组/104 条；新增规则文件 `control-plane.yml`（仅 Pod phase/ready，apiserver/etcd 绑 127.0.0.1 未覆盖）、`middleware-{dragonfly,minio,elasticsearch}.yml`。OTel `prometheus/middleware` 抓 Dragonfly TLS :6379、MinIO ClusterIP :9000（需 `MINIO_PROMETHEUS_AUTH_TYPE=public`）、`components/elasticsearch-exporter` :9114。⚠️ OTel 会把 `dragonfly_uptime_in_seconds` 改名 `_total`，值守选用 `dragonfly_connected_clients`；`elasticsearch_cluster_health_status` 按 `color` label 取值 1。ecommerce 10 个 Go 服务经 `OTEL_RESOURCE_ATTRIBUTES=service.namespace=ecommerce` 打标；OTel 升级后 RPC 指标名/错误码 label 已变，`ecommerce-app.yml` 已修且 `unless on ()` 必须包住整个 OR 守卫。ecommerce pre-push 的 verify-quick 会被宿主 safe-delete 拦截前端 dist 清理，先把 `apps/*/dist` 和 `consumer-next/.next` 移到 /tmp 再跑；改 helm 模板要同步 10 份裸 deployment + prod overlay 的 JSON6902 下标。

## 文档索引
`APPARMOR-SIGNAL-RUNBOOK.md`（容器信号拦截通用排障手册：判据/诊断/修复/陷阱/速查，后续同类问题先看这篇）｜`EDGE-MIGRATION-2026-11-12.md`（node1→node3 全记录，当前依据）｜`OBSERVABILITY-COVERAGE-BASELINE-2026-11-25.md`（可观测性基线+实施状态）｜`OBSERVABILITY-INTEGRATION.md`（三信号链路）｜`UPGRADE-RECORD-2026-11-10.md`｜`PANGOLIN-EDGE-RETROSPECTIVE-2026-11-10.md`｜`components/host-watchdog/README.md`｜`components/newt/README.md`+`WINDOWS-CLIENT-RUNBOOK.md`。
