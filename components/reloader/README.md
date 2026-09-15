# Reloader

> Secret / ConfigMap 变了，引用它的工作负载自动滚动。它是 ESO 链路的最后一环，不是凭据轮换的完整答案。

## 1. 定位

ESO 把 Vault/OpenBao 里的值物化成 K8s Secret 之后，链路就断了：Secret 变了，Pod 不会重启，进程继续用启动时读到的旧值（[external-secrets 组件 README §2](../external-secrets/README.md) 明写「物化后 Pod 不会自动重启」）。Reloader 补的就是这一步。

```text
Vault/OpenBao 改值 → ESO(refreshInterval) 物化 Secret → Reloader 滚动引用方 → 进程用上新值
```

它**不做**的事，比它做的事更重要：

| 场景 | Reloader 管不管 | 谁管 |
|---|---|---|
| Dragonfly 密码变了，Dragonfly 自己重启 | ✅ 管（Deployment 引用 `dragonfly-password-secret`） | — |
| Dragonfly 密码变了，10 个 ecommerce 服务在 **Config Center** 里的 `bootstrap.yaml` 要跟着改 | ❌ 不管——那是 KV，不是 K8s Secret | `tools/config-center-harvest.sh` |
| cert-manager 续期了证书 Secret | 默认不管（`autoReloadAll: false` + 未加注解） | 应用自己热加载 |
| Job/CronJob 引用的 Secret 变了 | 不管（`ignoreJobs/ignoreCronJobs: true`） | 下次调度自然读新值 |

所以共享凭据的轮换顺序是「改 Vault → Reloader 滚动提供方 → **harvest 重写消费方**」。只装 Reloader 不跑 harvest，等于把「密码不一致」从提供方挪到了消费方。这也是它 `DEFAULT_ENABLED=false` 的原因：当前唯一的改值路径是「人跑脚本」，`install.sh` 里显式 `rollout restart` 时机可控；只有 Vault/OpenBao 的值会在脚本之外变化时（定期自动轮换、多人操作）才需要它。

不装会怎样：ESO 同步了新值，Pod 静默用旧密码跑到下次任何原因的重启。

## 2. 上游最佳实践

来源：[stakater/Reloader](https://github.com/stakater/Reloader)、chart `stakater/reloader` 2.2.17 / app v1.4.22。

- 用**注解按工作负载显式接入**，不开 `autoReloadAll`：全局模式会把控制器自己维护的 Secret（证书、SA token、ESO 目标）都算进去。
- 两种注解：`reloader.stakater.com/auto: "true"`（该工作负载引用到的所有 Secret/CM）与 `secret.reloader.stakater.com/reload: "a,b"`（点名）。点名更可审计。
- `reloadStrategy: annotations` 改的是 Pod 模板注解，与 `kubectl rollout restart` 同构；默认的 `env-vars` 策略会往容器塞 `STAKATER_*_LAST_RELOADED` 环境变量。
- `syncAfterRestart` 默认关：开了等于 Reloader 自己一升级就把全集群带注解的工作负载滚一遍。
- 单副本足够；`enableHA` 是 leader election，不是吞吐。
- 指标口 `:9090`，`reloader_reload_executed_total{success}` 是唯一需要看的计数器。

## 3. 本集群取舍

集群特性：3 节点 ARM64（node4 控制面 / node3、node5 工作节点），Cilium 替代 kube-proxy，装有 Argo Rollouts、ESO（`ClusterSecretStore openbao` Ready，`vault` 当前 InvalidProviderConfig）、cert-manager、CNPG。

| 上游默认 | 本集群 | 原因 |
|---|---|---|
| `autoReloadAll: false` | 保持 false | 见 §2 第一条；CNPG 每 90 天续 CA、cert-manager 续证书，都不该滚业务 Pod |
| `isArgoRollouts: false` | **true**（CRD 不存在时 install.sh 自动关） | 集群装了 Argo Rollouts，将来灰度发布的对象也是 Rollout |
| `ignoreJobs/ignoreCronJobs: false` | **true** | Secret 变了不该重跑一次性任务（harvest 将来若做成 Job 更不能被它触发） |
| `reloadStrategy: default`（env-vars） | **annotations** | 不往业务容器注入额外环境变量；与 `kubectl rollout restart` 留下的痕迹一致，排障时不用学第二种 |
| `reloadOnCreate/Delete: false` | 保持 false | ESO 首次物化时工作负载还没起；删除更不该滚 |
| `ignoreNamespaces` 空 | `kube-system,cert-manager,external-secrets,openbao,trust-system` | 控制面 Secret 一律不看，缩小 watch 面 |
| `resources: {}` | 10m/32Mi – 100m/128Mi | 上游不给 requests，调度评分失真（ecommerce TECH §7.3）；实测常驻 <30Mi |
| 无 `readOnlyRootFilesystem` | true + drop ALL | 纯控制器，没有写盘需求 |
| `logFormat: ""` | json | Vector/VictoriaLogs 按 JSON 解析 |

## 4. 暴露方式

- 无对外入口。`EXPOSE=none`，无 Gateway 资源。
- 指标：Pod 注解 `prometheus.io/scrape: "true"`、`:9090/metrics`，由现有 vmagent 按注解抓取。
- 集群内地址（只有指标）：`reloader-reloader.reloader.svc:9090`。

接入某个工作负载：

```bash
# 点名(推荐): 只盯这一个 Secret
kubectl -n dragonfly annotate deploy/dragonfly secret.reloader.stakater.com/reload=dragonfly-password-secret
# dragonflydb 的 chart 只有 podAnnotations, 其 install.sh 末尾用 kubectl annotate 打在 Deployment 上(metadata 合并, 与 helm 不冲突)
```

## 5. 验证

「Pod Running」不算验证。跑自检：建临时 Secret + 带注解的 Deployment，改 Secret 值，断言 60 秒内 `observedGeneration` 递增且新 Pod 读到新值：

```bash
bash components/reloader/examples/selftest.sh
# → ✔ Reloader 自检通过: generation 1 → 2, 新 Pod PASSWORD=v2   (机房集群 2026-09-11 实测通过后已卸载, 开关保持关)
```

真实链路验证（P1 之后）：在 OpenBao 改 `k8s/<集群>/dragonfly` 的 `password`，等 ESO 刷新（或 `kubectl annotate externalsecret ... force-sync=$(date +%s)`），看 `kubectl -n dragonfly rollout history deploy/dragonfly` 多出一版，再跑 `tools/config-center-harvest.sh` 把消费方跟上。

## 6. 踩坑

- **加了注解却不滚动**：先确认 Secret 真的变了（`kubectl get secret -o yaml | sha256sum` 前后对比）——ESO 值没变时不会写 Secret。再看 Reloader 日志里有没有 `Changes detected`；没有多半是 `ignoreNamespaces` 把这个 ns 排除了，或注解写在了 Pod 模板上（必须在 **Deployment 的 metadata**）。
- **滚动了但 Pod 还是旧值**：应用把 Secret 挂成文件并缓存了内容，或者密码只在首次初始化时读（Grafana/Harbor/Bugsink 这类，见 TODO「借机轮换的边界」）。Reloader 只负责重启，不负责应用语义。
- **chart fullname 是 `<release>-reloader`**，READY_CHECK 与 install.sh 里的 `rollout status` 都按这个名；改 `RELEASE` 要同步。
- **`isArgoRollouts: true` 而 CRD 不存在**会让控制器启动即报错；install.sh 检测 CRD 后自动关闭，手工 helm 装时别忘。
- **升级 Reloader 本身不会触发任何滚动**（`syncAfterRestart: false`）；要重放一次就临时开它，或者对目标 `kubectl rollout restart`。
