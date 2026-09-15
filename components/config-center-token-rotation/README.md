# Config Center service-token rotation Job

This component contains the restricted automation boundary for service-token rotation.

## Build（推到 TCR，不用 GHCR/Docker Hub：集群和构建机都连不上）

基础镜像先镜像进 TCR（Docker Hub 不可达；集群节点是 amd64）：

```bash
# 在能拉 Docker Hub 的机器(如 node1)上 pull --platform linux/amd64 alpine:3.20, docker save 搬到本机后:
docker push --platform linux/amd64 ccr.ccs.tencentyun.com/sumery/alpine:3.20-amd64
```

从仓库根目录构建（脚本要 `components/_lib` 与 `bootstrap/lib`），tag 用内容哈希，CronJob 里按 digest 固定：

```bash
TAG=config-token-rotation-$(date +%Y%m%d)-$(sha256sum tools/config-center-rotate-service-tokens.sh | cut -c1-8)
docker buildx build --platform linux/amd64 -f components/config-center-token-rotation/Dockerfile \
  -t ccr.ccs.tencentyun.com/sumery/kubernetes-tools:$TAG --push .
docker buildx imagetools inspect ccr.ccs.tencentyun.com/sumery/kubernetes-tools:$TAG | awk '/^Digest:/{print $2}'
# 把 digest 写进 cronjob.yaml 的 image@sha256:…, 然后 bash components/config-center-token-rotation/install.sh
```

当前镜像：`config-token-rotation-20260915-c4f2e533` = `sha256:14859b5e…`。脚本改了就要重建（镜像里是脚本的拷贝）。

## 状态（2026-09-15 启用）

两次集群内 Job 演练后 `suspend: false`，每周日 03:17 轮换 pre 的 10 个 service token：

| 演练 | 结果 | 修了什么 |
|---|---|---|
| `rotation-drill-1534` | 失败 | 暴露两个真缺陷：① 脚本逐服务「签发→写 Secret→**吊销旧**」之后才滚动消费者，而滚动在第一个 Deployment 就因 RBAC 缺 `list` 超时退出——其余 9 个服务的 Pod 拿着已吊销的 token 跑（watch 流 401，靠缓存配置活着）；② 「读回验证」用的是 operator 头，没验证新 service token 本身。当场手工滚动 9 个 Deployment 止血 |
| `rotation-drill-1542` | 成功 | 脚本重写为三阶段（A 签发+**用新 token 读回**+写 Secret → B 滚动全部消费者并只用 `get` 轮询等就绪 → C 全部就绪后才吊销），待吊销的旧 id 落在 `service-token-ids-previous` 注解，失败后重跑进入续跑模式（不签新 token，只重做 B+C）。独立核验：旧 token `revokedAt` 非空、10 服务 3 分钟内 0 个 401、previous 注解已清 |

手动触发：`kubectl -n config-center create job drill-$(date +%H%M) --from=cronjob/config-center-service-token-rotation`。

## Security boundary

- The Job receives only an already-issued operator token from Secret `config-center-operator`.
- It never receives a Casdoor password, admin JWT, OpenBao root token, or Pangolin credential.
- The operator token is restricted to its own environment and cannot issue another operator token.
- `backoffLimit: 0`：失败必须人看，不盲目重试；重跑 = 再建一个 Job（续跑模式安全）。
- `concurrencyPolicy: Forbid` prevents overlapping rotations.

RBAC 是按名字给的最小集（`rbac.yaml` 头注释），`kubectl auth can-i --as=system:serviceaccount:config-center:config-center-token-rotation` 核过：能读 pre operator、不能读 dev operator、不能 list secrets、不能 delete deployment。`rollout status` 需要 `list`（resourceNames 对 list 无效），所以脚本改成只用 `get` 轮询 Deployment 状态。
