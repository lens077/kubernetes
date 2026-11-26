# Pangolin / Newt 全量升级到 1.26.0 —— 执行记录（2026-11-10）

## 结论

全部完成并验证通过。**Pangolin 服务端 = 1.26.0，newt 客户端 = 1.20.0，Badger = v1.8.0**
（三条独立版本线，详见 §2）。面板 11 个站点全部 `online=1`，服务端 0 条告警。

| 目标 | 组件 | 升级前 | 升级后 | 形态 |
|---|---|---|---|---|
| node1 | Pangolin 控制面 | 1.25.3 | **1.26.0** | Docker（`fosrl/pangolin`） |
| node1 | Badger 插件 | v1.7.0 | **v1.8.0** | Traefik `experimental.plugins`（1.26 迁移自动改写） |
| node2 / node3 / node4 / node5 / node6 | Newt | 1.19.0 | **1.20.0** | `/usr/local/bin/newt` + systemd |
| k1 / k2 / k3 | Newt | 1.19.0 | **1.20.0** | `/usr/local/bin/newt` + systemd |
| k8s 集群 | Newt | 1.19.0 | **1.20.0** | Deployment（`docker.io/fosrl/newt`） |
| Mac（05:47 追加） | Newt | 1.19.0 | **1.20.0** | launchd `net.pangolin.newt`，`~/.local/bin/newt` |
| node1 | Gerbil | 1.5.2 | **未动** | 独立版本线，上游已有 1.6.0 |
| node1 | Traefik | v3.7.12 | **未升镜像** | 仅为让 Badger v1.8.0 生效重启过一次 |

---

## 1. 与 2026-10-24 那次相比，范围变了

| 项 | 10-24 | 11-10 |
|---|---|---|
| SSH 主机 | node1–node4 / node6 / k1–k3（另有 node0） | **node1–node6 / k1–k3**（node0 已重装成 node5） |
| 主机级 newt 台数 | 4（node2 + k1/k2/k3） | **8**（node2/3/4/5/6 + k1/k2/k3） |
| 面板站点数 | 8（含 offline 的 node0） | **11**（node3/4/5/6 于 11-03 新增，siteId 15–18；node0 已消失） |
| 排除项 | node0 / node6 | **无**，本次全量 |

node6 这次纳入：它现在装了主机级 newt 且在线，上次的排除理由已不成立。
Mac 的 newt 不在 SSH 主机范围内，**仍是 1.19.0**（详见 §7）。

---

## 2. 版本线

| 组件 | 上游版本 | 本集群 | 说明 |
|---|---|---|---|
| Pangolin（服务端） | 1.26.0（11-04） | 1.26.0 | 用户口中的「1.26.0」只属于这条线 |
| Newt（客户端） | 1.20.0（11-03） | 1.20.0 | 1.26.0 release notes 明确要求 `Newt v1.20.0+` 才支持 SSH session logging |
| Newt 补丁 | 1.19.1（11-03） | — | 修 `data plane dies on access violation`，已被 1.20.0 包含 |
| Gerbil | 1.6.0（11-03） | 1.5.2 | 独立数据面，无 1.26.0；本次不动以免扩大变更面 |
| Badger | v1.8.0（10-21） | v1.8.0 | 11-03 解禁，见 §4 |
| Traefik | v3.7.17（10-30） | v3.7.12 | 未升；v1.8.0 的修复在插件目录服务端，不是镜像版本门槛 |

---

## 3. 执行顺序（关键：客户端先于服务端）

上次只升服务端、k8s 内还留 1.18.1 时出现过
`Newt ping with outdated config version: 2 (current: 0)`。这次让**所有客户端先到位**：

1. 备份 node1（§5）
2. node2 试点：下载 `newt_linux_amd64` 1.20.0 → 校验 `Newt version 1.20.0` →
   备份 `newt.bak-1.19.0` → `install -m 0755` → `systemctl restart newt.service` → 验证握手
3. 推广到其余 7 台；同时在 k1/k2/k3 `crictl pull docker.io/fosrl/newt:1.20.0` 预拉
4. k8s：改 manifest → 同步到 k1 仓库副本 → `bash components/newt/install.sh`
   （`secret/newt-credentials unchanged`，凭据没动）→ `rollout status`
5. node1：改 compose tag → `docker compose pull pangolin` → `docker compose up -d pangolin`
   （**只重建控制面**，traefik/gerbil 不中断）→ 等 healthy
6. 处理 Badger 漂移（§4）
7. 全量验证（§6）

GitHub 下载走 `https://ghfast.top/https://github.com/...`（机房直连不通），
8 台均一次成功，产物 39,782,023 字节。

---

## 4. Badger：结论反转 + 配置漂移（本次最需要注意的一点）

**10-24 的旧结论是错的**：当时推断「本集群 Traefik 配置深度定制、不匹配默认安装器模板，
所以 Pangolin 的自动改写会静默失败」。官方更新文档确实这么写，但 1.26.0 迁移日志实测是：

```
Starting migrations from version 1.25.3
Running migration 1.26.0
Migrated database
Updated the version of Badger in your Traefik configuration to v1.8.0
1.26.0 migration complete
```

`traefik_config.yml` 指纹 `d4c74bd1ad4727d3a386fef0f2a9057e` → `2cc2cf735c630d5ae811f3b341a3a72a`。

- **v1.8.0 已解禁**：1.26.0 release notes 说明 Traefik 团队 11-03 修好了阻止它被拉取的 bug。
  修复在插件目录服务端（Traefik 最新稳定版 v3.7.17 发布于 10-30，早于 11-03），
  所以 v3.7.12 也能加载。`v1.8.0` 的 `go.mod` 是 `go 1.25`，正是当初校验卡住的点。
- ⚠️ **迁移只改配置文件、不重启 traefik** → 一度出现「配置 v1.8.0 / 运行态 v1.7.0」漂移。
  不处理的话，下次任何一次 traefik 重启才生效，等于埋雷。
- 处理：先确认 `safeline-detector` 为 healthy（没重启才安全），再 `docker restart traefik`。
  重启后验证：
  `Plugins loaded. plugins=["badger","crowdsec","safeline"]`、
  插件缓存 `/plugins-storage/archives/github.com/fosrl/badger/v1.8.0.zip`、
  源码 `go.mod` = `go 1.25`、入口 200，且日志无
  `crowdsec … 403` / `safeline error in detection` / `broken pipe`。
- 若加载失败，回滚只需 `sed -i 's/version: v1.8.0/version: v1.7.0/'` 后重启 traefik，
  不要整份覆盖旧配置（11-06 之后安全栈配置已变）。

---

## 5. 备份与回滚

| 内容 | 位置 |
|---|---|
| node1 compose + 整套 config + SQLite 一致性快照 | `/root/pangolin-backups/20261110-043559/`（4.8G） |
| 一致性快照 | 同目录 `snapshot.sqlite`，447,115,264 字节，与原 `db.sqlite` 一致（python `sqlite3.backup()` API） |
| 升级前 compose | node1 `/home/docker/pangolin/docker-compose.yml.bak-p1.26.0-<时间戳>` |
| 旧 newt 二进制 | 8 台各自 `/usr/local/bin/newt.bak-1.19.0` |
| 升级前 k8s Deployment | 本地 `/tmp/newt-deploy-before-1260.yaml`（临时文件，长期请自行归档） |

**schema 迁移后不可降级**（官方明示），回滚必须用上面的快照整体恢复，不要只换镜像 tag。
Pangolin 自己也会在 `config/db/backups/` 留一份迁移前 DB，但别只依赖它。

---

## 6. 验证判据

```
8 台主机级 newt：Newt version 1.20.0 / active / Server version: 1.26.0 / Tunnel connection ... successfully!
k8s newt：      image=docker.io/fosrl/newt:1.20.0  ready=1/1  Server version: 1.26.0
node1：         fosrl/pangolin:1.26.0 Up (healthy) / Badger v1.8.0 / 插件缓存 v1.8.0.zip
面板：          11 个站点 online=1（node1-local, node2, mac, k8s-cluster, k1, k2, k3, node3, node4, node5, node6）
服务端告警：    0 条
公网入口：      pangolin.apikv.com 200 / shop.apikv.com 200 / gorse 302 / grafana 302
```

客户端日志 `Server version: 1.26.0` 才是隧道真正确认的判据，**别拿 Pod Running / service active 当通了**。

---

## 7. 遗留项

- ~~**Mac 的 newt 仍是 1.19.0**~~ → **05:47 已补升到 1.20.0**，见 §8。至此全部 newt 客户端版本自洽。
- ~~**`gateway.apikv.com` 仍 404**（资源在库且 enabled，路由未命中）~~ → **05:55 查明：不是故障**，见 §9。
  10-28 那句「路由未命中」本身就是误判——它已到集群，只是根路径没注册 procedure。
- **Gerbil 1.5.2 → 1.6.0** 未升（独立数据面，1.26.0 无要求）；**Traefik v3.7.12 → v3.7.17** 未升。
- ~~node0 站点（siteId 8）已从 `sites` 表消失，10-28 记录中已提出待确认~~ → **06:10 查明：主机改名 + 重装，旧站点随删**，见 §10。
- ~~Mac newt 日志 `~/Library/Logs/Newt/stdout.log` 仍无 rotation~~ → 06:18 已按日志分析结果选定方案 B 并改 plist；
  ⚠️ **但 launchd 作业重新加载失败，Mac newt 当前未运行，需手动恢复**，见 §12。

---

## 8. 追加：Mac 的 newt 升到 1.20.0（05:47）

Mac **不是 SSH 主机**，是 launchd 托管：`~/Library/LaunchAgents/net.pangolin.newt.plist`
写死二进制路径 `/Users/lens/.local/bin/newt`，凭据直接放在 `ProgramArguments` 的 `--id` / `--secret` 里。

1. 下载 `newt_darwin_arm64` 1.20.0：直连 GitHub 慢，走 `https://ghfast.top/https://github.com/...`，
   38,109,232 字节，与上游 release 产物大小一致。
2. 校验：`Mach-O 64-bit executable arm64`、`Newt version 1.20.0`、
   `codesign` identifier `io.fossorial`。
   旧二进制有 `com.apple.provenance` xattr（不是 quarantine），不影响执行。
3. 备份 `~/.local/bin/newt.bak-1.19.0`（连原有的 1.17.0 / 1.18.1 共三份可回滚）。
4. 原子替换：`install -m 0755 … "${BIN}.new"` → `mv -f` 覆盖，避免运行中的进程读到半个文件。
5. `launchctl kickstart -k gui/501/net.pangolin.newt`（PID 5307 → 78576）。**plist 不用动**。

验证：

```
INFO: 2026/11/10 05:47:10 Newt version 1.20.0
INFO: 2026/11/10 05:47:11 Server version: 1.26.0
INFO: 2026/11/10 05:47:12 Tunnel connection to server established successfully!
INFO: 2026/11/10 05:47:12 Started tcp proxy to 127.0.0.1:3080 / 9730 / 9528
```

面板 `mac`（siteId 6）`online=1`。`auth-daemon is only supported on Linux, not darwin` 是预期的平台限制。

---

## 9. `gateway.apikv.com` 404 定性（05:52–05:56）

**结论：不是故障，是 Connect RPC 网关的正常响应。10-28 全景图里「资源在库且 enabled、路由未命中」
这个判断本身错了——路由命中了，请求也到了集群，404 是后端应用返回的。**

### 证据

```
GET https://gateway.apikv.com/        → 404  {"code":"not_found","message":"no route for this procedure",
                                             "details":[{"type":"google.rpc.ErrorInfo", ...}]}
                                          server: envoy
                                          x-error-reason: ROUTE_NOT_FOUND
                                          x-envoy-upstream-service-time: 1   ← 已到上游
GET https://gateway.apikv.com/readyz  → 200  ok
GET https://gateway.apikv.com/healthz → 200  ok
```

`x-envoy-upstream-service-time` 有值就说明 envoy 把请求转发到了后端、后端回了包；
纯「Pangolin 没资源 / Traefik 没路由」不会带这个头，也不会是 Connect 协议的 JSON 错误体。

### 完整链路（逐层验证过）

| 层 | 对象 | 状态 |
|---|---|---|
| Pangolin | resource `rid 72` `gateway`，`fullDomain=gateway.apikv.com`，enabled=1，mode=http | ✅ |
| Pangolin target | `targetId 97` → siteId 11 `k8s-cluster`，`10.10.31.240:443` https，tlsServerName `gateway.dev.test` | ✅ |
| 集群入口 | Cilium Gateway `default/cilium-gateway` LB `10.10.31.240`，PROGRAMMED=True | ✅ |
| HTTPRoute | `ecommerce/control-tower-gateway`，hostnames `[gateway.dev.test, gateway.apikv.com]`，PathPrefix `/` → `ecommerce-gateway-service:8080` | Accepted / ResolvedRefs ✅ |
| 后端 | `control-tower-gateway` 2/2 Running（control-tower 0.2.18） | ✅ |

### 为什么根路径必然 404

`gateway` 服务是 **Connect 原生反代，按一级 proto 包名路由**（见 `control-tower/README.md`）。
它不是网站，没有注册 `/` 对应的 procedure，所以任何非 RPC 路径都返回
`no route for this procedure`。`/readyz` 与 `/healthz` 是它单独注册的探活端点，才返回 200。

**没有「改名成 config.apikv.com」这回事**，三个域名是三个服务：

| 域名 | 服务 | 根路径 | 探活 |
|---|---|---|---|
| `config.apikv.com` | config-web 前端 | 200 HTML | `/` |
| `config-api.apikv.com` | 配置 API | 401 需认证 | `/healthz` 200 |
| `gateway.apikv.com` | Connect RPC 网关 | 404（无 procedure） | `/readyz` 或 `/healthz` 200 |

### 怎么"解决"的

后端不该改（给 RPC 网关加首页没有意义，且会把 API 语义弄脏）。真正的修复落在**消除误判**：

- `control-tower/AGENTS.md` 里 9-27 的历史结论「Pangolin 里没有这条资源、公网仍 404」已过时
  （rid 72 后来重建了），已改写为当前事实，并把旧结论折叠保留备查；
- 明确写出「纯文本 `404 page not found` = 没到集群；应用层 JSON `no route for this procedure`
  = 到了集群但 procedure 没注册」这个区分方法；
- 明确「**探活只能用 `/readyz` 或 `/healthz`**」；
- 本记录 §7 与 10-28 全景图里的这条未决项一并划掉。

Gatus 当前没有对 `gateway.apikv.com` 配置检查（grep 无命中），所以不存在持续误报告警需要修。
若要加监控，端点应写 `/readyz`，而不是 `/`。

### 06:28 严格复核：只是探测路径选错，服务没有故障

上次只证明了「进程活着 / 请求到了集群」，这次把路由表、后端转发、鉴权链都实测了：

```
GET  /                              → 404  x-error-reason: ROUTE_NOT_FOUND
                                          {"code":"not_found","message":"no route for this procedure"}
POST /user.v1.UserService/SignIn    → 400  {"code":"invalid_argument",
                                          "message":"validation errors: code/state must be at least 1 characters"}
GET  /admin/health/services         → 401  x-error-reason: JWT_MISSING
GET  /readyz | /healthz             → 200  ok
```

- **400 `invalid_argument` 是决定性证据**：真实 RPC 被按一级 proto 包名 `user` 命中
  （`routes/pre.yaml`: `user → direct://ecommerce-user-service.ecommerce.svc:30001`），
  转发到后端并由后端做了字段校验。若路由表没加载，这里会是 404 `no route for this procedure`。
- **401 `JWT_MISSING`** 说明 JWT 鉴权中间件在工作（该端点要求 admin）。
- 网关自己的 access log 直接写明根路径 404 的来源：
  `{"level":"info","msg":"access","method":"GET","path":"/","status":404,
  "upstream":"","reason":"ROUTE_NOT_FOUND","duration":0.041179636}`
  —— `upstream` 为空 = **没有转发给任何后端**，不是后端超时/挂掉。
- 集群侧：`control-tower-gateway` 2/2 Running 38min、近 15min 无 error/panic、
  HTTPRoute Accepted/ResolvedRefs、Gatus 探针 `code="200" total=9`、`endpoint_success=1`。

**结论：`404` 100% 是探测方法错误（拿 `/` 当健康检查），不是真故障。**

对照——「真有问题」会是这样：Pangolin 资源没了 → 纯文本 `404 page not found` 且无
`x-envoy-upstream-service-time`；后端挂了 → 502/503 且 access log `upstream` 非空；
路由表加载失败 → `/readyz` 503（9-15 `discovery:///` 空 catalog 踩过）。
当前现象全不在此列。同一判据已同步到 `control-tower/AGENTS.md`。

> 注：Mac 的 newt（siteId 6）此时因 §12 的 launchd 问题处于 offline，
> **与 gateway 无关** —— gateway 走的是 siteId 11 `k8s-cluster` 的 newt 隧道。

---

## 10. Gatus 补 `/readyz` 探针（06:12）

`components/gatus/endpoints.yaml` 的 `public-edge` 组新增 `control-tower-gateway-edge`：

```yaml
  - name: control-tower-gateway-edge
    group: public-edge
    url: https://gateway.apikv.com/readyz
    interval: 2m
    client: {timeout: 10s, ignore-redirect: true}
    conditions: ["[STATUS] == 200", "len([BODY]) > 0", "[CERTIFICATE_EXPIRATION] > 720h", "[RESPONSE_TIME] < 5000"]
    alerts: [{type: custom, failure-threshold: 6, success-threshold: 4}]
```

同时改掉组头注释里 9-22 那句「gateway / mall / bugsink-edge 仍未部署，不恢复探针」——gateway 已上线，
只剩 mall / bugsink 未部署。同步 `endpoints.yaml` 到 k1 仓库副本后跑 `components/gatus/install.sh`
（ConfigMap 指纹变化触发 Pod 滚动）。

验证：`rollout status` 成功、ConfigMap 含新条目、Pod 1/1 Running、日志无配置解析错误、
metrics 里 `gatus_results_endpoint_success{name="control-tower-gateway-edge"} = 1`、
`code="200" total=1`、`duration≈225ms`。

---

## 11. node0 站点消失的溯源（06:10，结掉 10-28 未决项）

**结论：不是故障，也不是 10-24 升级导致。是同一台云主机改名 + 重装，旧站点被有意删除后重建。**

### IP 比对（决定性证据）

| 来源 | 值 |
|---|---|
| 10-24 DB 快照 `/root/pangolin-backups/20261024-132731/snapshot.sqlite`，`sites` 表 siteId 8 `node0` | `endpoint = 115.159.84.100:63774`，`localEndpoints = ["172.18.0.2:63774"]`，`online=0` |
| 当前 `~/.ssh/config` 的 `Host node5` | `HostName 115.159.84.100`，`Port 38415`，`User root` |
| `CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md` 延迟测试 IP 列表 | 首个 `115.159.84.100` 对应当时的 `node0` |
| 当前面板 `sites` 表 | siteId 17 `node5`，`online=1`（无 siteId 8） |

**公网 IP 完全一致**，说明是同一台机器换了主机别名，不是"一台机器消失、另一台新加"。

### 时间线（git + DB 快照）

| 时间 | 事件 |
|---|---|
| 10-20 | `CLOUD-HOSTS-JOIN-ANALYSIS`：node0 = 腾讯 ap-shanghai，跑 blog(Docker) + newt + otelcol + crowdsec |
| 10-23 01:15 | commit `a862fa78`「将 node0 从主机监控预期清单移除（**已改 Windows**）」→ newt 停了，站点转 offline |
| 10-24 13:27 | 升级备份快照里 siteId 8 仍在，`online=0`、`lastPing=1792650051`（10-22 后就没再 ping） |
| 10-24 ~ 10-28 | 面板里删除 siteId 8（`actionAuditLog` 是空表，拿不到精确时刻；Pangolin 不记录该操作） |
| 10-28 00:09 | 全景图记录「node0 站点消失」，列为未决 |
| 11-03 00:31 | commit `fbc4048e`「node5/node6 重装后重归观测」明确写 **「node5（原 node0 重装 Ubuntu 26.04）」**，并新增 newt 站点 siteId 15–18 |

所以 10-28 那句「今已不在库里」的谜底就是：**Windows → 重装 Ubuntu 26.04 → 改名 node5 → 删旧站点建新站点**。
旧 siteId 8 与新 siteId 17 是同一台物理机的两代身份，凭据（pubKey）也完全不同，不是简单改了个 name。

### 剩余

`actionAuditLog` 表为空，无法给出站点删除的精确时刻和操作者；但用户已确认原因是「更换了名称」，
与 IP 比对、git 提交说明三者一致，这项未决可以结掉。10-28 全景图里剩下的就只有
**Mac 日志轮转**与**版本巡检脚本**两项工程债。

---

## 12. Mac newt 日志分析 → 选 B（06:17–06:20）⚠️ 收尾未完成

### 日志正则分析结论：ERROR 多，但没有严重事件

`~/Library/Logs/Newt/stdout.log`：3,205,976 字节 / 31,069 行 / 2026-09-08 04:11 → 2026-11-10 05:47。

| 级别 | 行数 | 占比 |
|---|---|---|
| ERROR | 25,362 | 81.63% |
| OTHER（无级别前缀的续行） | 3,118 | 10.04% |
| INFO | 2,009 | 6.47% |
| DEBUG | 456 | 1.47% |
| WARN | 124 | 0.40% |
| **FATAL / PANIC** | **0 / 0** | — |

ERROR 去重 TOP：

```
21301 × Error connecting to target: dial tcp <ip>:<port>: connect: connection refused   (本地端口无人监听)
 2787 × Failed to connect: ... get token ... 404 page not found                        (历史维护窗口)
  939 × ... Post ".../get-token": dial tcp ... connection refused
   90 × Error accepting TCP connection: endpoint is in invalid state
   78 × Failed to send message: not connected
   52 × ... 502 Bad Gateway. Retrying ...
   23 × Failed to ensure WireGuard interface: invalid IP address format
```

`connection refused` 的端口分布：9528 → 10,658 次、9730 → 10,605 次、3080 → 38 次
（Mac 本地三个后端服务没常开时，每来一个请求报一条）。
**该类最后一次出现在 2026-11-03 07:11:20，之后完全消失。**

按天看最近一周 ERROR：11-03:1 / 11-04:0 / 11-05:2 / 11-06:0 / 11-07:14 / 11-09:3 / 11-10:1。
最后一条 `token/connect` 是 04:46:11 升 Pangolin 1.26.0 时的 502 重试，随后
`Tunnel connection to server established successfully!`。`stderr.log` 为 0 字节，
`panic` / `crash` / `segfault` / `broken pipe` 命中均为 0。

**判定：日志没有需要保留的诊断价值**（只剩「本地端口有没有人在听」的噪音，
公网链路已由 Gatus `/readyz` 覆盖），按用户给的条件选 **方案 B**。

### 已改动

- 备份 `~/Library/LaunchAgents/net.pangolin.newt.plist` →
  `net.pangolin.newt.plist.bak-before-devnull-20261110`（951 字节）。
- plist 的 `StandardOutPath` / `StandardErrorPath` 由
  `/Users/lens/Library/Logs/Newt/{stdout,stderr}.log` 改为 `/dev/null`（现 889 字节，
  `plutil -lint OK`）。**历史 3.2MB 日志文件保留未删**。

### ⚠️ 未完成：launchd 作业重新加载失败，Mac newt 当前是停的

改 plist 必须 unload/load 才生效。执行 `launchctl unload` 成功后，
**所有重新注册方式都返回 `Bootstrap failed: 5: Input/output error`**：

- `launchctl load` / `load -w` / `load -F -w`
- `launchctl bootstrap gui/501` / `user/501`
- `launchctl enable` + `bootout` + 重试
- `xattr -c` 清 provenance 后重试、`plutil -lint` 均 OK
- 无沙箱环境重试、`osascript do shell script` 走 GUI 上下文
- **连一个全新的最小测试 Label（`wb.probe.test`，`/bin/sleep 60`）也 EIO 5**
  → 说明不是 plist 内容或 `/dev/null` 的问题，是**当前执行环境无法向 launchd 注册新服务**；
  同一会话里 `kickstart -k` 对已登记服务能成功（05:47 换二进制时验证过），走的是不同路径。

后果：`launchctl list` 无 `net.pangolin.newt`、`pgrep` 无 newt 进程、
面板 `mac`（siteId 6）从 online=1 变 **online=0**。

### 恢复步骤（需用户在本机 GUI 终端执行）

```bash
launchctl load -w ~/Library/LaunchAgents/net.pangolin.newt.plist
launchctl print gui/$(id -u)/net.pangolin.newt | grep -E 'state|pid'
```

若仍 EIO：**注销并重新登录** macOS（登录时会自动加载 LaunchAgents）。
恢复后 `mac` 站点应回到 online=1，且日志不再增长。

想撤销 B（改回写日志文件）：

```bash
cp ~/Library/LaunchAgents/net.pangolin.newt.plist.bak-before-devnull-20261110 \
   ~/Library/LaunchAgents/net.pangolin.newt.plist
launchctl unload ~/Library/LaunchAgents/net.pangolin.newt.plist
launchctl load -w ~/Library/LaunchAgents/net.pangolin.newt.plist
```

> **经验教训**：以后改 LaunchAgent plist，别用 `unload` + 在 agent 会话里 `load`。
> 要么只改文件内容、用 `kickstart -k` 让进程重启（但 `StandardOutPath` 这类键不会重读），
> 要么用**符号链接**把日志路径指到 `/dev/null`（plist 完全不动），
> 要么直接让用户在自己的 GUI 终端执行加载。

### ✅ 06:35 复核：已由用户恢复，B 生效

`launchctl print gui/501/net.pangolin.newt` = `state = running` / `active count = 1`，
进程 PID 7720（`--endpoint/--id/--secret` 由 plist 传入），面板 `mac` `online=1`、
`lastPing` 在 11 秒前持续更新。**日志文件 mtime 停在 06:18:21、大小不再增长**，
说明 B 已生效（日志不再落盘）。§12 开头的告警到此解除。

> 观察差异：当前 agent shell 里 `launchctl list` 看不到该作业，但 `launchctl print gui/501/...`
> 能看到完整状态 —— 是 domain 视图差异，不是服务没起来，以 `print` + 面板 `lastPing` 为准。

---

## 13. SafeLine WAF fail-open 复发与修复（06:34–06:38）

### 发现

06:34 全量复核时发现 traefik 近 10min 有 **506 条** `error|broken pipe|detection|403` 命中，
拆开是 263 条 `safeline error in detection` + 263 条 `write tcp ... write: broken pipe`（同一批）。

| 窗口 | broken pipe |
|---|---|
| 近 1min | 22 |
| 近 10min | 262 |
| 近 2h | 1,700 |
| 历史累计 | 863,838 |

发 3 个正常请求 → 新增 11 条；近 3000 条 access.log 里 **`DownstreamStatus:403` = 0**
（2821×200 / 114×302 / 21×401 / 13×404）—— **WAF 实际没有在拦截**，插件 err 分支 fail-open 全放行。

### 根因线索

- traefik 最近启动 `2026-11-09T20:47:54Z`（本地 04:47，为 Badger v1.8.0 生效重启的那次）；
  `safeline-detector` 最近启动 `2026-11-06T23:00:47Z`，**Up 3 days healthy，没有重启**。
- 与 11-10 04:14 那次不同：那次是 detector 重启时 traefik 抢先建连接池，整批建到将被 kill 的旧进程；
  这次 detector 没动，**是重启后连接池逐渐劣化** —— detector 侧关掉空闲连接，
  SafeLine 插件没有失效重连，死连接越积越多。04:47 重启后当时 `--since 3m` 是干净的，
  到 06:35 已积累 1700 条。
- 结构性诱因（沿用 11-10 巡检结论）：插件每个 router 实例化一次、`PoolSize: 100`，
  detector 侧连接数偏多，空闲断连概率高。

### 修复（06:37）

前置检查 `safeline-detector` healthy（**不与 traefik 同时重启**），然后只
`docker restart traefik` 重建插件连接池。

验证：

```
Plugins loaded. plugins=["badger","crowdsec","safeline"]     # Badger v1.8.0.zip 缓存保留
发 5 个正常请求：broken pipe delta = 0                        # 期望 0
稳态近 1min：broken pipe 0 / error in detection 0 / level=ERR 0
GET https://shop.apikv.com/.git/config  → 403                 # WAF 恢复拦截
GET https://shop.apikv.com/             → 200                 # 不误杀
入口：pangolin 200 / shop 200 / gateway /readyz 200；面板 11/11 online
```

### ⚠️ 未根治

重启只是重建连接池，**根因（插件不重连死连接 + PoolSize 过大）仍在，
预计数小时后会再次劣化**。要根治需要三选一：

1. 把 SafeLine 插件 `pool_size` 从 100 降到 t1k-go 默认 8（先验证 mapstructure 能否解析该键）；
2. 给插件连接池加失效重连 / 空闲探活（改 vendored 代码，需走 `plugins-local/PROVENANCE.txt` 流程）；
3. **加监控把复发变成告警**：Gatus 加一条「攻击载荷应返回 403」的探针，或 vmalert 对
   `broken pipe` 日志速率告警 —— 这样复发时能立刻发现，不用靠人工复核撞见。

建议至少先做 3（成本低、不改变运行行为），再做 1。

---

## 14. SafeLine 复发根治 + Gerbil/Traefik 升级（06:43–06:55）

### 真正根因：连接池被放大了 12.5 倍

读 vendored 源码后，§13 里「插件不重连死连接」只是表象：

- `t1k-go/conn.go` 的 `onErr(err)` **本来就会** `socket.Close()` + `socketFactory()` 重新 dial；
  `Server.PutConn` 也会丢弃 `failing` 连接，`GetConn` 自动补齐；还有 20s 心跳探活。
- 问题在数量：`traefik-safeline/safeline.go` 的 `CreateConfig()` 把 `PoolSize` 设成 **100**
  （`t1k-go` 自己的 `DEFAULT_POOL_SIZE` 是 **8**），而 Traefik **每个 router 实例化一次插件** ——
  日志里实测有 **55 个实例**，于是共 **55 × 100 = 5500 条**常驻 TCP 连接压向
  `safeline-detector:8000`。
- detector 扛不住就批量关空闲连接；`onErr` 一次只修当前那一条，池里其余仍是死连接，
  **永远追不上**，于是每个请求都踩死连接 → `broken pipe` → 插件 err 分支 fail-open。
  这也解释了为什么 04:47 重启后当时是干净的、约 1.8 小时后才劣化到 1700 条。

**修复**：`CreateConfig()` 的 `PoolSize: 100 → 8`（对齐 t1k-go 默认值），
总连接数 5500 → **440**。备份 `safeline.go.bak-poolsize100-20261110`，
patch 已记入 `plugins-local/PROVENANCE.txt`（LOCAL PATCH #2）。
没有改请求重试逻辑 —— `DetectHttpRequest` 会消费 `req.Body`，重试会送空 body 导致 POST 误判。

### Gerbil 1.6.0 / Traefik v3.7.17

compose 里 `traefik` 用 `network_mode: service:gerbil`（共享网络栈、所有对外端口都在 gerbil 上），
**两个必须同时重建**，因此与 SafeLine 改动合并成一次变更窗口：

1. 备份 `/root/pangolin-backups/edge-20261110-064611/`（155M，compose + 整套 traefik 配置 + 插件源码）；
   另把 Badger `v1.8.0.zip` 备份到 `/root/badger-cache-backup/`（`/plugins-storage` 无 volume，重建会丢）。
2. 预拉 `docker.io/traefik:v3.7.17` 与 `docker.io/fosrl/gerbil:1.6.0`，均成功。
3. 改 compose 两个 tag → `docker compose up -d gerbil traefik`（pangolin 保持 healthy 不动）。
4. 上游 release notes 无破坏性变更：Gerbil 1.6.0 是 IPv6 PROXY 映射 / holepunch 队列 /
   keepalive 修复 + peer bandwidth；Traefik 3.7.13–17 是 http3、k8s、middleware 小修与 quic-go 升级。

### 兜底：Gatus WAF 活性探针

根因修了，但 fail-open 的特征是「入口仍 200」，光探首页发现不了。新增
`public-edge/safeline-waf-liveness`：探 `https://shop.apikv.com/.git/config`，
条件 `[STATUS]==403` + `[BODY].code==403` + `[BODY].success==false` + 证书，
`interval: 10m`、`failure-threshold: 3`。校验响应体是为了区分 CrowdSec ban 页面（HTML）避免假阳性。
实测 `code="403" total=1`、`endpoint_success=1`。

### 验证

```
traefik v3.7.17 / gerbil 1.6.0 / pangolin 1.26.0 healthy
Plugins loaded. plugins=["badger","crowdsec","safeline"]   ← 新 Traefik 上重新加载成功
Badger 配置 v1.8.0 + 缓存 v1.8.0.zip                       ← 容器重建后自动重拉成功
safeline config: &{Addr:safeline-detector:8000 PoolSize:8 ...} × 55 实例  ← 修复生效
启动至今：broken pipe 0 / error in detection 0 / level=ERR 0（跨 6+ 轮 20s 心跳）
/.git/config → 403（WAF 拦截），首页 → 200（不误杀）
入口 pangolin / shop / config / config-api / gateway /readyz 全 200；面板 11/11 online
Gatus 两条新探针均 success=1
```

### 回滚

- compose：`docker-compose.yml.bak-edge160-<时间戳>` 或备份目录里的原文件，改回
  `gerbil:1.5.2` / `traefik:v3.7.12` 后 `docker compose up -d gerbil traefik`。
- 插件：`safeline.go.bak-poolsize100-20261110` 覆盖回去（**会重新引入 fail-open，不建议**）。
- 全套配置：`/root/pangolin-backups/edge-20261110-064611/traefik/`。

> 观察窗口只有 4 分钟（旧问题是约 1.8 小时后才劣化），所以不能只靠这次观察下结论；
> 真正的长期保障是 §13 的根因修复 + 上面这条 WAF 活性探针：万一再复发会直接告警，
> 不用等人工复核撞见。
