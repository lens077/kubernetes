# Dragonfly

集群内 ecommerce 缓存，替代业务侧 Redis。仅用于可丢缓存，不承载锁、幂等键或领域真相。

- Chart：Dragonfly `v1.39.0`
- Namespace：`dragonfly`
- Service：`dragonfly.dragonfly.svc:6379`
- 协议：TLS-only + AUTH
- 存储：`openebs-lvm`，2Gi
- 外部 L4：独立 Cilium `Gateway`/`TCPRoute`，VIP `10.10.31.242:6379`
- Secret：`dragonfly-auth`，由 ESO 从 OpenBao `k8s/<集群>/dragonfly` 物化（`externalsecret.yaml`）；OpenBao 不可用时 `install.sh` 退回 `get_cred`。首次迁移 `tools/openbao-seed.sh dragonfly`（取现值），轮换 `--rotate dragonfly`
- 证书：cert-manager `global-ca-issuer`，Secret `dragonfly-tls`

## remote-dev（开发机不在机房 LAN）

Pangolin raw TCP 资源 `redis-dev`（resourceId 59，proxyPort 30005）→ site `k8s-cluster` → `10.10.31.242:6379`，TLS 直通。
契约字段在 `component.env`（`REMOTE_HOST=redis-dev.apikv.com` / `REMOTE_PORT=30005` / `REMOTE_CA=private`），
证书 SAN 含 `redis-dev.apikv.com`，客户端必须带私有根 CA 并做主机名/SNI 校验。2026-09-22 Mac 实测：

```bash
redis-cli --tls --cacert <global-root-ca> --sni redis-dev.apikv.com -h redis-dev.apikv.com -p 30005 PING   # PONG
# 错密码 → WRONGPASS; 错 CA → certificate verify failed
```

旧 `components/dragonflydb`（6380、`dragonfly-password-secret`、node4 site）是集群重建前的形态；`CC_PROVIDERS` 已把
`redis` 指到本组件。

## 节点 iowait / IO pressure 虚高（io_uring 记账，不是磁盘繁忙）

2026-09-29 排查 k3 `/proc/pressure/io` 长期 `some≈65% full≈55%`，而磁盘 `sda` 利用率约 5%。定位结果：

| 证据 | 值 |
|---|---|
| IO pressure 最高的 cgroup | Pod `dragonfly/dragonfly-0`，`some avg60≈95%`；其它 Pod 均 < 1% |
| 该 Pod 实际磁盘 IO（`io.stat`） | 写 0 字节，读累计 157MB（启动加载），无持续 IO |
| 线程状态 | `Proactor0` 常驻 `S` 状态，`wchan=io_cqring_wait`（等 io_uring 完成事件，即等网络请求） |
| `delayacct_blkio_ticks` 5 秒增量 | 0（没有真实块设备等待） |
| `/proc/stat procs_blocked` | 连续 6 秒恒为 1 |
| k3 CPU `state=wait` | 24%（4 核中 1 个线程一直记为 iowait）；k1 0.2%、k2 2% |

Dragonfly v1.39 默认用 io_uring，只有 1 个 proactor 线程（CPU limit 250m）。内核 7.0 把这个线程等待完成事件的时间记成 iowait，
于是节点 PSI io 与 CPU iowait 一直虚高。这不影响性能，但会误导排障：CPU「使用率」若按 `1 - idle` 算，k3 从 15% 虚报到 38%；
以 IO pressure 做判断的告警或容量评估也会误判。

已做：运维控制台和 `vmalert/rules/cloud-hosts.yml` 的 CPU 使用率改为 `1 - (idle + wait)`。
可选：给 Dragonfly 加 `--force_epoll` 改用 epoll（官方 flag，本版本支持），记账随之恢复正常；需要滚动重启 `dragonfly-0`，
单副本会短暂断连，先确认下游（control-tower BFF 会话等）能容忍再做。
