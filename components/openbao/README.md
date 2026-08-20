# OpenBao（+ ESO 接线）

**定位**：专职凭据后端（TECH-RADAR §4 定稿：ESO+OpenBao；LF 治理，替 BSL 的 Vault）。次序纪律=治理修订(AGENTS.md 硬规则4)合入前，业务凭据不迁入，本部署仅验证链路。
**上游**：openbao/openbao chart 0.29.2 / app v2.6.2（实测 2026-08-20，arm64 有）。
**本集群取舍**：standalone+file 单副本（raft 的价值在多副本 HA，测试不引）；init 1-share/1-threshold（**测试取舍**，生产应提高并离线保管）；init 输出与 ESO token 落 STATE_DIR/creds 不进 git；ESO 用 eso-read 只读 token（root token 只用于初始化）；**pod 重启后需手工解封** `examples/unseal.sh`。
**验证**：`kubectl -n default get externalsecret demo-from-openbao`（Ready=True）+ `kubectl -n default get secret demo-from-openbao -o jsonpath='{.data.username}' | base64 -d` = demo。
**生产化清单**：TLS listener（挂 global-ca-issuer 证书）、kubernetes auth 替 token、auto-unseal、审计日志。
