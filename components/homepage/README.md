# homepage

d.apikv.com 总控制台（静态页 + 遥测只读代理），原部署在 node1 docker（`/home/docker/homepage`，挂 `pangolin_frontend` 网络），
2026-10-28 迁入集群，复刻 blog 的暴露方式：cilium-gateway 终结 TLS，HTTPRoute 按 `d.apikv.com` 分发。

- 对外域名：`d.apikv.com`（Pangolin 资源 `d-console`，SSO 登录墙在 Pangolin 侧，迁移不动它）
- 镜像：`ccr.ccs.tencentyun.com/sumery/homepage:<tag>` = 官方 nginx + `site/` + `nginx/templates/`；
  模板里 docker DNS resolver(127.0.0.11) 构建时替换为 kube-dns，envsubst 由 nginx 官方 entrypoint 完成
- 遥测代理：`/t/*.json` → `https://metrics.apikv.com`（vmauth 只读 token）。token 真相源是集群
  secret `victoriametrics/vmauth-credentials` 的 `read-token`，install.sh 现取物化成 `sites/homepage-secret`
- 回滚：Pangolin 把目标从 `k8s-cluster` 切回 `node1-local`（homepage:80）即可；node1 compose 栈保留未删
