# k1/k2/k3 重建状态（2026-09-22）

> 接手请先读 [`HANDOFF-2026-09-22.md`](HANDOFF-2026-09-22.md)：那里有主机改名对照、阻塞项和
> 改过的文件清单。本文是恢复过程的逐项记录。

## 当前拓扑

- `k1`：control-plane + workload
- `k2`、`k3`：worker
- Kubernetes：`v1.36.4`
- Cilium：`v1.20.1`，kube-proxy 已移除，三节点 Ready
- OpenEBS：`v4.5.1`，每台节点使用 `80G` loopback 底座创建 `openebs-vg`，默认 StorageClass 为 `openebs-lvm`

## 已验证组件

- CNPG operator、`pg-main`、`ecommerce` Database CR
- Elasticsearch `9.4.5`，使用公开官方镜像 + initContainer 安装 IK 9.4.5；`ik_smart` 中文 analyzer 已实测可用；单节点认证 Secret 为 `elasticsearch-auth`
- Strimzi Kafka `4.3.0` 单节点 KRaft
- Kafka Connect `my-connect-cluster`
- Debezium PostgreSQL source：状态 `Ready`，task `RUNNING`
- Elasticsearch sink：状态 `Ready`，task `RUNNING`
- VictoriaMetrics、VictoriaLogs、VictoriaTraces
- OTel Collector、Vector 三节点 DaemonSet
- vmalert、Alertmanager、alert-bridge、Gatus、Healthchecks
- Grafana `13.2.2`（chart `grafana-community/grafana` `13.2.5`）；数据源按实际后端预置
  VictoriaMetrics（默认）/ VictoriaLogs / VictoriaTraces / Alertmanager
- 共享 Gateway `default/cilium-gateway`：VIP `10.10.31.240`，80 重定向 + 443 终结 TLS

## CDC 边界

CDC source 使用集群内 CNPG：

```text
pg-main-rw.postgresql.svc.cluster.local:5432
```

CNPG 中已创建 `ecommerce_cdc` publication，并为 CDC 用户授予 `REPLICATION` 属性。source/sink 进程链路已验证，但当前 `ecommerce` 库没有业务表，因此尚未声称业务数据恢复或产生真实业务事件。恢复真实业务 dump 后，必须重新验证：

```text
PostgreSQL → Debezium → Kafka → Elasticsearch
```

## 镜像与网络取舍

- 优先使用仓库 `bootstrap/files/certs.d` 中的 registry mirror。
- GitHub/Helm chart 下载优先使用本机 zsh `proxy`，再复制到节点 `/var/cache/k8s-installer/charts/`。
- OpenEBS LVM 镜像在当前 Docker Hub 链路出现 EOF，已使用同版本 Quay 镜像覆盖：
  - `quay.io/openebs/provisioner-localpv:4.5.1`
  - `quay.io/openebs/lvm-driver:1.9.1`
- Elasticsearch 使用公开官方镜像；IK 9.4.5 由 initContainer 从项目固定 URL 下载并校验 SHA-512 后安装到共享插件卷，避免依赖 TCR 凭据。

## 备份边界

`backup/pigsty-node3-20260921/` 中的 PostgreSQL SQL 是角色、授权和默认权限参考，不是业务数据备份。当前仓库没有把权限 SQL 当成业务库恢复输入，也没有伪造业务数据来验证 CDC。

## 已修复

- `bootstrap/lib/common.sh`：空 `.items` 时 `terminal_pod_count()` 不再触发 jq 错误。
- `bootstrap/scripts/70-storage.sh`：OpenEBS Docker Hub 镜像异常时覆盖为 Quay 镜像。
- `components/_lib/env.sh`：chart 已通过代理缓存时不强制刷新不可达 Helm 仓库。
- `components/elasticsearch/manifests/01-statefulset.yaml`：改用公开 Elasticsearch 镜像、`ELASTIC_PASSWORD` Secret 注入，并通过 initContainer 安装 IK 9.4.5。
- `components/kafka/cdc/ecommerce-postgres-source.yaml`：从旧 node3 地址改为 CNPG Service。
- `components/opentelemetry/component.env`：重建后默认使用集群内 VM/VL/VT，不再依赖旧 node3 Pigsty endpoint。
- `components/opentelemetry/values.yaml`：关闭 Tetragon 时不再抓取不存在的 Vector security `:9598` endpoint。
- `components/vector/values.yaml`：容器日志写入集群内 VictoriaLogs，不再指向旧 node3 URL。

### 2026-09-22 下午追加

- **共享 Gateway 此前根本没装**。`default/cilium-gateway` 不存在，而 14 条 HTTPRoute 都
  `parentRef` 到它，`status` 全空——集群没有任何可用的 HTTP 入口，Grafana 等组件只是
  「Pod Running」而已。跑一次 `components/gateway/install.sh` 即补齐（LB-IPAM 两个池和
  `global-ca-issuer` 本来就已就绪，缺的只是这一步）。
  - 连带暴露 `bootstrap/scripts/90-verify.sh` 的盲区：它只在「本轮 `--only` 选了 gateway」时
    才检查该 Gateway 是否存在，所以用 `--only` 装其它组件时这个缺口不会被报出来。
    与交接文档里「已装组件：无」是同一个根因：**验收读的是本轮选择，不是 live 集群**。
- `components/grafana/component.env`：`grafana/grafana` chart 已被上游标记 `deprecated`
  且停在 appVersion `12.3.1`；改用迁移后的 `grafana-community/grafana` `13.2.5`（appVersion `13.2.2`）。
- `components/grafana/values.yaml`：
  - `deploymentStrategy: Recreate`——PVC 是 openebs-lvm 的 RWO 本地卷，默认 RollingUpdate
    会让新旧 Pod 抢同一个卷，升级永远不收敛。
  - 补 `resources.requests`（此前只有 limits，调度器按 0 计算余量）。
  - `image.tag: "{{ .Chart.AppVersion }}"`——只去掉 chart 默认的 `-distroless` 变体
    （distroless 无 shell，`kubectl exec ... sh` 的排查动线会全部失效），不写死版本号。
  - `grafana.ini` 补 `root_url`（网关后面终结 TLS，否则告警/分享链接指向内网域名）、
    `cookie_secure`、关闭 gravatar 与 `check_for_updates`。
- `components/newt/manifests/01-deployment.yaml`：镜像 `1.15.0` → `1.17.0`。
- `components/newt/component.env`：更正「旧 site 已失效」的说法（见文件内注释）。

## 尚未完成

- 真实业务 dump 导入 CNPG 并做数据恢复校验。
- 用真实业务表/变更验证 CDC 消息和 Elasticsearch 文档落库。
- 外部 LAN/newt 到 Cilium Gateway VIP 的访问验收；安装器只验证了 LB-IPAM 编程和 L2 Lease。
- Grafana、Gateway、newt 等非 CDC 基础设施的最终业务验收。

## 应用数据库迁移

项目实际使用 `backend/services/<service>/internal/data/migrations/` 和 `internal/data/seeds/`，没有统一的顶层 `data/` 或 `examples/` 目录。迁移入口是 `backend/tools/dbmigrate`；本次通过 CNPG 临时 LoadBalancer + SSH 隧道执行了：

```text
go run ./tools/dbmigrate -svc all up
go run ./tools/dbmigrate -svc all seed
```

已执行的服务包括 `address`、`behavior`、`cart`、`inventory`、`merchant`、`order`、`payment`、`product`、`user`。迁移与种子命令成功完成；`ecommerce` 当前包含各服务 schema 和迁移对象。未把权限 SQL 当成业务数据导入。

## 当前缺失或待补基础设施

- **Grafana**：已部署 `13.2.2`（2026-09-22 下午）。上面那条「未部署」是本文与第 14 节
  自相矛盾的旧描述，已更正。
- **Gateway / 外部入口**：共享 Gateway 已补装，7 条对外 hostname 经 VIP `10.10.31.240:443`
  实测返回 200/302。仍未验收的是**公网侧**（newt → VIP）这一段。
- **newt/Pangolin**：Pangolin 已升到 `1.23.0`、gerbil `1.5.2`；node0/node2 的 newt 已升到
  `1.17.0` 且隧道在线。集群侧 newt 仍未部署——需要先在面板新建 site 拿凭据。
- **业务缓存**：Dragonfly 当前未启用；需要 ecommerce 登录、Session、限流或缓存链路时必须部署并同步 Secret/CA。
- **OpenFGA**：当前未启用；授权业务接线前需要先完成 CNPG 独立库和 OpenFGA model/tuple 恢复。
- **OpenBao/ESO**：当前未作为恢复前置启用；生产凭据治理前必须完成 unseal、SecretStore 和 Secret 同步验收。
- **真实业务数据**：当前只有迁移建立的空表/种子，尚无旧业务 dump 恢复证据。
