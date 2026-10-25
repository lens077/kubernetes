#!/usr/bin/env bash
# =============================================================================
# ArgoCD 暴露模式：tls
#   argocd-server 自己出 TLS（去掉 --insecure），网关只做 SNI 透传、不解密。
#
#   bash components/argo/mode-tls.sh             # 切换
#   bash components/argo/mode-tls.sh --dry-run   # 只渲染清单，不动集群
#
# 为什么要单独一个 Gateway：共享网关的 443 已被 HTTPS/Terminate 占用，同一 Gateway
# 里再放 TLS/Passthrough 抢同一端口是非法的（见 components/gateway/README.md）。
#
# 顺序不能反：
#   先建 passthrough 入口 → 再让 server 出 TLS → 最后撤明文路由。
#   反了就是「网关把 TLS 打到明文口」，整站 502。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

CLI_HOSTNAME=${CLI_HOSTNAME:-argocd-api.dev.test}
GW=argo-passthrough-gateway
DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1

log_step "ArgoCD → TLS 模式（SNI: $HOSTNAME / $CLI_HOSTNAME）"

# 1) passthrough 入口：新 Gateway 自己去 LB 池领 VIP，不碰共享网关。
out=$(mktemp -d)
render_tpl "$DIR/gateway/tls/tlsroute.yaml" "$out/tlsroute.yaml" CLI_HOSTNAME
if [[ $DRY == 1 ]]; then
  cat "$out/tlsroute.yaml"
  rm -rf "$out"
  log_skip "--dry-run：未改集群"
  exit 0
fi
kctl apply -f "$out/tlsroute.yaml"
rm -rf "$out"

# 2) argocd-server 出 TLS。两处必须一起改，否则 Pod 起不来：
#    a) server.insecure=false  ← 让 8080 出 TLS
#    b) 探针 scheme HTTP→HTTPS ← kubelet 的 HTTPS 探针不校验证书，自签不影响；
#       只改 a 不改 b，探针会拿明文打 TLS 端口，3×10s 后 liveness 杀掉 Pod。
kctl -n "$NAMESPACE" patch deploy argocd-server --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/scheme","value":"HTTPS"},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/scheme","value":"HTTPS"}
]' >/dev/null
kctl -n "$NAMESPACE" patch cm argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"false"}}'
kctl -n "$NAMESPACE" rollout restart deploy argocd-server >/dev/null
kctl -n "$NAMESPACE" rollout status deploy argocd-server --timeout=180s

# 3) 撤明文路由：同一个 hostname 不能同时挂在 terminate 和 passthrough 上。
#    argocd / argocd-redirect 是本组件 HTTP 模式建的；后两个是更早清单留下的名字。
kctl -n "$NAMESPACE" delete httproute "$RELEASE" "$RELEASE-redirect" \
  argocd-server-route argocd-api-http --ignore-not-found >/dev/null

# 4) 等 Gateway 拿到 VIP、TLSRoute 被接受
kctl -n "$NAMESPACE" wait --for=condition=Programmed "gateway/$GW" --timeout=120s
for r in "$RELEASE-ui" "$RELEASE-api"; do
  st=$(kctl -n "$NAMESPACE" get tlsroute "$r" \
    -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status} {end}{end}' 2>/dev/null || true)
  [[ $st == *"Accepted=True"* ]] \
    || log_warn "TLSRoute/$r 尚未 Accepted（$st）——检查 hostnames 与客户端 SNI 是否一致"
done

VIP=$(kctl -n "$NAMESPACE" get gateway "$GW" -o jsonpath='{.status.addresses[0].value}')
[[ -n $VIP ]] || die "Gateway $GW 还没分配到 VIP：看 kubectl -n $NAMESPACE get gateway $GW -o yaml 的 status"

log_ok "TLS 模式就绪：$VIP:443（SNI $HOSTNAME / $CLI_HOSTNAME）"
cat <<EOF

Pangolin 侧（两个资源都要改）：
  1) 资源 argocd     → 目标 https://$VIP 端口 443，开「启用 TLS」，TLS 服务器名称 = $HOSTNAME
  2) 资源 argocd-api → 目标 https://$VIP 端口 443，开「启用 TLS」，TLS 服务器名称 = $CLI_HOSTNAME
     （CLI 也可直连 argocd-server.argocd.svc.cluster.local:443，对端是自签证书，
      同样要开 TLS + 跳过校验，少一跳网关）
  面板上填了 TLS 服务器名称后，Pangolin 会自动生成
  serversTransport{serverName, insecureSkipVerify:true}，Argo 的自签证书不用另配 CA。

LAN/内网访问：
  argocd.dev.test 现在指向旧网关 10.10.31.240，必须改成 $VIP（DNS 或 /etc/hosts），
  否则浏览器会打到没有路由的旧 VIP。域名解析不在本仓库管理，这一步要手工做。

验证：
  openssl s_client -connect $VIP:443 -servername $HOSTNAME </dev/null 2>/dev/null \\
    | openssl x509 -noout -subject          # 期望 argocd-server 自签证书
  argocd login argocd-api.apikv.com --username admin   # 原生 gRPC，不再需要 --grpc-web
EOF
