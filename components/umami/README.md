# umami —— 网站分析

自托管的 Umami：无 cookie、不采 PII、不需要 Cookie 同意横幅。面板给运营看站点级指标
（PV/UV/来源/停留/设备），**不是** `@ecommerce/tracker` 那条喂 gorse 推荐的商品行为链路，两者互不替代。

| 项 | 值 |
| --- | --- |
| 命名空间 | `ops` |
| 入口 | `https://umami.apikv.com`（Cilium Gateway → Pangolin） |
| 集群内地址 | `http://umami.ops.svc.cluster.local:3000` |
| 数据库 | 集群内 CNPG `pg-main-rw.postgresql.svc:5432/umami`（`UMAMI_DB_ENDPOINT`） |
| 凭据 | OpenBao `secret/k8s/<集群>/umami` → ESO → Secret `ops/umami-secret` |
| 开关 | `ADDON_UMAMI`（默认 `false`，当前未部署） |

## 为什么没有 PVC

Umami 的全部状态都在 PG 里，本组件因此**没有 PVC**，删掉重装不丢数据。

库在集群内 CNPG `pg-main`（2026-09-22 起；此前 2026-09-17 首装时用的是 node3 Pigsty `10.10.21.172`，
node3 已重装为 k3，那条路径作废）。Pod 用 Service DNS 直连，不经 Pangolin。

库与角色需要**预先建好**（本组件不建库）：角色 `umami`、库 `umami`、库属主为该角色，
且 `public` schema 的属主是库主（PG 15+ 起 `public` 不再默认给 PUBLIC `CREATE` 权限，
不改的话 Prisma 迁移会报 `permission denied for schema public`）。

## 安装

```bash
# 在集群节点上执行（节点的 config.env 才有正确的 CLUSTER_NAME）
ADDON_UMAMI=true bash components/umami/install.sh
```

幂等：重复执行是 `configured` 而不是报错。

### 凭据

三个值的真相源在 OpenBao `secret/k8s/<集群>/umami`：

| 键 | 说明 |
| --- | --- |
| `app-secret` | 会话/JWT 签名密钥。换掉只是让登录态失效。 |
| `two-factor-key` | 2FA 种子的加密密钥。**换掉会让已绑定的 2FA 永久失效**。 |
| `database-url` | 整串 DSN。密码不拆开存，URL 编码只在写入时做一次。 |

首次 seed：

```bash
kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN=<root-token> \
  bao kv put -mount=secret k8s/<集群>/umami \
    app-secret="$(openssl rand -hex 32)" \
    two-factor-key="$(openssl rand -hex 32)" \
    database-url='postgresql://umami:<密码>@pg-main-rw.postgresql.svc:5432/umami'
```

root token 在控制面节点 `/var/lib/k8s-installer/creds/openbao-init`。

ESO 不可用时 install.sh 会走降级路径，但**必须**由调用方给 `UMAMI_DATABASE_URL`——
密码不在仓库里（硬规则 4），脚本不会凭空造一个。

## 首次登录

默认账号 `admin` / `umami`，**登录后立刻改密码**。这是 Umami 内置的初始账号，
写在迁移里，不由本组件的 Secret 控制，所以改密码之后 Secret 里也不会有它。

## 接入前端

1. 面板 → Settings → Websites → Add website，域名填 `shop.apikv.com`
2. 拿到 websiteId（UUID）
3. 在 ecommerce 仓设两个前端的构建期变量：

| 应用 | 变量 |
| --- | --- |
| `apps/consumer`（Vite，chart `frontend`） | `VITE_UMAMI_SCRIPT_URL` / `VITE_UMAMI_WEBSITE_ID` |
| `apps/consumer-next`（Next.js） | `NEXT_PUBLIC_UMAMI_SCRIPT_URL` / `NEXT_PUBLIC_UMAMI_WEBSITE_ID` |

script URL 是 `https://umami.apikv.com/s.js`——文件名由 `UMAMI_TRACKER_SCRIPT_NAME` 决定，
改名是为了绕开按文件名匹配的广告拦截规则。

> ⚠️ 改名**不会关闭**默认路径：`/script.js` 和 `/s.js` 都返回 200（2026-09-17 实测）。
> 所以它只是提供了一条不被规则命中的备用路径，不是「把默认名藏起来」。前端必须显式用 `/s.js`，
> 用默认名照样能工作，但会被拦截器挡掉一部分流量。

两个变量缺任一，前端就完全不加载 tracker（本地开发不会往面板灌垃圾数据）。
它们是**构建期**内联的，改值要重新构建镜像。

## 已知问题与坑

**首次启动慢，probe 窗口要给够。** 26 个 Prisma migration 建 27 张表，
`startupProbe` 的 `failureThreshold=30`（150s）实测**不够**——迁移没跑完就被判失败
SIGTERM 掉（exitCode 143），重启后靠已完成的部分迁移才起来。现给 `120`（600s）。
稳态 `/api/heartbeat` 只要约 10ms，所以这个窗口只在首装时用得上。

**镜像拉取很慢。** ghcr.io 经 Spegel P2P 未命中后回退 `ghcr.m.daocloud.io`，
322MB 实测拉了 6m45s。首装时别把 `ContainerCreating` 误判成故障，先看
`crictl images` 或 kubelet 的 Pulling 事件。

**镜像锁的是 digest 不是语义 tag。** ghcr 的 tag 列表分页不全（`postgresql-*` 前缀
那批停在 v1.x/v2.x，查不到 v3），与 bugsink 同样的处理：锁 digest。
升级要手工换 `UMAMI_IMAGE` 里的 digest，并按上游 docs 在大版本升级后跑一次 `ANALYZE`
（迁移会让 PG 查询计划器的统计信息过期，面板变慢）。

**`init: true` 没有对应字段。** compose 的 `init: true` 在 Pod 里用
`shareProcessNamespace: true` 近似——pause 进程当 PID 1 负责回收僵尸进程。
但它**不负责 SIGTERM 转发**：上游镜像 CMD 是 `sh scripts/start-docker.sh`，
shell 不转发信号，停机会等满 `terminationGracePeriodSeconds`（这里设了 15s）。
要秒停得自建带 tini 入口点的镜像。

## 验证

```bash
kubectl -n ops get pods -l app.kubernetes.io/name=umami
kubectl -n ops logs -l app.kubernetes.io/name=umami --tail=20   # 迁移与启动
curl -s -o /dev/null -w '%{http_code}\n' https://umami.apikv.com/api/heartbeat
```

数据库侧确认迁移建表：

```bash
kubectl -n postgresql exec pg-main-1 -c postgres -- psql -U postgres -d umami -tAc \
  "select count(*) from information_schema.tables where table_schema='public'"
# 期望 27（2026-09-17 在旧 Pigsty 上实测的 v3 迁移集表数）
```

## 卸载

```bash
kubectl -n ops delete deploy/umami svc/umami httproute/umami httproute/umami-redirect
kubectl -n ops delete externalsecret umami-secret    # 连带删除 Secret（creationPolicy: Owner）
```

**数据不会被删**——它在 CNPG `pg-main` 的 `umami` 库里。要连数据一起清，另外 `DROP DATABASE umami`。
