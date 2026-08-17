# infra —— 集群底座（**由 bootstrap 安装，这里只是参考**）

> [!WARNING]
> **不要直接执行这些目录里的安装脚本。** Cilium、OpenEBS、LoadBalancer 都由
> `bootstrap/` 的 60/70 阶段负责安装，参数来自 `bootstrap/config.env`。
> 在这里再跑一遍旧脚本会用另一套参数覆盖集群配置（典型后果：Cilium values 被
> 换掉导致 KPR/netkit 失效、LVM 卷组被重建）。

| 目录 | 谁负责安装 | 这里放什么 |
|---|---|---|
| `cilium/` | `bootstrap/scripts/60-cilium.sh` | 排查脚本、连通性测试、Hubble 笔记、历史 values 对照 |
| `openebs/` | `bootstrap/scripts/70-storage.sh` | LVM 卷组操作、StorageClass/PVC 示例、清理脚本 |
| `loadbalancer/` | Cilium 自带 L2 通告（`bootstrap/config.env` 的 `CILIUM_LB_POOL_*`） | OpenELB / PureLB 两种**替代方案**，当前未启用 |

要改这三者的配置，改 `bootstrap/config.env` 后重跑对应阶段：

```bash
sudo bash bootstrap/start.sh --only 60-cilium     # 或 70-storage
```

集群之上的组件（可观测、数据库、网关路由等）在 [`../components/`](../components/)。
