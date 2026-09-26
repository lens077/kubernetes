# alert-bridge：持久降噪与 ntfy 分流

Alertmanager webhook → 单副本 bridge → ntfy JSON UTF-8 发布。只使用 Python 标准库，镜像保持 `python:3.13-alpine`。Bugsink Slack webhook 路由保留，仍直发 core；本轮不扩展它的去重语义。

## 契约

- Alertmanager 负责首次触发的 `for` 与 `group_wait`，bridge **不再延迟首发**。短时重启在 10 分钟内恢复是否不通知，必须由源规则 `for >=10m` 与相应条件保证。
- AM 的 `repeat_interval=5m` 用来重新投递；实际 ntfy 重复间隔由 bridge 管理：page 为 **1、2、4、8、24 小时**，ticket/test 为 **4、8、16、24 小时**，之后封顶 24 小时。实际触发受 AM 轮询粒度影响；bridge 无后台队列。
- 每条 member 的 severity `crit/critical` → page，其他（包括未知值）→ ticket。未知 severity 在正文可见。显式 `labels.notification_class=test` 或 `labels.notification_route=test` → test；测试 topic 未配置绝不回退 core。
- 状态 key 为 `receiver + groupKey + notification class + topic` 的 SHA-256；混合 severity 按 class 分别发送。身份为 fingerprint（缺失时完整 labels hash）加规范化 UTC startsAt，避免相同标签的新 episode 被吞；只变 annotation/value 不重置退避。
- firing 成员集合改变立即更新并重置退避。混合 payload 分别计数 firing/resolved，最多显示 3 个对象；只有已通知的 active episode 被完全覆盖恢复且上游未截断时才发完整恢复，每个 episode 一次。每个 fingerprint 的最新 startsAt 随发送成功持久化；晚到的旧 firing/resolved class 快照整体忽略，避免旧成员过滤后误删新 episode，下一轮 AM 当前快照仍可处理。已恢复 episode 的重复 firing 不重开。
- 上游 `truncatedAlerts` 会显示；截断的 resolved 载荷不能证明全组恢复，因此不清除 active 状态。建议 AM `max_alerts=0`（不截断），并用 grouping 限制组规模；bridge 仍限制请求 1 MiB / 1000 alerts。

## Topic 与环境变量

| 环境变量 | 用途 |
|---|---|
| `NTFY_URL` | HTTPS 服务根 URL；不允许 URL userinfo |
| `NTFY_TOPIC` | 已有 core topic |
| `NTFY_TICKET_TOPIC` | 显式 ticket topic |
| `NTFY_TEST_TOPIC` | 显式 test topic |
| `NTFY_TOKEN` | publisher token；匿名发布服务可为空 |
| `BRIDGE_STATE_FILE` | 默认 `/state/notifications.json`，必须放持久卷 |
| `ALERTMANAGER_LISTEN` | 默认 `0.0.0.0:9099` |
| `BUGSINK_BRIDGE_LISTEN` | 默认 `0.0.0.0:9199` |
| `BUGSINK_BRIDGE_TOKEN` | 现有 Bugsink 路径凭据；不要轮换或写进仓库 |

安装器先从 `$STATE_DIR/creds/ntfy.env` 读取默认值，再保留显式环境值（包括显式空值）。core/ticket/test 必须非空且彼此不同，否则 readiness=503、发送拒绝，安装器在修改 Secret 前退出。凭据文件保留原有内容，追加 shell 安全转义后的当前五个字段，权限 0600；与 Gatus 共用时不能删掉未知字段。现有 bridge Secret 存在而本地 Bugsink 路径 token 缺失时也退出，避免意外改坏已有 webhook。不得在日志/对话里输出 token/topic。

部署入口仍是 `components/alert-bridge/install.sh`，但生产执行属于单独授权动作。本地测试不调用安装器。

## 持久性、故障与恢复

Manifest 新增 `${SC_NAME}` 的 1 GiB ReadWriteOnce PVC `alert-bridge-state`，挂到 `/state`，UID/GID/fsGroup=1000，Deployment `replicas=1`、`strategy=Recreate`。旧新进程不得同时使用该文件；不是多副本协议。脚本 SHA 注解继续驱动滚动。

状态使用单进程线程锁 + 临时文件 fsync + 原子 replace + 目录 fsync。**只有 ntfy 成功后才提交**；失败返回 502，AM 下次重试。多个 class 之一失败时已成功 class 的状态保留，重试不会重发成功的 class。关闭的状态保留 30 天，在下一次成功提交时清理；active 组保留以支持迟到恢复。

- **首次部署空 PVC、丢失 PVC、修改 groupKey/receiver/topic 会立即重新通知当前 firing 组。** 切换前应安排维护窗口或短期明确 silence，不能假设新状态自动继承 AM 的历史。
- 发送成功后进程在持久提交前崩溃仍可能重发一次：网络发布与本地文件不能形成分布式原子事务，语义为 at-least-once，不保证 exactly-once。
- 损坏、无法读取/写入的状态使进程启动失败，不丢弃后空状态启动。出现此类故障先保留 PVC/证据，由运维决定恢复或重置；重置可能重发。
- `/healthz`：缺 URL/core/ticket/test 配置或没有初始化 engine 时 **503**，成功时 200；不实际向 ntfy 发布，因此不是端到端送达证明。
- `/livez`：进程 200，仅供 liveness，避免凭据故障引起无意义重启。readiness 使用 `/healthz`。
- 请求 JSON/schema/Content-Length 非法返回 400；过大返回 413；发送或持久化失败返回 502。异常日志仅记录 exception 类型，不打印 URL、token 或异常内容。

正文最多 6 行、UTF-8 不超过 3000 bytes，标题示例 `[故障][关注] 服务或规则 · cluster` / `[故障][待办] ...`。恢复使用 `[恢复]` 和明确恢复说明，不照抄故障 summary/description。HTTPS dashboard 可作为 Click，拒绝 userinfo/control characters/非 HTTPS。page 首发 priority=4，ticket=2、test=1、恢复=2；page 是「关注」而非要求实时操作。发布不跟随 HTTP 重定向，避免带凭据跳到另一地址；2xx 还必须解析出 JSON `event=message` 才提交成功状态。

## 指标契约

`GET /metrics` 在 9099 端口暴露 Prometheus 文本格式，由 OTel Collector 抓取后写入 VictoriaMetrics。

| 指标 | 类型与含义 |
|---|---|
| `alert_bridge_notifications_total{notification_class,result,reason}` | counter。`page/ticket/test` 与固定结果/原因组合在启动时导出零值，共 18 条 series；避免首个事件之前没有基线。`sent` 为 ntfy 已接受发布，`failed` 为发布异常，`suppressed` 为状态机抑制。 |
| `alert_bridge_state_entries{active}` | gauge。当前持久状态中的 active / closed 组数量，不是待发送队列长度。 |

指标只覆盖 Alertmanager webhook 路径，不覆盖 Gatus、宿主 watchdog、证书任务或 Bugsink 直推。`sent` **不证明手机送达**。计数器随进程重启归零，`rate` / `increase` 能处理已观察到的重置，但首次抓取前的事件、重启间隙和接入前历史仍可能漏计；不能作为消息审计账本。退避状态独立保存在 PVC，不因计数器归零而重置。

Grafana 的 `ntfy-alerting-overview` 面板显示发布、失败与抑制，规则仍由 vmalert 管理。三条 bridge 规则的排查入口随通知链接到该面板；同一发布链路故障时，它们也可能无法送达，不能代替独立外部 dead-man。

## 本地验证（无真实通知）

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s components/alert-bridge/tests -v
bash -n components/alert-bridge/install.sh
git diff --check -- components/alert-bridge
```

测试使用假 sender/clock、临时 JSON 状态和 loopback HTTP server，覆盖：持久退避与封顶、进程重建、发送失败重试、partial-class 重试、混合恢复、新 startsAt、旧 webhook、损坏状态、Unicode 上限、显式 topic、unknown severity、JSON 发布、非法 Content-Length、缺配置 fail closed、import 不启动服务器。真实 ntfy 发布只能在授权的隔离 test topic 做；不能复用 core 做测试。

### 上线/回滚核对

1. 先确认三个 topic 的写权限与手机订阅策略，Secret 包含三 topic；不能以 Secret 存在替代配置有效性。
2. 在隔离环境应用 PVC/Deployment/脚本，再验证 Ready、持久卷写权限与离线 fixture；部署过程会短暂没有 bridge，AM 应保留重试。
3. 再由维护者更新 AM grouping 与 5m repeat，并分阶段恢复业务通知。验证只读 AM status、bridge health 与持续的 ntfy 结果，不仅看 CM 内容。
4. 回滚脚本/Deployment 前保留 PVC。旧脚本不会理解新状态，也不会遵守退避；回滚前评估重复量。不要删除状态卷来「修复」通知。

本目录不包含真实凭据。Healthchecks/Gatus 的独立旁路不能因为 bridge 分流统一而移除。
