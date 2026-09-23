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
