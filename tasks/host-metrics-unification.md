# 实施计划：统一主机指标与消费方

## 授权与边界

用户要求按建议全部推进，并确认：
- 现役 host_otel 代码、清单、测试、部署入口迁入 Kubernetes 仓库，旧 observability 入口保留兼容转发。
- 验收通过后，把当前已部署功能分支和本次变更快进合入 main 并推送；不强推、不改历史。
- 本计划独立存放，不覆盖 observability/tasks 下尚未结束的 ntfy 工作。

只改主机指标契约及其现役消费方。保留原始 system_* 指标、现有主机日志/容器采集和凭据；不新增通知通道，不修改业务规则阈值掩盖问题，不处理本轮无关用户改动。

## 要回答的问题

1. 各页面显示的同一主机 CPU、内存、磁盘是否同口径？
2. 8 台预期主机是否全部上报？从未上线或缺某一类指标时能否看见缺口？
3. CPU 忙碌与 iowait 是否分开，逐核采集/重复 exporter 是否会放大数值？
4. 采集部署、规则和前端重建后能否复现，而非依赖机器上的临时修改？

## 契约方向

- 共享指标由 components/vmalert 生成、评估并写回现有 VictoriaMetrics，定义和测试同仓管理。
- 规范标签：host 为主机名，host_kind 为 cloud 或 kubernetes。优先使用 k8s_node_name；cloud 来源须带明确 host_group=cloud 与非空 host_name。不得把两个名字拼接，拒绝无身份数据。
- 主机清单是预期覆盖与 watchdog 分工的真相源，同时生成云主机 Ansible 清单与预期主机指标。
- CPU 忙碌率 = 1 - 平均每核 idle - 平均每核 wait；iowait 单独展示。先聚合每核状态，再对核平均；缺必要状态不补成零。
- 内存使用率沿用 OTel Linux used 状态；磁盘为 used/(used+free)，明确不含 reserved；网络排除回环/容器虚拟设备，先对 counter 求 rate 再按主机汇总。
- 所有比率是 0–1，展示百分数只在消费层转换。
- 缺数据不是零负载：预期主机独立列出，最后原始采样时间用数值保存，不能把 recording rule 的重写时间当成主机心跳。
- recording rules 直接读取原始数据，避免在同组依赖刚写回的其它 recording rule（vmalert remoteWrite 异步）。告警读取已持久化共享指标，分阶段切换。
- 新指标从上线后产生；不删除/改写历史数据，不静默回退到旧公式。需要更早时段时明确提示可查原始指标。

## 切片与验收

### 1. 契约与部署源码归位
- 将现役采集角色迁至 hosts/observability，固定依赖和二进制校验；主机清单覆盖 k1–k3 / node0–node4。
- 检查旧入口转发、离线渲染与 Ansible 语法；不启动旧 Pigsty 剧本。
- 文件预计：hosts/observability、根 Makefile、旧目录兼容入口。

### 2. 共享规则与真实计算测试
- 新增 recording rule 生成器/输出、契约文档和合成规则测试。
- 用真实 VictoriaMetrics/vmalert-tool 求值：多核不超 1、wait 分离、reserved 排除、身份为空/双标签、重复来源、缺一项/缺整机、零分母、counter 重启。
- 先证明消费端当前仍用不同原始公式的回归测试失败，再迁移。

### 3. 影子部署记录指标
- 备份精确规则 ConfigMap，仅添加共享规则，既有告警与页面先不切换。
- 核验加载状态、全部主机/标签/范围、原始数据与共享指标相同时间点比较。
- 缺记录/写回失败时停止后续迁移；不通过重启采集器或业务凑验收。

### 4. 迁移现役消费方（逐项验证）
- Grafana ops-portal 与 infra-overview：统一查询、独立 iowait、预期覆盖与缺失态。
- control-tower System 主机图：修改 catalog 与测试，不改变既有 wire；确认 8 台分线和百分比单位。
- docker-deploy/homepage：固定查询代理改读共享指标，保留 token 仅服务端、SSO 和请求白名单；修复 NaN/缓存/请求失败显示为在线的风险。
- 主机告警：同一共享口径覆盖云主机与 K8s 节点资源；磁盘归属仍由 host-watchdog 标记决定；保留现有阈值、分级和失联降噪。

### 5. 发布、验收与版本管理
- 规则逐文件校验/加载；Grafana ConfigMap 发布；homepage 按现有脚本；control-tower 遵循 GitOps tag 发布，不手动覆盖 Argo 管理的 Deployment。
- 验证实际 API / 浏览器请求中的表达式，8 台主机、缺值与真实零值、SSO/只读鉴权仍正常。
- 只读审阅与聚焦回归通过后分仓提交。保留 docker-deploy 其它未提交工作、control-tower/image.png。
- Kubernetes 功能分支快进合入 main；并记录各仓提交与实际部署版本，源码提交不冒充上线。

## 风险与回退

| 风险 | 处理 |
|---|---|
| recording rule 尚无历史导致空图 | 先部署并等新样本；明确生效时间，不补零、不删原始指标 |
| 原始数据缺失但记录结果仍被回看 | 原始采样时间与信号覆盖单独验证，消费方显示缺失/延迟 |
| 同名主机或标签冲突 | host_kind 隔离来源，清单校验全局主机名唯一；冲突 fail-closed |
| vmalert 异步写回引入依赖延迟 | 记录规则直接读原始数据，告警延后启用并验证运行延迟 |
| 重复提醒 | 保留 host-watchdog 与 vmalert 分工，不增加第二套相同告警 |
| 源码迁移覆盖其它会话改动 | 修改前后核对 git status，只按精确路径暂存/同步 |
| 默认分支含既有额外变更 | 用户已确认合入，先审阅提交列表和相关验收，不强推 |

回退优先按切片恢复消费方旧版本，保留新增共享指标与原始数据。不得以重新开放 metrics 公网写入作为本次指标迁移回退。

## 进度

- [x] 用户确认源码归属、合入策略和独立计划路径。
- [x] 发现三个现役消费方；现网原始主机指标覆盖 8 台。
- [x] 共享契约和真实求值测试通过；审阅修复状态跨源配对、整核缺失、memory 单信号故障、coverage 记录缺失四项边界。
- [x] 记录规则已持久化且影子对照通过：8 台，32 个信号覆盖项，16 条网络方向；同一评估时间的 raw parity 通过。
- [x] 现役消费方和告警源码已迁移；五台云主机通过新版本化部署入口验收，全部 changed=0。
- [x] 三个现役消费方已发布：Grafana、homepage、control-tower 0.2.21。Grafana 和 control-tower 真实登录验收通过；homepage 为真实部署数据+隔离浏览器渲染及公网SSO拒绝验证，未声称完成其SSO登录旅程。
- [x] 源码迁移、三仓提交推送及 Kubernetes main 快进合入完成。

## 验证记录

- `vmalert-tool` v1.150.0，固定镜像 digest，在 node4 的 `--network none` 临时容器中执行；独立存储，未写生产测试序列或通知。
- `host-recording.yml` fixtures：聚合/逐核、重复同值/不同值来源、双身份优先级、缺状态/缺整核、真实零、零分母、reserved、网络counter重启、单memory故障与整机停止。
- `host-alerts.yml` fixtures：never-seen 主机、整组失联只报一条、watchdog 磁盘归属、coverage absent、全局评估停止；全部通过。
- Grafana：真实公网登录 cookie+Origin，10 个实际面板查询全部执行、8 台标签齐全，桌面/420px截图验收；仅点击/接口成功不算显示成功，覆盖表文字也核对。
- homepage：18 项 Node 与 5 项 Python 测试；部署 payload 校验8台/4类/时间/比率；公网未登录仍由SSO拒绝。隔离浏览器用原样部署HTML+实际payload渲染并检查窄屏，无凭据注入、无SSO绕过；这不等于已完成公网登录旅程。
- control-tower：13组live查询通过，CPU16/内存8/磁盘8/网络16；`make verify` 全仓build/vet/竞态测试通过，Web109项和build通过。发布 run `36577175295` 全绿，0.2.21 三个 Deployment 已上线，Argo 两个 Application 均 Synced/Healthy，公网healthz的build=0.2.21。
- 真实登录 E2E run `36580892917`：系统页「共享指标覆盖全部主机，CPU与iowait独立」通过，登录/编辑器/CSP/网关等12项通过；3项管理变更用例按既有开关未启用。整体仍有1项原有legacy-token七天窗口门禁失败（旧0.2.11实例增量1），未删测或修改审计历史。
- 主要提交：Kubernetes `12ef0ba6`（源和共享记录）、`29a6ae41`（告警）、`19cbefaf`（Grafana与记录）、`cacc34ec`（兼容入口）；此前功能分支11个提交按用户确认一同快进main。docker-deploy `dbb1bf0`；control-tower `bd89963` + 验收修正 `0965904`，发布自动提交 `03c4400`。目录外用户改动未暂存或提交。
- 部署前 vmalert ConfigMap 备份：k1 `/root/rollback-host-metrics/vmalert-rules-before.json`；homepage 本次备份路径由发布日志记录，未拷贝凭据。
