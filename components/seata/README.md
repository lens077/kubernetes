# seata —— Apache Seata 事务协调器（TC，单副本）

## 1. 定位

**技术验证组件，默认不装**（`ADDON_SEATA=false`）。

⚠️ 先说清楚它**不是** ecommerce 的一致性方案。ecommerce 的
[`docs/design/order/consistency.md`](../../../ecommerce/docs/design/order/consistency.md)
已明确决议：下单跨服务事务走 **Outbox + Kafka + 编舞式 Saga**，
**不引入 Seata**（Seata 的 AT 模式深度绑定 Java 生态，Go 栈的 seata-go 长期滞后——
本仓实测时最新的 seata-go 还是 v1.2.0，而 TC 已到 2.6.0）。

那为什么还留这个组件：

- **平台侧要能回答"如果要用，怎么部署"** —— archive 里那份旧清单是错的（见第 6 节），
  留一份跑得通的比留一份跑不通的强；
- ecommerce 之外的服务（若将来接入 Java 侧组件）可能需要 TC；
- 作为 TCC/AT 模式的**对照实验场**：Saga 方案的每个取舍（幂等消费、显式补偿、状态即真相）
  都是在"不用 TC"的前提下做的，手上有个能跑的 TC 才好验证那些取舍是否成立。

## 2. 上游最佳实践

来源：[Seata Deploy with Kubernetes](https://seata.apache.org/docs/next/ops/deploy-by-kubernetes/)、
[v2.6.0 application.yml](https://github.com/apache/incubator-seata/blob/v2.6.0/server/src/main/resources/application.yml)、
[SecretKey 安全公告](https://seata.apache.org/docs/next/security/secret-key/)（2026-08 复核）

- **最新稳定版 2.6.0**（2026-01-28）。v2.7.0 在 GitHub 仍是 prerelease，但
  **Docker Hub 的 `latest` 已经指向 2.7.0** —— 必须钉版本。
- 镜像用 `docker.io/apache/seata-server`（`seataio/` 是遗留命名空间，别再用）。
- **架构已变（关键）**：2.5 起 console web UI 从 seata-server 移除，
  2.6 默认 `spring.main.web-application-type: none` —— **server 本体只有 8091 一个端口**
  （Netty TC 协议），7091 console 不复存在（现为独立模块，要 JDK25 + namingserver）。
- `store.mode` 四选一：`file`（单机最快）/`db`（推荐生产）/`redis`（异步有丢数风险）/
  `raft`（要 ≥3 副本）。
- 老版本（<1.8.1 / <2.1）有 hessian 反序列化 RCE（CVE-2024-22399），2.6.0 已规避。
- 部署 console/namingserver 时必须改三处默认值（`console.user.username/password`、
  `seata.security.secretKey`），出厂凭据是众所周知的 seata/seata。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 官方 helm chart | **自写 manifests** | 官方 chart（`script/server/helm/seata-server`）事实弃养：apiVersion `v1`（Helm 2 时代）、appVersion `"1.0"`、镜像写 `seataio/seata-server:latest`、配置靠 hostPath。装不起来。 |
| Deployment | **StatefulSet + PVC** | `store.mode=file` 的事务日志（sessionStore）必须持久化——TC 重启丢掉未完成的全局事务，正好摧毁它存在的意义。 |
| `store.mode` 生产推荐 `db` | **`file`** | 验证定位，不想为一个默认不装的组件在 PG 里建四张表（global/branch/lock/distributed_lock）。要转 db 见下方「换 db 模式」。 |
| `image: latest` | **钉 `2.6.0`** | Docker Hub 的 latest 已是 prerelease 的 2.7.0。 |
| 官方示例 requests 1c/2Gi、limits 2c/4Gi | requests 100m/512Mi，limits.memory 1Gi | 内存偏紧；2.6 起 JVM 参数按容器内存自动计算，不用手写 `-Xmx`。轻负载实测 1Gi 够用。 |
| HTTP 健康检查 | **`tcpSocket: 8091`** | 2.6 无 HTTP server，没有 `/health` 可探。 |
| registry 接 Nacos/Consul | `registry.type: file` | 单副本 + 客户端直连 Service DNS，引入注册中心只是多一个故障点。 |

### 换 db 模式（要生产用时）

1. 在 [postgres](../postgres/) 的实例里建库与四张表：
   [`script/server/db/postgresql.sql`](https://github.com/apache/incubator-seata/tree/v2.6.0/script/server/db)；
2. 改 `manifests/01-config.yaml` 的 `seata.store.mode: db` 并补 `store.db` 段
   （用 Secret 注入口令，别写字面量——见 [SECURITY.md](../../SECURITY.md)）；
3. 确认镜像内有 PG JDBC 驱动，没有就挂到 `/seata-server/resources/jdbc/`（官方预留目录）；
4. `component.env` 的 `DEPENDS_ON` 改为 `postgres`；PVC 可去掉。

db 模式的收益：TC 可多副本、Pod 漂移不丢状态、不被 OpenEBS LVM 本地卷钉在单节点。

## 4. 暴露方式

- 集群内：`seata-server.seata.svc.cluster.local:8091`
- 局域网：Gateway `seata-gateway` 的 TCP listener（8091），IP 由 Cilium 分配：
  `kubectl -n seata get gateway seata-gateway -o wide`

**8091 是 Netty 私有二进制协议，不是 HTTP** —— 只能走 TCPRoute，挂共享网关的
http/https listener 是无效的（archive 旧清单的错误，见第 6 节）。

⚠️ 这条入口是**明文**：Seata 客户端在 TC 连接上没有原生 TLS 配置项。只在可信局域网内
使用；跨网络需自行加隧道。这与 [redis](../redis/) 能做原生 TLS 是不同的（那边协议自带）。

## 5. 验证

```bash
kubectl -n seata get pods,pvc                        # Running / Bound
kubectl -n seata logs seata-server-0 | grep 'service listen port'
```

真验证（用官方 seata-go 编解码器走完整 Netty 协议做 **TM 注册握手**，
而不是只 `nc` 一下端口）：

```bash
cd components/seata/examples/tc-probe
go build -o probe .
VIP=$(kubectl -n seata get gateway seata-gateway -o jsonpath='{.status.addresses[0].value}')
./probe $VIP:8091
# 期望: TM_REGISTER identified=true resultCode=0
```

服务端侧对账：

```bash
kubectl -n seata logs seata-server-0 | grep 'TM register success'
```

> **实测结论（2026-08-19）**：经 Gateway VIP `192.168.3.105:8091` 完成 TM 注册握手，
> `identified=true / resultCode=0`；服务端日志出现
> `TM register success ... applicationId='probe-app', client version:2.6.0`。
> 删 Pod 重建后 `sessionStore/8091/root.data` 仍在 PVC 上。
> 探针用的 seata-go 是 v1.2.0（远落后于 TC 2.6.0），**协议层向后兼容**验证通过——
> 这条信息本身也是"Go 栈接 Seata 值不值"的一个输入。

## 6. 踩坑

- **archive 里的旧清单是错的，两处**（`archive/seata/yaml/install.sh`）：
  ① 给 8091 挂 `HTTPRoute` + `sectionName: http` —— Netty 私有协议过不了 Envoy 的 HTTP
  解析，那条路由永远不会工作；② `image: latest` + `STORE_MODE=file` 却用 Deployment
  无持久卷，TC 一重启事务日志全丢。
- **官方 K8s 文档页仍是 2.3 时代的示例**：写着 `containerPort: 7091` + console
  的 ConfigMap。照抄会得到一个「端口对不上、console 打不开」的部署，而根因是
  **2.5/2.6 把 console 移走了**，不是配置写错。
- **`seata.server.service-port` 不写会偏移 1000**：默认值是 `${server.port} + 1000` = 9091，
  客户端按 8091 连就会连不上。清单里显式写死。
- **ConfigMap 必须用 `subPath` 只覆盖 application.yml**：整卷挂 `/seata-server/resources`
  会遮蔽同目录的 logback 等文件，启动即失败。（与本仓 helm db-ca-cert 挂载遮蔽系统 CA
  是同一类错误。）
- **自己手拼协议帧会被 TC 拒绝**：实测手写 v1 帧头（Full length 位置/head length 猜错）
  得到服务端 `Can not recognize protocol from remote ... preface = [...]`。
  好消息是这条报错本身证明链路通到了 TC；要做协议级验证请用官方编解码器（examples/tc-probe）。
- **ConfigMap 改了不会自动重启**：没有 helm 的 checksum 注解，改完手动
  `kubectl -n seata rollout restart statefulset/seata-server`。
