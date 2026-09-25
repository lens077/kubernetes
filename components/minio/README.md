# Silo：S3 兼容对象存储

## 1. 用途

本组件在 `minio` 命名空间部署 [PGSTY Silo](https://silo.pgsty.com/) 单实例对象存储。Silo 保留 MinIO 兼容的 S3 API、管理 API、`MINIO_*` 配置和完整 Web Console。

入口：

- 集群内 S3 API：`http://minio-service.minio.svc.cluster.local:9000`
- 公网 S3 API：`https://silo-api.apikv.com`
- 公网 Web UI：`https://silo.apikv.com`

公网请求路径为 Pangolin → `k8s-cluster` newt → 共享 Gateway VIP → HTTPRoute → Silo Service。

## 2. 部署取舍

| 项目 | 当前实现 | 说明 |
|---|---|---|
| 拓扑 | 单实例 Deployment + 单块 RWO PVC | 当前数据没有节点级冗余。承载卷或节点故障时服务不可用；重要对象必须另有备份。 |
| 镜像 | `docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z` | 固定已验证版本，不使用浮动 `latest`。 |
| 更新策略 | `Recreate` | 避免单实例滚动更新时两个 Pod 争用 RWO 卷。 |
| 数据盘 | `${MINIO_STORAGE_SIZE}`，默认 StorageClass `${SC_NAME}` | 线上当前为 OpenEBS LVM LocalPV。 |
| 凭据 | OpenBao `secret/k8s/${CLUSTER_NAME}/minio` → ESO → `Secret/minio-root` | 仓库、Deployment 和安装日志不保存或回显密码。 |
| 对外入口 | API 与 Console 使用不同域名 | S3 API 路径与 Console 路由互不干扰。 |

Silo 官方把多节点、多磁盘纠删码拓扑作为生产推荐。本集群暂按单节点、单盘部署，这是容量和资源约束下的明确折中，不提供节点故障容忍能力。

## 3. 首次部署

在控制平面节点执行：

```bash
cd /root/kubernetes

# 首次生成并写入 OpenBao；值通过 stdin 传递，不出现在命令参数或日志中。
bash tools/openbao-seed.sh minio

# ESO 物化 Secret，创建 PVC、Deployment、Service 和 HTTPRoute。
bash components/minio/install.sh
```

`install.sh` 可重复执行。已有 OpenBao/Secret 值时不会自动轮换凭据。

## 4. 验证

### 4.1 工作负载与路由

```bash
kubectl -n minio rollout status deploy/minio --timeout=10m
kubectl -n minio get pod,svc,pvc,externalsecret,httproute
kubectl -n minio get secret minio-root -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
```

最后一条应输出 `ExternalSecret`。

### 4.2 S3 读写闭环

不要把密码写在命令行参数中。使用临时 Pod 的 `secretKeyRef` 注入凭据，创建测试桶、写入、读回并删除：

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: silo-smoke, namespace: minio}
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z
      command: [/bin/sh, -ceu]
      args:
        - |
          export MC_CONFIG_DIR=/tmp/mc
          mc alias set local http://minio-service.minio.svc.cluster.local:9000 "$SILO_USER" "$SILO_PASSWORD" >/dev/null
          bucket="silo-smoke-$(date +%s)"
          mc mb "local/$bucket" >/dev/null
          printf ok | mc pipe "local/$bucket/probe.txt" >/dev/null
          test "$(mc cat "local/$bucket/probe.txt")" = ok
          mc rb --force "local/$bucket" >/dev/null
      env:
        - name: SILO_USER
          valueFrom: {secretKeyRef: {name: minio-root, key: user}}
        - name: SILO_PASSWORD
          valueFrom: {secretKeyRef: {name: minio-root, key: password}}
YAML
kubectl -n minio wait --for=jsonpath='{.status.phase}'=Succeeded pod/silo-smoke --timeout=2m
kubectl -n minio delete pod silo-smoke
```

Secret 值只进入容器环境，不经过 shell 展开或 `kubectl` 命令参数。

### 4.3 公网入口

```bash
curl -fsS https://silo-api.apikv.com/minio/health/ready
curl -I https://silo.apikv.com/
```

API 健康检查应返回 HTTP 200；Web UI 应返回页面或重定向，不应跳转到集群内域名。

## 5. Pangolin 配置

在 Pangolin 组织 `main` 下创建两个 HTTP resource，均绑定 `k8s-cluster` site（当前 `siteId=11`）：

| Resource | 公网域名 | Target | `setHostHeader` / `tlsServerName` | SSO |
|---|---|---|---|---|
| `silo-api` | `silo-api.apikv.com` | `https://10.10.31.240:443` | `silo-api.apikv.com` | 关闭 |
| `silo-webui` | `silo.apikv.com` | `https://10.10.31.240:443` | `silo.apikv.com` | 关闭 |

必须改写 Host 和 SNI，否则共享 Gateway 无法匹配对应 HTTPRoute。S3 API 不得开启 Pangolin SSO：S3 签名客户端不能完成浏览器登录流程。Web UI 使用 Silo 自身的 root 用户登录，也保持 Pangolin SSO 关闭，避免双重登录和 API 请求被边缘层拦截。

公网验证：

```bash
# 未签名访问 S3 根路径通常返回 403，证明请求已抵达 Silo；健康端点必须返回 200。
curl -fsS https://silo-api.apikv.com/minio/health/ready
curl -I https://silo.apikv.com/
```

## 6. 凭据消费

root 用户固定为 `silo-admin`。密码只从 OpenBao/ESO 管理；不要把 root 凭据写入 Git、ConfigMap、Deployment 或文档。

Scorpius 本地管理凭据写在其项目根目录 `.silo-admin.env`。保存前必须在目标仓库显式忽略该文件，并用 `git check-ignore .silo-admin.env` 确认生效；`.env.*` 不能匹配这个文件名。本仓库通过 `.*.env` 排除此类本地文件。文件权限必须为 `0600`，内容格式为：

```dotenv
SILO_ENDPOINT=https://silo-api.apikv.com
SILO_ROOT_USER=silo-admin
SILO_ROOT_PASSWORD=<从 minio/minio-root Secret 读取>
```

应用日常访问不应复用 root 用户。后续应按应用创建独立 access key，并绑定最小权限策略。

## 7. 常见问题

- Pod 报 `minio: command not found`：Silo 二进制名是 `silo`。当前镜像使用自身 entrypoint，参数为 `server /data --console-address :9090`。
- Console 登录后跳到内部地址：检查 Deployment 的 `MINIO_BROWSER_REDIRECT_URL=https://silo.apikv.com`。
- 预签名 URL 使用内部地址：检查 `MINIO_SERVER_URL=https://silo-api.apikv.com`。
- Console 正常但 S3 客户端失败：确认 API 域名转发 9000，Console 域名转发 9090。
- PVC 导致升级卡住：Deployment 必须保持 `strategy.type=Recreate`。
