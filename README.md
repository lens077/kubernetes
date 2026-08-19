# kubernetes

单控制面 Kubernetes 集群的**安装器 + 组件库**。从裸机装到可用集群，再把集群之上的组件
（可观测、数据库、缓存、网关路由）按统一契约装上去。

> 本仓库由原 `lens077/kubernetes`（安装器）与 `lens077/cloud-native-deploy`（组件部署资产）
> 于 2026-08-17 合并而来，cloud-native-deploy 的提交历史完整保留（按**旧路径**查询：
> `git log --full-history -- jaeger/manifests/04-deployment.yaml`）。

## 两个入口

```bash
# 1. 裸机 → 可用集群（containerd + Cilium eBPF + OpenEBS LVM + Gateway API）
sudo bash bootstrap/start.sh

# 2. 集群 → 装组件（交互多选；也可只装某一个）
sudo bash bootstrap/start.sh --only 80-components
bash components/grafana/install.sh          # 单个组件，任何有 kubectl+helm 的机器都能跑
```

## 目录

| 目录 | 职责 |
|---|---|
| [`bootstrap/`](bootstrap/) | 集群安装器。11 个阶段（预检 → 系统调优 → 运行时 → kubeadm → Cilium → 存储 → 组件 → 验收），配置集中在 `config.env`，断点续跑 |
| [`components/`](components/) | 集群之上的组件，一目录一组件，统一契约（见下） |
| [`infra/`](infra/) | Cilium / OpenEBS / LoadBalancer 的参考与进阶配置。**安装由 bootstrap 负责，不要直接跑这里的脚本** |
| [`archive/`](archive/) | 历史实验性目录（istio / higress / elastic-stack / longhorn 等），原样保留不维护 |

## 组件契约

每个 `components/<组件>/` 固定这几样，编排器按 `component.env` 发现组件：

```
component.env   元数据：命名空间/依赖/开关/就绪判据（编排器读它）
install.sh      幂等安装，helm 优先；既能被编排器调用，也能单独执行
values.yaml     values 模板，${SC_NAME} 等占位符由 install.sh 渲染
gateway/        Cilium Gateway API 路由（HTTPRoute / TLSRoute / TCPRoute）
examples/       CR 示例、客户端验证程序、被取代的旧方案
README.md       解决方案文档：定位 / 上游最佳实践 / **本集群取舍** / 暴露方式 / 验证 / 踩坑
```

`80-components.sh` 只做四件事：扫描 → 选择（依赖自动补选）→ 拓扑分层后并行调用各 `install.sh`
→ 就绪等待与凭据汇总。**编排器里没有任何 values。**

## 组件一览

| 组件 | 说明 | 暴露 |
|---|---|---|
| [metrics-server](components/metrics-server/) | `kubectl top` / HPA 的指标源 | — |
| [cert-manager](components/cert-manager/) | 自签根 CA + `global-ca-issuer` | — |
| [gateway](components/gateway/) | 共享 L7 入口 + **全仓路由约定** | 80/443 |
| [victoriametrics](components/victoriametrics/) | 指标后端 | `metrics.dev.test` |
| [loki](components/loki/) | 日志后端 | `logs.dev.test` |
| [jaeger](components/jaeger/) | 链路追踪（badger 本地卷） | `jaeger.dev.test` |
| [opentelemetry](components/opentelemetry/) | OTLP 统一入口，pipeline 按后端动态生成 | 集群内 |
| [grafana](components/grafana/) | 观测门面，数据源自动预置 | `grafana.dev.test` |
| [postgres](components/postgres/) | CloudNativePG 算子 | TLS passthrough |
| [dragonflydb](components/dragonflydb/) | Redis 协议缓存 | TCPRoute `:6379` |
| [kafka](components/kafka/) | Strimzi 算子 | LoadBalancer（不走网关） |
| [meilisearch](components/meilisearch/) | 商品即时搜索 | `search.dev.test` |
| [minio](components/minio/) | S3 对象存储（pgsty/silo） | `minio-ui` / `s3` |
| [argo](components/argo/) | ArgoCD (GitOps) | `argocd.dev.test` |
| [external-secrets](components/external-secrets/) | ESO：线上 Vault(`vault.apikv.com`) → k8s Secret（密钥不入 Git/明文） | — |
| [kured](components/kured/) | 维护窗口内自动重启 | — |
| [vpa](components/vpa/) | 只装 recommender：出 `resources` 推荐值，不自动改 Pod | — |
| [newt](components/newt/) | Pangolin 隧道客户端，把集群服务暴露到 `*.apikv.com` | 纯出站 |
| [redis](components/redis/) | 官方 OSS Redis + 原生 TLS（技术验证；缓存主力仍是 dragonflydb） | TCPRoute `:6380` |
| [tempo](components/tempo/) | Grafana Tempo 链路后端（评估期，与 jaeger 并存） | `tempo.dev.test` |
| [seata](components/seata/) | 事务协调器 TC（技术验证；ecommerce 走 Outbox+Saga 不依赖它） | TCPRoute `:8091` |
| [okteto](components/okteto/) | 内环开发 CLI —— **本机组件，不往集群装东西** | — |

域名后缀由 `bootstrap/config.env` 的 `CLUSTER_DOMAIN` 控制（默认 `dev.test`）。

## 集群特性（组件配置的前提）

单控制面 + 2 节点（node2 控制面 / node1 工作节点）、ARM64（Parallels VM，Ubuntu 26.04，
内核 7.0）、**Cilium eBPF 完全替代 kube-proxy**、Gateway API v1.6.1（10 个 CRD 全装，
TCPRoute 可用）、OpenEBS LVM 本地卷（有节点绑定特性）、内存偏紧。

每个组件 README 的「本集群取舍」一节，记录的就是在这些约束下**为什么这么配**。

## 验收

```bash
sudo bash bootstrap/start.sh --verify
```

除了控制面/CNI/存储的常规复检，还包含三个冒烟测试：PVC 读写、LoadBalancer L2 通告、
**可观测链路打点→后端查回**（往 OTel Collector 打真 OTLP 指标/日志/链路，再分别从
VictoriaMetrics / Loki / Jaeger 查回来，只校验实际启用的后端）。

## 许可证

[MIT](LICENSE)
