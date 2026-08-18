# Jaeger v2 + badger(原生清单)

替代原先的 Helm 方案。**已移除对 Elasticsearch 的依赖**,trace 落在节点本地 PVC 上。

```bash
./install.sh
```

## 为什么不再用 Helm

原方案是 `helm install jaegertracing/jaeger --version 4.11.0`,后端为 ES。要在保留 Helm 的前提下换成 badger 持久化,必须给 Deployment 注入一个 volume,而 **chart 4.11.0 的 Deployment 模板没有 `extraVolumes` / `extraVolumeMounts` 钩子**,只能挂 `user-config`、`ui-config` 两个 ConfigMap。

绕过它的唯一途径是 post-renderer。实测下来这条路代价过高:

- **node101 是 Helm v4**,`--post-renderer` 不再接受可执行文件路径,只认 `postrenderer/v1` 类型的插件,必须专门写一个插件并安装到 `~/.local/share/helm/plugins`(机器本地状态,不在仓库里)。
- **忘记加 `--post-renderer` 会静默丢掉持久化**。实测:带参数安装后 PVC 挂载数为 1;升级时漏掉参数,`helm upgrade` 依然成功退出、Pod 照常 Ready,但挂载数变成 0 —— badger 转而写容器可写层,重启即丢数据,**全程无任何报错**。
- **kustomize patch 目标匹配不到时同样静默 no-op**(helm 退出 0、渲染 347 行、patch 内容 0 处)。而该 chart 自己的 NOTES 写着 `EXPERIMENTAL / Breaking changes may occur in minor versions`,资源命名一变 patch 就无声失效。

为了一份可丢弃的 trace 数据引入两种「静默降级」故障模式,不划算。原生清单里所有内容都在 git 中可见,`install.sh` 末尾还有三条硬断言兜底。

## 与 ES 方案的等价性

对外行为完全一致,消费方无需任何改动:

| 项 | 迁移前(ES) | 迁移后(badger) |
|---|---|---|
| Service 名 / 命名空间 | `jaeger` / `observability` | 不变 |
| 14 个端口(名称、号码、appProtocol) | — | 逐字不变 |
| receivers | otlp(grpc/http)、jaeger(grpc/thrift_http)、zipkin | 不变 |
| pipeline / processors | batch | 不变 |
| 自身指标 | prometheus `:8888` + pod 注解 | 不变 |
| 保留期 | esIndexCleaner CronJob,7 天 | badger `ttl.spans: 168h` |
| UI / 路由 | jaeger-ui.dev.test 等 | 不变(路由清单未改动) |

变化的只有两点,均不影响消费方:

1. **ClusterIP 重新分配**(原 `10.100.15.3`)。otel-collector 走 DNS `jaeger.observability.svc`,HTTPRoute/GRPCRoute 走 `backendRefs` 名称引用,都感知不到。
2. **历史 trace 不迁移**。ES 里那 7 天、约 17MB 的 span 直接丢弃(已确认无需保留)。

## 顺带解决的问题

- jaeger 曾重启 **112 次**(`exitCode 1`),根因是 ES 不可用时 jaeger 跟着退出。解耦后不再受 ES 影响。
- ES 单节点、集群常年 yellow:56 个 unassigned shard 里 **50 个是 jaeger 的**(10 个索引 × 5 主分片 × 1 副本,单节点副本永远分配不了)。清掉 jaeger 索引后只剩 6 个。
- 移除了 values 里两处明文 ES 密码。
- 少一个 CronJob(`jaeger-es-index-cleaner`,此前还失败过)。

**ES 本身不能下线** —— 里面还有 `ecommerce_orders_*`、`ecommerce_products_*` 业务索引和 Kibana。本次只解除 jaeger 对它的依赖。

## 运维须知

- **改完 ConfigMap 必须手动重启**,不再有 Helm 的 checksum 注解:
  ```bash
  kubectl rollout restart deployment/jaeger -n observability
  ```
- **PVC 把 jaeger 钉在了某个节点上**。`openebs-lvmpv` 是节点本地卷 + `WaitForFirstConsumer`,该节点故障时 Pod 无法漂移。这是换取持久化的代价;trace 属可丢数据,判断为可接受。
- **必须用 `strategy: Recreate`**。RWO 卷下若改成 RollingUpdate,新旧 Pod 争抢同一 PVC,新 Pod 会永远 Pending。
- 路由(`jaeger-ui-route` / `jaeger-http-route`)在 `../gateway/` 下,由 `kubectl apply` 管理,内容与本次迁移无关、未作改动。该目录原名 `helm`,因 Helm 方案已废弃、其中只剩 Route 清单而更名。
