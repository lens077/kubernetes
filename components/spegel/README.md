# Spegel（试装）

**定位**：节点间 P2P 镜像缓存（TECH-RADAR §9 定稿：第 3 节点触发条件命中后由观察转试装；3 节点并发拉 TCR 可省 2/3 WAN）。
**上游**：oci://ghcr.io/spegel-org/helm-charts/spegel v0.7.4（实测 2026-08-20）。
**本集群取舍**：两节点期收益=单邻居，试装保留直连仓库回退（containerdMirrorAdd 卸载即除）。**已验证（2026-08-20）**：containerd 2.3.4 + `use_local_image_pull=false` 下 hosts.toml mirror 生效——同镜像 node1 首拉 8.811s → node2 102ms（86×），`spegel_mirror_requests_total{cache="hit"}` docker.io=1、TCR=2；无需改节点配置。若未来 containerd 升级后命中掉 0，再查 `use_local_image_pull` 开关。
**验证**：seed-and-probe——node1 起 pod 拉全新镜像（首拉走公网）→ 删 pod → node2 起 pod 拉同镜像，对比 `kubectl describe pod` 的 Pulled 用时；铁证=各 pod IP 的 `:9090/metrics` 里 `spegel_mirror_requests_total{cache="hit"}` 递增。
