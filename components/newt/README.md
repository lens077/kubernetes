# newt —— Pangolin 隧道客户端（把集群服务暴露到公网）

## 1. 定位

集群在局域网里，没有公网 IP。newt 与公网 VPS 上的 [Pangolin](https://pangolin.apikv.com)
建立 WireGuard 隧道，让 `*.apikv.com` 的请求能打到集群内的服务。

```
公网用户 ──HTTPS──> node3 VPS(193.112.22.183:34125) ← Pangolin + Traefik（2026-11-12 从 node1 迁入）
                        │ WireGuard(隧道由集群侧发起)
                        └──> 本集群 newt ──> Cilium Gateway 固定 VIP:443 ──> HTTPRoute ──> Service/Pod
                                         └──> 10.10.21.161|162|163:<端口> ──> node4|5|3 节点服务
```

**关键性质：局域网侧全程只出不进** —— newt 不监听任何端口，路由器不需要做端口映射，
也不需要公网 IP。这是选它而不是 frp/nps 之类的主要原因。

不装的后果：`shop.apikv.com` / `gateway.apikv.com` 这类对外域名全部 502
（Pangolin 侧站点 offline，没有隧道可转发）。

## 2. 上游最佳实践

来源：[fosrl/newt](https://github.com/fosrl/newt)、Pangolin 面板的站点安装指引（2026-08 复核，newt 1.15.0）

- 每个站点（site）一份 `newtId` + `secret`，**secret 只在建站点那一刻回显一次**，
  面板 API 之后不再返回它（`GET /site/:id` 里 `newtId` 有值、`secret` 为 null）。
- 一份凭据只应有一个进程在用；重复注册会互相顶替连接。
- 参数三件套：`--endpoint` / `--id` / `--secret`，也可用配置文件。
- 上游**没有可用的 helm chart 仓库**（`https://fosrl.github.io/newt` 实测 404）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| helm chart | **自写 manifest** | 上游 chart 仓库 404；而 newt 本来就只是一个容器 + 三个参数，为它引一层 chart 不划算。 |
| `replicas` 随意 | **1 + `strategy: Recreate`** | 同一份凭据的两个进程会互相顶替，滚动更新期间隧道反复断开。Recreate 是"先断后连"，短暂中断但状态干净。要冗余得在面板另建站点，不是加副本。 |
| 镜像 `latest` | **钉 `1.15.0`** | 见踩坑第一条——版本错了会得到"Pod Running 但隧道没建"的假象。 |
| 容器以 root 跑 | 非 root + 只读根文件系统 + drop ALL | newt 的隧道能力不需要这些权限。代价是 `auth-daemon` 子功能起不来（日志有一条 WARN），本集群用不到它。 |
| 默认 `$HOME` | 显式 `HOME=/home/newt` + emptyDir | 镜像没给 uid 1000 设 HOME，newt 会往 `/.config/` 写配置，只读根下必失败。**不影响隧道**（参数已从命令行拿到），但每次启动刷一条 ERROR 很误导。 |

## 4. 暴露方式

`EXPOSE=none` —— 它自己不对外暴露任何东西，是**让别人能被暴露**的那个组件。

对外暴露某个集群服务是两步（详见 ecommerce 仓 `context/team/pangolin-tunnel.md`）：

1. 给目标服务的 HTTPRoute **追加** hostname（保留原 `*.dev.test`，增量可回退）：
   ```bash
   kubectl patch httproute <name> -n <ns> --type=json \
     -p='[{"op":"add","path":"/spec/hostnames/-","value":"xxx.apikv.com"}]'
   ```
2. Pangolin 面板建资源：subdomain `xxx`，site 选本组件对应的那个，target 用共享 Gateway 的**固定 VIP**：
   ```bash
   # 内网版默认 192.168.3.120；机房版默认 10.10.31.240；以运行配置为准
   source bootstrap/config.env
   echo "https://${CILIUM_GATEWAY_LB_IP}:443"
   ```
   不再写会随重建变化的 Service ClusterIP。Gateway manifest 用 `spec.addresses` 钉住
   `CILIUM_GATEWAY_LB_IP`；Cilium 的 `gateway-pool` 让该 Service 独占 `/32`，preflight 验证它不与
   给其它 LoadBalancer 的 default-pool 重叠。

直接暴露节点服务不经过 HTTPRoute：Pangolin resource 的 target 填节点内网 IP 与真实端口，例如
`10.10.21.161:<port>` / `.162:<port>` / `.163:<port>`。这仍通过 newt 隧道，节点不需要新增公网映射；
只暴露确实需要的端口，kubelet/etcd/Cilium metrics 等管理端口不应建资源。

> ⚠️ HTTPRoute **target 必须走 443/https**：本仓的 HTTPRoute 都带 `sectionName: https`，
> 路由只挂在 443 listener 上，**80 端口上没有任何路由，envoy 对一切 Host 返 404**。
> 判别 404 来源：看响应头有没有 `server: envoy`。

## 5. 验证

```bash
kubectl -n pangolin get deploy newt        # READY 1/1
```

**别拿 Pod Running 当隧道通了** —— 参数错误时 newt 会打印 usage 然后退出，
被 restartPolicy 拉起来看着一切正常。要看日志里的握手：

```bash
kubectl -n pangolin logs deploy/newt | grep -iE 'tunnel|connect'
# 期望: Tunnel connection to server established successfully!
#       Client connectivity setup. Ready to accept connections from clients!
```

最终判据在面板侧（站点 `online` 必须为 true）：

```bash
curl -s -b <cookie> https://pangolin.apikv.com/api/v1/org/main/sites \
  | jq -r '.data.sites[] | "\(.name) online=\(.online)"'
```

> **实测结论（2026-08-19）**：newt 1.15.0 在本集群建立隧道成功，
> 面板站点 `k8s-cluster` `online=true`。

> **实测结论（2026-10-24）**：newt 1.19.0（当时最新）+ Pangolin 服务端 1.25.3 配套运行正常，
> `k8s-cluster` / `k1` / `k2` / `k3` / `node2` 站点全部 `online=true`。
> 客户端启动日志同时打印 `Newt version 1.19.0` 与 `Server version: 1.25.3`，两者都对才算版本配平。

> **实测结论（2026-11-10）**：newt 1.20.0 + Pangolin 服务端 1.26.0 配套运行正常，
> 面板 11 个站点（含 2026-11-03 新增的 `node3`/`node4`/`node5`/`node6`）全部 `online=1`。
> 8 台主机级 newt 与 k8s 内 newt 均报 `Server version: 1.26.0`，服务端 0 条告警。

> **实测结论（2026-11-25，当前版本）**：newt **1.20.1** + Pangolin 服务端 **1.27.1** 配套运行正常，
> 8 个客户端（node2/4/5/6 + k1/k2/k3 + k8s 内）全部握手成功，均见
> `Newt version 1.20.1` + `Tunnel connection established successfully!`。
> newt 没有 1.27.1 这个号——服务端与客户端是两条独立版本线，别把服务端号套到客户端。

## 5.1 版本线对照（2026-11-25 复核）

**Pangolin 服务端与 newt 客户端是两个独立的版本线**，不要把服务端的号套到客户端上：

| 组件 | 上游 | 当前版本 | 说明 |
|---|---|---|---|
| Pangolin（服务端控制面） | [fosrl/pangolin](https://github.com/fosrl/pangolin) | **1.27.1** | 边缘核心已迁至 node3 的 Docker 控制面 |
| Gerbil（隧道数据面） | [fosrl/gerbil](https://github.com/fosrl/gerbil) | 1.6.0 | 独立版本线，已是最新（`:latest`） |
| Newt（客户端） | [fosrl/newt](https://github.com/fosrl/newt) | **1.20.1** | 客户端版本线独立，1.27.x 服务端配套 1.20.1；无 1.27.1 这个号 |
| Badger（Traefik 插件） | [fosrl/badger](https://github.com/fosrl/badger) | **v1.8.0** | 2026-11-03 起已解禁，迁移自动改写并实测加载成功 |
| Traefik | traefik | v3.8.0 | 2026-11-25 升级，vendored 插件 badger/crowdsec/safeline 全部加载 |

升级时服务端与客户端要**成对升**：只升服务端不升客户端，服务端日志会出现
`Newt ping with outdated config version: 2 (current: 0)`；只升客户端不升服务端，
客户端能连上但用不到新特性。

本集群当前有两套 newt 客户端，升级时**两套都要动**：

| 位置 | 形态 | 站点 | 升级方式 |
|---|---|---|---|
| k8s 内（`pangolin` ns） | Deployment，镜像 `fosrl/newt:1.20.1` | `k8s-cluster` | 改本目录 manifest → `bash components/newt/install.sh` |
| 主机级 | `/usr/local/bin/newt` + systemd `newt.service` | `k1`/`k2`/`k3`/`node2` + 云机 `node3`/`node4`/`node5`/`node6`（2026-11-03 新增，siteId 15–18） | 换二进制 → `systemctl restart newt.service` |

主机级 newt 的凭据在 `/home/docker/newt/newt.env`（每台一份），
装法同 node2；systemd 单元在 `/etc/systemd/system/newt.service`（模板：`newt.service.template`）。
云机的加/移除/巡检用 `./newt-host.sh add|remove <ssh-alias> | list`（面板凭据放 `~/.pangolin-admin.env`，不入库）；
secret 只在站点创建那一刻回显一次，凭据丢失只能在面板删站重建。

**Windows 客户端**（开发机接入）见同目录 `WINDOWS-CLIENT-RUNBOOK.md`：
面板建站点 → 下载 `newt_windows_amd64.exe` 1.20.1 → NSSM 注册开机自启 →
验握手与 `online=True` → 建 HTTP/TCP 资源。注意 newt 是反代，
资源 target IP 要从 Windows 本机视角写 `127.0.0.1`，不是机器公网 IP。

> **机房拉镜像**：k1/k2/k3 的 containerd 配了一串国内镜像站，个别站对非公开路径会 401。
> 实测 `fosrl/newt:1.20.1` 能拉到，但**换版本前先在三台节点上 `crictl pull` 预拉**，
> 否则 rollout 时可能卡在 `ImagePullBackOff`。
> GitHub release 下载同理，机房直连不通，走 `https://ghfast.top/https://github.com/...`。

## 6. 踩坑

- **版本号看着像 1.5 之后就是 1.15**：写成 `1.5.0` 会拉到一个没有 `-endpoint` flag 的老版本，
  表现是 `flag provided but not defined: -endpoint` + 打印 usage 退出，
  而 `kubectl get pod` 显示 `1/1 Running`（重启太快，撞不上 CrashLoop 计数）。
  **一定要看日志确认握手**。
- **secret 丢了只能重建站点**：面板不回显已有站点的 secret。本组件把凭据存进
  `$STATE_DIR/creds/newt-{id,secret}`，重装/重跑自动复用；
  但那是本机状态，换机器要么带着 creds 走，要么在面板重开一个站点。
- **旧资源不能继续指向 ClusterIP**：ClusterIP 随重建变化（旧值 `10.97.94.118` 已失效）。
  2026-09-03 已从 node3 收割站点凭据，可以复用这份 site（确保旧 newt 进程先下线，避免互相顶替）；
  面板资源 target 统一改成固定 `CILIUM_GATEWAY_LB_IP:443`，以后重建不再改地址。
- **凭据不入库**：`newt-credentials` Secret 由 install.sh 从 creds 生成，manifest 里只有引用。
- **`auth-daemon must be run as root` 是可忽略的 WARN**：那是 newt 的 SSH 认证附加功能，
  与隧道无关；本组件刻意不给 root。
- **Badger v1.8.0：结论在 2026-11-03 反转了**（2026-11-10 修订，覆盖 10-24 的旧记录）：
  - **10-24 当时**：上游明确警告 `v1.8.0` 是坏的（过不了插件完整性校验 → 插件被禁 → 全路由 404），
    要求留 `v1.7.0`。当时我们升 1.25.3 后配置指纹没变、Badger 仍是 v1.7.0，
    于是推断「深度定制的 Traefik 配置不匹配默认安装器模板 → 自动改写静默失败」。
  - **11-10 实测推翻了这个推断**：1.26.0 迁移日志明确打印
    `Updated the version of Badger in your Traefik configuration to v1.8.0`，
    指纹 `d4c74bd…` → `2cc2cf7…`。**不要依赖"定制配置能挡住改写"**。
  - 修复方是 **Traefik 插件目录服务端**（11-03），不是 Traefik 二进制版本门槛：
    最新稳定版 v3.7.17 发布于 10-30，早于修复日；本集群 v3.7.12 实测也能加载 v1.8.0。
    1.26.0 release notes 已明确「You can now safely upgrade to Badger v1.8.0」。
    （以上为 11-10 当时的版本；当前 Traefik 已升 v3.8.0、Pangolin 已升 1.27.1，插件仍全部加载。）
  - ⚠️ **最容易漏的一步**：迁移只改**配置文件**，不会重启 traefik。此时
    配置写 v1.8.0、运行态还是 v1.7.0，等于把雷留到下一次任何一次 traefik 重启。
    升完服务端必须立刻重启 traefik 让两者对齐，并验证插件真的加载成功：

    ```bash
    grep -A2 'badger:' /home/docker/pangolin/config/traefik/traefik_config.yml
    docker restart traefik
    docker logs traefik --since 2m | grep -i 'Plugins loaded'     # 应含 badger
    docker exec traefik ls /plugins-storage/archives/github.com/fosrl/badger/   # 应只有 v1.8.0.zip
    curl -s -o /dev/null -w '%{http_code}\n' -k https://pangolin.apikv.com/     # 200
    ```

    重启前先确认 `safeline-detector` 是 healthy（它没重启时才安全，详见 node1 安全栈记录）；
    重启后顺带看 traefik 日志无 `crowdsec …403` / `safeline error in detection` / `broken pipe`。

- **升服务端必然断隧道几秒**（2026-10-24 记录）：`docker compose up -d pangolin` 重建控制面时，
  所有 newt 客户端会连到断掉的后端，报 `failed to get token: ... 502 Bad Gateway. Retrying in 3s...`。
  客户端自带的重试会在几秒内恢复，日志随后出现 `Server version: <新版本>`。
  **看到 502 不要手动去重启客户端** —— 重启反而会多一次断连。
  判据是最终出现 `Tunnel connection to server established successfully!`。
- **SQLite 迁移前 Pangolin 会自动备份**（2026-10-24 记录）：迁移脚本会把 DB 快照写到
  `config/db/backups/db_<时间戳>_v<版本>.sqlite`。但**别依赖它**——
  官方文档明说「downgrade is sometimes impossible and is not recommended」，
  schema 变了旧版本可能读不了。升级前自己另存一份（`sqlite3` 的 `.backup` 或 `cp`）才是稳的。

