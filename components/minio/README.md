# minio —— S3 兼容对象存储（pgsty/silo）

## 1. 定位

集群里的 S3 端点：商品图片等静态文件、备份落地。ecommerce 应用通过
`minio-service.minio.svc:9000` 访问。

## 2. 上游最佳实践

来源：[MinIO 文档](https://min.io/docs/minio/kubernetes/upstream/)、[silo](https://silo.pgsty.com/docs/)

- 生产用 MinIO Operator + Tenant（多副本纠删码）；单节点单盘只适合开发与小规模。
- root 凭据只用于初始化，日常给应用发独立的 access key + 最小权限策略。
- 健康检查端点：`/minio/health/live`（存活）、`/minio/health/ready`（就绪）。
- MinIO 官方社区版 2025 年起移除了完整控制台；`pgsty/silo` 是保留 console 的 fork。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Operator + Tenant 多副本 | **单实例 Deployment** | 两节点、一块本地 LVM 盘，纠删码没有意义。Operator 那套 values 保留在 `examples/helm-operator-tenant/`，将来扩节点可切。 |
| `minio` 官方镜像 | `pgsty/silo` | 官方社区版砍了控制台。**注意二进制名是 `silo` 不是 `minio`** —— 见踩坑。 |
| root 密码写 env | **Secret + secretKeyRef** | 原方案把密码明文写在 Deployment 的 env 里，`kubectl get deploy -o yaml` 就能看到。现在走 `get_cred` + Secret。 |
| 无探针 | 加 readiness/liveness | 用 `/minio/health/{ready,live}`，避免"Pod Running 但服务没起来"。 |
| `strategy` 默认 RollingUpdate | `Recreate` | 单副本 + RWO 卷，滚动更新时新 Pod 会因为卷被占用而永远 Pending。 |

## 4. 暴露方式

- S3 API（集群内）：`http://minio-service.minio.svc.cluster.local:9000`
- S3 API（对外）：`https://s3.dev.test`
- 控制台：`https://minio-ui.dev.test`
- 凭据：用户 `admin`，密码见 `/root/.k8s-installer-credentials`

## 5. 验证

```bash
kubectl -n minio logs deploy/minio | tail -5      # 应看到 "Silo Object Storage Server" 与 API/WebUI 地址
```

真验证（建桶 → 上传 → 下载）：

```bash
PASS=$(cat /var/lib/k8s-installer/creds/minio-root)
kubectl -n minio exec deploy/minio -- sh -c "
  mc alias set local http://127.0.0.1:9000 admin $PASS &&
  mc mb -p local/probe && echo hello | mc pipe local/probe/probe.txt &&
  mc cat local/probe/probe.txt && mc rb --force local/probe"
# 期望输出 hello
```

## 6. 踩坑

- **Pod 反复 Error，日志只有一行 `minio: command not found`（exit 127）**：
  `pgsty/silo` 镜像里只有 `/usr/bin/silo`（外加 `mc`/`mcli`），没有 `minio`。
  命令要写 `silo server /data --console-address :9090`。环境变量仍读 `MINIO_*`。
- **首次启动日志里的 "more than 0 drives of set" 警告**：单盘部署的正常提示，
  意思是主机故障即不可用——本集群已接受这个代价。
- **S3 客户端连不上但控制台正常**：两个端口用途不同，9000 是 API、9090 是控制台，
  路由别接错。
