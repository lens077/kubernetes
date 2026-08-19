# vpa —— Vertical Pod Autoscaler（只装 recommender）

## 1. 定位

给「这个容器到底该配多少 CPU/内存」提供**实测依据**，替代拍脑袋。
本仓 [TODO.md](../../TODO.md) 里多处写着「resources 取值待 VPA 校准」
（kafka-connect 的 1Gi/`-Xmx768m` 就是按一次实测 RSS 拍的），这个组件就是那件事的落地。

**只装 recommender：出推荐值，不碰任何 Pod。**改 `resources` 是人的动作，
看完推荐值自己改进 values/CR 再滚动更新。

不装的后果：没有历史用量模型，`resources` 只能靠 `kubectl top` 的瞬时值猜。

## 2. 上游最佳实践

来源：[VPA installation](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/installation.md)、
[features](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/features.md)（2026-08 复核，VPA 1.7.1）

- VPA 由三个独立二进制组成：**recommender**（算推荐值）、**updater**（驱逐待更新的 Pod）、
  **admission-controller**（webhook，在 Pod 创建时改规格）。recommender 可**单独运行**。
- `updateMode: Off` 时后两者完全无用武之地——这正是「只要推荐值」场景。
- **`updateMode: Auto` 自 1.5 起 deprecated**，别再照旧文档写。
- K8s 1.35 起 in-place pod resize 已 GA、VPA 1.6 起 `InPlaceOrRecreate` GA，
  但仍需装 updater + admission-controller。
- **CRD 不随 `helm upgrade` 更新**（helm 的既定行为），升版本要手动 apply 新 CRD。
- 硬依赖 metrics-server（实时用量来源）。
- **不兼容 pod-level `resources`**（K8s 1.34+ 的新写法），用了的工作负载别挂 VPA。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| 三组件全装 | **只装 recommender** | 关掉 admission-controller 就没有 webhook——连带整个证书链（certgen job / cert-manager 签发 / CA 注入）和「webhook 挂了导致全集群 Pod 创建失败」的经典事故一起消失。关掉 updater 就没人驱逐 Pod：单控制面集群里自动驱逐的风险远大于收益。 |
| 各组件 `replicas: 2` | **1** | 两节点集群，第二个副本只是占内存；recommender 挂了最多是推荐值停止更新，不影响任何工作负载。 |
| `podDisruptionBudget.enabled: true` | **false** | 单副本 + `minAvailable: 1` 会让节点永远排空不掉，与 [kured](../kured/) 的自动重启窗口直接打架。 |
| 无 resources 默认值 | requests 50m/200Mi，limits.memory 500Mi | recommender 在内存里为每个容器建直方图模型，Pod 越多越涨，必须给上限。 |
| chart 自动跟最新 | 钉 `VPA_CHART_VERSION`（0.11.0 / app 1.7.1） | 官方 chart README 至今写着 "under development"；只装 recommender 风险面虽小，版本仍要可控。 |

> chart 的官方仓库是 `https://kubernetes.github.io/autoscaler`（SIG Autoscaling 维护）。
> 旧 `hack/vpa-up.sh` 脚本用 openssl 现场生成证书 + kubectl 直插 kube-system，不适合本仓的
> 幂等/可重跑模型，已弃用（archive 里的旧 install.sh 就是那个路子）。

## 4. 暴露方式

无对外端点。推荐值经 VPA CR 的 status 读取：

```bash
kubectl get vpa -A                              # 概览：MODE / CPU / MEM / PROVIDED
kubectl -n <ns> describe vpa <name>             # 四档推荐值明细
```

## 5. 验证

```bash
kubectl -n kube-system get deploy vpa-vertical-pod-autoscaler-recommender   # READY 1/1
kubectl get crd verticalpodautoscalers.autoscaling.k8s.io
```

真验证（挂一个 CR，看它是否真的产出推荐值）：

```bash
kubectl apply -f components/vpa/examples/vpa-off-mode.yaml
sleep 60
kubectl get vpa -A                              # PROVIDED 应为 True
kubectl -n observability describe vpa grafana | sed -n '/Recommendation/,$p'
```

> **实测结论（2026-08-18）**：recommender 起来约 1 分钟后，`grafana` 与 `pg-main`
> 两个 CR 的 `PROVIDED=True`，四档推荐值（Lower Bound / Target / Uncapped Target /
> Upper Bound）齐全；`resourcePolicy.minAllowed` 生效可见——grafana 的
> Uncapped Target 12m 被抬到 Target 25m。CNPG 的 `Cluster` 直接作 targetRef 可用。

推荐值怎么读：

| 档位 | 含义 | 怎么用 |
|---|---|---|
| **Target** | 推荐的 requests | 直接抄进 `resources.requests` |
| Lower Bound | 低于它会明显影响性能 | 压成本时的下限 |
| Upper Bound | 再高就是浪费 | 设 limits 的参考上界 |
| Uncapped Target | 忽略 min/maxAllowed 的原始推荐 | 判断你的边界是否卡住了推荐 |

## 6. 踩坑

- **推荐值要"养"**：recommender 按滑动窗口建直方图，**至少一天**才有参考价值，一周更稳。
  刚 apply 完 status 是空的，别当成坏了。
- **推荐值反映的是"当前配置下的行为"**：TODO.md 里 kafka-connect 那条踩过——
  给它挂 VPA 时 `resources` 根本没应用到集群，于是 VPA 观察到的是**无 limit 状态**下的
  用量，推荐值不能用来校准有 limit 的配置。**先确认目标负载的现状与文件一致**（`kubectl diff`）。
- **CNPG 只能 `updateMode: Off`**（官方明令）：算子视 `spec.resources` 为真相源，
  VPA 改了会被顶回；驱逐又被 primary PDB 挡住导致 stall。
- **`kubectl get vpa` 的 MEM 列可能是裸字节数**（如 `351198544`）：那是没有取整的原始值，
  `describe` 里同样，除以 1048576 换算成 MiB 自己判断。
- **升级 chart 后行为不变**：CRD 没跟着升。按 install.sh 注释里的命令手动 `apply --server-side`。
- **别装 updater/admission-controller 后忘了改 CR**：一旦 admission-controller 就位，
  `updateMode` 不是 `Off` 的 CR 会立刻开始改 Pod 规格——这是"装了个观察工具"到
  "它开始动我的集群"的静默跨越。
