# Harbor —— OCI 镜像仓库

## 1. 定位

Harbor 保存 OCI 镜像和制品，并通过 Trivy 执行漏洞扫描。组件使用官方 Helm chart，部署到
`harbor` 命名空间，通过共享 Cilium Gateway 暴露为 `https://harbor.dev.test`。

源目录 `/Users/sumery/lens077/cloud-native-deploy/harbor` 与本仓原有 `archive/harbor`
内容一致。旧脚本已移至 `examples/legacy/`，仅用于追溯，不得直接执行。

## 2. 部署取舍

参考 [Harbor Helm chart](https://github.com/goharbor/harbor-helm)、
[Harbor 安装与配置文档](https://goharbor.io/docs/latest/install-config/) 和
[Harbor 生产最佳实践](https://goharbor.io/docs/latest/install-config/harbor-ha-helm/)。

| 旧脚本 | 正式组件 | 原因 |
|---|---|---|
| Ingress、NodePort、LoadBalancer 三套脚本 | chart 原生 Gateway API `HTTPRoute` | 对外入口统一接入 `default/cilium-gateway`。 |
| `Harbor12345` 等明文默认值 | K8s Secret + 节点本地随机凭据 | 仓库不保存密码，重复执行不轮换现有凭据。 |
| `helm uninstall` 后重新安装 | `helm upgrade --install` | 避免误删 release 和中断服务。 |
| 外部 PostgreSQL/Redis 占位地址 | chart 内置 PostgreSQL/Valkey | 当前两节点环境没有专用 Harbor 数据库；先使用可持久化的单副本拓扑。 |
| TLS 在每套暴露方式中单独生成 | 共享 Gateway 终结 TLS | 复用 `*.dev.test` 证书，Harbor Pod 之间保持集群内 HTTP。 |
| 手工修改 Docker/containerd 配置 | 不修改节点运行时 | 客户端只需信任共享 Gateway 的根证书。 |

## 3. 数据与凭据

registry、jobservice、PostgreSQL、Valkey 和 Trivy 分别使用 RWO PVC。PVC 带 Helm keep
策略；删除 release 时不会自动删除业务制品卷。当前配置是单副本，不提供跨节点高可用。

安装脚本使用 `get_cred` 生成管理员、数据库、registry 和加密密钥。管理员密码通过
`harbor-admin` Secret 交给 chart，仓库中不保存密码。初始管理员密码保存在执行节点的
`/var/lib/k8s-installer/creds/harbor-admin`。管理员在 Portal 修改密码后，以 Portal 中的值为准。

不要把该密码加入 `config.env`、values、命令历史或 CI 日志。

## 4. 安装

前置条件：

- chart 的 Harbor `appVersion` 必须支持集群中所有节点的 CPU 架构。官方 ARM64 release
  从 `v2.16.0` 开始；`v2.15.x` 只有 amd64 镜像。
- `default/cilium-gateway` 已存在，并包含 `https` listener。
- Gateway 证书覆盖 `harbor.dev.test`。
- 默认配置中的 StorageClass 支持动态创建 RWO PVC。

执行：

```bash
bash components/harbor/install.sh
kubectl -n harbor rollout status deployment/harbor-core --timeout=15m
kubectl -n harbor get pods,pvc,httproute
```

安装脚本先读取 chart 的 `appVersion` 和节点架构。ARM64 集群使用低于 `v2.16.0` 的 Harbor
时，脚本在创建 namespace、Secret、Helm release 或路由之前退出。不要通过 QEMU 或来源不明的
第三方镜像绕过闸门。

## 5. 验证

```bash
curl --resolve harbor.dev.test:443:192.168.3.100 \
  --cacert /path/to/global-root-ca.crt \
  https://harbor.dev.test/api/v2.0/health

curl --resolve harbor.dev.test:443:192.168.3.100 \
  --cacert /path/to/global-root-ca.crt \
  https://harbor.dev.test/v2/
```

第一个请求应返回 `healthy`。第二个请求在未认证时应返回 `401`，并包含 Harbor token
服务的 `WWW-Authenticate` 响应头；该结果表示 registry 鉴权链路已启用。

## 6. 限制与升级

- **ARM64 暂停安装**：2026-08-18 在两台 ARM64 节点实测官方 `v2.15.2`，所有已拉取
  Pod 均因 amd64 可执行文件报 `exec format error`。失败 release 和路由已清理，五个 PVC、
  管理员 Secret、加密 Secret 与节点凭据已保留。跟踪官方
  [#23558](https://github.com/goharbor/harbor/issues/23558) 和
  [#23674](https://github.com/goharbor/harbor/issues/23674)。
- 当前 PostgreSQL、Valkey、registry 和 Trivy 都是单副本。节点或本地卷故障会中断服务。
- Gateway 到 Harbor Service 的流量未启用内部 TLS。该方案只适用于受信任的集群网络。
- Trivy 首次启动需要下载漏洞数据库。上游 registry 不可达时，扫描器可能较晚 Ready。
- 升级前先阅读 Harbor 和 `harbor-helm` 的迁移说明，并备份 registry 数据和 PostgreSQL。
- 不要直接提高有 RWO PVC 的工作负载副本数。生产高可用需要共享对象存储、外部 PostgreSQL、
  外部 Valkey/Redis，以及可跨节点运行的多副本拓扑。
