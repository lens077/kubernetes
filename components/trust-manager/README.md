# trust-manager

**定位**：把 cert-manager 的 global-root-ca 以 Bundle 分发为各 ns 的 ConfigMap（TECH-RADAR §4 定稿；用户拍板）。
**上游**：jetstack/trust-manager v0.24.0（实测 2026-08-20）。
**本集群取舍**：trust ns=cert-manager（source Secret 所在地）；只出 ConfigMap（secretTargets 关，最小权限）；defaultPackage 关（只发私有 CA，需要公有 CA 另建 Bundle）。
**验证**：`kubectl create ns trust-test && kubectl -n trust-test get cm global-root-ca -o jsonpath='{.data.ca\.crt}' | head -3`。
**踩坑**：source Secret 必须在 app.trust.namespace；消费侧用 subPath 挂载，别整卷盖 /etc/ssl/certs。
