# mcm-site

MCM 宣传页（纯静态 Astro 产物），原部署在 node1 docker（`/home/docker/mcm-site`，挂 `pangolin_frontend` 网络），
2026-10-28 迁入集群，复刻 blog 的暴露方式：cilium-gateway 终结 TLS，HTTPRoute 按 `pyxis.apikv.com` 分发。

- 对外域名：`pyxis.apikv.com`（Pangolin 资源名 `mcm`，SSO 登录墙在 Pangolin 侧配置，迁移不动它）
- 镜像：`ccr.ccs.tencentyun.com/sumery/mcm-site:<tag>`，内容由 node1 `site/` 目录打进镜像（构建时剔除 macOS `._*` 伴随文件）
- 回滚：Pangolin 把目标从 `k8s-cluster` 切回 `node1-local`（mcm-site:80）即可；node1 compose 栈保留未删

## 更新内容

1. 改 `node1:/home/docker/mcm-site/site/`
2. node1 上 `docker build -t ccr.ccs.tencentyun.com/sumery/mcm-site:vYYYYMMDD . && docker push ...`
3. 改本目录 `component.env` 的 `MCM_IMAGE`，重跑 `bash components/mcm-site/install.sh`
