# TODO

## 2026-08-06 · Jaeger 去 Elasticsearch 化 + 失效网关配置清理

### 背景

Jaeger 原先以 Elasticsearch 为 trace 后端。该依赖带来三个实际问题:ES 不可用时 jaeger 跟着退出(pod 累计重启 **112 次**,`exitCode 1`);单节点 ES 上 jaeger 索引产生 50 个永远无法分配的副本分片(占集群 56 个 unassigned 的绝大部分);values 里硬编码了两处明文 ES 密码。

目标是解除 jaeger 对 ES 的依赖。**ES 本身继续保留** —— 其中还有 `ecommerce_orders_*`、`ecommerce_products_*` 业务索引和 Kibana。

### 集群变更

| 操作 | 对象 |
|---|---|
| 卸载 | Helm release `jaeger`(chart `jaeger-4.11.0`)@ `observability` |
| 新建 | ServiceAccount / PVC(`jaeger-badger` 5Gi)/ ConfigMap(`jaeger-config`)/ Deployment / Service |
| 删除 | GRPCRoute `jaeger-grpc-route` @ `observability`(55 天从未生效) |
| 删除 | ES 中 10 个 `ecommerce-jaeger-*` 索引 |

存储后端改为 badger(节点本地 PVC),`ttl.spans: 168h` 对齐原 `esIndexCleaner.numberOfDays: 7`。随 Helm 卸载一并消失的还有 `jaeger-es-index-cleaner` CronJob。

**对外行为保持一致**:Service 名、14 个端口(名称/端口号/appProtocol)、receivers(otlp、jaeger、zipkin)、processors、pipeline、`:8888` 自身指标端点全部逐字未变,otel-collector 与所有路由无需改动。唯一变化是 ClusterIP 重新分配(`10.100.15.3` → `10.109.117.7`),消费方均走 DNS 或 backendRef 名称,不受影响。

ES 中 7 天约 17MB 的历史 trace 已确认无需保留,未做迁移。

### 验证结果

- `install.sh` 三条断言全过:PVC 已挂载 / 后端为 badger 且日志无 ES / Service 端口数为 14
- 端到端:经真实链路 otel-collector → jaeger 打入 trace,再按 traceId 查回成功
- **重启后数据仍在**:`rollout restart` 后 Pod 换名,同一 traceId 依然查得到
- HTTPRoute `jaeger-ui-route` / `jaeger-http-route` 在 Service 重建后仍为 `Accepted` + `ResolvedRefs=True`
- 日志中 error/warn 计数为 0;迁移后运行至今 0 重启
- ES unassigned 分片 **56 → 6**,6 个业务索引完好无损

配置正确性用反证法确认过:故意插入不存在的 key,jaeger 报 `has invalid keys`,证明解析是严格的 —— 因此 `ttl.spans` 是被真正识别的配置项,而非被静默忽略。

### 为什么放弃 Helm

chart 4.11.0 的 Deployment 模板没有 `extraVolumes` / `extraVolumeMounts` 钩子,badger 挂 PVC 只能靠 post-renderer 绕过。实测该路线代价过高:

- node101 是 **Helm v4**,`--post-renderer` 不再接受可执行文件路径,只认 `postrenderer/v1` 插件(机器本地状态,不在仓库里)
- **漏加 `--post-renderer` 会静默丢失持久化**:实测带参数安装时 PVC 挂载数为 1,升级时漏掉参数后 `helm upgrade` 依然成功退出、Pod 照常 Ready,挂载数变成 0,badger 转写容器可写层,全程无任何报错
- **kustomize patch 目标匹配不到时同样静默 no-op**(helm 退出 0、渲染 347 行、patch 内容 0 处),而该 chart 的 NOTES 自称 `EXPERIMENTAL`,资源命名一变 patch 就无声失效

为一份可丢弃的 trace 数据引入两种静默降级故障模式,不划算。

### 仓库变更

```
jaeger/
  + README.md                          目录说明 + 变更记录
  + manifests/                         01-sa / 02-pvc / 03-cm / 04-deploy / 05-svc
                                       + install.sh(含 3 条硬断言)+ README.md
  ~ helm/ → gateway/                   Helm 废弃后其中只剩 Route 清单,更名
  - helm/install.sh                    危险:再次执行会用 ES 装一个 helm release 与现有 Deployment 打架
  - helm/memory.yaml                   旧版 v1 chart 的 values,与 4.x 结构不兼容
  - helm/examples/jaeger-trace-to-es-store.yml
  - helm/{grpc-route,gateway,certificate}.yml   失效的 observability-gateway 三件套
  - helm/gateway.sh                    创建的 elastic-gateway / jaeger-route 均不存在,
                                       且会与现有 jaeger-ui-route 撞域名

opentelemetry/server/helm/collector/examples/
  ~ configs/jaeger-es-loki-vm.yml → jaeger-loki-vm.yml    名字里的 es 已不成立
  - gateway/{gateway,certificate,root-ca,issuer}.yml      整条自签 CA 链从未 apply
  - gateway/get-tls.sh                                    要读的 Secret 不存在,必然报错

elastic-stack/
  - 02-gateway.sh                      见下
  - examples/gateway.yml               elastic-gateway HTTP:80,集群中不存在
  - examples/tls/tls-gateway.yml       elastic-gateway HTTPS:443,同上
  - examples/tls/certificate.yml       引用的 ClusterIssuer selfsigned-issuer 不存在
  ~ examples/kibana-httproute.yml      校正为与线上 kibana-https-route 一致
```

otel-collector 的配置**无需功能性改动** —— 它只与 Jaeger 的 Service 通信,不接触存储后端。只改了文件名和一处注释。

`elastic-stack/02-gateway.sh` 除失效外还有三处会造成实际损害:生成 `es-gateway.yml` 却 `apply -f gateway.yml`;创建的 `elasticsearch-route` 与线上同名同命名空间但 parentRef 指向不存在的网关,跑一次就会打断 `es.app.com` 的外部访问;还会把 `es-httproute.yml` / `kibana-httproute.yml` 覆盖写到当前目录。

---

## 待办

### 需要验证

- [ ] **真实应用链路未验证**。`ecommerce` 命名空间当前为空(无任何工作负载),迁移后只用合成 trace 验证过。应用恢复后需重新确认业务 trace 能正常写入并查询。
- [ ] **badger TTL 未经时间验证**。`ttl.spans: 168h` 的配置有效性已确认,但"7 天后旧数据确实被清除"需运行满一周后核对 PVC 用量(`kubectl exec deploy/jaeger -- du -sh /badger`)。

### 已知风险

- [ ] **jaeger 被 PVC 钉在单个节点**。`openebs-lvmpv` 是节点本地卷 + `WaitForFirstConsumer`,该节点故障时 Pod 无法漂移。这是换取持久化的代价;trace 属可丢数据,当前判断为可接受,但需要知情。
- [ ] **改 ConfigMap 后必须手动重启**,不再有 Helm 的 checksum 注解自动触发:
      `kubectl rollout restart deployment/jaeger -n observability`。
      可考虑加 checksum 注解或改用 kustomize 的 configMapGenerator。

### 遗留失效配置

- [ ] **`opentelemetry/server/helm/config-otel-collector.sh` 已失效**。它引用 `jaeger-collector.<ns>.svc.cluster.local:4317/4318`,集群中不存在该 Service(只有 `jaeger`)。待修正或删除。
- [ ] **`jaeger/test/grpc/main.go` 指向不存在的端点**。目标为 `otlp-grpc.app.com:443`,该域名无任何路由。改指 `otel-collector` 的 LoadBalancer(`192.168.3.117:4317`),或补一条路由。
- [ ] **`jaeger/gateway/examples/rbac.yml` 位置不当**。内容是 otel-collector 的 ClusterRole/Binding,与 jaeger 无关,宜移至 opentelemetry 目录下。

### 待决策

- [ ] **ES 集群仍为 yellow**。清理 jaeger 索引后剩 6 个 unassigned,来自 6 个业务索引的副本分片 —— 单节点 ES 无处安放。需决定:把业务索引 `number_of_replicas` 设为 0,或给 ES 加节点。这是 ES 自身的单节点配置问题,与 jaeger 无关。
- [ ] **elastic-stack 的 TLS 方案已随清理移除**。目前 ES / Kibana 仅通过 `cilium-gateway` 的 HTTP listener 暴露(`es.app.com`、`kibana.app.com`)。若需要 TLS,需重新规划 —— 原先那套 `elastic-gateway` + 自签证书从未生效过,不要直接照抄。

### 环境观察

- [ ] **镜像拉取异常缓慢**。两次独立观察:`curlimages/curl` 在 node3 上超过 5 分钟未拉完;Kibana 滚动更新的新 Pod 在 node2 拉取 `docker.elastic.co/kibana/kibana:9.4.0` 时长时间停留在 `Init:0/1`(无报错事件,纯粹是拉取中)。可能值得排查 registry 连通性或配置镜像加速。
