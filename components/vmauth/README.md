# vmauth —— metrics.apikv.com 的只读鉴权代理

## 1. 定位

VictoriaMetrics 单机版本身不做鉴权。2026-09-29 之前 `metrics.apikv.com` 直通 VM：公网任何人都能查询、写入，
还能调 `/api/v1/admin/tsdb/delete_series`、`/snapshot/*`、`/flags`。vmauth 是 VictoriaMetrics 官方的鉴权代理，
只挂在公网入口上，思路与 opentelemetry 的 `otlp/public`（bearertokenauth）一致：**鉴权边界只在公网入口**。

```text
metrics.apikv.com → Pangolin → 网关 metrics.dev.test → vmauth:8427 → vm-single:8428
集群内 Grafana / vmalert / collector / otel-node → vm-single:8428（直连，不经 vmauth）
```

## 2. 谁能做什么

| 身份 | 凭据 | 放行 |
|---|---|---|
| 程序（Gatus、control-tower 本地开发 / e2e / live 测试） | `Authorization: Bearer <read-token>` | 查询类 API（`query`、`query_range`、`series`、`labels`、`label/*/values`、`metadata`、`status/{buildinfo,tsdb,top_queries,active_queries,metric_names_stats}`、`export`），带或不带 `/prometheus` 前缀 |
| 浏览器 VMUI | 用户 `ops` + `ui-password`（浏览器弹框） | 上面全部 + `/vmui/*`、`/prometheus/vmui/*` 页面资源 |
| 其它 | — | 无凭据 401；已认证但路径不在白名单 400 `missing route`（不转发给 VM） |

写入（`/api/v1/write`、`/api/v1/import*`、`/opentelemetry/*`）与管理接口（`/api/v1/admin/*`、`/snapshot/*`、
`/flags`、`/metrics`、`/debug/pprof/*`）对任何公网身份都不放行。公网写入统一走 `otlp-dev.apikv.com`（opentelemetry 组件，bearer token）。
vmauth 自己的 `/metrics`、`/flags`、`/-/reload`、pprof 在独立端口 8426（`-httpInternalListenAddr`），不进 Service、不经网关。

## 3. 凭据

与 `otlp-public-auth` 同一机制：`get_cred` 在安装节点 creds 目录只生成一次，写入 Secret `victoriametrics/vmauth-credentials`
（键 `read-token`、`ui-password`）。配置文件用 vmauth 的 `%{ENV}` 占位符，ConfigMap 里不含凭据；凭据或配置变化时
Pod 模板注解 `checksum/config` 随之变化，Deployment 自动滚动（vmauth 只在启动时展开占位符）。

```bash
kubectl -n victoriametrics get secret vmauth-credentials -o jsonpath='{.data.read-token}'  | base64 -d   # 程序用
kubectl -n victoriametrics get secret vmauth-credentials -o jsonpath='{.data.ui-password}' | base64 -d   # 浏览器 VMUI，用户 ops
```

token 的使用方（换 token 后要同步）：
- Gatus `metrics-edge` 探针：Secret `ops/gatus-vmauth`，由 `components/gatus/install.sh` 从同一 creds 生成，重跑即同步。
- control-tower：`scripts/dev-local.sh` 运行时从上面的 Secret 现取；GitHub Actions Secret `E2E_METRICS_TOKEN`（lens077/control-tower）需手动更新。
- d.apikv.com 总控制台（docker-deploy 仓 `homepage/`）：node1 上 `/home/docker/homepage/telemetry.env`，重跑 `bash homepage/deploy.sh` 即同步。

## 4. 安装与验收

```bash
VMAUTH_SKIP_ROUTE=1 bash components/vmauth/install.sh   # 只装代理，公网仍直连 VM（灰度）
kubectl -n victoriametrics port-forward svc/vmauth 18427:8427 &
BASE=http://127.0.0.1:18427 bash components/vmauth/verify.sh
bash components/vmauth/install.sh                       # 切路由（接管 HTTPRoute vm-single / vm-single-redirect）
bash components/vmauth/verify.sh                        # 公网验收，默认 BASE=https://metrics.apikv.com
```

`verify.sh` 覆盖 24 项：无凭据 / 错 token / 未展开占位符 / 错密码被拒；token 与 VMUI 查询 200；写入、删除、快照、
`/flags`、`/metrics`、pprof 被拒；401 带 `WWW-Authenticate: Basic`（浏览器才会弹框）。已认证但路径不在白名单的 400
要求正文含 `missing route`，避免把 VM 自己的参数错误当成拒绝。写入类用例只发空请求体。

回退：把 HTTPRoute `victoriametrics/vm-single` 的后端改回 `vm-single-victoria-metrics-single-server:8428`
即恢复直连——同时也恢复了公网写入与删除，只用于紧急排障。

## 5. 踩坑

- **VMUI 走 `/prometheus` 前缀**：页面启动读 `/prometheus/vmui/{config.json,timezone,custom-dashboards}`，查询也发到
  `/prometheus/api/v1/*`。白名单只写无前缀路径时，页面能打开但所有面板 400（2026-09-29 用真实浏览器测出）。
- **已认证未命中路由返回 400 而不是 403**：这是 vmauth 的行为（`user <name> missing route for "<path>"`），请求没有转发。
- **vmauth 自身端点默认与代理端口共用**：不设 `-httpInternalListenAddr` 时，公网能直接读 vmauth 的 `/flags`、`/metrics`。
