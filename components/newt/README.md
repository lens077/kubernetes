# newt —— Pangolin 隧道客户端（把集群服务暴露到公网）

## 1. 定位

集群在局域网里，没有公网 IP。newt 与公网 VPS 上的 [Pangolin](https://pangolin.apikv.com)
建立 WireGuard 隧道，让 `*.apikv.com` 的请求能打到集群内的服务。

```
公网用户 ──HTTPS──> node1 VPS(114.132.233.129)     ← Pangolin + Traefik
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

> **实测结论（2026-10-24）**：newt 1.19.0（当前最新）+ Pangolin 服务端 1.25.3（当前最新）配套运行正常，
> `k8s-cluster` / `k1` / `k2` / `k3` / `node2` 站点全部 `online=true`。
> 客户端启动日志同时打印 `Newt version 1.19.0` 与 `Server version: 1.25.3`，两者都对才算版本配平。

## 5.1 版本线对照（2026-10-24 复核）

**Pangolin 服务端与 newt 客户端是两个独立的版本线**，不要把服务端的号套到客户端上：

| 组件 | 上游 | 当前版本 | 说明 |
|---|---|---|---|
| Pangolin（服务端控制面） | [fosrl/pangolin](https://github.com/fosrl/pangolin) | **1.25.3** | node1 Docker 版控制面 |
| Gerbil（隧道数据面） | [fosrl/gerbil](https://github.com/fosrl/gerbil) | 1.5.2 | 已是最新，无需动 |
| Newt（客户端） | [fosrl/newt](https://github.com/fosrl/newt) | **1.19.0** | 客户端版本线独立，1.25.x 服务端配套 1.19.0 |

升级时服务端与客户端要**成对升**：只升服务端不升客户端，服务端日志会出现
`Newt ping with outdated config version: 2 (current: 0)`；只升客户端不升服务端，
客户端能连上但用不到新特性。

本集群当前有两套 newt 客户端，升级时**两套都要动**：

| 位置 | 形态 | 站点 | 升级方式 |
|---|---|---|---|
| k8s 内（`pangolin` ns） | Deployment，镜像 `fosrl/newt:1.19.0` | `k8s-cluster` | 改本目录 manifest → `bash components/newt/install.sh` |
| 主机级 | `/usr/local/bin/newt` + systemd `newt.service` | `k1`/`k2`/`k3`/`node2` | 换二进制 → `systemctl restart newt.service` |

主机级 newt 的凭据在 `/home/docker/newt/newt.env`（site k1/k2/k3/node2 各一份），
装法同 node2；systemd 单元在 `/etc/systemd/system/newt.service`。

> **机房拉镜像**：k1/k2/k3 的 containerd 配了一串国内镜像站，个别站对非公开路径会 401。
> 实测 `fosrl/newt:1.19.0` 能拉到，但**换版本前先在三台节点上 `crictl pull` 预拉**，
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
- **升服务端时别让 Pangolin 把 Badger 改成 v1.8.0**（2026-10-24 记录）：
  Pangolin 1.25 起，如果 release 里含 Badger 更新，它会**尝试自动改写 Traefik 配置**里的
  Badger 版本号。坏消息是上游明确警告 **Badger `v1.8.0` 是坏的**（过不了 Traefik 插件完整性校验，
  插件会被禁用 → 所有路由 404），要求留在 `v1.7.0`。
  好消息是这个自动改写**只在 Traefik 配置与默认安装器模板一致时才生效**，
  改不动就静默失败。本集群 `config/traefik/traefik_config.yml` 已深度定制
  （vendored `plugins-local` + `localPlugins` + crowdsec/safeline），与默认模板不符，
  实测升级后指纹不变、Badger 仍是 `v1.7.0`。
  **但这是"碰巧安全"，不是保证** —— 每次升服务端前都该确认一次：

  ```bash
  grep -A3 'badger:' /home/docker/pangolin/config/traefik/traefik_config.yml   # 应为 v1.7.0
  ```

- **升服务端必然断隧道几秒**（2026-10-24 记录）：`docker compose up -d pangolin` 重建控制面时，
  所有 newt 客户端会连到断掉的后端，报 `failed to get token: ... 502 Bad Gateway. Retrying in 3s...`。
  客户端自带的重试会在几秒内恢复，日志随后出现 `Server version: <新版本>`。
  **看到 502 不要手动去重启客户端** —— 重启反而会多一次断连。
  判据是最终出现 `Tunnel connection to server established successfully!`。
- **SQLite 迁移前 Pangolin 会自动备份**（2026-10-24 记录）：迁移脚本会把 DB 快照写到
  `config/db/backups/db_<时间戳>_v<版本>.sqlite`。但**别依赖它**——
  官方文档明说「downgrade is sometimes impossible and is not recommended」，
  schema 变了旧版本可能读不了。升级前自己另存一份（`sqlite3` 的 `.backup` 或 `cp`）才是稳的。

