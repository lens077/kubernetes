# Dragonfly

集群内 ecommerce 缓存，替代业务侧 Redis。仅用于可丢缓存，不承载锁、幂等键或领域真相。

- Chart：Dragonfly `v1.39.0`
- Namespace：`dragonfly`
- Service：`dragonfly.dragonfly.svc:6379`
- 协议：TLS-only + AUTH
- 存储：`openebs-lvm`，2Gi
- 外部 L4：独立 Cilium `Gateway`/`TCPRoute`，VIP `10.10.31.242:6379`
- Secret：`dragonfly-auth`（只在集群 Secret/本地 credentials 中，不能提交明文）
- 证书：cert-manager `global-ca-issuer`，Secret `dragonfly-tls`

Pangolin/remote-dev 资源必须指向 `10.10.31.242:6379`，并保留 TLS passthrough；公网域名和
resource id 由 Pangolin 面板创建后再写入 Config Center，不把未知域名写入仓库。
