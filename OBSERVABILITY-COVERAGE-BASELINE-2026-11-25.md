# 可观测性覆盖基线报告（2026-11-25）

> 目的：在动手补全前，先给出「当前有什么、缺什么」的可核查基线。
> 范围：node3 边缘 ntfy、集群 k1/k2/k3、GitHub 近 2 个月活跃仓库、参考项目 `/Users/lens/lens077/ecommerce`。
> 方法：本地文件盘点 + `gh api` + SSH 只读实测（node3 ntfy db、k1 ConfigMap）+ 历史审计文档交叉验证。**本轮未做任何配置修改。**

---

## 0. 结论速览

| 项 | 现状 |
|---|---|
| ntfy 规则 | **结构完善**：3 topic 分权、page/ticket/test 分流、退避+续期上限+HMAC 静音+恢复通知；**覆盖有 8 处盲区**（见 §1.4） |
| vmalert | 10 个规则文件、约 73–75 条告警（仓库逐条 73 / 集群 ConfigMap 原始 `alert:` 75）+ 15 条记录规则；2 条抑制；覆盖应用/K8s/PG/CNC/CDC/主机/安全/观测链 |
| Gatus | 仓库 42 个端点（31 带 ntfy 直推、11 只显示）；集群 ConfigMap 43 个 `name:` 条目，基本对齐 |
| GitHub 活跃仓库 | 31 个仓库中 **24 个近 2 个月有提交**；其中 **15 个有 GitHub Actions，9 个无 CI**；7 个仓库近期有失败 CI |
| 微信文章启示 | `runtime.copystack` 占 Uber Go 集群 CPU **3.9%**（GC 为 7.3%），600 服务中 334 个 >3%；当前体系**完全没有持续剖析 / Go runtime 函数级 CPU 归因** |
| 最大缺口 | ① 持续剖析与 Go runtime 指标验收 ② Rust 服务端零遥测 ③ 集群控制面零规则 ④ 中间件（Dragonfly/MinIO/ES）只黑盒无指标 ⑤ VL/VT 新鲜度与外部 dead-man ⑥ 应用层 APM 面板缺失 |

---

## 1. ntfy 规则检查

### 1.1 服务端现状（node3 实测）

- 容器 `ntfy-ntfy-1`，镜像 `binwiederhier/ntfy:v2.38.2`（11-25 升级），healthy，绑定 `10.1.4.10:8080→80`，经 Pangolin/Traefik 暴露 `https://ntfy.apikv.com`。
- `server.yml`：`auth-default-access: deny-all`、`enable-login: true`、`behind-proxy: true`、`cache-duration: 12h`；`upstream-base-url: https://ntfy.sh` 用于 iOS APNs 中转（只转 topic 哈希，不转正文，属于已知取舍）。
- 只读查询 `data/lib/user.db`：用户 `cat` / `cat-mobile` / `infra-publisher` / `blog-reminder` / `infra-alerts-reader` / `infra-alerts-publisher` / `admin`；topic 为 `infra-alerts-<32位随机>-{page,ticket,test}`（另 `cat-evt-%` / `cat-cmd-%`），三 topic 读写权限分离，发布者与读者分离。
- 结论：**鉴权模型本身完好**，三 topic 隔离、最小权限、随机后缀防枚举。

### 1.2 规则与路由

| 生产者 | 路径 | topic / 优先级 | 降噪 |
|---|---|---|---|
| vmalert → Alertmanager → alert-bridge | `:9099/alerts` → ntfy | page=`NTFY_TOPIC` 优先级 4；ticket 优先级 2；test 优先级 1；恢复 2 | page 1/2/4/8/24h、8 次后续 3d 慢心跳；ticket/test 4/8/16/24h、6 次后 7d 慢心跳 |
| Bugsink webhook（预留，服务未部署） | `:9199/bugsink/<token>` | 主 topic，优先级 5，`bug` 标签 | 桥内无去重 |
| Gatus | custom provider 直推 | 主 topic，触发 4 / 恢复 2 | `minimum-reminder-interval: 0s`，仅状态转换 |
| healthchecks | UI 内 ntfy integration | 同 token，topic 在 UI 配 | check 自身 grace 期 |
| host-watchdog | 各主机 `notify.py` 直推 | page/ticket，同级优先级 | 1/2/4/8/24h 与 4/8/16/24h，**无续期上限**；去抖 600s / 恢复 300s |

- Alertmanager：`group_wait 1m` / `group_interval 5m` / `repeat_interval 15m`；Watchdog → null；抑制 2 条（`K8sNodeNotReady` 抑制 `category=kubernetes`、`K8sClusterMetricsMissing` 抑制 8 条 K8s/采集规则）。
- ack 静音：HMAC-SHA256 + 1h 有效期 + 时长白名单 4h/24h/3d/7d；只压「成员不变的续期」，新成员/新 episode/恢复永不吞；状态落 PVC，`reason=acked` 可观测。
- 11-25 升级后实测：vmalert ConfigMap 10 文件 / 75 条 `alert:`；Gatus ConfigMap 43 个 `name:`。

### 1.3 规则是否还足够完善？

**结构层面：够完善。** 11-07 全量审计 + 11-10 复审已把证书逾期、CNPG 备份、CDC 位点、d-console 盲区、watchdog 清单漂移等问题闭环；阈值 `AlertBridgeNotificationFlood` 已由 20/h 校准到 40/h（7 天实测 page 峰值 29/h）；当前无需要删除的死规则。

**覆盖层面：仍有 8 个盲区。**

1. **无独立外部 dead-man**：vmalert/AM/bridge/Gatus/watchdog 最终都依赖 node3 上同一个 ntfy + 同一公网入口，同域故障会集体失声。
2. **VL/VT 写入新鲜度无探针无规则**：Gatus `observability-pipeline` 只查 VM 与 AM Watchdog；`OBSERVABILITY-INTEGRATION.md` 说会查 VL 容器日志与 Event，实际没有。
3. **healthchecks 的 check 清单与 ntfy integration 只在 UI**，不在版本控制，审计看不见。
4. **host-watchdog 无续期上限**，退役检查项必须手工 `retire-check.sh`，否则 `incidents.json` 僵尸条目永久滞留且不补发恢复。
5. **Gatus console-edge 11 个端点零告警**，只给控制台卡片显示（部分已用 public-edge 带告警探针补位，但组本身仍无告警）。
6. **证书有效期只靠 Gatus 的 `[CERTIFICATE_EXPIRATION] > 720h` 条件**，无独立证书日历/续期任务成功率规则；11-25 刚升级过 ntfy/Pangolin/Traefik/Casdoor，下一次真实续期演练在 2027-01 ARI 窗口。
7. **node1 已退役**（11-12 边缘迁 node3）但 `hosts/node1.env`、`node1-public` 探针命名仍在；node4/5/6 无 watchdog env；node3/5 无 docker，容器层天然盲区。
8. **通知「送达」不可证**：bridge 的 `sent` 只证明 ntfy 接受发布，不能证明手机收到；alert-bridge `/metrics` 只覆盖 AM webhook 路径，不覆盖 Gatus/watchdog/证书任务/Bugsink 直推。

---

## 2. GitHub 活跃仓库 CI 检查

统计口径：`gh repo list` 共 31 个仓库，按 `pushedAt` 取最近 61 天，得 **24 个活跃仓库**（名单见下表）。

| 仓库 | 最近提交 | Workflow 数 | CI 信号 | 近期状态 |
|---|---|---:|---|---|
| kubernetes | 11-25 | 0 | — | 无 GitHub Actions；配置变更靠本地脚本/集群内验证 |
| cloud-native-deploy | 11-24 | 0 | — | 无 CI |
| snow-runner | 11-24 | 0 | — | 无 CI |
| blog | 11-24 | 3 | test/build/deploy | success |
| sumery-cn | 11-24 | 3 | test/lint/build/deploy/e2e | **CI/Pages 失败：`prettier --check`** |
| Scorpius | 11-22 | 5 | test/lint/race/build/deploy/e2e | **context-gate「门禁元评测」失败 1 次** |
| ToDo | 11-22 | 3 | test/lint/build/deploy（含 `rust-check`） | success |
| go-connect-template-cli | 11-22 | 1 | test/lint | **5/15 失败** |
| go-connect-template | 11-22 | 1 | test/lint | success |
| Libra | 11-22 | 0 | — | 无 CI |
| palcommerce | 11-22 | 0 | — | 无 CI（业务仓，最值得补） |
| ecommerce | 11-22 | 12 | test/lint/race/security/build/deploy/e2e | success（覆盖最完整） |
| deepseek-harness | 11-21 | 20 | test/cover/security/bench/build/deploy/e2e | **E2E (real DeepSeek API) 15/15 失败** |
| control-tower | 11-21 | 3 | test/lint/race/build/deploy/e2e | **CI 2/15 失败** |
| 3a1-multiplayer | 11-19 | 1 | test/deploy（k8s-release） | 无近期 run |
| jimao-3a-consumer | 11-19 | 0 | — | 无 CI |
| tauri-fullstack-template | 11-18 | 1 | release | 无近期 run |
| mcm | 11-18 | 4 | test/lint/build/deploy/e2e | **ci 2/15 失败** |
| LyraPass | 11-18 | 3 | CI / Cloud E2E / Desktop beta | **CI 9/15、Cloud E2E 有失败** |
| qqbot | 11-18 | 0 | — | 无 CI |
| horizon-rush | 11-18 | 0 | — | 无 CI |
| cs2-four | 11-18 | 1 | test/deploy | success |
| go-connect-kit | 11-05 | 1 | test/lint | success |
| docker-deploy | 10-14 | 0 | — | 无 CI |

**横向判断：**

- 24 个活跃仓库中 **9 个完全没有 CI**（含 palcommerce、kubernetes、docker-deploy 三个运维/业务关键仓）。
- 信号覆盖极不均衡：`race`/`security` 只有 ecommerce、control-tower、Scorpius 等少数有；`coverage` 仅 deepseek-harness；`benchmark` 仅 deepseek-harness；**没有任何一个仓库在 CI 里检查 OpenTelemetry/指标契约**（如 OTel SDK 版本、span 名、`service.namespace`、runtime 埋点验收）。
- 7 个仓库近期失败；其中 deepseek-harness 的「真实 API E2E」连续 15 次失败，属于持续红灯而非偶发；sumery-cn 是格式门禁失败，容易修。
- **CI 失败通知目前没有统一进 ntfy**：GitHub Actions 默认只发邮件，桥接器没有 GitHub webhook 入口，这是「CI → 可观测性 → 告警」的直接缺口。

---

## 3. 微信文章的直接启示（Go 侧）

文章：Tony Bai《Go 的 goroutine 栈增长，为什么会吃掉 Uber 近 4% CPU？》（2026-11-25），依据 Uber Issue golang/go#77893。

| 事实 | 数据 | 对可观测性的要求 |
|---|---|---|
| `runtime.copystack` 占 Uber Go 集群 CPU | 3.9%（GC 7.3%）；600 服务中 334 个 >3%、406 个 >2%、509 个 >1% | 必须能按**函数级 CPU 归因**，否则这类开销被当成「业务正常开销」 |
| Go 1.19 自适应栈的盲区 | GC 快照看不到短生命周期 RPC goroutine 的峰值栈需求 | 需要 goroutine 数量 / 栈大小分布 / 生命周期指标，而不只是总量 |
| Stack Cache（CL 793780） | copystack 4% → 0.2% | 优化前后需要可对比的 CPU profile 基线与回归门禁 |
| Lend Budget / Token Budget | 默认 `GOMAXPROCS * 2048KB`；token 默认 64、上限 255；`GODEBUG=stackcachelendkb=0` / `stackcachetokens=0` 可关 | 需要内存与 CPU 的联动观测，避免「CPU 降了内存涨了」 |
| Watermark（CL 793920） | 三个服务 copystack 降到 0.7% / 0% / 0.4% | 需要长期趋势，不是一次性抓取 |
| 合成 benchmark | 几何平均耗时降 92.68% / 92.99%（特定短生命周期大栈负载） | 需要 benchmark 结果入库（`go test -bench` → VM）做版本回归 |

**当前状态：全链路无持续剖析组件**（无 Pyroscope/Parca/pprof sidecar、无 CPU profile 入库、无 profile diff 看板）。ecommerce 虽开了 `RuntimeMetrics: true`，但产出的是 OTel 语义名（`process.runtime.go.goroutines` → `go_goroutine_count` 等），APM 盘 R4 段仍标 P1「等 runtime 埋点发版」，actual series 未验收；`runtime.copystack` 这类**函数级 CPU**完全不可见。

---

## 4. 分层覆盖矩阵

图例：✅ 已有并接入 ｜ ◐ 部分/弱覆盖 ｜ ❌ 缺失

| 层 | 指标 | 日志 | 链路 | 告警/自检 | 面板 | 主要证据 |
|---|---|---|---|---|---|---|
| **Golang 应用**（ecommerce 10 服务、control-tower、go-connect-* 等） | ◐ RPC RED + OTel runtime + PG/Redis 插装；ecommerce 10 服务有 `service.namespace=ecommerce`，但实测只有 HTTP 5xx 埋点无 RPC、config-service 才有 RPC；runtime 系列已进 VM，无 copystack/GC pause | ◐ zap JSON + RPC trace_id + stdout→Vector；**OTLP log 在 K8s 被关**、go-connect-kit 已加脱敏/限流 | ✅ W3C TraceContext/Baggage、Connect/PG/Redis 插装、Collector 尾采样；前端 RUM 未关联、无 Kafka span | ◐ 4 条 ecommerce（HTTP 5xx/配置 stale/守卫）+ 2 条 config-service（RPC），+ 8 条 palcommerce；无延迟分位/SLO；无 CI 指标契约检查 | ◐ APM 盘已重建（uid `ecommerce-apm`），规则链 Explore；trace→log 已配 derivedFields | `ecommerce/backend/services/*/internal/pkg/otel/`, `go-connect-kit@v1.0.0/otel/otel.go`, `components/vmalert/rules/{ecommerce-app,control-tower-app}.yml` |
| **Rust 服务端**（ToDo `sync-server`、LyraPass `lyrapass-cloud-server`/`selfhost`、mcm import/export） | ❌ 无 metrics 暴露/抓取；LyraPass 仅 `tracing` 依赖，未见 subscriber 初始化；ToDo sync-server 无 tracing | ◐ println/tracing 默认输出，无结构化采集 | ❌ 无 OTLP | ❌ 无规则 | ❌ 无面板 | 各仓 `Cargo.toml` / `src/` |
| **系统（主机）** | ◐ otel-node hostmetrics + 云主机 host_otel；`host:*` 15 条记录规则；CPU/内存/磁盘/网络 4 类；**iowait 只记录无告警**，无 FD/TCP 重传/OOM/NTP | ◐ journald → otelcol → VL，node5/6 有历史 404/500 丢数据 | — | ◐ Host* 9 条 + 5 条观测链；node5/6 清单未同步 | ◐ ops-portal（验收口径仍是 8 台，`hosts.json` 已 9 台） | `components/vmalert/rules/cloud-hosts.yml`, `hosts/observability/hosts.json` |
| **中间件** | ◐ CNPG 13 条、Kafka/Connect/CDC 9 条；Dragonfly/MinIO/ES/Seata/Consul/ClickHouse/Redis **无 scrape job** | ◐ 容器日志经 Vector 进 VL | — | ◐ 仅 CNPG/CDC；ES 只有 Gatus 401+RT；Dragonfly/MinIO 无规则 | ◐ infra-cnpg / infra-cdc；其余无 | `components/opentelemetry/values.yaml`, `components/vmalert/rules/{cnpg,ecommerce-cdc}.yml` |
| **基础设施/存储后端** | ◐ VM/VL/VT 自身指标有 collector 抓取；**VL/VT 无写入新鲜度规则** | ✅ Vector→VL；k8sobjects Event | ✅ OTLP→VT | ◐ 观测链自身规则最密（16 warning + 6 critical + 2 readiness），但 VL/VT 新鲜度空 | ◐ infra-observability | `components/vmalert/rules/{observability-pipeline,ecommerce-observability-readiness}.yml` |
| **集群** | ◐ k8s_cluster/k8sobjects + Cilium/Hubble；**控制面零规则**（apiserver/etcd/scheduler/CM） | ◐ Event→VL | — | ◐ K8s 工作负载 6 条 + 元规则；无控制面规则 | ◐ infra-kubernetes；无控制面盘 | `components/vmalert/rules/ecommerce-k8s.yml` |
| **Docker/容器运行时** | ◐ 云主机 `container_uptime_seconds`/`container_restarts_total` 两条；**无逐容器 CPU/MEM/IO/网络、无 containerd/CRI 指标** | ◐ 容器 stdout→VL | — | ◐ 2 条（清单丢失/重启风暴）；node1 已退役清单过期；node3/5 无 docker | ❌ 无专门面板 | `cloud-hosts.yml`, `components/host-watchdog/hosts/*.env` |
| **安全（eBPF/网络）** | ◐ Tetragon 2 类事件 + Hubble drop；Tetragon 事件曾中断 11-06，判定为安静态 | ✅ Vector 分类导出 | — | ◐ 4 条有效 + 1 absent 守卫 | ◐ infra-observability | `ecommerce-security.yml` |
| **告警通知（ntfy）** | ✅ bridge/AM/gatus 指标进 VM | ✅ 每条告警落 JSON→VL | — | ✅ 分流/退避/静音/恢复齐全；8 处盲区见 §1.3 | ✅ ntfy-alerting-overview + alert-instance-detail | `components/alert-bridge/bridge.py` |

---

## 5. 补全优先级建议（待确认后再实施）

### P0 — 先让现有链路「自证活着」

1. Gatus 增加 VictoriaLogs / VictoriaTraces 写入新鲜度探针（查最近 5 分钟真实日志/span 数）；补对应 vmalert 规则。
2. 建立**外部独立 dead-man**：不依赖 node3 ntfy 的第二通道（如 healthchecks 外部 beat + 邮件/另一 topic），覆盖「整站+ntfy 同域失声」。
3. 把 GitHub Actions 失败事件接入告警桥（新增 webhook 入口 + 去重/退避），修 deepseek-harness 连续红灯、sumery-cn 格式门禁。
4. `host-watchdog`：退役 node1 清单、补 node4/5/6，按受管行流程 install → retire-check。

### P1 — 补齐 Go 运行时与主要层

5. 验收并固化 Go runtime 指标：确认 `go_goroutine_count`/`go_memory_*`/`go_schedule_duration_seconds_*` 有 series；补 `service.namespace`；补 GC pause（Go 1.19+ OTel runtime 不提供，需自定义采集）。
6. 引入**持续剖析**（pprof 定时抓取 → Pyroscope/Parca 或 Grafana Profiles），把 `runtime.copystack` / `morestack` / `newstack` 纳入函数级 CPU 看板；以当前为基线，优化后对比。CI 中加 `go test -bench` 结果入库做回归。
7. 集群控制面：新增 `control-plane.yml`（apiserver 延迟/5xx、etcd leader/raft/DB size、scheduler/CM leader lease）+ Grafana 面板。
8. 中间件：为 Dragonfly、MinIO、ES 增 scrape job → 规则 → 面板（先 Dragonfly，业务缓存最关键）。

### P2 — Rust 与体验层

9. Rust 服务端（`ToDo/sync-server`、`LyraPass/lyrapass-cloud-server`、`selfhost`）接入 `tracing-subscriber` + `opentelemetry` OTLP，统一 resource 属性与 W3C 传播；先做日志/链路，再补 metrics。
10. 重建 ecommerce APM 面板（R4 runtime 段转正）、补 trace→log 关联、merchant/admin 前端 perf 与 Bugsink SDK。
11. 日志脱敏/限流在 go-connect-kit 一处实现；清除 `ecommerce/backend/services/user/configs/dev.yml:92` 的明文 ntfy token。
12. 清理文档漂移：规则数（9/65 → 10/73–75）、主机数（8 → 9）、拓扑（node1 退役）、版本（11-25 升级）、`OBSERVABILITY-INTEGRATION.md` 中 Gatus 查 VL 的过期描述。

---

## 6. 基线盘点时点未做的事

> 以下描述的是**写基线报告时**的状态；后续已按 §5 顺序实施，实际进度见 §7。

- 未修改任何 ntfy / vmalert / gatus / Alertmanager / alert-bridge 配置。
- 未修改任何 GitHub 仓库或 CI 文件。
- 未对业务代码、Go/Rust SDK 做任何改动。
- 只读取证：node3 ntfy db 查询、k1 ConfigMap 读取、`gh api` 查询、本地文档与源码阅读。

---

## 7. 实施状态（2026-11-25 更新）

| 项 | 状态 | 证据 / 备注 |
|---|---|---|
| P0-1 VL/VT 写入新鲜度 | ✅ 已完成 | Gatus `victorialogs-log-ingestion` / `victoriatraces-span-ingestion` 双绿；OTel `prometheus/victoria` 抓 VL/VT 自身指标；vmalert 增 4 条新鲜度规则 |
| P0-2 外部 dead-man | ✅ 已完成 | `.github/workflows/deadman.yml`，30 分钟探测 5 个公网端点，失败建/更新 `deadman` issue；手工运行 45523609590 全绿 |
| P0-3 GitHub Actions 失败 → ntfy | ✅ 已完成 | alert-bridge `/github` HMAC 验签 + 24h 去重；webhook 走 `config-api.apikv.com/github`（`ack` 资源 SSO=1 不可用）；49 个单测全绿 |
| P0-4 host-watchdog 清单 | ✅ 已完成 | node1 清单清空并清理 14 条僵尸事件；node3 移除 `mcm-site` 漂移；node4/5/6 由 `cloud-hosts.yml` 覆盖，不部署 watchdog |
| P1-5 Go runtime / namespace | ◐ 部分完成 | 已验证 `go_goroutine_count` 等 series；10 个 Go 服务经 `OTEL_RESOURCE_ATTRIBUTES` 统一下发 `service.namespace=ecommerce` 并已进入 VM；RPC 指标名/错误码 label 漂移已修；GC pause 自定义采集未做 |
| P1-6 持续剖析 | ❌ 未开始 | pprof / Pyroscope / Parca 均未接入，函数级 `runtime.copystack` 仍不可见 |
| P1-7 控制面 | ◐ 部分完成 | `control-plane.yml` 3 条规则已上线，基于 `k8s_pod_phase` / `k8s_container_ready`；apiserver 延迟、etcd leader/raft、scheduler/CM leader lease 因端点只监听 127.0.0.1 尚未覆盖；无 Grafana 面板 |
| P1-8 中间件 | ✅ 抓取与规则完成，面板未做 | Dragonfly（TLS :6379/metrics）、MinIO（`MINIO_PROMETHEUS_AUTH_TYPE=public`）、ES（`elasticsearch-exporter` v1.7.0）均已进 VM；规则组 3+5+4 条全 `ok/inactive`；无专门面板 |
| P2-9 Rust OTel | ❌ 未开始 | `ToDo/sync-server`、`LyraPass/lyrapass-cloud-server`、`selfhost` 未接入 tracing/OTLP |
| P2-10 APM 面板 / trace→log | ❌ 未开始 | 面板重建与前后端 perf/Bugsink SDK 未做 |
| P2-11 日志脱敏/限流、明文 token | ◐ 部分完成 | 10 份 gitignored `dev.yml` 中的明文 ntfy token 已清空；go-connect-kit 统一脱敏/限流未做 |
| P2-12 文档漂移 | ◐ 部分完成 | `OBSERVABILITY-INTEGRATION.md` 中 Gatus 查 VL 的过期描述、node1-public 历史组名已修；规则数现为 17 文件 / 18 组 / 109 条（95 alerting + 14 recording；基线时为 9 组 / 65 条） |

当前 vmalert 规则文件 17 个、18 组、109 条（95 alerting + 14 recording）：`control-plane`、`control-plane-process`、`control-tower-app`、`ecommerce-app`、`middleware-{dragonfly,minio,elasticsearch}` 等；实测全部组 health=`ok`、无误报 firing（2026-11-25 `/api/v1/rules`）。

**2026-11-25 config-service 告警拆分**：`ecommerce-app.yml` 原有两条基于 `rpc_server_*` 的错误率/unknown 规则对 10 个 ecommerce 服务是死规则（实测这些服务只有 `http_server_*`，无 RPC 序列；RPC 序列只在 config-service 上）。本次把错误率改为 HTTP 5xx 口径（`EcommerceHTTPErrorRateHigh`），删除 RPC 特有的 unknown 占比规则，`EcommerceRPCMetricsMissing` 去掉死 RPC 分支并改名 `EcommerceAppMetricsMissing`；config-service 的 RPC 告警移到新组 `control-tower-app`（`ConfigServiceErrorRateHigh` + `ConfigServiceRPCMetricsMissing`），真相源在 control-tower 仓 `docs/operations/alerts/control-tower-app.yml`，本仓 `rules/control-tower-app.yml` 为同内容副本，改一边必须改另一边。6 条规则实测 `health=ok/inactive`。
