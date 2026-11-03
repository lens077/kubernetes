# 项目长期记忆 —— kubernetes 集群

## 环境拓扑

- **SSH config**（`~/.ssh/config`）：node0/node1/node2/node3/node4/node6 + k1/k2/k3。
  - node1 = **Pangolin 服务端控制面**（`/home/docker/pangolin/docker-compose.yml`，
    `fosrl/pangolin` + `fosrl/gerbil` + `traefik`），跑全部对外域名。**它没有 newt 客户端**。
  - node2 / k1 / k2 / k3 = **newt 客户端**（二进制 `/usr/local/bin/newt` + systemd `newt.service`，
    凭据 `/home/docker/newt/newt.env`），各有独立 siteId 5/12/13/14。
  - k8s 集群内还有一个 newt Deployment（siteId 11 `k8s-cluster`），
    是集群对外服务的入口，**必须与主机级一起升**。
  - node3/4/5/6 = newt 客户端（2026-11-03 新增，siteId 15/16/17/18，
    凭据各自 `/home/docker/newt/newt.env`）；node0 已重装成 node5（Ubuntu 26.04）。
    加/移除/巡检脚本：`components/newt/newt-host.sh`（面板凭据 `~/.pangolin-admin.env`）。
  - 云主机指标：`hosts/observability/hosts.json` 现含 node1–node6（9 台预期主机全部 PASS）；
    otelcol 带 resourcedetection（os.type/os.version/host_arch），Grafana ops-portal 有「系统信息」表。
- **k1 是唯一控制面**（etcd 只在 k1），机房 `10.10.21.0/24`。
- 云主机（node0/1/2/3/4/6）与机房之间**无 L3 通路**，Pangolin/newt 是 L4 反代不是 L3 路由。

## Pangolin / newt 版本线（最容易搞混）

**Pangolin 服务端与 newt 客户端是两条独立版本线，号对不上。**

- Pangolin（服务端）：`fosrl/pangolin` —— 版本号如 1.25.3
- Newt（客户端）：`fosrl/newt` —— 版本号如 1.19.0，**没有 1.25.3 这种号**
- Gerbil（数据面）：`fosrl/gerbil` 1.5.2
- Badger（Traefik 插件）：`fosrl/badger` —— **必须留 v1.7.0，v1.8.0 是坏的**
  （过不了 Traefik 插件完整性校验 → 插件被禁 → 全路由 404）
- Traefik：需 ≥ 3.6（当前 v3.7.12）

服务端与客户端**成对升级**：只升服务端 → 服务端刷
`Newt ping with outdated config version: 2 (current: 0)`；只升客户端 → 连得上但用不到新特性。

### 升服务端前必查 Badger

Pangolin 1.25 启动时会**尝试自动改写 Traefik 配置里的 Badger 版本**，
但仅在配置与默认安装器模板一致时生效，改不动则静默失败。
本集群 `config/traefik/traefik_config.yml` 已深度定制（vendored `plugins-local` +
`localPlugins` + crowdsec/safeline），自动改写不触发 —— 但这是「碰巧安全」，每次都要复核：

```bash
grep -A3 'badger:' /home/docker/pangolin/config/traefik/traefik_config.yml   # 应为 v1.7.0
```

## 升级注意事项

- **升服务端必然断隧道几秒**，客户端报 502 后自愈。**不要手动重启客户端**。
- **schema 迁移后不可降级**（官方明说），升级前自己备份 DB
  （用 `sqlite3` 的 `.backup` API 做一致性快照，别只 `cp`）。
- 升服务端只重建 `pangolin` 容器，**traefik/gerbil 不动**，入口与数据面不中断。
- 主机级 newt 升级：`--version` 精确校验 → 备份旧二进制（名带版本号）→
  `install -m 0755` → `systemctl restart newt.service`。
- k8s 内 newt 升级：改 `components/newt/manifests/01-deployment.yaml` →
  同步到 k1 → 在 k1 上跑 `bash components/newt/install.sh`（secret 不会变）。
- **判据**：客户端日志 `Tunnel connection to server established successfully!`
  且 `Server version:` 与目标服务端版本一致。**别拿 Pod Running 当隧道通了。**

## gorse（2026-11-03 迁入集群）

- `components/gorse`：ArgoCD Application + 仓内 helm chart **三件套**（master/server/worker 0.5.11）。
  gorse-in-one 只跑 master（RESTful API 缺位，node2 旧形态同样如此）；API 在 gorse-server:8087（集群内），
  Dashboard=gorse.apikv.com（HTTPRoute，302→/login）。
- cache=**Dragonfly db0**（RediSearch 索引只允许 db0，db!=0 报 `ERR Cannot create index on db != 0`）；
  data=**CNPG pg-main 的 gorse 库**（user gorse，密码在 k1 creds gorse-pg-password）。
- 凭据 Secret `gorse-store`（api-key/admin-api-key/cache-store/data-store），CA 同 ns `gorse-ca`
  （Secret 不能跨 ns 挂载）；Go 信任链 SSL_CERT_FILE + DSN sslrootcert。
- **ArgoCD 源是 GitLab 镜像** `gitlab.com/sumery/kubernetes`（机房拉 GitHub 超时）；本地 `git push && git push gitlab`。
- **Cilium gateway 卡死坑**：operator 10-31 重启后新 HTTPRoute 一律不编程（status.parents 空、CEC 不更新），
  重启 operator 即恢复。判据：`cilium-gateway-cilium-gateway` CEC 里搜新路由 hostname。
- node2 gorse / node1 redis-gorse 已 down（redis.apikv.com 裸 TLS 直连无路由残留）；node1 pg 的旧 gorse 库只读留存。

## 网络与镜像通道

- 机房 k1/k2/k3 拉 GitHub 不通 → 走 `https://ghfast.top/https://github.com/...`
- 机房 containerd 配了一串国内镜像站（1ms.run / daocloud / xuanyuan 等），
  个别站对非公开路径返 401 → **换镜像版本前先在三台节点 `crictl pull` 预拉**，
  否则 rollout 卡 `ImagePullBackOff`
- node1 有腾讯云 mirror（`mirror.ccs.tencentyun.com`），直拉 Docker Hub 没问题
- node1 拉 GitHub 需走 ghfast.top

## 集群操作位置

- **本地 Mac**：`~/.kube/config` 可直连集群，但**无 creds**，`components/*/install.sh` 跑不了
- **k1 上有仓库副本** `/root/kubernetes/` + 凭据 `/var/lib/k8s-installer/creds/`
  → 组件安装/升级在 k1 上跑，`export KUBECONFIG=/etc/kubernetes/admin.conf`
- 面板站点 online 状态可直读 DB：
  `sqlite3 /home/docker/pangolin/config/db/db.sqlite` → `sites` 表 `online` 列

## 文档

- `components/newt/README.md` —— newt 组件的完整说明（版本线对照表、暴露方式、踩坑）
- `UPGRADE-RECORD-2026-10-24.md` —— Pangolin/newt 升 1.25.3/1.19.0 的完整执行记录
- `HANDOFF-2026-09-22.md` —— 历史快照（含站点拓扑表、newt 站点 siteId 清单）
- `CLOUD-HOSTS-JOIN-ANALYSIS-2026-10-20.md` —— 云主机并入集群的收益/代价实测
