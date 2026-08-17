# Okteto — 在集群里改代码（内环开发）

把你正在改的那个服务，**以集群里 Pod 的身份运行**，同时保留本地编辑器 + 秒级反馈。
代码在你机器上，进程在集群里，中间是双向文件同步。

```
你的编辑器 ──保存──> syncthing 同步 ──> 集群 Pod（继承 env / Secret / DNS / 身份）
                                            └─ 你在里面手动 go run / npm dev
```

CLI 是开源的，**对任意 k8s 集群可用，不需要装 Okteto 平台、不需要 license**。

---

## 1. 它解决的是"外环太慢"，不是"本地不好用"

| 环 | 一次循环 | 谁快 |
|---|---|---|
| **内环**（本地跑） | 改 → 编译 → 跑 → 看 | 本地原生最快，几秒 |
| **外环**（进集群） | 改 → 构建镜像 → 推仓库 → 改 tag → GitOps 同步 → Pod 重启 | 几分钟到几十分钟 |

Okteto 把**外环的验证能力**塞进**内环的速度**里。

**所以判据很清楚**：只有当你要验的东西**只在集群里才成立**时，它才有价值：

| 要验的东西 | 本地跑能发现吗 |
|---|---|
| 配置分环境（本地用 A 套地址、集群用 B 套） | ❌ 本地读的就是 A |
| Secret 挂载权限（`0400` + `runAsUser` 能不能读） | ❌ 本地是你自己的 uid，文件随便读 |
| `securityContext` / PSA 策略下能不能起来 | ❌ 本地没有这一层 |
| 集群 DNS、Service 解析、NetworkPolicy | ❌ 本地走的是另一套网络 |
| 服务注册进注册中心后网关能否路由到 | ⚠️ 本地注册的是你机器的 IP |

**反过来**：改业务逻辑、调接口、写单测 —— 本地 `go run` / `npm dev` 永远更快，别用它。

---

## 2. 安装与接入

```bash
brew install okteto            # 或 https://github.com/okteto/okteto/releases
okteto version                 # 本文基于 3.22.0

# 指向你的集群（就是 kubeconfig 里的 context 名）
okteto context use <kube-context> --namespace <namespace>
okteto context show
```

**能力边界**（CLI 的 `--help` 里每个命令都标了）：

| 命令 | 需要平台吗 | 用途 |
|---|---|---|
| `okteto up` / `down` | ❌ 开源即可 | **内环开发，本文的主角** |
| `okteto deploy` | ✅ 需要平台 | 部署整套环境 |
| `okteto test` | ✅ 需要平台 | Test Containers |
| `okteto build` | ❌ | 构建镜像 |

自托管平台是商业产品（免费档有座位与期限限制），**只想要内环开发就不必碰它**。

---

## 3. 核心概念

**Development Container**：集群里跑你的代码的那个容器。它用一个**带工具链的镜像**
（如 `golang`、`node`）而不是你的生产镜像——因为你要在里面编译、调试。

**Okteto Manifest**（`okteto.yaml`）：声明每个可开发的服务。`dev:` 下的 key
**必须与集群里的工作负载名逐字一致**，否则找不到目标。

**文件同步**：syncthing 双向同步，本地保存毫秒级到达容器。同步的**不是**镜像层，
所以容器里没有你的构建产物，一切在容器里现编。

**Okteto Context**：集群 + namespace 的组合。所有命令都在当前 context 上执行。

---

## 4. 第一次使用

```yaml
# okteto.yaml
dev:
  my-service:              # ← 必须等于 kubectl get deploy 里的名字
    image: golang:1.26.5   # 带工具链的镜像
    command: bash
    workdir: /workspace
    sync:
      - .:/workspace       # 本地目录 : 容器内路径
    persistentVolume:
      enabled: true        # 持久化依赖缓存，否则每次都重新下载
    forward:
      - 8080:8080
```

```bash
okteto up my-service         # 首次要拉镜像 + 建 PVC，几分钟；之后秒级
# 你人已经在集群的 Pod 里了
my-service:/workspace$ go run ./cmd/server

# 另开终端改代码 → 保存 → 回到 Pod 里 Ctrl+C 重跑
okteto down my-service       # 恢复原状
```

非交互执行一条命令（写脚本 / 冒烟检查用）：

```bash
okteto up my-service -- bash -c 'go build ./... && echo OK'
```

---

## 5. 它到底改了集群什么（必须知道）

`okteto up` **不是原地改你的 Deployment**，而是：

1. 新建 `<name>-okteto` Deployment —— 镜像换成 dev 镜像，command 换成 sleep；
2. **把原 Deployment 缩到 0 副本**；
3. 建一个 PVC `<name>-okteto` 放依赖缓存；
4. 注入两个 init 容器（`okteto-bin` / `okteto-init-volume`）准备二进制与卷；
5. 起 syncthing 建立同步。

`okteto down` 删掉 `-okteto` 那套、把原 Deployment 恢复副本数。
**PVC 默认保留**（下次 up 直接复用缓存），要彻底清理得手动删。

新 Pod **继承原 Deployment 的其余部分**——环境变量、Secret/ConfigMap 挂载、
ServiceAccount、securityContext、imagePullSecrets、DNS——这正是它的全部价值来源。

---

## 6. 与 GitOps（ArgoCD/Flux）共存

**这是最容易吃亏的一条。** 上一节那两处改动（原 Deployment 副本数变 0、多出一个
`-okteto` 资源）在 GitOps 眼里就是**漂移**：

- `selfHeal: true` → 把副本数改回去，你的开发容器被顶掉；
- `prune: true` → 直接删掉 `-okteto` 资源。

表现是**敲着敲着 shell 断了**，极难往 GitOps 身上想。

三种处理，按推荐度排：

**① 临时关自动同步（推荐）** —— 用 ArgoCD 的 AppProject sync window：

```yaml
# AppProject spec.syncWindows 追加一条「永远激活」的 deny 窗口
- kind: deny
  schedule: "* * * * *"     # 每分钟触发
  duration: "24h"           # 持续 24h ⇒ 恒定生效
  applications: ["*"]
  manualSync: true          # 仍允许显式手工 sync
```

不要写进 Git —— "临时暂停"进了版本库就变成永久状态。写个脚本按需 patch，
开发结束移除（本仓 `ecommerce/scripts/argocd-devwindow.sh` 是一个可抄的实现：
off/on/status 三态、幂等、只移除自己那条不动别人配的窗口）。

**② `ignoreDifferences`** —— 让 Argo 忽略 `spec.replicas` 与容器 image。
好处是不用手工开关；代价是真实的漂移也不管了。

**③ 什么都不做** —— 只在 auto-sync 本来就关着时可行，且要记得它随时可能被打开。

> **比"忘了关"更糟的是"忘了恢复"**：GitOps 静默失效，之后所有部署都不生效，
> 而且没有任何报错。把恢复动作写进你的收工清单。

---

## 7. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `okteto up` 报找不到目标 | manifest 的 dev key ≠ 工作负载名 | `kubectl get deploy -n <ns>` 核对 |
| shell 无故断开 | GitOps 把漂移同步回去了 | 见 §6 |
| 卡 `Init:0/2` 很久 | init 镜像来自 `ghcr.io`，某些网络环境很慢 | 用 `OKTETO_CLI_IMAGE` 指向你的私有仓副本 |
| `container's runAsUser breaks non-root policy` | okteto 的 init 容器硬编码 `runAsUser: 0`，与工作负载的 `runAsNonRoot: true` 冲突 | 见下 |
| Pod 一直 Pending，`didn't match PersistentVolume's node affinity` | 本地卷（openebs-lvm/local-path）把 PVC 钉死在首次调度的节点 | `kubectl delete pvc <name>-okteto` 重新分配 |
| 编译时 `x509: certificate signed by unknown authority` | 工作负载把某个 CA 挂到 `/etc/ssl/certs`，**整个目录被替换**，系统 CA 全没了 | 见下 |
| 文件同步不动了 | syncthing 状态坏了 | `okteto up <svc> --reset` |
| 卡 `ContainerCreating`、**零事件、无 IP** | **不是 okteto 的问题**，节点起不了新 Pod | 见下 |

### runAsNonRoot 冲突

okteto 的两个 init 容器需要 root（拷贝二进制、chown 卷），而生产工作负载通常带
`runAsNonRoot: true`，kubelet 会直接拒绝。在 manifest 里放行：

```yaml
    securityContext:
      runAsUser: 1000        # ← 保住「你的代码仍以非 root 跑」这个关键性质
      runAsGroup: 1000
      fsGroup: 1000
      runAsNonRoot: false    # ← 只为放行 okteto 的 init 插件
```

**别偷懒直接跑成 root** —— 保留原 uid 正是为了让"Secret 读不到""目录写不进去"
这类问题当场暴露；改成 root 等于把要验的东西关掉了。

### 系统 CA 被挂载遮蔽

如果工作负载把某个自签 CA 挂到 `/etc/ssl/certs`，**这会替换整个目录**：

```bash
$ ls /etc/ssl/certs
my_internal_ca.crt          # ← 只剩这一个，发行版自带的 CA 包全不可见
```

于是容器内任何公网 HTTPS 都验不过证书（拉依赖、调第三方 API）。dev 容器可以绕：

```yaml
environment:
  - SSL_CERT_DIR=/usr/share/ca-certificates/mozilla   # Debian 系原始证书还在这里
```

但**这同时是一个生产侧信号**：你的服务如果有出站公网 HTTPS 调用，线上大概率也是坏的。
根治方式是挂成 `/usr/local/share/ca-certificates/xxx.crt` 后跑 `update-ca-certificates`，
或用 `subPath` 只挂单个文件而不是覆盖整个目录。

### 判别"是 okteto 还是集群"

`ContainerCreating` + **零事件** + **无 IP** 不是镜像问题（镜像问题会有
`Pulling`/`Failed` 事件），是节点侧沙箱创建卡住。一条命令定位：

```bash
# 用一个集群里已有的镜像，钉到另一个节点起 Pod
kubectl run probe -n <ns> --image=<已有镜像> --restart=Never \
  --overrides='{"spec":{"nodeName":"<另一个节点>",
                "containers":[{"name":"probe","image":"<同上>","command":["sleep","60"]}]}}'
```

换节点秒起 ⇒ 原节点故障。处置：`kubectl cordon <node>`（阻止新 Pod 落上去，
已有 Pod 不受影响，`kubectl uncordon` 恢复）。

---

## 8. Manifest 常用字段

| 字段 | 说明 |
|---|---|
| `image` | dev 镜像。**版本要与项目声明的语言版本一致**，否则工具链会自动下载 |
| `command` | 进容器后执行什么。`bash` 需要 Debian 系镜像（alpine 只有 `sh`） |
| `workdir` | 容器内工作目录 |
| `sync` | `本地路径:容器路径`。**单一模块/monorepo 要同步到能编译的最小根目录**，不是子目录 |
| `environment` | 追加/覆盖环境变量。常用来修 `HOME`/缓存路径/CA 路径 |
| `persistentVolume` | 持久化依赖缓存。不开的话每次 up 都重新下载 |
| `forward` | `本地端口:容器端口`。调试器端口写这里 |
| `reverse` | 容器 → 本地的反向转发（让集群里的服务回调你本机） |
| `securityContext` | `runAsUser` / `runAsGroup` / `fsGroup` / `runAsNonRoot` / `capabilities` |

**同步排除**用同步根目录下的 `.stignore`（syncthing 语法，注释是 `//`）。
至少排掉 `.git`、构建产物、测试覆盖率文件 —— 尤其当本地和容器架构不同时，
构建产物同步过去会互相污染。

**缓存目录写权限**是最常见的启动后问题：官方语言镜像的默认 `HOME` 常常是 `/root`，
而 Pod 强制非 root 时写不进去。指到一个可写位置即可，例如 Go：

```yaml
environment:
  - HOME=/go                        # 官方 golang 镜像的 GOPATH 是 1777，任何 uid 可写
  - GOCACHE=/go/.cache/go-build
```

---

## 9. 什么时候该选别的工具

| 工具 | 思路 | 相对 Okteto |
|---|---|---|
| **mirrord** | 进程留在本地，"借"集群 Pod 的网络/env/挂载 | 不改工作负载 ⇒ **不和 GitOps 打架**；但复现不了 uid、架构、文件权限这类容器内属性 |
| **Telepresence** | 拦截流量到本地进程 | 同上，偏"让集群流量打到我本机" |
| **DevSpace / Skaffold** | 快速构建-推送-部署循环 | 仍然经过镜像构建，比 Okteto 慢，但更贴近真实交付路径 |
| **不用任何工具** | 本地跑 + 端口转发依赖 | 依赖能从本地直连时最简单，**优先考虑这个** |

选择判据：**你要验的问题是否依赖"容器内的身份"**。
是（uid、Secret 权限、securityContext、集群 DNS）→ Okteto；
否（只是想让流量过来 / 只是想连上集群里的数据库）→ mirrord 或端口转发。

---

## 10. 收工清单

```bash
okteto down <svc>                     # 恢复工作负载
<恢复 GitOps 自动同步>                # 见 §6，别忘
kubectl get deploy -n <ns>            # 核对副本数已恢复
kubectl delete pvc <svc>-okteto       # 可选：清缓存卷（下次 up 会重建，但要重新下依赖）
```
