# argo —— ArgoCD（GitOps 交付）

## 1. 定位

把集群状态交给 Git 管理。当前是**装好待用**状态，业务应用还没纳管。

## 2. 上游最佳实践

来源：[Argo CD 文档](https://argo-cd.readthedocs.io/)

- 生产用 HA 清单（`ha/install.yaml`，含 Redis HA）；单集群开发用普通 `install.yaml`。
- 反向代理/网关终结 TLS 时，argocd-server 要跑 `--insecure`，否则会出现
  「网关已解密、server 又要求 HTTPS」的重定向循环。
- CRD 体积大，必须 server-side apply。
- 初始密码在 `argocd-initial-admin-secret`，首次登录后应改掉并删除该 Secret。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| Helm chart | **官方 yaml manifest** | 便于逐项自定义；chart 的抽象层在只有一个实例时反而碍事。 |
| HA 清单 | 普通清单 | 两节点，Redis HA 的三副本没有真正的故障域隔离。 |
| server 走 HTTPS | `server.insecure=true` | TLS 由共享网关终结（见上方最佳实践里的重定向循环）。 |
| client-side apply | `--server-side --force-conflicts` | CRD 超过 client-side apply 的 `last-applied-configuration` 注解上限。 |

## 4. 暴露方式

- 对外：`https://argocd.dev.test`（共享网关）
- 初始密码：`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## 5. 验证

```bash
kubectl -n argocd get deploy argocd-server                    # READY 1/1
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk -o /dev/null -w "%{http_code}\n" https://argocd.dev.test/ --resolve argocd.dev.test:443:$GW
# 期望 200（登录页）
```

## 6. 踩坑

- **登录页无限重定向**：`server.insecure` 没设成 true，而网关已经终结了 TLS。
- **apply 报注解超长**：忘了 `--server-side`。
- **CLI 版本与服务端不一致**：`argocd version` 两边都看；CLI 由安装器顺带装到
  `/usr/local/bin/argocd`（失败不阻塞服务端）。
