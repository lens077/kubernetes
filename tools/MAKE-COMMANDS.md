# 运维 Makefile 快捷命令

在 kubernetes 仓库根目录运行 `make` 或 `make help`。默认只显示帮助，不部署、不轮换、不修改公网入口。

## 前置条件与目标选择

- Bash >= 4.2、kubectl、Helm、jq。先运行 `make bootstrap-tools` 创建 `.venv-tools`，它通过 `uv` 安装 PyYAML/jsonschema；也可显式传 `PYTHON=/path/to/python`。
- 默认读取 `bootstrap/config.hosting.env`。这只选择部署参数，不切换 kubeconfig；执行前用 `kubectl config current-context` 确认目标集群。
- `KUBECONFIG` 按底层脚本处理；组件公共库在节点存在 `/etc/kubernetes/admin.conf` 时优先使用该文件。Mac 上不要假设本地配置会切换远程目标。
- `ENV=pre` 默认选择集群内地址；`ENV=dev` 默认选择 `remote-dev`。可以显式传 `STRATEGY=gateway`，但当前 Mac 经 Pangolin 开发不需要 split DNS。
- `ADMIN_TOKEN_SECRET` 自动取 pre 的 `config-center/config-center-operator:token`，其他环境取 `config-center/config-center-operator-<env>:token`。可显式覆盖引用，禁止把 token 明文放进 make 命令行。
- Makefile 是现有脚本的快捷入口，不会补齐脚本缺少的权限、备份或网络能力。

## 配置检查与自动填充

```bash
make contracts
make mapping-test
make cc-plan ENV=pre
make cc-plan ENV=dev SERVICES="cart search"
make cc-apply ENV=dev CONFIRM=yes
make cc-apply ENV=pre CONFIRM=yes
make cc-bootstrap-plan
make cc-bootstrap-apply CONFIRM=yes
```

`cc-apply ENV=dev` 写 Config Center 的 dev 键，不滚动集群中的 pre Deployment；Mac 上已启动的进程是否需要重启，应按应用加载配置的行为判断。config-center 自举 Secret 始终按 pre 策略处理，不能把远程 Mac 地址覆盖进它。

Mac 需要连接本地 selector 指定的 Config Center 时，在另一终端保持：

```bash
make cc-forward
# 在操作终端指定工具访问该转发地址：
CONFIG_CENTER_URL=http://127.0.0.1:30010 make cc-plan ENV=dev
```

`cc-forward` 前台运行，Ctrl-C 停止。它只转发 Config Center，不提供到 Gateway VIP 的网段路由。

## operator 签发与凭据轮换

```bash
# 推荐在控制面节点运行；准备受保护的管理员 JWT 文件或既有 Casdoor 登录文件。
ISSUER_JWT_FILE=/secure/admin.jwt make operator-issue ENV=dev CONFIRM=yes
make rotate-plan
make rotate-apply CONFIRM=yes
# 共享同一个 Dragonfly 时，轮换后 dev 也要更新：
make cc-plan ENV=dev
make cc-apply ENV=dev CONFIRM=yes
```

签发脚本会创建新 token 并覆盖对应 Secret；它不是无变化时跳过的 ensure 操作，旧 token 不会自动吊销。operator 不能签发另一个 operator，首次签发仍需管理员授权。

service token 的 fail-closed 轮换入口：

```bash
# 先让 harvest --rotate-tokens 记录 selector Secret 的 service-token-ids 注解
ENV=pre ADMIN_TOKEN_SECRET=config-center/config-center-operator:token \
  bash tools/config-center-rotate-service-tokens.sh
CONFIRM=yes ENV=pre ADMIN_TOKEN_SECRET=config-center/config-center-operator:token \
  bash tools/config-center-rotate-service-tokens.sh --apply
```

它按三阶段执行：A 签发新 token 并**用新 token 本身**读回、写 selector Secret（旧 id 记入 `service-token-ids-previous`）→ B 滚动全部消费者并等就绪 → C 全部就绪后才吊销旧 token。任一阶段失败即停，旧 token 仍有效；重跑进入续跑模式（不签新 token，只重做 B+C）。同一脚本打进 TCR 镜像由 CronJob `config-center/config-center-service-token-rotation` 每周日跑 pre（`components/config-center-token-rotation/`）。operator token 自身不能用这个流程自我升级。轮换入口仅允许 pre；底层轮换脚本会执行组件安装、服务滚动，可能涉及 Helm 变更，执行前必须安排窗口。预览不是完整的故障回滚演练。

## Pangolin remote-dev 入口

```text
Mac → Pangolin resource → newt → K8s Gateway / node service
```

远程开发资源当前为：

```text
consul-dev.apikv.com       → 10.10.31.240:443
redis-dev.apikv.com:30005  → 10.10.31.243:6380
```

### 三层配置边界

新增或维护 raw TCP 端口时，配置分为三层：

| 层 | 由什么维护 | 当前内容 |
|---|---|---|
| Pangolin API | `reconcile-k8s-dev-resources.sh` | resource、SSO、TLS Server Name、target、启用状态 |
| node1 VPS | `--apply-infra` | gerbil 的端口映射、Traefik `tcp-30005` entryPoint |
| 腾讯云 Lighthouse | `--apply-infra` | raw TCP `30005` 防火墙规则 |

普通 API 收敛不会修改 VPS 或云防火墙；基础设施收敛需要单独显式执行。

### 命令

```bash
# 只读：检查三层是否一致
make pangolin-check

# 只收敛 Pangolin API resource/target
make pangolin-apply CONFIRM=yes

# 收敛 node1 VPS + Tencent Cloud firewall + Pangolin API
make pangolin-apply-infra CONFIRM=yes

# 临时禁用两个 remote-dev resource；不删除配置、不关闭云防火墙端口
make pangolin-disable CONFIRM=yes

# 恢复
make pangolin-apply CONFIRM=yes
```

`pangolin-apply-infra` 的安全边界：

- SSH 目标只能是 `node1`；脚本拒绝 `node3`、`node4`、`node5` 和其他主机名。
- 不读取、不修改 Kubernetes 节点的 SSH 配置和 SSH 端口。
- 修改 node1 前备份到 `/home/docker/pangolin/.reconcile-backups/<timestamp>/`。
- `docker compose up -d` 可能让 Pangolin/gerbil/Traefik 短暂重建；执行前应确认公网入口可接受短暂中断。
- 云防火墙规则只允许明确声明的端口；当前是 TCP `30005`，不是 SSH 端口。

这些目标调用相邻 `docker-deploy` 仓的 `pangolin/reconcile-k8s-dev-resources.sh`。位置不同时传 `DOCKER_DEPLOY_DIR=/path/to/docker-deploy`。需要 `~/.pangolin-login` 或 `PANGOLIN_LOGIN_FILE` 指定的受保护文件，内容为两行邮箱和密码；用完由操作者删除。

`pangolin-disable` 只禁用 API 资源，不删除配置、不关闭公网监听端口、不提供自动过期机制。传播有延迟；TCP 握手成功不能证明 Redis 可用，应继续验证 TLS、AUTH、PING。

## 组件与本地服务

```bash
make component-install COMPONENT=reloader CONFIRM=yes
# 单独重跑 Consul 安装（包含 ACL 恢复）：
make component-install COMPONENT=consul CONFIRM=yes
```

这不是单独的 ACL 修复命令，会运行整个组件安装脚本。Consul 重建演练与 OpenBao 集群外备份已延期，没有加入默认目标。

业务开发命令属于 ecommerce 仓，不在这里运行：

```bash
make -C ../ecommerce/backend/services/cart dev
# 先安全地向进程环境提供 CONSUL_HTTP_TOKEN，再显式注册：
make -C ../ecommerce/backend/services/cart dev-consul
```

不要使用 `make -n dev-consul` 检查带真实 token 的调用：已有服务 Makefile 会展开并打印 token。更多配置语义见 [Config Center 自动填充](config-center/README.md)。

## 安全约定

写操作要求 `CONFIRM=yes`，仅防止误触，不取代权限与维护窗口审批。默认不接受任意 `ARGS` 转发，避免把预览命令意外变成写操作。不要并行执行签发、填充和轮换；一个阶段失败应先修复，不要跳过错误继续执行。
