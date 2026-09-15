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

环境名（`--env`）与地址策略（`--strategy`）是两件事：环境名任意；策略缺省由环境名推导（`dev` → `pangolin`，其它 → `pre`），可显式指定。

| `--strategy` | 消费方位置 | 地址 | CA | 契约字段 |
|---|---|---|---|---|
| `pre` | 集群内 Pod | `<svc>.<ns>.svc:PORT`（外部实例是域名） | 集群 DNS 不需要；外部实例按 `CA_REF` | `SVC/PORT/SCHEME` |
| `gateway` | 机房 LAN 上的开发机，直连 Cilium Gateway VIP | `HOSTNAME:DEV_PORT`（`*.dev.test`） | 必须带 `ca_pem`（私有 CA） | `HOSTNAME/DEV_PORT/DEV_SCHEME` |
| `pangolin`（`dev` 默认，2026-09-12 定稿） | 不在机房 LAN 的开发机（这台 Mac），经 Pangolin 资源 → newt → VIP | `REMOTE_HOST:REMOTE_PORT`（`*.apikv.com`） | `REMOTE_CA=public`（Traefik 终止，清空 ca_pem）或 `private`（raw TCP 直通，带 ca_pem，证书 SAN 须含 REMOTE_HOST） | `REMOTE_HOST/REMOTE_PORT/REMOTE_SCHEME/REMOTE_CA` |

`pangolin` 策略用到的 Pangolin 资源（面板 API 建，2026-09-12）：

| 资源 | 类型 | 公网 | target | 备注 |
|---|---|---|---|---|
| `consul-dev`（id 52） | HTTP，SSO 关 | `https://consul-dev.apikv.com` | node4/node5 站点 → `10.10.31.240:443`，`tlsServerName` 与 `setHostHeader` = `consul.dev.test`（HTTPRoute 按 Host 匹配） | Traefik 终止 TLS → `ca_pem` 空 |
| `redis-dev`（id 53） | raw TCP，`proxyPort 30005` | `redis-dev.apikv.com:30005` | node4/node5 站点 → `10.10.31.243:6380` | TLS 直通到 Dragonfly 证书；`certificate.yaml` 已把 `${REMOTE_HOST}` 加进 SAN |

30005 是新开的 raw 端口：云防火墙（`tccli lighthouse CreateFirewallRules`）+ VPS `docker-compose.yml` gerbil ports + `traefik_config.yml` `tcp-30005` 三处，都在 docker-deploy 仓 `pangolin/`；重建 gerbil/traefik 时 `*.apikv.com` 中断约 10 秒。

`gateway` 策略的前提：开发机在集群 LAN 上（网关 VIP `10.10.31.x` 只在机房 L2 可达，家里的 Mac 经隧道只到 API server），且开发机能把 `<组件>.dev.test` 解析到网关 VIP（RFC 6761 保留域，公网永不解析）。`/etc/hosts` 不支持通配，要么逐条写（`10.10.31.240 consul.dev.test`、`10.10.31.243 redis.dev.test`……每个组件一行，HOSTNAME 见各 `component.env`），要么用本机 split DNS：macOS 放一个 `/etc/resolver/dev.test` 指向跑 dnsmasq 的地址（`address=/.dev.test/10.10.31.240`，TCP 组件另指其独立 Gateway VIP），Linux 用 systemd-resolved/dnsmasq 同理。2026-09-12 在节点宿主机实测：`consul.dev.test:443` 经共享网关 HTTPS 200、证书链过私有 CA（CN `dev.test`）；`redis.dev.test:6380` 经 dragonfly-gateway TLS 校验通过、`AUTH` +OK / `PING` +PONG、错密码 `-WRONGPASS`。写入 Config Center `dev` 环境需要一枚 `ENVIRONMENT=dev` 的 operator token（Secret `config-center-operator-dev`）。

**`make dev` 实测（2026-09-12，这台 Mac）**：`ENV=dev`（pangolin 策略）写入后，`backend/services/cart` 的 `make dev`（`source.dev.yaml` 指向 `127.0.0.1:30010`，先 `kubectl -n config-center port-forward svc/config-center 30010:30010`）：`bootstrap config loaded (config_center)` → `database connected successfully to pg.apikv.com` → `redis connected successfully {"addr": "redis-dev.apikv.com"}` → `http server starting 0.0.0.0:30006`，`/healthz` 200。Makefile 的 `CONSUL_ENABLED=false`，Consul 注册不在本地跑；`consul-dev.apikv.com/v1/status/leader` 单独 curl 为 200。

### macOS split DNS 配置

`/etc/hosts` 不支持 `*.dev.test`。本机需要输入管理员密码执行一次：

```bash
brew install dnsmasq
sudo ifconfig lo0 alias 10.0.0.1 255.255.255.255
sudo mkdir -p /opt/homebrew/etc/dnsmasq.d /etc/resolver
sudo tee /opt/homebrew/etc/dnsmasq.conf >/dev/null <<'EOF'
listen-address=10.0.0.1
bind-interfaces
port=53
no-resolv
server=192.168.3.1
conf-dir=/opt/homebrew/etc/dnsmasq.d,*.conf
EOF
sudo tee /opt/homebrew/etc/dnsmasq.d/dev.test.conf >/dev/null <<'EOF'
# HTTPRoute/shared Gateway
address=/.dev.test/10.10.31.240
# 独立 TCP Gateway：更具体的规则覆盖上面的后缀规则
address=/redis.dev.test/10.10.31.243
address=/pg.dev.test/10.10.31.242
EOF
sudo tee /etc/resolver/dev.test >/dev/null <<'EOF'
nameserver 10.0.0.1
timeout 2
search_order 1
EOF
sudo brew services restart dnsmasq
```

以后新增走共享 HTTP Gateway 的 `a.dev.test`，只要 DNS 记录仍符合这条规则，就不需要再改 `/etc/hosts` 或 dnsmasq；新增独立 TCP/TLS Gateway 时，必须在 `dev.test.conf` 增加该组件的具体 VIP 规则。macOS 的 `/etc/resolver/dev.test` 是按域转发，不是通配 hosts 记录。

验证不要用 `dig`（它通常绕过 `/etc/resolver`）：

```bash
dscacheutil -q host -a name a.dev.test
dscacheutil -q host -a name redis.dev.test
curl --cacert /path/to/global-root-ca.crt --resolve consul.dev.test:443:10.10.31.240 https://consul.dev.test/v1/status/leader
```

`make dev` 使用 Go 纯解析器时，应以真实启动验证为准；若服务不读取 `/etc/resolver`，给服务设置 `GODEBUG=netdns=cgo`，或把需要的主机逐条写入 `/etc/hosts`。

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
| `templates/<svc>.bootstrap.yaml` | 每服务的脱敏骨架（`--export-templates` 从现网导出）：映射覆盖的路径与非空机密叶子是 `__HARVEST__`，其余（`server.addr`、超时、池、日志级别、`store`/`pay`/`recommend` 等服务固有配置）原样。键不存在时 harvest 用它从零合成整份，再按契约填满、校验 schema、拒绝残留占位符 |

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

**从零（新集群 / 新环境）**：键不存在时自动走骨架合成，不再需要 `config-center-pre-seed.sh` 从 dev 复制。注意 operator token 按 environment 收窄——给新环境播种要先为那个环境签一枚（`ENVIRONMENT=<env> bash tools/config-center-operator-token.sh`）。骨架过时时（服务新增了固有字段）从有现值的环境 `--export-templates` 重新导出并入库。

**装完就填好**：`config.env` 的 `CC_AUTO_HARVEST="true"` 让 80 阶段末尾自动跑 harvest（含 config-center 消费方）；前提是 Config Center 在跑、operator token Secret 已存在，否则该步只警告不阻断。默认关，因为它会滚动业务服务。

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
