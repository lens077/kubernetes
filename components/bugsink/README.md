# bugsink —— 错误追踪（Sentry 协议兼容，单用户）

## 1. 定位

Go 服务与前端用 Sentry SDK 把异常发到这里（DSN），按 issue 聚合、去重、附上下文；新 issue 经
webhook 打到告警桥再推 ntfy。它回答「用户遇到了什么错」，与 VictoriaLogs（日志）/ VictoriaTraces（链路）
互补：issue 页里带 trace id 就能跳到链路。取值沿用 node3 的 compose（2026-09-03 收割）。

## 2. 上游最佳实践

来源：[Bugsink 文档](https://www.bugsink.com/docs/)（Docker install / Settings）

- 环境变量配置；`SECRET_KEY` ≥ 50 字符；`CREATE_SUPERUSER=email:password` 首次启动建管理员。
- `BASE_URL` 同时决定 `ALLOWED_HOSTS`；反代终结 TLS 时设 `BEHIND_HTTPS_PROXY=True`。
- sqlite（WAL）是官方推荐的默认库，只要挂的是真实文件系统（不是 Docker 命名卷）。
- `ALERTS_WEBHOOK_OUTBOUND_MODE=allowlist_only` 限制 webhook 出口，避免 SSRF。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| `latest` 镜像 | 钉 node3 上验证过的 digest | 官方只发 latest；digest 才可复现 |
| 多用户/团队 | `SINGLE_USER=True`、注册与建团队关闭 | 一个人的项目 |
| 邮件通知 | dummy 邮件后端；通知走 webhook → 告警桥 → ntfy | 统一渠道 |
| 事件永久保留 | `MAX_EVENT_AGE_DAYS=${BUGSINK_EVENT_RETENTION_DAYS}`（90） | PVC 只有 `BUGSINK_STORAGE_SIZE` |
| webhook 出口不限 | 白名单只有 `alert-bridge.observability.svc.cluster.local`，`DENY_NON_GLOBAL=False` | 白名单是集群内地址（非公网），默认策略会拒掉 |

## 4. 暴露方式

- 宿主网：`https://bugsink.${CLUSTER_DOMAIN}`（面板与 DSN 入口）。
- SDK 上报：DSN 形如 `https://<key>@bugsink.${CLUSTER_DOMAIN}/<project_id>`，走共享网关。
  集群内 Pod 直连 `http://bugsink.ops.svc:8000` 会被 `ALLOWED_HOSTS` 拒绝（Host 头不是 `BASE_URL` 的域名），
  Pod 内要能解析 `*.${CLUSTER_DOMAIN}` 到网关地址——CoreDNS 没有这条解析时见 `OBSERVABILITY-INTEGRATION.md` §6。
- 公网前端上报：经 newt 暴露 `bugsink.apikv.com`（gatus 的 `bugsink-edge` 探针对应它）。

## 5. 验证

```bash
kubectl -n ops rollout status deploy/bugsink
kubectl -n ops exec deploy/bugsink -- curl -fsS -H "Host: bugsink.${CLUSTER_DOMAIN}" http://127.0.0.1:8000/health/ready
# 登录 → 建项目 → 复制 DSN → 用 sentry-cli 或任一 SDK 发一条测试事件 → issue 出现
# 项目 Alerts → Webhook, URL 填告警桥的 Bugsink webhook(见 /root/.k8s-installer-credentials) → 触发一条 → 手机收到
```

## 6. 踩坑

- `CREATE_SUPERUSER` 只在用户不存在时生效；改密码去面板改，creds 文件不会跟着变。
- 事件量大时 sqlite 单写者是瓶颈；到那一步再迁 CNPG（`DATABASE_URL=postgresql://…`，官方标注为「应可用但未充分测试」）。
- `stop_grace_period 30s`：snappea worker 处理中的事件需要时间落盘，别把 `terminationGracePeriodSeconds` 调小。
