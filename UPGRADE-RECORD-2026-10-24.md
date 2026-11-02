# Pangolin / Newt 全量升级到 1.25.3 —— 执行记录（2026-10-24）

## 结论

全部完成并验证通过。**Pangolin 服务端 = 1.25.3，newt 客户端 = 1.19.0**（两个独立版本线，详见 §2）。

| 主机 | 组件 | 升级前 | 升级后 | 形态 |
|---|---|---|---|---|
| node1 | Pangolin 控制面 | 1.24.0 | **1.25.3** | Docker（`fosrl/pangolin`） |
| node1 | Gerbil | 1.5.2 | 1.5.2（未动） | Docker |
| node1 | Traefik | v3.7.12 | v3.7.12（未动） | Docker |
| node2 | Newt | 1.18.1 | **1.19.0** | `/usr/local/bin/newt` + systemd |
| k1 / k2 / k3 | Newt | 1.18.1 | **1.19.0** | `/usr/local/bin/newt` + systemd |
| k8s 集群 | Newt | 1.18.1 | **1.19.0** | Deployment（`fosrl/newt`） |

**未改动（按要求排除）**：`node0`、`node6`（SSH 当次即连接拒绝，未做任何操作）。

> node3 / node4 本来就没装 newt（`docker ps` 空、无 systemd unit、无二进制），保持原状。

---

## 1. 范围界定：为什么 node1 是「控制面」而不是「客户端」

`~/.ssh/config` 里共 8 台云主机 + 3 个 k8s 节点。逐台勘察后，实际需要升级的对象分两类：

- **node1** 是 **Pangolin 服务端**（`/home/docker/pangolin/docker-compose.yml`，
  `fosrl/pangolin` + `gerbil` + `traefik`），跑 6 个站点与全部对外域名。
  它**没有** newt 客户端（无 `/usr/local/bin/newt`、无 `newt.service`）——
  面板里的 `node1-local` 站点是 `type=local`，不是 newt 站点。
- **node2 / k1 / k2 / k3** 是 **newt 客户端**，各有独立 siteId（5 / 12 / 13 / 14），
  装法是二进制 + systemd。
- **k8s 内** 还有一个 newt Deployment（siteId 11 `k8s-cluster`），
  是集群所有对外服务的入口 —— 这套**必须升**，否则 `*.apikv.com` 全 502。

> 踩过的坑：1.25 之后 newt 客户端会在 ping 时上报自己的 config version。
> 只升服务端不升客户端时，服务端日志会出现
> `[warn]: Newt ping with outdated config version: 2 (current: 0)`。
> 本次把 k8s 内那个也升到 1.19.0 后，该告警不再出现。

---

## 2. 版本线澄清（最容易搞混的一点）

用户要求「全部升级到 1.25.3」，但 **1.25.3 只是 Pangolin 服务端的版本号**。
newt 是**独立版本线**，没有 1.25.3 这个版本；与 1.25.x 服务端配套的最新客户端是 **1.19.0**
（newt 1.19.0 发布于 2026-10-20，Pangolin 1.25.0 发布于 2026-10-21）。

上游 release 对照：

| 仓库 | 最新版 | 发布日 |
|---|---|---|
| [fosrl/pangolin](https://github.com/fosrl/pangolin) | 1.25.3 | 2026-10-23 |
| [fosrl/newt](https://github.com/fosrl/newt) | 1.19.0 | 2026-10-20 |
| [fosrl/gerbil](https://github.com/fosrl/gerbil) | 1.5.2 | 2026-09-18 |
| [fosrl/badger](https://github.com/fosrl/badger) | v1.8.0（**坏的，见 §4**） | 2026-10-21 |

若把客户端也强行当成 1.25.3，会拉到一个不存在的 tag。

---

## 3. 执行步骤与顺序

### 3.1 备份（node1，升级前）

```bash
TS=$(date +%Y%m%d-%H%M%S); B=/root/pangolin-backups/$TS
mkdir -p $B
cp -a /home/docker/pangolin/docker-compose.yml $B/
cp -a /home/docker/pangolin/config $B/config          # 3.2G
# 再用 sqlite3 backup API 补一份一致性快照（拷贝期间可能有写入）
python3 -c "import sqlite3; s=sqlite3.connect('/home/docker/pangolin/config/db/db.sqlite'); \
            d=sqlite3.connect('/home/docker/pangolin/config/db/db.snapshot.sqlite'); s.backup(d)"
cp -a .../db.snapshot.sqlite $B/snapshot.sqlite
```

产物：`/root/pangolin-backups/20261024-132731/`
（`docker-compose.yml` + `config/` 3.2G + `snapshot.sqlite` 447MB）。

> 之所以额外做 `.backup` 快照：`cp` 拷 447MB 的 SQLite 期间可能正在写入，
> 拷出来的文件不保证一致。

### 3.2 主机级 newt 升级（node2 → k1 → k2 → k3）

**先升客户端再升服务端**：这样服务端重启时，已经有配套的新客户端在跑。

```bash
# 每台节点执行
curl -fsSL -o /tmp/newt https://ghfast.top/https://github.com/fosrl/newt/releases/download/1.19.0/newt_linux_amd64
chmod +x /tmp/newt
/tmp/newt --version                    # 必须是 "Newt version 1.19.0"，否则中止
cp -a /usr/local/bin/newt /usr/local/bin/newt.bak-1.18.1
install -m 0755 /tmp/newt /usr/local/bin/newt
systemctl restart newt.service
```

校验点：`--version` 输出必须精确匹配目标版本（防止镜像站给错包）；
备份名带上旧版本号，便于回滚。

产物备份：`node2` 有 `newt.bak-1.16.0 / 1.17.0 / 1.18.1`，
`k1/k2/k3` 有 `newt.bak-1.17.0 / 1.18.1`。

### 3.3 node1 Pangolin 控制面升级

```bash
cd /home/docker/pangolin
cp -a docker-compose.yml docker-compose.yml.bak-p1.25.3-$(date +%Y%m%d-%H%M%S)
sed -i 's#fosrl/pangolin:1.24.0#fosrl/pangolin:1.25.3#' docker-compose.yml
docker compose pull pangolin
docker compose up -d pangolin          # 只重建控制面, 不动 traefik/gerbil
```

**只重建 pangolin 容器**，traefik 与 gerbil 保持运行 —— 这样 443 入口与隧道数据面全程不中断，
只有控制面 API 短暂不可用。

迁移日志（容器 stdout）：

```
Starting migrations from version 1.24.0
Migrations to run: 1.25.0, 1.25.3
Running migration 1.25.0 → Migrated database → complete
Running migration 1.25.3 → Migrated database → complete
All migrations completed successfully
```

Pangolin 自己也自动备份了 DB：`config/db/backups/db_2026-10-24_05-33-5x_v1.25.{0,3}.sqlite`。

### 3.4 k8s 内 newt Deployment 升级

1. 改仓库 `components/newt/manifests/01-deployment.yaml`：`fosrl/newt:1.18.1` → `:1.19.0`；
2. 同步到 k1 的仓库副本 `/root/kubernetes/`，跑官方安装流程：

```bash
cd /root/kubernetes && export KUBECONFIG=/etc/kubernetes/admin.conf
bash components/newt/install.sh
# secret/newt-credentials unchanged   ← 凭据没被改
# deployment.apps/newt configured
kubectl -n pangolin rollout status deploy/newt --timeout=180s
```

> **预拉镜像**：机房 containerd 配了一串国内镜像站（1ms.run / daocloud / xuanyuan 等），
> 个别站对非公开路径返 401。换版本前先在三台节点 `crictl pull` 预拉，
> 否则 rollout 可能卡 `ImagePullBackOff`。本次 k2/k3 就缺镜像层，已补拉。
>
> **GitHub 下载**：机房直连 GitHub 不通，走 `https://ghfast.top/https://github.com/...`。
> 仓库文档里已记录这条路径。

---

## 4. 关键风险点与处理

### 4.1 Badger v1.8.0 是坏的 —— 但自动升级没触发

Pangolin 1.25 release notes 明确警告：

> Badger `v1.8.0` is currently broken, so please stay on `v1.7.0`.
> Badger `v1.8.0` fails Traefik's plugin integrity check, which disables the plugin.

Badger 被禁用 → 所有路由 404。

同时，官方文档说：Pangolin 启动检测到版本更新时会跑迁移脚本，
「If a release includes a Badger update, Pangolin also tries to update the Traefik config
**when it still matches the default Pangolin installer Traefik config**.
If Pangolin cannot apply that change, it fails silently.」

本集群的 `config/traefik/traefik_config.yml` 已深度定制（vendored `plugins-local` +
`localPlugins` + crowdsec/safeline + 大量 `forwardedHeaders.trustedIPs`），
与默认安装器模板不符 → **自动改写静默失败**。

实测验证（升级前后对比）：

```
升级前 md5: dcac5e63eb57561cad0360b98e691343
升级后 md5: dcac5e63eb57561cad0360b98e691343   ← 未变
badger version: v1.7.0                          ← 未被改成 v1.8.0
```

⚠️ 这是「碰巧安全」不是保证。**每次升服务端前都应复核**：

```bash
grep -A3 'badger:' /home/docker/pangolin/config/traefik/traefik_config.yml   # 应为 v1.7.0
```

### 4.2 升服务端必然断隧道几秒

控制面容器重建期间，所有客户端报：

```
ERROR: Failed to connect: failed to get token: failed to get token with status code: 502, body: Bad Gateway. Retrying in 3s...
```

客户端自带重试，几秒内恢复，随后打印 `Server version: 1.25.3`。
**不要手动去重启客户端** —— 只会多一次断连。判据是出现
`Tunnel connection to server established successfully!`。

### 4.3 备份的必要性

官方文档明说「downgrading is sometimes impossible and is not recommended」——
schema 变了旧版本可能读不了。本次 schema 从 1.24.0 迁到 1.25.3，
**理论上不可降级**，所以备份是唯一退路。

---

## 5. 验证结果

### 5.1 版本与服务状态

```
node2  Newt version 1.19.0  service=active  Server version: 1.25.3
k1     Newt version 1.19.0  service=active  Server version: 1.25.3
k2     Newt version 1.19.0  service=active  Server version: 1.25.3
k3     Newt version 1.19.0  service=active  Server version: 1.25.3

pangolin    fosrl/pangolin:1.25.3    Up (healthy)
gerbil      fosrl/gerbil:1.5.2       Up
traefik     traefik:v3.7.12          Up

k8s newt:  docker.io/fosrl/newt:1.19.0   rollout succeeded   (Running 1/1)
```

### 5.2 隧道握手（最终判据，不是看 Pod Running）

k8s 内 newt：

```
INFO: Newt version 1.19.0
INFO: Server version: 1.25.3
INFO: Tunnel connection to server established successfully!
INFO: Client connectivity setup. Ready to accept connections from clients!
```

服务端侧 7 个 WebSocket 连接建立。

### 5.3 面板站点 online（直读 DB，最终判据）

| siteId | 名称 | 类型 | online |
|---:|---|---|---|
| 1 | node1-local | local | 1 |
| 5 | node2 | newt | 1 |
| 6 | mac | newt | 1 |
| 8 | node0 | newt | **0**（按要求排除，未升级；SSH 当次即拒连） |
| 11 | k8s-cluster | newt | 1 |
| 12 | k1 | newt | 1 |
| 13 | k2 | newt | 1 |
| 14 | k3 | newt | 1 |

### 5.4 公网入口实测

```
gateway.apikv.com      HTTP=404   server: envoy
shop.apikv.com         HTTP=200   server: envoy
pangolin.apikv.com     HTTP=200
```

`gateway.apikv.com` 的 404 带 `server: envoy` —— 这是**请求已到达集群网关**、
只是 Host/path 不匹配，不是隧道故障（见 `components/newt/README.md` §4 的说明）。

### 5.5 告警清理

升级后 `[warn]: Newt ping with outdated config version: 2 (current: 0)`
仅在 13:34:04（k8s 内还是 1.18.1 时）出现一次，之后未再出现。

---

## 6. 遗留与建议

1. **node0 的 newt 站点 offline**（siteId 8）—— 按要求排除在本次升级外。
   若后续要恢复，需单独处理（它走 Docker `fosrl/newt`，且当次 SSH 端口拒连）。
2. **Badger 仍钉在 v1.7.0** —— 上游说 v1.8.0 已坏，等 Traefik 修复后再升。
   在此之前**每次升 Pangolin 都要复核它没被自动改动**。
3. **Pangolin 1.25 的新特性未启用** —— redirects / mTLS / machine roles
   都是可选功能，升级不会自动打开，需要时去面板配。
4. **Traefik 已是 v3.7.12 ≥ 3.6**，满足 1.25 对 load balancing 的前置要求，无需动。
5. **仓库配置源已同步**：`components/newt/manifests/01-deployment.yaml` 改为
   `fosrl/newt:1.19.0`，并同步到 k1 的 `/root/kubernetes/` 副本；
   `components/newt/README.md` 补了版本线对照表与本次的三条踩坑。

---

## 7. 复现命令

```bash
# 版本总览
for h in node2 k1 k2 k3; do
  printf "%-6s %s  " $h "$(ssh $h '/usr/local/bin/newt --version' 2>&1 | head -1)"
  ssh $h 'systemctl is-active newt.service'
done
ssh node1 'docker ps --filter name=pangolin --format "{{.Names}} {{.Image}} {{.Status}}"'

# 握手(客户端)
ssh k1 'journalctl -u newt.service --no-pager -n 30 | grep -iE "Server version|Tunnel connection"'

# 握手(k8s 内)
ssh k1 'export KUBECONFIG=/etc/kubernetes/admin.conf; \
        kubectl -n pangolin logs deploy/newt | grep -iE "Newt version|Server version|Tunnel connection"'

# Badger 版本(每次升服务端前必查)
ssh node1 'grep -A3 "badger:" /home/docker/pangolin/config/traefik/traefik_config.yml'

# 站点 online
ssh node1 'python3 /root/check_sites.py'    # 见 §5.3
```
