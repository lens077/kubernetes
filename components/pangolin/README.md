# Pangolin newt — k8s 集群接入与服务暴露

前置:Pangolin 服务端已在公网 VPS 部署好(见 docker-deploy 仓库 `pangolin/`)。
本文只管 k8s 侧:集群作为一个 newt site 接入隧道,再把集群内服务暴露成公网子域名。

```
公网用户 → VPS(Traefik 443) → WireGuard → newt Pod(ns pangolin)
                                             → Gateway ClusterIP:443 → HTTPRoute → Service
```

## 1. 安装 newt(helm)

面板 → Sites → Add Site(类型 newt)拿到 `id/secret`,然后:

```bash
helm repo add fossorial https://charts.fossorial.io && helm repo update
helm install newt fossorial/newt -n pangolin --create-namespace \
  --set-string newt.id=<SITE_ID> \
  --set-string newt.secret=<SITE_SECRET> \
  --set-string newt.endpoint=https://pangolin.example.com
```

- 凭据用 `--set` 传 inline,**values 文件不要提交进仓库**;事后查看:`helm get values newt -n pangolin`;
- newt 是纯出站连接,集群不需要 LoadBalancer/NodePort/防火墙放行;
- 默认用户态 netstack,低流量够用;高吞吐再考虑 `USE_NATIVE_MAIN_INTERFACE=true` + `NET_ADMIN`(验证:容器里 `wg show` 能看到接口才是内核态)。

## 2. 暴露集群服务:两步法

以 Cilium Gateway API(集群里已有 Gateway + HTTPRoute 体系)为例,把
`foo.example.com` 指到集群内某服务:

**① HTTPRoute 追加 hostname**(增量追加,保留原有内网域名,可回退):

```bash
kubectl patch httproute <name> -n <ns> --type=json \
  -p='[{"op":"add","path":"/spec/hostnames/-","value":"foo.example.com"}]'
```

**② 面板建资源**:subdomain `foo`,site 选 k8s,target 写 **Gateway 的 ClusterIP:443,协议 https**。

Gateway ClusterIP 查法:

```bash
kubectl get svc -n <gateway-ns> | grep gateway   # 形如 cilium-gateway-xxx 的 ClusterIP
```

## 3. 坑:target 走 80 会得到 envoy 404

如果 HTTPRoute 的 parentRef 带 `sectionName: https`,路由**只挂在 443 listener 上,
80 上没有任何路由** —— target 写 `ClusterIP:80` 时 envoy 对一切 Host 返回 404,
和"域名配错"的表现一模一样,非常误导。

- target 必须写 `ClusterIP:443` + https;
- Gateway 用自签证书没关系,VPS 侧 Traefik 已配 `insecureSkipVerify`;
- **判别 404 来源**:看响应头 —— `server: envoy` 说明已经到了集群网关(是路由问题),
  再拿直连 svc ClusterIP 的结果对比,一分钟定位在哪一层。

## 4. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| 502(**快**,<0.5s) | target 写错或后端没起 | target 必须是「Traefik 容器视角能到达的地址」——`localhost`/`127.0.0.1`/`0.0.0.0` 全错(都指向 Traefik 容器自己),**监听地址 ≠ 目的地址** |
| 502(**慢**,数秒) | 隧道断/ClusterIP 不可达 | `kubectl logs -n pangolin deploy/newt`,查 site 在面板是否 online |
| 404 + `server: envoy` | 路由没挂对 listener | 见上节,查 sectionName 与 target 端口 |
| 面板改完没生效 | VPS 侧 Traefik 5s 轮询 | 等 6s 再验证 |
| 证书告警 | 面板证书状态 pending 是 BYO 已知显示问题 | 以浏览器实际握手为准 |
