# 共享主机资源指标契约

## 来源与范围

本契约统一 Grafana `ops-portal`、control-tower System 页、`d.apikv.com` 总控制台和主机资源告警。
`hosts/observability/hosts.json` 是预期主机与磁盘告警归属的唯一清单；当前为 k1–k3、node0–node4。
云主机采集部署也从该清单生成，不再依赖未版本化的 observability 目录。

原始 `system_*` 指标保持不变。共享指标由 `build-host-recording.py` 生成 `rules/host-recording.yml`，
每 30 秒评估，写入现有 VictoriaMetrics。新增记录从启用时开始，不追溯改写历史。

## 身份与单位

- `host`：主机名，全局唯一；清单禁止重名。
- `host_kind`：`kubernetes` / `cloud`。
- K8s 来源用非空 `k8s_node_name`，即使同时存在 `host_name` 也不拼接；云主机需明确 `host_group="cloud"` 和非空 `host_name`，且没有 K8s 身份。
- 缺身份数据不进入共享主机指标。原始采集端和业务进程指标不能混在一个空主机组里。
- 所有 `*_ratio` 都是 0–1。Grafana 使用 `percentunit`，control-tower 在适配层乘一次 100，总控制台格式化一次百分数。

| 记录指标 | 含义 / 额外标签 |
|---|---|
| `host:cpu_busy_ratio` | `1 - idle - wait`，先每核合并状态再平均；不把多核相加成 400%。每核必须有 idle/wait |
| `host:cpu_iowait_ratio` | 每核 wait 的平均值，独立展示，不混成 CPU 执行时间 |
| `host:memory_used_ratio` | OTel Linux `used` 状态。不等同 `1 - MemAvailable / MemTotal` |
| `host:filesystem_used_ratio` | `used/(used+free)`，排除 reserved；保留 `mountpoint`；同挂载点多个设备时拒绝合并 |
| `host:network_io_bytes_per_second` | 每条 counter 先 `rate[5m]`，再按主机/`direction` 汇总；排除 lo、容器虚拟接口和 safeline 虚拟设备 |
| `host:cpu_count` / `host:load1` | 逻辑核数 / 1 分钟负载，不把 load 再除核数冒充利用率 |
| `host:last_seen_timestamp_seconds` | CPU、内存、文件系统、网络四类原始样本的最新 Unix 秒数，回看 1 天；单类故障不冒充整机失联，规则重写不会推进它的值 |
| `host:expected_info` | 每个预期主机常数 1，包含 `disk_alert_owner=watchdog|vmalert`；不依赖曾有上报 |
| `host:signal_present` | 每预期主机、每 `signal=cpu|memory|filesystem|network` 的覆盖 0/1；0 不是零使用率 |
| `host:rules_evaluation_timestamp_seconds` | 单条全局评估时间，不带 host；检测共享规则是否仍推进 |

先保留来源标签配对互斥状态、计算每源比率，再按 host/核或 host/设备取较高比率去重；不能把不同来源的最大 idle/wait 或 used/free 拼成一个不存在的低水位。逐核模式对照原始逻辑核数校验完整性，拒绝聚合与逐核混用。所有必需原始样本年龄小于 180 秒；不完整比率不生成数值，覆盖项返回 0。

## 缺失与历史

1. 利用率缺失不补绿色零，也不回退到旧公式。
2. 页面同时看预期清单、信号覆盖、原始采样时间和规则评估时间。规则或源样本超过 180 秒表示数据延迟；通知沿用约 5 分钟原始数据缺失加 10 分钟确认，不等于页面延迟阈值。
3. 从未上报的主机也在预期清单。采集停超过 1 天后 last_seen 可消失，但主机不能从清单自动消失。
4. VictoriaMetrics 会丢弃 NaN 查询结果。Grafana 即时展示用独立的 -1 占位并明确映射成灰色「指标缺失」，不是记录到数据库的利用率；其它消费者用 null/空点。
5. 过去的曲线使用历史评估时点，不拿当前时间过滤所有历史点。图表断点不连接，规则启用前的时段明确无共享数据。

## 规则评估与依赖

vmalert 的 remoteWrite 是异步的，不能假设同组上一条 recording rule 的结果已写入。
本组记录全部直接读取原始指标和声明清单，不链式依赖其它记录；资源告警在独立组读取已持久化的记录。覆盖率拆为四条同名、不同 signal 标签的记录，避免合并表达式超过 VM 默认 16 KiB 查询长度上限；生成器拒绝重复的 record＋固定标签组合。
默认 evalDelay 与写回会引入几十秒延迟，展示新鲜度留到 180 秒，不把该延迟伪装成零。

参考：
- [vmalert limitations](https://docs.victoriametrics.com/victoriametrics/vmalert/#limitations)
- [vmalert-tool 单元测试](https://docs.victoriametrics.com/victoriametrics/vmalert-tool/)
- [OTel 0.158.0 CPU 指标定义](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.158.0/receiver/hostmetricsreceiver/internal/scraper/cpuscraper/metadata.yaml)

## 告警分工与排查

`rules/cloud-hosts.yml` 保留文件路径，资源组替换为 `host-resources`，覆盖清单中的两类主机；旧六条 CloudHost 资源告警不并行保留。
现有 CPU >90%/30m、内存 >90%/15m、磁盘 >85%/15m 和 >95%/5m 不降低门槛。磁盘只匹配清单中交给 vmalert 的主机，其他仍由 host-watchdog 报；日志自监控组不变。

- `HostMetricsMissing`：一台预期主机没有近期原始样本。先看同组其它主机是否正常，云主机查 otelcol，K8s 查 otel-node；从未接入不会被遗漏。
- `HostMetricsPipelineMissing`：同类主机整组无数据，只保留一条链路待办，抑制该组逐台失联。
- `HostMetricSignalMissing`：主机还上报，但一类必要信号缺失。检查 scraper、身份和 host-recording 的实际结果；不要填零。
- `HostMetricRulesStale`：共享评估时间不推进，检查 `/api/v1/rules` 的 host-recording health/lastError 和 remoteWrite，不逐台重启业务。
- 资源水位告警：联看忙碌率/iowait、used 内存、`df`、进程与容器。阈值是排查入口，不代表已经定位根因。

## 生成、验证、发布

```bash
make host-metrics-generate
make host-metrics-check
# Docker 本机或一台已授权测试主机；--network none，测试内置独立存储，不写生产
bash components/vmalert/test-host-rules.sh host-recording.yml
bash components/vmalert/test-host-rules.sh host-alerts.yml
# 本机没有 Docker 服务时显式指定
TEST_HOST=node4 bash components/vmalert/test-host-rules.sh host-recording.yml
# 上线后只读核对清单、4类×8台、时间、比率范围与同一评估时刻的 raw parity
python3 components/vmalert/verify-host-metrics.py
```

上线顺序：先新增共享记录 → 确认数据和新鲜度 → 一次只迁一个消费方 → 最后替换资源告警。
首次新数据历史不足是事实，不把现役业务停掉制造验收样本。失联、计数器重启、重复来源、零分母、缺状态和 watchdog 归属在隔离 fixtures 验证。

回退：先回退有问题的消费方提交，保留原始指标和已生成共享数据；不删除历史、不重新开放公网写入。
