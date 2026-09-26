# grafana —— 观测数据的统一门面

## 1. 定位

指标（VictoriaMetrics）、日志（Loki）、链路（Jaeger）三个后端的统一查询界面与告警入口。
数据源在安装时按**集群里实际装了哪些后端**自动预置，不用手点。

## 2. 上游最佳实践

来源：[Grafana Helm chart](https://github.com/grafana/helm-charts/tree/main/charts/grafana)

- 数据源用 provisioning（`datasources.yaml`）声明式管理，不要手工在 UI 里加——
  重建实例就丢。
- 管理员密码用 `admin.existingSecret` 或外部 secret 管理，别写进 values 提交到仓库。
- 面板同样走 provisioning（sidecar 按 label 自动加载 ConfigMap）。
- 反向代理后面部署要设 `grafana.ini.server.root_url` 与 `serve_from_sub_path`（仅子路径场景）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 数据源手工配置或写死在 values | **按集群实况生成** | `install.sh` 查各后端 Service 是否存在再决定加哪个数据源。没装 Loki 却预置了 Loki 数据源，面板打开就是一片红。 |
| 密码写 values | **走 creds 机制** | `get_cred grafana-admin` 只生成一次，存在 `/root/.k8s-installer-credentials`（chmod 600），仓库里不出现密码。 |
| 独立域名 + 自己的 Gateway | 共享网关 + `grafana.dev.test` | 见 [gateway](../gateway/) 的路由约定。旧仓的 `observability-web-gateway` 硬编码了 IP 和 3000 端口，已废弃。 |
| 无 resources | `limits 0.5c/512Mi` | 面板渲染是突发负载，限住上限避免和数据后端抢内存。 |
| `dataproxy.concurrent_query_count` 默认 | 20 | 后端是单机 VM/Loki，并发放太大只会让它们排队，反而更慢。 |

## 4. 暴露方式

- 公网：`https://grafana.apikv.com`；内部共享网关 hostname 为 `grafana.dev.test`。
- 集群内：`grafana.observability.svc.cluster.local:80`
- 凭据：用户 `admin`，密码见 `/root/.k8s-installer-credentials`

声明式资源：

- 带 `grafana_dashboard=1` 标签的 ConfigMap 由 sidecar 自动加载。`build-dashboards.py` 生成 `dashboards/*.json`；安装器逐份发布。问题工作台与实例详情位于 `Alerting`，基础设施证据位于 `Infrastructure`。
- 带 `grafana_alert` 标签的 ConfigMap 可加载 Grafana-managed rules；当前生产告警仍以 vmalert 为唯一规则所有者，避免 Grafana 与 vmalert 对同一症状重复通知。
- 面板入口：[ntfy 告警链路与降噪](https://grafana.apikv.com/d/ntfy-alerting-overview)。数据源变量按 VictoriaMetrics 名称选择，不绑定环境生成的 UID。
- 面板区分 Alertmanager 的 5 分钟 webhook 刷新与 bridge 发布/抑制。`sent` 只证明 ntfy 已接受 bridge 发布，不证明手机送达；Gatus、宿主 watchdog、证书任务和 Bugsink 直推不计入该 counter。
- Gatus 当前成功率和失败端点使用 `gatus_results_endpoint_success` gauge；累计 `gatus_results_total` 不能说明端点现在是否恢复。Watchdog 同时检查 VM 评估状态和 Gatus 对 Alertmanager 的探测，不把 remoteWrite 成功当成 AM 收到。
- 发布和失败卡片在 bridge 指标缺失时显示「无数据」，不无条件补绿色零。覆盖卡片显示 bridge 指标是否存在和 Gatus 当前有数据的端点数；短时残留受采集/回看窗口影响，成功率也不能证明配置清单中的每个端点都被采集。
- 相关规则位于 `components/vmalert/rules/observability-pipeline.yml`：桥指标缺失、桥发布失败、发布量超出试运行预算。规则沿用既有分流与退避；20/h 是待观察校准的预算，不是去重失效的证明。
- 指标从接入后开始计数；进程重启、首次抓取和采样空档可能漏计。面板内含口径与排查说明，不声称覆盖外部独立 dead-man。

### 告警说明与一键定位

工作台的问题表直接读取 vmalert `/api/v1/alerts`：显示实际 `annotations.summary`、`annotations.description`、对象标签、`activeAt` 与状态。`AlertFiringTooLong` 标为「持续提醒」，按 `exported_alertname` / `exported_alertgroup` 指向原始问题，不计作新的独立故障。

- **点击问题摘要**：打开精确实例详情，查看规则原文、表达式、实际值、条件开始时间及完整对象标签。实例以 `group_id:id` 区分，避免两个同名提醒混在一起。
- **点击查看证据**：进入相应基础设施面板，携带数据库集群、Pod、namespace、node 或 connector 过滤以及时间窗。没有具体 Pod 的聚合告警不会猜一个 Pod。
- **点击对象日志**：按实际 namespace/Pod 进入 VictoriaLogs Explore；聚合告警先进入证据页选对象。
- **列标题筛选**：按状态、类型、级别和影响对象缩小问题表。规则说明是排查建议，不等于系统已确认根因。

详情来源使用 Grafana Labs 签名的 Infinity `4.0.0`（`ds-alert-evidence`，配置在 `triage-values.yaml`）。只查询现有集群内 vmalert 告警 API，设置精确 `allowedHosts`、GET 和禁用危险 HTTP 方法；不新建规则评估服务，不向 Prometheus 写入正文标签，不更改通知路由。`alert_rows.jq` 负责映射与 URL 编码，source API 失败时返回查询错误而不是空问题表。

| 面板 | 用途 |
|---|---|
| `ntfy-alerting-overview` | 当前问题原文、实例入口、通知发布与降噪 |
| `alert-instance-detail` | 单实例说明、表达式、实际值、标签与对象链接 |
| `infra-overview` | 观测能力覆盖与统一入口；缺失来源明确标出 |
| `infra-cnpg` | PostgreSQL 可用性、备份时间与恢复点、连接、WAL 和复制 |
| `infra-kubernetes` | 节点 Ready、Deployment/StatefulSet、运行容器与重启 |
| `infra-cdc` | Connect task、Debezium、复制槽 WAL、消费 lag 和 PG/ES 对账 |
| `infra-observability` | OTel 队列、Hubble、Gatus 与通知链路 |

**边界**：实例详情是实时视图，不保存已恢复实例的历史正文。`activeAt` 是条件开始时间，包含 pending 的 `for` 阶段；不是 Alertmanager `startsAt`。备份时间戳为 0 显示无记录，不换算成 1970 年起的年龄。宿主 CPU/内存、容器实际用量、Backup CR 状态和部分服务专属指标仍需采集，不用已有 Gatus/Pod 状态冒充覆盖。

### 生成与发布

生成入口为 `build-dashboards.py`，问题表映射为 `alert_rows.jq`。现有通知统计面板沿用已验证的 JSON 查询定义，生成器只调整这些面板的布局；新详情与基础设施面板由生成器构造。修改后执行：

```bash
python3 components/grafana/build-dashboards.py
python3 components/grafana/build-dashboards.py --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s components/grafana -p 'test_*.py' -v
```

只更新面板时，无需运行会触及凭据及 Helm release 的完整安装器。获准部署后，单独更新对应 ConfigMap；以下为问题工作台示例，其他面板使用 `grafana-dashboard-<uid>` 名称与 `Infrastructure` 文件夹（实例详情使用 `Alerting`）：

```bash
kubectl -n observability create configmap grafana-dashboard-ntfy-alerting \
  --from-file=ntfy-alerting-overview.json=components/grafana/dashboards/ntfy-alerting-overview.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl annotate --local -f - grafana_folder=Alerting -o yaml \
  | kubectl apply -f -
```

预期结果是 Grafana API 返回同 UID 的 provisioned dashboard，面板查询成功；仅 ConfigMap 更新成功不算验收。离线口径回归：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s components/grafana -p test_dashboard.py -v
```

浏览器验收必须使用公网地址、登录 cookie 和浏览器自动发送的 Origin，不能用 Basic Auth 或去掉 Origin 的 API 请求替代。`verify-browser.cjs` 复用已安装的 Playwright，无需安装依赖；以同级 ecommerce 前端为例，从本仓根目录执行：

```bash
PLAYWRIGHT_MODULE="$(node -p 'require.resolve("@playwright/test", {paths:["../ecommerce/frontend"]})')" \
  node components/grafana/verify-browser.cjs
# 只跑 cookie + Origin 的快速回归：追加 --http-only
PLAYWRIGHT_MODULE="$(node -p 'require.resolve("@playwright/test", {paths:["../ecommerce/frontend"]})')" \
  node components/grafana/verify-triage.cjs
```

`verify-triage.cjs` 使用当前 `CNPGNoBackupEver` 实例验证「摘要 → 精确实例 → CNPG 对象过滤 → 对象日志」和全部基础设施入口，并检查桌面/移动布局。该实例不存在时脚本明确退出，不注入生产告警来凑验收。

脚本使用已有 `observability/grafana-admin` Secret 登录独立浏览器，只在内存传递会话，不写出凭据。验收包含：公网 Origin 查询成功、无关 Origin 仍为 403、真实面板请求无 HTTP/query/console 错误、所有数据查询均已执行；截图写到工具输出的临时目录。

## 5. 验证

```bash
kubectl -n observability get pvc grafana                     # Bound
```

真验证（登录 + 数据源连通性，而不只是 Pod Running）：

```bash
PASS=$(cat /var/lib/k8s-installer/creds/grafana-admin)
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')

# 从局域网其他主机执行
curl -sk -u "admin:$PASS" https://$GW/api/datasources --resolve grafana.dev.test:443:$GW \
     -H "Host: grafana.dev.test" | python3 -m json.tool | grep -E '"name"|"type"'

# 逐个数据源做健康检查（返回 200 才算真连通）
curl -sk -u "admin:$PASS" -H "Host: grafana.dev.test" \
     "https://$GW/api/datasources/name/VictoriaMetrics" | head -c 200
```

### 验收契约

- `build-dashboards.py --check` 检查生成结果，离线测试保护真实 annotations、实例 ID、提醒关联、URL 编码、变量命名和缺失语义。
- 先检查已导入的 datasource/plugin、dashboard UID 与源码是否一致，再通过真实浏览器请求验收。只验证 ConfigMap、Pod Ready 或 Basic Auth API 不能证明页面可用。
- `verify-browser.cjs` 验证公网 Origin 的允许/拒绝两侧、页面真实请求与控制台。它不伪造浏览器查询的数据源，也不忽略 HTTP 错误。
- `verify-triage.cjs` 验证精确实例、对象过滤、日志链接和基础设施页面。链接存在不算通过，必须点击并检查目标表达式与筛选值。
- 规则是否评估正常、实时告警数量与部署 Ready 属运行观测，需要时现查，不把某次结果当永久状态。
- 无数据场景同时检查数据源错误与指标存在性；页面空表与请求失败不能混用。真实 topic 发布、手机订阅和外部 dead-man 是独立验收，本套浏览器测试不会触发它们。

## 6. 踩坑

- **链接存在但选不中实例**：行数据中的完整 URL 已做参数编码，Grafana data link 需用 `${__data.fields["detail_url"]:raw}`，否则 `%3A` 被再次编码成 `%253A`。`raw` 仅用于本地构造、限定目标的完整链接，不把外部注入 URL 当可信入口。
- **详情有 ID 却报 JQ 错误**：Infinity 会在执行前插值 dashboard 变量。实例筛选使用 `${instance:percentencode}` 与 `(.key | @uri)` 比较；JQ 局部变量使用 `$alert_pod`、`$alert_node`，不能与 dashboard 的 `$pod`、`$node` 重名。离线契约加真实点击回归共同保护这条边界。
- **长说明截断**：`wrapText` 属于 field custom，而非 `cellOptions`；摘要使用自动单元格加链接，行高使用 `auto`。表格容器仍需足够高度，不能以 DOM 包含全文代替截图可读性验收。
- **副本表只有数字，没有对象名**：按 UID 做向量匹配时用 `group_left` 保留左侧 namespace 与 workload 名称，再合并表格帧。验收须检查实际表头和对象行，查询 200 不足以证明身份标签保留。
- **时间戳被计数阈值染色**：备份日期和恢复点用中性日期显示；timestamp=0 映射为无记录，缺失映射为中性缺失，备份年龄只在有效正时间戳时计算。不要把「大于 1 为红」的失败计数规则复用到日期或年龄。
- **所有面板红色错误标记，但脚本查询 200**：2026-09-26 公网浏览器请求报 `403 origin not allowed`。Pangolin 将后端 Host 改为 `grafana.dev.test`，浏览器 Origin 仍为 `https://grafana.apikv.com`；Grafana 的 CSRF 检查不使用 `root_url`，无 cookie 或无 Origin 的脚本请求跳过了该检查。`grafana.ini.security.csrf_trusted_origins` 只配置 `grafana.apikv.com`（13.2.2 按 hostname 匹配，不带 scheme），不使用通配符、不禁用校验。通过 `verify-browser.cjs` 同时验证允许与拒绝两侧。实现依据：[Grafana 13.2.2 CSRF 中间件](https://github.com/grafana/grafana/blob/v13.2.2/pkg/middleware/csrf/csrf.go)。
- **数据源列表是空的**：装 Grafana 时后端还没起来。重跑 `bash components/grafana/install.sh`
  即可（幂等，密码不变）。
- **Secret 与登录密码不一致**：Grafana 只在数据库首次初始化时读取管理员 Secret，之后更改 Secret 或重跑安装器不会同步数据库密码。不要删除本地凭据文件后重装来重置密码；这会扩大凭据源漂移。面板更新只操作 dashboard ConfigMap，凭据修复须作为单独的授权任务处理。
- **面板里 trace 关联不上日志**：Jaeger 数据源要配 `tracesToLogs`，这块目前没预置，
  需要在 UI 里按实际的 label 映射配置。
