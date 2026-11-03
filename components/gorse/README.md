# gorse —— 推荐引擎（2026-11-03 自 node2/node1 迁入集群）

## 1. 定位

ecommerce `behavior`/`product` 的推荐引擎（客户端 `backend/pkg/gorse`，X-API-Key 鉴权）。
原形态：node2 docker `gorse-in-one` + node1 docker 专用 Redis（`redis.apikv.com:61246`）。
本组件把它收进集群：**ArgoCD + 仓内 helm chart** 部署，HTTPRoute 挂共享 Gateway。

```
Pangolin gorse(rid 17) ──> k8s-cluster site VIP 10.10.31.240:443 ──> HTTPRoute gorse.apikv.com
                                                                        └─> svc gorse:8088 (gorse-in-one)
gorse ──cache──> Dragonfly  dragonfly.dragonfly.svc:6379/2  (TLS+AUTH, 逻辑 DB 隔离)
       ──data───> CNPG      pg-main-rw.postgresql.svc:5432/gorse (verify-full + pg-main-ca)
```

## 2. 关键取舍

| 上游/原形态 | 本组件 | 原因 |
|---|---|---|
| docker-compose 部署 | **ArgoCD Application**（`argocd/application.yaml` → `chart/`） | 集群状态进 Git；仓库 public，ArgoCD 免凭据跟踪 |
| 上游无官方 chart（2026-11-03 复核） | **仓内最小 chart** | 不为它引第三方 chart 仓；4 个模板就够了 |
| node1 专用 Redis 容器 | **Dragonfly 逻辑 DB 2** | 蜻蜓 db 已是集群缓存标准件；多 DB 实测可用；省一个 StatefulSet 与一套证书/守卫 |
| node1 postgres 的 gorse 库 | **CNPG pg-main 新建 `gorse` 库 + 独立用户** | 摘掉 node1 依赖；进 CNPG 备份口径 |
| `zhenghaoz/gorse-in-one:latest` | **钉 `0.5.11`**（上游最新 release） | latest 漂移 |
| config.toml 里明文 DSN/api_key | **config.toml.tpl 占位符 + init 容器渲染**，值来自 Secret `gorse-store` | 凭据不入仓不入 ConfigMap |

## 3. 凭据与信任链（Secret `gorse-store`，install.sh 现取物化）

| 键 | 内容 | 来源 |
|---|---|---|
| `cache-store` | `rediss://default:<dragonfly-auth>@dragonfly.dragonfly.svc:6379/2` | Dragonfly 组件 Secret 现取 |
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

bash components/gorse/install.sh                 # 建库/Secret → apply ArgoCD Application → 等 Healthy
bash components/gorse/install.sh --migrate node1 # 一次性：node1 pg gorse 库 → CNPG（2026-11-03 已做过）
```

验证：

```bash
kubectl -n gorse rollout status deploy/gorse
curl -s -H "X-API-Key: $(...) https://gorse.apikv.com/api/health   # Pangolin 边缘
kubectl -n gorse exec deploy/gorse -- wget -qO- http://127.0.0.1:8088/api/health
```

回退：Pangolin 把 target 切回 node2 site（`127.0.0.1:8088`）即回到旧链路；旧栈在摘除前保留。
删除组件：`kubectl -n argocd delete application gorse`（finalizer 会清 ns 内资源）+ 删 CNPG `gorse` 库。

## 6. 摘除记录（2026-11-03）

- node2 `/home/docker/gorse`（compose down，目录保留作回滚）
- node1 `/home/docker/redis`（redis-gorse 容器 down；redis.apikv.com Pangolin 资源已下线）
- node1 postgres 的 `gorse` 库保留只读备查（同日已迁 CNPG）
- 消费方切换：Config Center 的 gorse 地址不变（仍是 `https://gorse.apikv.com`），业务无需改
