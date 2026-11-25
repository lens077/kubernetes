# host-watchdog 受管清单

主机侧巡检（`host-watchdog.timer`，每 5 分钟）的**检查项清单**在本目录按主机版本化管理。
巡检脚本本身不在本仓库：它在 `~/lens077/ecommerce/infrastructure/host-watchdog/`
（`watchdog.sh` / `notify.py` / `host-watchdog.service`），由各主机 `/usr/local/bin/host-watchdog` 执行。

## 为什么要有这份清单

2026-11-07 的 ntfy 全量审计宣称「规则体系健康、零漂移」，但它只比对了
**仓库文件 ↔ 集群 ConfigMap**。真正持续制造过期通知的是散落在主机本地的
`/etc/host-watchdog/watchdog.env`——它不在任何仓库里，迁移后没人同步，于是：

| 主机 | 过期检查项 | 后果 |
|---|---|---|
| node2 | `WATCH="gorse-gorse-1 minio"` + `HTTP_CHECKS` 探 `:8088` | gorse 11-04 迁入集群，容器与端口都没了，仍按退避重发 9 轮 |
| node1 | `WATCH` 含 `redis` | 实际容器名是 `redis-gorse`，业务缓存已由集群 Dragonfly 承担，误报重发 14 轮 |
| node1 | `pangolin:8` 事件滞留 | siteId 8 是已删除的 node0 站点，从 10-24 起在状态文件里躺了 16 天 |

把清单纳入版本管理后，漂移可以在 `verify.sh` 里被审计出来，而不再依赖「谁还记得哪台主机上改过什么」。

## 受管 / 非受管边界

**受管**（`hosts/<alias>.env`，可入 git）：检查项定义与阈值——
`HOST_LABEL` `WATCH` `SYSTEMD_UNITS` `HTTP_CHECKS` `PANGOLIN_DB` `PANGOLIN_IGNORE_SITES`
`DISK_PATHS` `DISK_WARN_PCT` `DISK_CRIT_PCT` `HC_PING_URL`
`NOTIFY_HOLD_SECONDS` `NOTIFY_RECOVER_SECONDS`。

**非受管**（只在主机 `/etc/host-watchdog/watchdog.env`，绝不入库、下发脚本不读其值）：
`NTFY_URL` `NTFY_TOPIC` `NTFY_TICKET_TOPIC` `NTFY_TEST_TOPIC` `NTFY_TOKEN` `NTFY_PUBLISHER_USER`。

## 用法

```bash
# 1. 改清单后先看差异（只读，默认行为）
bash components/host-watchdog/install.sh node1 node2

# 2. 确认无误才下发。只覆盖受管行；备份原文件；不改 systemd 单元
CONFIRM=yes bash components/host-watchdog/install.sh node1 node2

# 3. 审计：仓库 ↔ 主机一致性 + 僵尸事件扫描（只读，退出码 1 表示有问题）
bash components/host-watchdog/verify.sh

# 4. 若本次移除了检查项，必须清理状态文件里的旧事件
bash components/host-watchdog/retire-check.sh node2 docker:gorse-gorse-1 http:gorse
bash components/host-watchdog/retire-check.sh node1 docker:redis pangolin:8
```

下发不重启服务，下一次 5 分钟 timer 自然生效。不要为了「让配置快点生效」去 stop/start 服务——
2026-11-10 在 Mac 上为改 LaunchAgent 执行 `unload` 后，当前 agent 会话无法重新注册，
`net.pangolin.newt` 至今 offline。这是同一个道理：**改配置，别动服务管理器**。

## ⚠️ 退役检查项的顺序（务必）

`notify.py.process()` 的语义是「**缺席不等于健康**」：

```python
# Omitted/retired checks are not proof of health; never synthesize recovery.
for key in incidents.keys() - seen - held:
    incidents[key]['recover_since'] = None
    if not incidents[key]['firing_sent']:
        incidents[key]['first_seen'] = now
```

也就是说，直接从 `WATCH` / `HTTP_CHECKS` 删掉一项，**旧事件不会自动删除，也不会发恢复通知**，
条目会永久滞留在 `incidents.json` 里继续占位置。正确顺序是：

1. 先从 `hosts/<alias>.env` 移除检查项；
2. `install.sh` 下发到主机（此时旧条目标记 `recover_since=None`，但不会重建）；
3. `retire-check.sh <host> <key>...` 从 `incidents.json` 删掉旧条目。

**顺序反了会立刻重建事件**：`retire-check.sh` 会校验待删 key 是否已不在活跃检查项里，
仍在则拒绝执行。它用 `fcntl.flock` 与 timer 互斥、备份 `incidents.json` 后原子替换。

删除条目**不会**向 ntfy 补发「恢复」通知，手机通知栏里的旧故障要手动清掉。
如果需要一条说明性通知，另行确认后再发——不要把「清理动作」伪装成「业务恢复」。

## 检查项的拓扑依据（2026-11-10 核实）

- **gorse**：11-04 从 node2 docker 迁入集群 `gorse` 命名空间（master/server/worker 0.5.11），
  cache = 集群 Dragonfly **db0**（RediSearch 索引只允许 db0），data = CNPG `pg-main` 的 `gorse` 库，
  对外经 Cilium Gateway 暴露。现役监控是 `gatus/public-edge/gorse-edge-alert`（302 + 证书，6/4）。
  node2 现在只剩 minio 一个业务容器。
- **node1 Redis**：TLS 路径 `/home/docker/redis/tls/redis.crt` 早已不存在，分发链在 11-07 修复时
  已移除该目标；容器 `redis-gorse`（Up 3 days）还在，但不再是业务缓存入口。
- **mcm-site（暂留，待评估）**：容器仍在跑，但 mcm 公网站点 10-28 已迁入集群并改名 pyxis，
  Gatus 侧探针已换成 `pyxis-site`。watchdog 只查进程存活，查不出「进程活着但业务 404」——
  这是已知的覆盖盲区，不要把它当有效业务监控。本次未擅自移除。
- **Pangolin 站点检查**：`notify.py --pangolin` 按 siteId 生成 `pangolin:<id>` key。
  siteId 8（node0，同 IP 重装成 node5，现 siteId 17）已删除，故其事件条目不会再被刷新。
  siteId 6（Mac）由 `PANGOLIN_IGNORE_SITES=mac` 按精确名称忽略。

## 覆盖范围（别再引用旧口径）

2026-11-25 实测后的真实范围：

| 主机 | watchdog | 说明 |
|---|---|---|
| node1 | **已退役** | `host-watchdog.timer` inactive；边缘 11-12 迁 node3。清单检查项全部置空，14 条僵尸事件已用 `retire-check.sh` 清空（备份 `incidents.json.bak-20261125-092044`）。保留 `hosts/node1.env` 只作退役记录 |
| node2 | 在跑 | `WATCH="minio"`，systemd docker/fail2ban，minio HTTPS 深检 |
| node3 | 在跑 | 24 容器白名单 + 本地 HTTP + Pangolin 站点，随 11-12 边缘迁移建立 |
| node4 / node5 | **不部署** | 实测无运行容器、无 watchdog 脚本/单元；`vmalert/cloud-hosts.yml` 的 `host:*` 指标已覆盖主机资源与失联，再装 watchdog 只会重复 |
| node6 | **不部署** | 只有一个 `lookeke-site` 容器，`docker_stats` 已由 otelcol 上报给 `cloud-hosts.yml` 的容器清单/重启风暴规则；装 watchdog 需要先分发 ntfy 凭据，收益不足以抵消新增故障面 |
| k1/k2/k3 | — | k1 有 env 但 `WATCH=''`、只查 kubelet；k2/k3 无 env。由集群内 k8s_cluster receiver 覆盖 |

2026-11-07 报告里的「host-watchdog：k1–k3 / node1–node6」不成立；不要再把 node4–node6
写成「已覆盖容器级巡检」，准确说法是「由 vmalert 主机/容器指标覆盖」。
