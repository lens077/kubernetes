# Cloud Native Deploy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

面向 Kubernetes 的云原生部署清单、Helm 配置、运维脚本和可观测性实践集合。主要文档语言为简体中文；目录中的上游项目名称、Kubernetes 资源字段与命令保持其原始英文写法。

本仓库不是一个“一键安装所有组件”的产品。每个目录都是独立的部署实验、可复用清单或某个集群的运维记录，使用前必须阅读该目录下的 README、脚本和 values 文件，并按自己的集群、网络、存储与安全策略调整。

> [!WARNING]
> 目录中的脚本可能创建、更新或删除集群资源。请先在测试环境审阅并执行；不要把密码、Token、私钥、kubeconfig 或真实域名证书提交到仓库。

## 目录

- [当前部署基线](#当前部署基线)
- [仓库内容](#仓库内容)
- [使用前准备](#使用前准备)
- [推荐部署顺序](#推荐部署顺序)
- [Jaeger 部署入口](#jaeger-部署入口)
- [配置与凭据](#配置与凭据)
- [文档与开源协作](#文档与开源协作)
- [许可证](#许可证)

## 当前部署基线

下表只描述已经在仓库中明确记录、且近期维护过的部署关系；它不是某个集群的完整资源清单，也不表示其余目录都已部署到生产环境。部署进度、已知风险和待验证项以 [TODO.md](TODO.md) 为准。

| 能力 | 当前基线 | 仓库入口 |
| --- | --- | --- |
| Gateway API | 路由使用 `default` 命名空间中的 `cilium-gateway`。HTTPRoute 必须显式写明 `namespace: default` 与对应的 `sectionName`。 | [gateway/](gateway/)、[elastic-stack/examples/](elastic-stack/examples/)、[jaeger/gateway/](jaeger/gateway/) |
| 链路追踪 | Jaeger v2 运行在 `observability` 命名空间，使用原生 Kubernetes 清单和 `badger` 本地 PVC；不再通过 Helm 或 Elasticsearch 存储 trace。 | [jaeger/README.md](jaeger/README.md)、[jaeger/manifests/](jaeger/manifests/) |
| OpenTelemetry | Collector 向 `jaeger.observability.svc:4317` 导出 trace；存储后端变化不要求修改 Collector 的服务发现地址。 | [opentelemetry/server/](opentelemetry/server/)、[Collector 示例配置](opentelemetry/server/helm/collector/examples/configs/jaeger-loki-vm.yml) |
| Elasticsearch 与 Kibana | Elasticsearch 仍保留业务索引与 Kibana，但不再承担 Jaeger 存储。现有路由使用 Cilium Gateway 的 HTTP listener；TLS 方案需要单独规划。 | [elastic-stack/](elastic-stack/) |
| 本地卷 | Jaeger 的 `jaeger-badger` 使用 `openebs-lvmpv` 本地卷，具备节点绑定特性。 | [openebs/](openebs/)、[Jaeger 运维说明](jaeger/manifests/README.md) |
| 资源调优 | VPA 的安装、示例和 Argo CD Application 清单位于 `vpa/`。 | [vpa/](vpa/) |

## 仓库内容

下面按职责索引现有顶层目录。目录存在表示已收录相应部署资产，不代表全部组件同时启用，也不表示所有方案可以混用。

### 集群基础、网络与存储

| 目录 | 内容 |
| --- | --- |
| `tool/` | Helm、Krew、Kustomize、Metrics Server、Kubernetes Dashboard、OLM 等客户端与集群工具。 |
| `cni/` | Cilium、Flannel 和 Kubernetes CNI 配置。CNI 方案应按集群选择，不能将多个主 CNI 叠加部署。 |
| `gateway/` | Gateway API CRD、Ingress NGINX、HAProxy、Higress 等入口与网关实验。 |
| `loadbalancer/` | OpenELB、PureLB 等 LoadBalancer 实现。 |
| `openebs/`、`longhorn/`、`csi/`、`juicefs/` | 本地卷、块存储、NFS CSI、分布式文件系统等存储方案。 |
| `cert-manager/` | ACME、私有 CA、Gateway TLS 等证书签发与路由配置。 |

### 交付、平台与服务治理

| 目录 | 内容 |
| --- | --- |
| `argo/`、`kargo/` | Argo CD、Argo 相关 CLI、GitOps 与持续交付实验。 |
| `jenkins/`、`gitlab/` | Jenkins、GitLab 相关部署资产。 |
| `harbor/` | Harbor 镜像仓库的 Helm、NodePort 与自定义安装配置。 |
| `consul/`、`istio/`、`casdoor/` | 服务发现、服务网格与身份认证相关部署。 |
| `kruise-rollout/` | 渐进式发布与工作负载 rollout 示例。 |

### 可观测性与运维

| 目录 | 内容 |
| --- | --- |
| `kube-prometheus/`、`prometheus-operator/` | Prometheus 监控栈与 Operator 部署。 |
| `grafana/` | Grafana 安装、路由、仪表盘与电商概览示例。 |
| `loki/`、`loki-stack/`、`fluent-bit/` | 日志采集、存储与查询。 |
| `opentelemetry/`、`jaeger/`、`tempo/` | OpenTelemetry Collector、Jaeger、Tempo 与 trace 示例。 |
| `victoriametrics/`、`greptime/` | 时序指标存储与查询方案。 |
| `elastic-stack/` | Elasticsearch、Kibana 以及 Gateway API 路由。 |
| `vpa/` | Vertical Pod Autoscaler 安装、示例和应用纳管。 |

### 数据、中间件与应用依赖

| 目录 | 内容 |
| --- | --- |
| `postgres/`、`citus/`、`cockroachdb/` | PostgreSQL、高可用 PostgreSQL、Citus、CockroachDB。 |
| `redis/`、`dragonflydb/` | Redis 与 DragonflyDB。 |
| `kafka/` | Kafka、Strimzi 等消息流平台配置。 |
| `minio/` | MinIO 的 Kubernetes 与 Docker Compose 示例、桶策略说明。 |
| `seata/` | 分布式事务中间件部署。 |

## 使用前准备

请根据目标组件准备对应工具；并非所有目录都需要以下全部工具。

- 可访问目标集群的 `kubectl`，并且当前上下文和命名空间正确。
- 对 Helm 部署，准备与目标 Chart 兼容的 `helm` 版本及必要的仓库访问权限。
- 对本地 Docker 示例，准备 Docker Engine 与 Docker Compose。
- 对 Gateway API 路由，先部署 Gateway API CRD、Gateway Controller，并确认目标 Gateway、listener 与跨命名空间路由策略。
- 对存储相关组件，先确认 StorageClass、节点拓扑、访问模式与数据备份方案。
- 对需认证的组件，在本地环境或受管密钥系统中提供凭据，不要把真实值写入 YAML、Shell 脚本、Compose 文件或文档。

## 推荐部署顺序

组件之间并非全部互相依赖，但下面的顺序能减少多数基础设施依赖错误：

1. 准备 Kubernetes 集群及 `kubectl`、Helm 等工具。
2. 在 `cni/` 中选择并部署一种主网络方案；需要对外暴露服务时，再选择 `loadbalancer/` 中兼容的方案。
3. 根据工作负载需求选择一个存储方案，例如 `openebs/`、`longhorn/`、`csi/` 或 `juicefs/`。
4. 部署 Gateway API/网关与 `cert-manager/`；确认 Gateway 名称、命名空间、listener 和证书链后再应用 HTTPRoute。
5. 按需部署 Harbor、Consul、Istio、数据库和消息中间件。
6. 部署可观测性基础设施：指标、日志、Collector 与 trace 后端；最后接入业务工作负载。
7. 使用 `vpa/`、Grafana 仪表盘和各组件自身指标持续观察资源与容量。

对于每一步，请优先采用组件目录中的 README 和脚本作为入口。仓库同时保留 Helm、原生 YAML、Operator 与 Compose 等多种实现；它们通常是可选方案，而不是同一组件的连续安装步骤。

## Jaeger 部署入口

Jaeger 是当前明确维护的 trace 后端，部署方式与旧版 Helm 文档不同：

- 使用 [原生清单](jaeger/manifests/) 创建 ServiceAccount、PVC、ConfigMap、Deployment 与 Service。
- 数据写入 `badger`，并由 `ttl.spans: 168h` 自动清理；不会再连接 Elasticsearch。
- Jaeger Service 仍为 `jaeger.observability.svc`，Collector 和已有 HTTPRoute 不需要因后端迁移而修改。
- PVC 是节点本地卷；节点故障时 Pod 不能自动迁移，这是当前为持久化 trace 选择的取舍。
- 修改 `jaeger-config` ConfigMap 后，必须手动滚动重启 Deployment。

开始前请完整阅读 [Jaeger 根说明](jaeger/README.md) 和 [部署与运维说明](jaeger/manifests/README.md)。`install.sh` 会卸载同名 Helm release 并应用资源，只应在确认影响范围后执行。

## 配置与凭据

- 用环境变量、密钥管理服务或 Kubernetes Secret 注入密码、Token、私钥和证书；仓库只保留变量名、示例值或脱敏占位符。
- 提交前检查 Shell 历史、Compose 环境变量、values 文件与导出的 manifest，防止凭据意外进入 Git。
- 不要直接复用过期的 Gateway、TLS、Helm 或路由示例。优先检查它所引用的资源是否仍存在，并核对命名空间、listener、hostname 与 `allowedRoutes`。
- `TODO.md` 记录近期部署事实、验证结论、已知风险和待办；修改运行方式时请同步更新它。

## 文档与开源协作

- [贡献指南](CONTRIBUTING.md)：开发环境、变更范围、提交与文档要求。
- [安全策略](SECURITY.md)：安全漏洞和凭据泄露的报告方式。
- [TODO.md](TODO.md)：近期部署变更、风险与待办的事实来源。
- 每个组件目录的 README：组件级前提条件、部署说明与参考资料。

欢迎提交可复现的修复、部署说明、兼容性记录和示例改进。请避免把某个私有集群的密码、IP、令牌或临时状态当作通用配置提交。

## 许可证

本仓库以 [MIT License](LICENSE) 发布。第三方 Chart、镜像、代码片段和文档仍受各自上游许可证约束；使用或再分发前请分别核查。
