# alert-bridge —— 告警桥（Alertmanager / Bugsink webhook → ntfy 推送 + 结构化日志）

## 1. 定位

Alertmanager 的唯一 receiver，Bugsink 的 issue webhook 目标。收到 webhook 后做两件事：
推 [ntfy](https://ntfy.sh)（手机通知，severity 映射优先级，resolved 用 ✅），并把**每条**告警以
JSON 行写 stdout——Vector 采进 VictoriaLogs（`kubernetes.container_name:alert-bridge`），告警历史可查。
脚本是 node3 Pigsty 时代自写的 `pigsty-alert-ntfy.py`（2026-09-03 收割），容器化改动见 `bridge.py` 头部。

## 2. 上游最佳实践

- ntfy 发布 API：`POST {url}/{topic}`，`Authorization: Bearer <token>`，`Priority`/`Tags`/`Title` 头。
- Alertmanager webhook 载荷：`status`、`commonLabels`、`commonAnnotations`、`alerts[]`；桥必须回 2xx，
  非 2xx 触发 Alertmanager 重试（这正是我们要的：ntfy 抖动不丢告警）。
- Bugsink 的 webhook 是 Slack 格式（`text` + `blocks`），桥解析 header/section/fields 拼成一条消息。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Alertmanager 直连通知渠道 | 经桥 | Alertmanager 没有 ntfy receiver；桥还负责落日志 |
| 构建镜像 | `python:3.13-alpine` + 脚本进 ConfigMap | 171 行标准库脚本，不值得建 registry 与流水线；脚本 sha256 进 Pod 注解，改了自动滚动 |
| ntfy 凭据必填 | 可空：只记日志不推送，`/healthz` 返回 `{"ok":true,"ntfy":false}` | 让 vmalert→AM→桥 这段先跑通，凭据后补；补上重跑 install.sh |
| Bugsink 路径无鉴权 | 路径里带 `BUGSINK_BRIDGE_TOKEN`（creds 机制生成，重装不变） | 集群内任何 Pod 都能访问这个 Service，token 至少挡住误打 |

## 4. 暴露方式

- 集群内：`alert-bridge.observability.svc.cluster.local:9099/alerts`（Alertmanager）、`:9199/bugsink/<token>`（Bugsink）
- 不暴露到宿主网。

## 5. 验证

```bash
NTFY_URL=https://ntfy.apikv.com NTFY_TOPIC=<topic> NTFY_TOKEN=<token> bash components/alert-bridge/install.sh
kubectl -n observability rollout status deploy/alert-bridge
kubectl -n observability exec deploy/alert-bridge -- python3 -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:9099/healthz').read())"   # {"ok": true, "ntfy": true}
# 直接给桥打一条(不经 Alertmanager), 手机应收到 [FIRING] BridgeTest
kubectl -n observability exec deploy/alert-bridge -- python3 -c "
import json,urllib.request
b=json.dumps({'status':'firing','commonLabels':{'alertname':'BridgeTest','severity':'warning'},'commonAnnotations':{'summary':'桥直连测试'},'alerts':[{'status':'firing','labels':{'alertname':'BridgeTest'},'annotations':{'summary':'桥直连测试'}}]}).encode()
print(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9099/alerts',data=b,headers={'Content-Type':'application/json'})).status)"
kubectl -n observability logs deploy/alert-bridge --tail=3      # 每条告警一行 JSON
```

## 6. 踩坑

- 凭据只在 `$STATE_DIR/creds/ntfy.env` 与 Secret 里；gatus 组件读同一个文件，两边只需配一次。
- 桥挂了 Alertmanager 会重试到桥恢复；桥收到但 ntfy 4xx/5xx 时回 502，同样会被重试——看到重复推送先查 ntfy 是否慢。
- Bugsink 的 webhook 白名单（`ALERTS_WEBHOOK_ALLOW_LIST`）填的是桥的 Service FQDN，改命名空间要同步改 bugsink 组件。
