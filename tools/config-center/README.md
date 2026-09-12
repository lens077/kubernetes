# Config Center 自动填充：组件契约 → 依赖配置

> 集群部署完成后，把各组件（含集群外实例）的地址、凭据、CA 按每个服务的 JSON Schema 写进 Config Center 的 `bootstrap.yaml`，以及 control-tower config 服务自己的自举 Secret。2026-09-11 落地；取代 `config-center-pre-seed.sh` 的「改字段」部分。

## 三个真相源，各自唯一

| 内容 | 真相源 | 进入消费方的路径 |
|---|---|---|
| 非机密声明：svc 名、端口、协议、凭据在哪 | Git：`components/*/component.env`、`components/_external/*/component.env` 的「依赖契约」字段 | `tools/verify-contracts.sh --json` |
| 机密：密码、token、api_key、client_secret | OpenBao `k8s/<CLUSTER_NAME>/<组件>`（`config.env` 的 `ESO_STORE`） | ESO ExternalSecret → K8s Secret → harvest 读 |
| 集群派生物：cert-manager 根 CA | 集群；`PushSecret` 镜像到 OpenBao `k8s/<集群>/ca/*` | `CA_REF` 直接读集群 Secret |

不要把非机密配置塞进 OpenBao：ESO 目标只能是 Secret，而且会让每次 reconcile 依赖 OpenBao 可达（sealed 就全停）。

## 地址策略

| `--env` | 消费方位置 | 地址 | CA |
|---|---|---|---|
| `pre`（默认） | 集群内 Pod | `SVC:PORT`（`<svc>.<ns>.svc`；外部实例是域名） | 集群 DNS 不需要；外部实例按 `CA_REF` |
| `dev` | 本机 / 内网，经 Cilium Gateway | `HOSTNAME:DEV_PORT`（`*.dev.test`） | 必须带 `ca_pem`（私有 CA） |

「优先 HTTPRoute > LB > Svc」的自动发现已放弃：对集群内消费方那是错的（control-tower `docs/operations/service-interconnect.md`）。声明优先、发现校验。

## 文件

| 文件 | 作用 |
|---|---|
| `mapping.yaml` | 能力（`PROVIDES`）→ schema 路径。每个服务要填哪些块由其 schema 的 `$defs` 推导，不维护消费者清单；`consumers:` 段是非 Config Center 的消费方（config 服务自举 Secret） |
| `harvest.py` | 核心：GetKey → 按 schema 判断能力 → 只改映射路径 → 往返等价自检 → JSON Schema 校验 → 脱敏 diff → PutKey → 签 token → selector Secret → 滚动 |
| `../config-center-harvest.sh` | bash 壳：加载 config.env、收集契约、找 schema、调 harvest.py |
| `../verify-contracts.sh` | 契约 ↔ 集群现状核对；`--json` 给 harvest 用 |
| `../openbao-seed.sh` | 把凭据搬进 OpenBao：集群内组件取运行中的现值，外部依赖从 Config Center 现值反向抽取（`harvest.py --extract-externals`）；`--rotate` 生成新值 |
| `../rotate-credential.sh` | 轮换四段编排：OpenBao 写新值 → ESO 同步 + 提供方滚动 → 消费方重写 → 验收 |
| `../../components/_external/` | 集群外实例的契约声明 + 通用 ExternalSecret 模板 + `apply.sh` |
| `../../tests/mapping_test.sh` | 门禁：映射路径必须能在 control-tower schema 里找到（schema 改名先红） |

## 日常操作

```bash
# 0. 只读检查(推荐每次先跑)
bash tools/verify-contracts.sh
bash tools/config-center-harvest.sh --dry-run
bash tools/config-center-harvest.sh --consumer config-center --dry-run

# 1. 正式写入(需要管理 token; 见下)
bash tools/config-center-harvest.sh                    # 10 个 ecommerce 服务, 写完滚动
bash tools/config-center-harvest.sh --consumer config-center

# 2. 轮换 dragonfly 密码(四段一次做完)
bash tools/rotate-credential.sh dragonfly --dry-run
bash tools/rotate-credential.sh dragonfly

# 3. 从非节点机器执行(Mac): 指定 config、python、Config Center 入口
K8S_CONFIG_ENV=bootstrap/config.hosting.env PYTHON=<venv>/bin/python \
CONFIG_CENTER_URL=http://127.0.0.1:30010 bash tools/config-center-harvest.sh --dry-run   # 先 port-forward
```

节点上 schema 副本在 `$STATE_DIR/config-center/schemas/`（从 control-tower `services/config/internal/schema/schemas/` rsync）；没有 schema 时 harvest 拒绝运行——不知道 cart 不该有 `search.catalog`。

## 管理 token

| 方式 | 何时 | 怎么给 |
|---|---|---|
| Casdoor 管理员 JWT | 现在 | `tools/config-center-admin-token.sh` 写 `/root/.config-center-admin-token`（浏览器会话，会过期） |
| operator machine token（P4，**已上线**：config 0.2.11，goose v3） | 现在起的默认 | 一次性：节点上放 `/root/.casdoor-login`（两行：Casdoor 管理员用户名、密码，0600）→ `bash tools/config-center-operator-token.sh`（用管理员 JWT 签 role=OPERATOR、存 Secret、读写自检）→ 之后 `ADMIN_TOKEN_SECRET=config-center/config-center-operator:token`。管理台 `/tokens` 页面暂无 role 选择器，只能走脚本 |

operator token 只能 PutKey/GetKey/签发与吊销 service 角色 token，不能签 operator、不能 DeleteKey/Rollback（control-tower `docs/design/machine-token.md`）。

## 集群重装后

1. `external-secrets` + `openbao` 组件起来并解封 → `tools/openbao-seed.sh`（外部依赖的值从 Config Center 现值抽；OpenBao 数据随集群亡，这一步就是重建它）。
2. `components/_external/apply.sh`（80 阶段会自动跑）。
3. 各组件 install.sh 自动走 ESO；`tools/verify-contracts.sh` 全绿。
4. `tools/config-center-harvest.sh --dry-run` 无差异或只有预期差异 → 正式跑。

`$STATE_DIR/creds/` 不再是重建须知第一条：它只剩降级路径（`OFFLINE=1`）在用。

## 轮换的边界

| 组件 | 改 Secret 后 | 结论 |
|---|---|---|
| dragonfly / meilisearch / minio / redis | 每次启动读 → 重启即生效 | 可用 `rotate-credential.sh` |
| grafana | 仅首次初始化，之后存库 | 原值迁移；换密码走 `grafana-cli admin reset-admin-password` |
| bugsink / healthchecks | 超级用户仅首次；`SECRET_KEY` 换了只踢会话 | 原值迁移 |
| harbor | 内部 PG 口令写死在库里 | 原值迁移，不轮换 |
| 外部实例（node3 PG/Redis/ES、Casdoor） | 真相在外部系统 | 外部改完后 `openbao-seed.sh <id>` 重新播种，再 harvest |

## 踩坑

- **`cmd | grep -q` 在 `pipefail` 下会误报**：grep 提前退出让上游吃 SIGPIPE，整条管道非 0。契约校验用 `grep -qx <<<"$var"`。
- **PEM 尾部换行**：Config Center 里的 `ca_pem` 有的带尾换行有的不带，harvest 比较时 `strip()`，否则每次都「改动 1 处」。
- **`is_secret` 必须是 false**：置 true 管理面 GetKey 脱敏成 `******`，数据面 SDK 也读不到真值（pre-seed 踩过）。
- **jsonpath 里键名带点要转义**：`{.data.ca\.crt}`。
- **不要把 `_external/otlp-node3` 这类纯地址声明也建 ExternalSecret**：OpenBao 没那条路径，ESO 会一直 `SecretSyncedError`；`apply.sh` 已按「有 `CRED_SECRET`/`CA_REF` 才物化」跳过。
