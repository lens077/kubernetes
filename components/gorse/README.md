# gorse —— 推荐引擎（2026-11-03 自 node2/node1 迁入集群）

## 1. 定位

ecommerce `behavior`/`product` 的推荐引擎（客户端 `backend/pkg/gorse`，X-API-Key 鉴权）。
原形态：node2 docker `gorse-in-one` + node1 docker 专用 Redis（`redis.apikv.com:61246`）。
本组件把它收进集群：**ArgoCD + 仓内 helm chart** 部署，HTTPRoute 挂共享 Gateway。

```
Pangolin gorse(rid 17) ──> k8s-cluster site VIP 10.10.31.240:443 ──> HTTPRoute gorse.apikv.com
                                                                        └─> svc gorse:8088 (gorse-in-one)
gorse ──cache──> Dragonfly  dragonfly.dragonfly.svc:6379/0  (TLS+AUTH, 与业务缓存共 db0)
       ──data───> CNPG      pg-main-rw.postgresql.svc:5432/gorse (verify-full + pg-main-ca)
```

## 2. 关键取舍

| 上游/原形态 | 本组件 | 原因 |
|---|---|---|
| docker-compose 部署 | **ArgoCD Application**（`argocd/application.yaml` → `chart/`） | 集群状态进 Git；仓库 public，ArgoCD 免凭据跟踪 |
| 上游无官方 chart（2026-11-03 复核） | **仓内最小 chart** | 不为它引第三方 chart 仓；4 个模板就够了 |
| node1 专用 Redis 容器 | **Dragonfly（db0 共享）** | 蜻蜓 db 已是集群缓存标准件，业务侧 `product:gorse:*` 本就写 db0；独立逻辑 DB 走不通——Dragonfly 的 RediSearch 索引只允许建在 db0（`ERR Cannot create index on db != 0`，gorse 初始化必须建索引，实测踩过） |
| node1 postgres 的 gorse 库 | **CNPG pg-main 新建 `gorse` 库 + 独立用户** | 摘掉 node1 依赖；进 CNPG 备份口径 |
| `zhenghaoz/gorse-in-one:latest` | **钉 `0.5.11`**（上游最新 release） | latest 漂移 |
| config.toml 里明文 DSN/api_key | **config.toml.tpl 占位符 + init 容器渲染**，值来自 Secret `gorse-store` | 凭据不入仓不入 ConfigMap |

### GitOps 源：GitLab 镜像（不是 GitHub）

机房 ArgoCD 拉 `github.com` 长期超时（`context deadline exceeded`，实测重试 3 次都挂），
所以 Application 的 `repoURL` 用 **GitLab 镜像** `https://gitlab.com/sumery/kubernetes.git`
（public，无凭据 Secret，与其他 10 个 repo-gitlab-* 同款）。本仓主 remote 仍是 GitHub，
推镜像固定两步：

```bash
git push && git push gitlab   # gitlab remote 已配置；漏 push gitlab ArgoCD 就不更新
```

## 3. 凭据与信任链（Secret `gorse-store`，install.sh 现取物化）

| 键 | 内容 | 来源 |
|---|---|---|
| `cache-store` | `rediss://default:<dragonfly-auth>@dragonfly.dragonfly.svc:6379/0` | Dragonfly 组件 Secret 现取 |
| `data-store` | `postgres://gorse:<pw>@pg-main-rw.postgresql.svc:5432/gorse?sslmode=verify-full&sslrootcert=/etc/gorse/ca/pg/ca.crt` | `get_cred gorse-pg-password` 自动生成（k1 creds） |
| `api-key` | 业务 RESTful API 鉴权 | **沿用 node2 config.toml 现值**（Config Center 同口径），首次部署前灌 `$STATE_DIR/creds/gorse-api-key` |
| `admin-api-key` | Dashboard/管理 API | 同上 `gorse-admin-api-key` |

出站 TLS：Dragonfly/CNPG 证书都由集群 CA 签（SAN 含 `dragonfly.dragonfly.svc` / `pg-main-rw`），
容器挂 `cert-manager/global-root-ca-secret` 与 `postgresql/pg-main-ca`；Go 侧通过 `SSL_CERT_FILE` 信任，
CNPG 走 DSN 的 `sslrootcert`。

## 4. 暴露与鉴权

- HTTPRoute `gorse`（ns `gorse`）→ 共享 Gateway https listener，hostname `gorse.apikv.com`。
  公网 TLS 由 **Pangolin 边缘终止**（ZeroSSL `*.apikv.com`，与 es-dev/shop 同模式）；Gateway 对 Pangolin 呈现的是 `*.dev.test` 证书，直通不上验。
- Dashboard 与 RESTful API 同端口 8088；SSO 登录墙在 Pangolin 资源侧（迁移不动）。
- gorse 数据/缓存数据可丢可重建（vector.db/blob 在 emptyDir；真相在 CNPG）。

## 5. 安装 / 数据迁移 / 卸载

```bash
# 前置：dragonfly、postgres、argo 组件已装；k1 上已有本仓副本
# 首次：把 node2 config.toml 的两个 key 灌进 k1 creds（0600，不入仓）
ssh node2 'grep -E "^(admin_)?api_key" /home/docker/gorse/config.toml'
ssh k1 'printf "a6e5d480..." > /var/lib/k8s-installer/creds/gorse-api-key; printf "935c..." > /var/lib/k8s-installer/creds/gorse-admin-api-key; chmod 600 /var/lib/k8s-installer/creds/gorse-*'

bash components/gorse/install.sh                 # 建库/Secret/CA → apply ArgoCD Application → 等 Healthy
bash components/gorse/install.sh --migrate node1 # 一次性：node1 pg gorse 库 → CNPG（2026-11-03 已做过）
```

已知降级（非致命）：Dragonfly 没有 RedisTimeSeries 模块，启动后每轮刷一条 `TS.ADD` error 日志——gorse 用它做监控时序，缺了只影响内部指标，不影响推荐主流程（原 node1 裸 Redis 同样如此）。

验证：

```bash
kubectl -n gorse rollout status deploy/gorse
# Dashboard: https://gorse.apikv.com（302 → /login；master 无 /api/health，探 /login）
# RESTful API(8087, 集群内): kubectl -n gorse run --rm -i curl --image=curlimages/curl -- \
#   curl -s -H "X-API-Key: $(kubectl -n gorse get secret gorse-store -o jsonpath='{.data.api-key}' | base64 -d)" \
#        http://gorse-server/api/items?n=2   # 匿名 401，带 key 200
#
# ⚠️ 新建 HTTPRoute 挂不上 Gateway（parents 空）时先重启 cilium-operator：
#   2026-11-03 实测 operator 10-31 重启后 gateway 控制器卡死，新路由一律不编程（CEC 不更新），
#   删 pod 重建后全部恢复。判据：get ciliumenvoyconfig cilium-gateway-cilium-gateway 里有没有新路由的 hostname。
```

回退：Pangolin 把 target 切回 node2 site（`127.0.0.1:8088`）即回到旧链路；旧栈在摘除前保留。
删除组件：`kubectl -n argocd delete application gorse`（finalizer 会清 ns 内资源）+ 删 CNPG `gorse` 库。

## 6. 摘除记录（2026-11-03）

- node2 `/home/docker/gorse`（compose down，目录保留作回滚）
- node1 `/home/docker/redis`（redis-gorse 容器 down；redis.apikv.com 是裸 TLS 直连容器端口、无 Traefik/Pangolin 路由，摘容器即摘端点，61246 实测关闭）
- node1 postgres 的 `gorse` 库保留只读备查（同日已迁 CNPG）
- 消费方切换：Config Center 的 gorse 地址不变（仍是 `https://gorse.apikv.com`），业务无需改
