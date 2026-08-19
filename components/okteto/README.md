# okteto —— 在集群里改代码（内环开发，本机 CLI）

## 1. 定位

把你正在改的那个服务，**以集群里 Pod 的身份运行**，同时保留本地编辑器 + 秒级反馈。
代码在你机器上，进程在集群里，中间是双向文件同步。

```
你的编辑器 ──保存──> syncthing 同步 ──> 集群 Pod（继承 env / Secret / DNS / 身份）
                                            └─ 你在里面手动 go run / npm dev
```

**这是本仓唯一的「本机 CLI 组件」**：集群里没有常驻工作负载，
`install.sh` 只做客户端自检与前置条件校验，不部署任何东西。
CLI 是开源的，对任意 k8s 集群可用，**不需要 Okteto 平台、不需要 license**。

判据很清楚——只有当你要验的东西**只在集群里才成立**时它才有价值：

| 要验的东西 | 本地跑能发现吗 |
|---|---|
| 配置分环境（本地读 A 套地址、集群读 B 套） | ❌ |
| Secret 挂载权限（`0400` + `runAsUser` 能不能读） | ❌ 本地是你自己的 uid |
| `securityContext` / PSA 策略下能不能起来 | ❌ 本地没有这一层 |
| 集群 DNS、Service 解析、NetworkPolicy | ❌ |
| 服务注册进 Consul 后网关能否路由到 | ⚠️ 本地注册的是你机器的 IP |

反过来：改业务逻辑、调接口、写单测——本地 `go run` / `npm dev` 永远更快，别用它。

## 2. 上游最佳实践

来源：[Okteto Manifest 文档](https://www.okteto.com/docs/reference/okteto-manifest/)、
[File Synchronization](https://www.okteto.com/docs/reference/file-synchronization/)、
[Okteto + ArgoCD 官方博客](https://www.okteto.com/blog/using-argocd-with-okteto-for-a-unified-kubernetes-development-experience/)（2026-08 复核，CLI 3.22.0）

- 开源 CLI 能力边界：`okteto up`/`down`/`build` 不需要平台；
  `okteto deploy`/`test` 需要商业平台。**只要内环开发就不必碰平台**。
- `okteto up` 对集群做的事（3.22.0 源码实测仍如此）：
  1. 原 Deployment **缩到 0**（原副本数存进注解 `dev.okteto.com/replicas`）；
  2. 克隆出 `<name>-okteto`（dev 镜像 + sleep + 注入 init 容器 + syncthing + SSH）；
  3. 建 PVC `<name>-okteto` 放依赖缓存（`persistentVolume.enabled` 时）。
  `okteto down` 恢复原状；**PVC 默认保留**（下次 up 复用缓存），要清得手动删。
- 新 Pod **继承原 Deployment 的其余部分**——env、Secret/ConfigMap 挂载、ServiceAccount、
  securityContext、imagePullSecrets、DNS——这正是它的全部价值来源。
- 同步与端口转发**全经 apiserver 的 port-forward 隧道**（syncthing 的 22000/8384 映射到
  本地随机端口），集群防火墙零开口。
- `OKTETO_CLI_IMAGE` 是当前的镜像覆写变量（取代了旧的 `OKTETO_BIN`/`OKTETO_REMOTE_CLI_IMAGE`）。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 组件即工作负载 | **`EST_MEM_MI=0`、无 `CONFIG_VAR`、无 `READY_CHECK`** | 它不装东西，没有可开关、可等待的对象。编排器菜单里默认不选。 |
| `persistentVolume` 用默认 SC | 显式指 `openebs-lvm` | 本地卷有**节点绑定**特性：PVC 会把 dev 容器钉死在首次调度的节点（见踩坑）。 |
| `okteto up` 随手就跑 | **先关 ArgoCD 自动同步** | 集群装了 ArgoCD，缩0 + 多出 `-okteto` 在 GitOps 眼里是漂移。`install.sh` 检测到 argocd 命名空间会主动告警。 |
| 直接跑成 root 省事 | 保留 `runAsUser: 1000`，只把 `runAsNonRoot` 设 false | 保留原 uid 正是为了让「Secret 读不到」「目录写不进」当场暴露；跑成 root 等于把要验的东西关掉。 |
| 首次直接 up | 挂代理 | 首次 `okteto up` 要从 GitHub 下载 syncthing 二进制（实测 10.68 MiB），大陆直连会卡死。 |

## 4. 与 GitOps 共存（最容易吃亏的一条）

上面那两处改动（原 Deployment 副本数变 0、多出 `-okteto` 资源）在 ArgoCD 眼里就是漂移：

- `selfHeal: true` → 默认几秒内把副本数改回去，**你的开发容器被顶掉**；
- `prune: true` → 直接删掉 `-okteto` 资源。

表现是**敲着敲着 shell 断了**，极难往 GitOps 身上想。三种处理，按推荐度：

**① 临时关自动同步（推荐）** —— AppProject 加一条恒定生效的 deny sync window：

```yaml
- kind: deny
  schedule: "* * * * *"     # 每分钟触发
  duration: "24h"           # 持续 24h ⇒ 恒定生效
  applications: ["*"]
  manualSync: true          # 仍允许显式手工 sync
```

**不要写进 Git** ——「临时暂停」进了版本库就变成永久状态。写个脚本按需 patch；
ecommerce 仓的 `scripts/argocd-devwindow.sh` 是可抄的实现（off/on/status 三态、幂等、
只移除自己那条不动别人配的窗口）。

**② `ignoreDifferences`** 忽略 `spec.replicas` 与容器 image：不用手工开关，
代价是真实漂移也不管了。**③ 什么都不做**：只在 auto-sync 本来就关着时可行。

> **比"忘了关"更糟的是"忘了恢复"**：GitOps 静默失效，之后所有部署都不生效，
> 而且没有任何报错。把恢复动作写进收工清单。

## 5. 验证

```bash
bash components/okteto/install.sh    # CLI 版本 / SC / ArgoCD 告警
```

真验证（完整 up → 在集群 Pod 里读到本机文件 → down 恢复）：

```bash
kubectl create ns okteto-probe
kubectl -n okteto-probe create deployment hello --image=curlimages/curl:latest -- sleep infinity
kubectl -n okteto-probe rollout status deploy/hello

mkdir -p /tmp/okteto-probe && cd /tmp/okteto-probe
echo "probe-content-$(date +%s)" > probe.txt
cat > okteto.yaml <<'YAML'
dev:
  hello:
    image: curlimages/curl:latest
    command: ["sh"]
    workdir: /workspace
    sync: [".:/workspace"]
    persistentVolume: {enabled: false}
    securityContext: {runAsUser: 0, runAsGroup: 0, fsGroup: 0, runAsNonRoot: false}
YAML

okteto context use "$(kubectl config current-context)" --namespace okteto-probe
okteto up hello -- sh -c 'echo "IN_POD: $(hostname)"; cat /workspace/probe.txt'
# 期望: 打印 hello-okteto-xxx 的主机名 + 本机 probe.txt 的内容

kubectl -n okteto-probe get deploy      # hello 0/0, hello-okteto 1/1  ← 缩0+克隆
okteto down hello
kubectl -n okteto-probe get deploy      # hello 1/1, -okteto 已消失   ← 干净恢复
kubectl delete ns okteto-probe
```

> **实测结论（2026-08-19，CLI 3.22.0 + K8s 1.36.3 ARM64）**：首次运行自动下载
> syncthing v2.1.2（macos-arm64，10.68 MiB，需代理）；文件同步后命令在
> `hello-okteto-556bc4d86-p6hjn` 内执行并读到本机 `probe.txt` 内容；
> 集群侧确认 `hello` 0/0 + `hello-okteto` 1/1；`okteto down` 后 `hello` 恢复 1/1。
> 「缩0 + `-okteto` 克隆」机制与官方文档一致，未随版本变化。

## 6. 踩坑

| 症状 | 原因 | 处理 |
|---|---|---|
| `okteto up` 找不到目标 | manifest 的 dev key ≠ 工作负载名 | `kubectl get deploy -n <ns>` 逐字核对 |
| shell 无故断开 | GitOps 把漂移同步回去了 | 见 §4 |
| 卡在 `Installing dependencies...` | 首次要从 GitHub 下 syncthing | 挂代理（`PROXY_URL`） |
| 卡 `Init:0/2` 很久 | init 镜像来自 ghcr.io | `OKTETO_CLI_IMAGE` 指向私有仓副本（如 CCR） |
| `container's runAsUser breaks non-root policy` | okteto init 容器硬编码 root，与 `runAsNonRoot: true` 冲突 | manifest 里设 `runAsNonRoot: false` 但**保留 `runAsUser: 1000`** |
| Pod Pending，`didn't match PersistentVolume's node affinity` | openebs-lvm 本地卷把 PVC 钉死在首次调度的节点 | `kubectl delete pvc <name>-okteto` 重新分配 |
| 编译时 `x509: certificate signed by unknown authority` | 工作负载把 CA 挂到 `/etc/ssl/certs`，**整个目录被替换** | dev 容器用 `SSL_CERT_DIR=/usr/share/ca-certificates/mozilla` 绕过；根治是改用 `subPath` 挂单文件（本仓 helm db-ca-cert 同款问题） |
| 文件同步不动了 | syncthing 状态坏了 | `okteto up <svc> --reset` |
| `ContainerCreating` + **零事件 + 无 IP** | 不是 okteto 的问题，节点起不了新 Pod | 换节点起个 probe Pod 验证；是节点故障就 `kubectl cordon` |

## 7. 什么时候该选别的工具

| 工具 | 思路 | 相对 Okteto |
|---|---|---|
| **mirrord** | 进程留本地，"借"集群 Pod 的网络/env/挂载 | 不改工作负载 ⇒ **不和 GitOps 打架**；但复现不了 uid、架构、文件权限 |
| **Telepresence** | 拦截流量到本地进程 | 偏"让集群流量打到我本机" |
| **DevSpace / Skaffold** | 快速构建-推送-部署循环 | 仍过镜像构建，更慢但更贴近真实交付路径 |
| **不用任何工具** | 本地跑 + 端口转发依赖 | 依赖能从本地直连时最简单，**优先考虑** |

判据：**你要验的问题是否依赖"容器内的身份"**。
是（uid、Secret 权限、securityContext、集群 DNS）→ Okteto；
否（只是想让流量过来 / 只是想连集群里的数据库）→ mirrord 或端口转发。

## 8. 收工清单

```bash
okteto down <svc>                     # 恢复工作负载
<恢复 GitOps 自动同步>                # 见 §4，别忘
kubectl get deploy -n <ns>            # 核对副本数已恢复
kubectl delete pvc <svc>-okteto       # 可选：清缓存卷（下次 up 要重新下依赖）
```
