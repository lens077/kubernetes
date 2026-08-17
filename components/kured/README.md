# kured —— 维护窗口内自动重启节点

## 1. 定位

`unattended-upgrades` 只装安全补丁、不重启（配置在 `bootstrap/scripts/10-system-base.sh`）。
内核补丁要生效必须重启，kured 负责把「重启」这件事挪到维护窗口内，并做排空/解除排空。

## 2. 上游最佳实践

来源：[kured 文档](https://kured.dev/)

- 靠哨兵文件 `/var/run/reboot-required` 判断是否需要重启。
- `--reboot-days` / `--start-time` / `--end-time` / `--time-zone` 限定窗口。
- 集群里同一时刻只有一个节点重启（内置锁，通过 DaemonSet 注解协调）。
- 可配 Slack/飞书通知与重启前后钩子。

## 3. 本集群取舍

| 上游默认/建议 | 本集群 | 原因 |
|---|---|---|
| `forceReboot: false` | **true** | 单节点/两节点集群里 PDB 很容易挡住排空（比如只有一个副本的组件），不强制就会永远卡在 drain。 |
| 全天可重启 | 03:00–05:00 窗口 | `config.env` 的 `KURED_REBOOT_WINDOW_*`。 |
| 通知未配 | 暂缺 | 告警统一规划：先只在 Grafana UI 看，后续接飞书 webhook。 |

## 4. 暴露方式

不暴露。

## 5. 验证

```bash
kubectl -n kube-system get ds kured                      # DESIRED == READY
kubectl -n kube-system logs ds/kured | tail -5           # 应看到窗口配置与轮询
```

真验证（**会真的重启节点，慎用**）：

```bash
# 在某个节点上人为制造哨兵文件，等窗口到来后观察它被排空并重启
sudo touch /var/run/reboot-required
```

## 6. 踩坑

- **节点一直不重启**：先看是不是不在窗口内；再看 `/var/run/reboot-required` 是否存在。
- **卡在 drain**：`forceReboot: false` 时被 PDB 挡住。本集群已设 true。
- **重启后 Pod 长时间 Pending**：本地 LVM 卷有节点亲和，重启期间用到这些卷的组件无法漂移
  ——这是本地存储的固有代价，不是 kured 的问题。
