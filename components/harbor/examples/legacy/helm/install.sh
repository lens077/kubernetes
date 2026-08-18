#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail
# https://github.com/container-registry/harbor-next
# https://github.com/goharbor/harbor-helm

# 是否启用 TLS。当禁用 TLS 且 expose.type 为 ingress 时，删除 expose.ingress.annotations 中的 ssl-redirect 注释。
# 注意：如果 expose.type 为 ingress 且禁用 TLS，则在拉取/推送镜像时，命令中必须包含该端口。
# 有关详细信息，请参阅 goharbor/harbor#5291 。

helm repo add harbor https://helm.goharbor.io

helm upgrade --install harbor harbor/harbor \
  --reuse-values \
  -n harbor \
  --create-namespace \
  --set expose.type=ingress \
  --set harborAdminPassword=Harbor12345 \
  --set expose.tls.enabled=auto \
  --set externalURL=core.fin-mermaid.ts.net \
  --set expose.clusterIP.annotations."tailscale\.com/expose"=true \
  --set expose.ingress.className=tailscale

