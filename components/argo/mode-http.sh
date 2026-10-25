#!/usr/bin/env bash
# =============================================================================
# ArgoCD 暴露模式：http（本集群原状，也是 tls 模式的回退路径）
#   argocd-server 跑 --insecure 走明文，TLS 由共享网关 cilium-gateway 终结。
#
#   bash components/argo/mode-http.sh             # 切换/回退
#   bash components/argo/mode-http.sh --dry-run   # 只渲染清单，不动集群
#
# 代价：8080 只说 HTTP/1.1，原生 gRPC 不可用，CLI 必须加 --grpc-web。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"

DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

CLI_HOSTNAME=${CLI_HOSTNAME:-argocd-api.dev.test}
GW=argo-passthrough-gateway
DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1

# 与 mode-tls.sh 同一份逻辑：--insecure 只能靠改 Deployment args 来加/删，
# cmd-params-cm 里的 server.insecure 对写死的命令行 flag 无效（2026-10-25 实测）。
insecure_patch() {  # insecure_patch <add|remove>  → 输出 JSON patch（无变化时输出 []）
  local want=$1 cur idx
  cur=$(kctl -n "$NAMESPACE" get deploy argocd-server -o json | jq -c '.spec.template.spec.containers[0].args // []')
  idx=$(jq -r --arg a "--insecure" 'to_entries[] | select(.value==$a) | .key' <<<"$cur" | head -1)
  case $want in
    remove) [[ -n $idx ]] || { echo "[]"; return; }
            echo "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$idx\"}]" ;;
    add)    [[ -z $idx ]] || { echo "[]"; return; }
            echo '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' ;;
  esac
}

log_step "ArgoCD → HTTP 模式（共享网关终结 TLS）"

# 0) 先渲染，--dry-run 到此为止（不写集群、不重启）
out=$(mktemp -d)
render_tpl "$DIR/gateway/http/httproute.yaml" "$out/httproute.yaml" CLI_HOSTNAME
if [[ $DRY == 1 ]]; then
  cat "$out/httproute.yaml"
  rm -rf "$out"
  log_skip "--dry-run：未改集群"
  exit 0
fi

# 1) 先撤 passthrough 入口，避免 TLS 客户端继续命中一个即将变回明文的后端。
kctl -n "$NAMESPACE" delete tlsroute "$RELEASE-ui" "$RELEASE-api" --ignore-not-found >/dev/null
kctl -n "$NAMESPACE" delete gateway "$GW" --ignore-not-found >/dev/null

# 2) server 回到明文（网关解密后必须以明文回源，否则重定向死循环）
#    探针 scheme 也要一起改回 HTTP，理由见 mode-tls.sh。
args_patch=$(insecure_patch add)
[[ $args_patch == "[]" ]] || kctl -n "$NAMESPACE" patch deploy argocd-server --type=json -p "$args_patch"
kctl -n "$NAMESPACE" patch deploy argocd-server --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/scheme","value":"HTTP"},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/scheme","value":"HTTP"}
]' >/dev/null
kctl -n "$NAMESPACE" patch cm argocd-cmd-params-cm --type=merge \
  -p '{"data":{"server.insecure":null}}' >/dev/null
kctl -n "$NAMESPACE" rollout restart deploy argocd-server >/dev/null
kctl -n "$NAMESPACE" rollout status deploy argocd-server --timeout=180s

# 3) 应用明文路由（共享网关 terminate → Service port 80）
kctl apply -f "$out/httproute.yaml"
rm -rf "$out"

log_ok "HTTP 模式就绪：https://$HOSTNAME（共享网关终结 TLS）"
cat <<EOF

Pangolin 侧（两个资源都要改）：
  1) 资源 argocd     → 目标 https://${CILIUM_GATEWAY_LB_IP:-10.10.31.240} 端口 443，
                       开「启用 TLS」，TLS 服务器名称 = $HOSTNAME
  2) 资源 argocd-api → 目标 http://argocd-server.argocd.svc.cluster.local 端口 80，
                       或 （要原生 gRPC 就别用本模式，用 mode-tls.sh）

验证：
  curl -sk -o /dev/null -w '%{http_code}\\n' https://$HOSTNAME/   # 期望 200
  argocd login argocd-api.apikv.com --username admin --grpc-web  # 本模式必须带 --grpc-web
EOF
