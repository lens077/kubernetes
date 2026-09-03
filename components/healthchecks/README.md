# healthchecks —— 死人开关（cron / 备份 / Job 到点不 ping 就告警）

## 1. 定位

自托管 [healthchecks.io](https://healthchecks.io)。每个周期性任务在面板上对应一个 check，任务成功
`GET /ping/<uuid>`、开始 `/start`、失败 `/fail`；到期没收到 ping 就通知（integration 里配 ntfy）。
它覆盖的是 vmalert 覆盖不到的一类故障：**任务根本没跑**（CronJob 被挂起、调度器出错、镜像拉不下来）。
node3 Pigsty 时代用它守 pgbackrest 每日全备（`pg-backup-healthchecked`，2026-09-03 收割）；
集群内首个接入是 CNPG 备份（`examples/cnpg-backup-ping-cronjob.yaml`）。

## 2. 上游最佳实践

来源：[healthchecks 自托管文档](https://healthchecks.io/docs/self_hosted/)，v4.3

- 环境变量配置：`SITE_ROOT`、`ALLOWED_HOSTS`、`REGISTRATION_OPEN=False`、`SECRET_KEY`；sqlite 足够单实例。
- `/start` + 成功/失败 ping 三段式能测出「任务卡住」，不只是「没跑」。
- Prometheus 指标按项目暴露（需项目 API key）；`/api/v3/status/` 是实例健康端点。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| PostgreSQL/MySQL | sqlite + PVC（`HEALTHCHECKS_STORAGE_SIZE`） | 几十个 check 的规模；不给 CNPG 再添一个租户 |
| 超级用户手工建 | install.sh 用官方 `createsuperuser --email --password` 非交互建 `admin@hc.<域名>` | 密码走 creds 机制，重装不变 |
| `ALLOWED_HOSTS` 只放域名 | 额外放行 Service FQDN | 集群内 CronJob 用 Service 名 ping，Host 头不是外网域名 |
| 邮件通知 | 不配邮件，check 的 integration 用 ntfy | 与其它告警同一个渠道 |

## 4. 暴露方式

- 宿主网：`https://hc.${CLUSTER_DOMAIN}`（面板）；公网 ping 若需要，经 newt 暴露 `/ping/` 前缀即可。
- 集群内 ping：`http://healthchecks.ops.svc.cluster.local:8000/ping/<uuid>`

## 5. 验证

```bash
kubectl -n ops rollout status deploy/healthchecks
kubectl -n ops exec deploy/healthchecks -- curl -fsS -H 'Host: localhost' http://127.0.0.1:8000/api/v3/status/
# 面板建 check → 拿 uuid → 从集群内 ping 一次 → 面板状态变绿
kubectl -n ops run hc-ping --rm -it --restart=Never --image=docker.io/curlimages/curl:latest -- \
  curl -fsS http://healthchecks.ops.svc.cluster.local:8000/ping/<uuid>
```

## 6. 踩坑

- 面板里给 check 配 ntfy integration 时，token 用与告警桥同一个（`$STATE_DIR/creds/ntfy.env`）。
- `createsuperuser` 对已存在邮箱返回 "already taken"，install.sh 视为成功；改密码要在面板里改，creds 文件不会跟着变。
- 容器以镜像内的 `hc` 用户运行，PVC 用 `fsGroup: 999` 放开写权限；若镜像升级改了 gid，Pod 起不来先看这里。
