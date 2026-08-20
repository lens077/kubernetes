# OpenFGA

**定位**：ReBAC 资源关系授权（TECH-RADAR §4 定稿；用户拍板）。边界=网关 Casbin 管路由粗闸不动，FGA 管「商家-店铺-商品-操作员」，禁止网关热路径远程 check；首接 merchant 域影子双跑。
**上游**：openfga/openfga chart 0.3.12 / app v1.18.3（实测 2026-08-20，arm64 有）。
**本集群取舍**：2 副本软反亲和；store=CNPG pg-main 独立库（DatabaseRole+Database CR，连接池上限 20 防挤业务池）；migrate 走 chart 的 `migrationType: job`；测试期 `sslmode=require`——**生产化改 verify-ca**：URI 加 `sslrootcert`，chart 的 extraVolumes/extraVolumeMounts 挂 postgresql ns 的 pg-main-ca（migrate job 同样要挂）。
**验收线（T5）**：check p95≤15ms / p99 25ms 目标 / 50ms 熔断；失败分级=降级只准缩小授权集。
**验证**：`bash examples/smoke.sh`（期望 `{"allowed":true}`）。
