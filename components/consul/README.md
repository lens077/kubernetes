# consul —— 服务注册与发现

## 1. 定位

ecommerce Kratos 微服务的注册发现。各服务启动时向 Consul 注册自身（Agent API 注册 + TTL 心跳）。
**KV 不再承担配置中心角色**：Consul KV 已于 2026-08-08 退役，运行时配置的唯一来源是 Config Center
（见 ecommerce 仓 `context/project/ecommerce/config/INDEX.md`）。本组件保留 KV 能力但无人使用。
2026-08-18 从 `archive/consul/server/helm/i.sh` 手工脚本整理成组件；同日开启 ACL。
client 侧（kratos 注册示例、Go SDK 用法）仍在 `archive/consul/client/`，属应用侧参考代码，不随组件安装。

## 2. 上游最佳实践

来源：[Consul on Kubernetes](https://developer.hashicorp.com/consul/docs/k8s)、
[helm chart 参考](https://developer.hashicorp.com/consul/docs/reference/k8s/helm)

- 用官方 helm chart 装；server 副本数取奇数（1/3/5），`bootstrapExpect` 跟随副本数无需手设。
- 不用服务网格就关 `connectInject`（省 mutating webhook 和 sidecar，也不会去碰 Gateway API CRD）。
  实测（chart 2.0.3）这个开关一关，渲染出的资源从 70+ 降到 14，且 **CRD 数量归零**。
- `server_rejoin_age_max` 默认 168h：server 离线超 7 天后拒绝启动，防陈旧数据脑裂。
- 生产建议开 ACL（`global.acls`）+ TLS（`global.tls`）；chart 默认全关。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| replicas 3 | 1 + `affinity: ""` | 单节点集群；上游默认反亲和会让多副本 Pending。扩节点后再升 3。 |
| `server_rejoin_age_max` 168h | 8760h | homelab 会长时间整机停机，超期后 server 拒绝启动只能手工清数据目录（实测踩过，见踩坑）。 |
| 旧脚本 `hostNetwork: true` | 不用 | 旧脚本用宿主机网络换固定广告地址；单 server + 持久卷重启自愈，不值得占宿主 8300/8500/8600 端口。 |
| ACL/TLS | **ACL 已开**，TLS 仍关 | 8500 经 `exposeService` 暴露在局域网，不开 ACL 时 `default_policy=allow`，任何人可注销别人的服务。2026-08-18 起 `global.acls.manageSystemACLs: true`。TLS 暂缓（同段内网 + 客户端要改证书链）。 |
| 旧脚本 UI LoadBalancer | ClusterIP + HTTPRoute | 对外统一走共享网关（`consul.dev.test`）。开 ACL 后 UI 需在右上角贴 token 才看得到内容。 |
| 旧脚本 `connectInject.apiGateway.manageExternalCRDs: false` | 直接不开 `connectInject` | 关掉服务网格后 chart 根本不渲染任何 CRD，那两个 `manage*CRDs` 旋钮自然无从谈起（见踩坑）。 |
| — | `server.exposeService` LoadBalancer 保留 | 局域网开发机上的服务按 `http://<LB IP>:8500` 直连拉 KV 配置；旧集群实测 `consul.dev.test` 从宿主机超时而 LB IP 可达。 |
| DNS 接口 | `dns.enabled: false` | 注册发现走 HTTP API（Kratos SDK），DNS 接口用不上。 |

## 4. 暴露方式

- 集群内：`consul-server.consul.svc.cluster.local:8500`（HTTP API/KV）
- 对外 UI：`https://consul.dev.test`（共享网关，同一入口也可走 HTTPS API）
- 局域网 API（本地开发用，写进 ecommerce 本地配置）：

```bash
kubectl -n consul get svc consul-expose-servers \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # http://<IP>:8500
```

## 5. 验证

```bash
kubectl -n consul exec consul-server-0 -- consul members
# consul-server-0  ... alive  server  <版本>  2  dc1

LB=$(kubectl -n consul get svc consul-expose-servers -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# ACL 真的拦住了吗（不带 token，两者都应"失败"，但形态不同）
curl -so /dev/null -w '%{http_code}\n' -X PUT --data probe "http://$LB:8500/v1/kv/probe"   # 403
curl -s "http://$LB:8500/v1/catalog/services"                                             # {} —— 200 但被过滤成空

# 带 root token 应能读写（token 只从 Secret 取，别落盘）
T=$(kubectl -n consul get secret consul-bootstrap-acl-token -o jsonpath='{.data.token}' | base64 -d)
curl -sX PUT -H "X-Consul-Token: $T" --data probe "http://$LB:8500/v1/kv/probe" \
  && curl -s -H "X-Consul-Token: $T" "http://$LB:8500/v1/kv/probe?raw"
curl -sX DELETE -H "X-Consul-Token: $T" "http://$LB:8500/v1/kv/probe"
```

## 5.1 ACL 与客户端 token

- root（bootstrap）token：Secret `consul/consul-bootstrap-acl-token`，键 `token`。**只用于管理**。
- 应用 token：Secret `consul/consul-ecommerce-token`，键 `CONSUL_HTTP_TOKEN`，绑定 policy
  `ecommerce-services` = `service_prefix "" { policy = "write" }` + `node_prefix "" { policy = "read" }`，
  **不含 KV 权限**。Kratos 走 Agent API 注册 + TTL 心跳，`service:write` 是最小必要权限。
- 客户端接法：导出环境变量 `CONSUL_HTTP_TOKEN` 即可，**无需改代码**——
  `registry/consul.go` 构造 `api.Config` 时不设 `Token`，`api.NewClient` 会回落到该环境变量
  （consul/api v1.34.2 `api.go:35,796`）。仓库里的 `constants.EnvConsulToken = "CONSUL_TOKEN"`
  是个没人读的声明，别照着设。

```bash
export CONSUL_HTTP_TOKEN=$(kubectl -n consul get secret consul-ecommerce-token \
  -o jsonpath='{.data.CONSUL_HTTP_TOKEN}' | base64 -d)
```

重建应用 token（policy 已存在时直接建 token 即可）：

```bash
T=$(kubectl -n consul get secret consul-bootstrap-acl-token -o jsonpath='{.data.token}' | base64 -d)
LB=$(kubectl -n consul get svc consul-expose-servers -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
NEW=$(curl -s -H "X-Consul-Token: $T" -X PUT \
  -d '{"Description":"ecommerce Kratos services","Policies":[{"Name":"ecommerce-services"}]}' \
  "http://$LB:8500/v1/acl/token" | python3 -c 'import json,sys;print(json.load(sys.stdin)["SecretID"])')
kubectl -n consul create secret generic consul-ecommerce-token \
  --from-literal=CONSUL_HTTP_TOKEN="$NEW" --dry-run=client -o yaml | kubectl apply -f -
```

## 6. 踩坑

- **chart 会抢 Cilium 的 Gateway API CRD**：默认 values（`connectInject.enabled: true`）
  会安装 5 个**集群级** CRD —— `gatewayclasses` / `gateways` / `httproutes` /
  `referencegrants` / `tcproutes`（均为 `gateway.networking.k8s.io`），与 60-cilium 阶段
  装的同名 CRD 直接冲突（helm 要么报 ownership 冲突失败，要么覆盖掉 Cilium 的版本）。
  本组件 `connectInject.enabled: false`，实测渲染结果 CRD 数为 0。
  **将来若要开服务网格**，必须同时设 `connectInject.apiGateway.manageExternalCRDs: false`。
- **chart 没有 values schema 校验**：写错的键会被静默忽略、不报任何错。实测把
  `ui.enabled` 写成 `ui.enable`、`server.storage` 写成 `server.storag`，`helm template`
  照常成功（旧的 `archive/consul/server/helm/i.sh` 里就有 `ui.enable`/`server.enable`/
  `global.enable` 三个无效键）。改 values 后请务必 `helm template` 渲染出来核对实际生效。
- **`refusing to rejoin cluster because server has been offline for more than the
  configured server_rejoin_age_max (168h0m0s)`**：values 已放宽到 8760h。若已有集群
  没带这条配置且已超期：`kubectl -n consul edit configmap consul-server-config`，在
  JSON 顶层加 `"server_rejoin_age_max": "8760h"` 后删 pod 重启。
- **`consul.dev.test` 从宿主机超时**：本地开发别走网关域名，用 `consul-expose-servers`
  的 LB IP（旧集群 192.168.3.112:8500 就是它）。
- **开 ACL 后"读"不报错、只是变空**：`default_policy=deny` 下写操作返回 403，但列表类读操作
  （`/v1/catalog/services`、`/v1/agent/members`）返回 **200 + 空结果**（Consul 的 ACL 过滤语义，
  不是拒绝）。所以"服务注册看着没报错、网关就是路由不到"时，先查客户端有没有带
  `CONSUL_HTTP_TOKEN`，别去翻网络。
- **`server.extraConfig` 与 ACL 自举冲突警告**：本组件同时用了 `extraConfig`
  （`server_rejoin_age_max`）和 `manageSystemACLs`，helm 会打印
  `Defining server extraConfig potentially disrupts the automatic ACL bootstrapping`。
  实测 2.0.3 上两者共存无碍（bootstrap 成功、Secret 已生成），但**将来往 extraConfig 里加
  `acl` 相关键会真的打架**。
- **KV 配置缺子块会静默降级**（历史，KV 已退役）：现象是服务不报错但功能失效。同一个
  mapstructure 解码器现在读 Config Center，坑仍在，只是换了数据源。
- **换 storageClass 重装**：`helm uninstall` 不删 PVC，需手动
  `kubectl -n consul delete pvc data-consul-consul-server-0`，否则旧 SC 的卷继续被复用。
