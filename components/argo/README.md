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
| server 走 HTTPS | **两种模式可切**：`http`（默认，`--insecure` + 网关终结）/ `tls`（server 自出 TLS + 网关 passthrough） | 默认保持原状；要原生 gRPC 才切 `tls`，见 §4 |
| client-side apply | `--server-side --force-conflicts` | CRD 超过 client-side apply 的 `last-applied-configuration` 注解上限。 |

## 4. 暴露方式（两种模式）

`argocd-server` 只能二选一：要么自己出 TLS，要么跑明文让网关终结。所以这里做成
两个**互斥、可重入**的脚本，`install.sh` 按 `ARGOCD_SERVER_MODE` 调其中一个（默认 `http`）：

| 模式 | 命令 | argocd-server | 网关 | 原生 gRPC |
|---|---|---|---|---|
| `http`（默认/回退） | `bash components/argo/mode-http.sh` | `server.insecure=true`，8080 只说 HTTP/1.1 | 共享 `cilium-gateway` 443 **Terminate** → 明文回源 `:80` | ✗ 必须 `--grpc-web` |
| `tls` | `bash components/argo/mode-tls.sh` | `server.insecure=false`，8080 出 TLS + h2 | 独立 `argo-passthrough-gateway` 443 **Passthrough** → TLS 回源 `:443` | ✓ |

两个脚本都支持 `--dry-run`（只渲染清单，不动集群）。

### 为什么 TLS 版要单独一个 Gateway

同一个 Gateway 里不能同时放 `HTTPS/Terminate` 和 `TLS/Passthrough` 去抢 443
（Gateway 会 `Programmed=False`），这条在 [gateway/README](../gateway/README.md) 写过。
共享网关只做 Terminate，所以 Argo 的透传入口自己带一个 Gateway、自己领一个 LB VIP。

### 路由清单放在子目录

`gateway/http/` 与 `gateway/tls/` 各放自己模式的清单。`routes_apply` 只扫
`gateway/*.yaml`（不递归），所以这些清单不会被安装器误 apply；由 `mode-*.sh` 显式渲染
（`render_tpl` 额外传入 `CLI_HOSTNAME`）。

| SNI | 用途 |
|---|---|
| `argocd.dev.test`（`HOSTNAME`） | 浏览器 / UI |
| `argocd-api.dev.test`（`CLI_HOSTNAME`） | ArgoCD CLI 的 gRPC |

### 切到 TLS 之后要同步的三件事

1. **Pangolin 两个资源都改目标**：`argocd` 与 `argocd-api` 都指到新 Gateway 的
   `https://<VIP>` + 端口 `443`，勾「启用 TLS」，`TLS 服务器名称` 分别填
   `argocd.dev.test` / `argocd-api.dev.test`。填了 SNI 后 Pangolin 自动生成
   `serversTransport{serverName, insecureSkipVerify:true}`，Argo 的自签证书不用配 CA。
2. **`argocd.dev.test` 的解析**：它现在指向旧共享网关 `10.10.31.240`，要改指新 VIP
   （DNS 或 hosts）。解析不在本仓库管理。
3. **证书**：透传时浏览器看到的是 argocd-server 自签证书，`argocd.dev.test` 直连会有
   证书告警；公网经 Pangolin 时看到的是 Pangolin 的证书，不受影响。

TLS 模式下的验证：

```bash
VIP=$(kubectl -n argocd get gateway argo-passthrough-gateway -o jsonpath='{.status.addresses[0].value}')
openssl s_client -connect $VIP:443 -servername argocd.dev.test </dev/null 2>/dev/null | openssl x509 -noout -subject
argocd login argocd-api.apikv.com --username admin      # 原生 gRPC，不需要 --grpc-web
```

- 对外：`https://argocd.dev.test`（`http` 模式经共享网关；`tls` 模式经独立网关）
- 初始密码：`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## 5. 验证

```bash
kubectl -n argocd get deploy argocd-server                    # READY 1/1
# http 模式（默认）
GW=$(kubectl -n default get gateway cilium-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk -o /dev/null -w "%{http_code}\n" https://argocd.dev.test/ --resolve argocd.dev.test:443:$GW
# 期望 200（登录页）
# tls 模式
VIP=$(kubectl -n argocd get gateway argo-passthrough-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk -o /dev/null -w "%{http_code}\n" https://argocd.dev.test/ --resolve argocd.dev.test:443:$VIP
```

## 6. 踩坑

- **登录页无限重定向**：`server.insecure` 没设成 true，而网关已经终结了 TLS。
- **apply 报注解超长**：忘了 `--server-side`。
- **CLI 版本与服务端不一致**：`argocd version` 两边都看；CLI 由安装器顺带装到
  `/usr/local/bin/argocd`（失败不阻塞服务端）。
- **`--insecure` 下的 8080 没有 h2c**：实测（2026-10-25）在 Pod 内直连
  `localhost:8080`，HTTP/1.1 正常 401，`--http2-prior-knowledge` 直接 `Connection reset`；
  原生 gRPC 连 `argocd login --plaintext` 都会自己回退并打印
  `Use flag --grpc-web`。所以**明文模式永远拿不到原生 gRPC**，这不是代理的锅。
- **Passthrough 与 Terminate 不能共用一个 443**：同一个 Gateway 里两个 listener 抢同端口
  不同协议是非法的，会 `Programmed=False`；L4 透传一律自带 Gateway。
- **切 TLS 的顺序**：先建 passthrough 入口 → 再让 server 出 TLS → 最后删明文路由。
  反了就是「网关把 TLS 打到明文口」，整站 502。
- **探针 scheme 必须跟着 server 的 TLS 状态走**：`argocd-server` 的 liveness/readiness 是
  `httpGet ... scheme: HTTP` 打在 8080 上。只把 `server.insecure` 改成 false，探针就会拿明文
  打 TLS 端口，3×10s 后 liveness 杀掉 Pod。两个 `mode-*.sh` 都会同步改探针；但**重跑
  `install.sh` 会先 apply 上游清单把探针改回 HTTP**，所以重装时务必用同一个
  `ARGOCD_SERVER_MODE`（默认 http），别在 tls 模式下裸跑 install。
- **VIP 会漂移**：独立 Gateway 的地址由 LB 池分配，换集群/重建后要重新查
  `kubectl get gateway -o wide`，同步改 Pangolin target 与 `argocd.dev.test` 的解析。
