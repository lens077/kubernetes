#!/usr/bin/env bash
# =============================================================================
# _external/apply.sh —— 为每个启用的集群外依赖(_external/<id>/component.env, EXTERNAL=true)
# 建 ExternalSecret, 让 ESO 把 OpenBao/Vault k8s/<CLUSTER_NAME>/<id> 物化成 Secret external/<id>。
#   bash components/_external/apply.sh            # 全部启用项
#   bash components/_external/apply.sh postgres-node3
# 80 阶段在校验契约之前调用它。OpenBao 里还没有这条路径时 ExternalSecret 会停在 SecretSyncedError,
# 用 tools/openbao-seed.sh 先播种。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
comp_require_cluster

enabled_by_config() { local var=$1 def=$2; if [[ -n $var && -n ${!var:-} ]]; then [[ ${!var} == true ]]; else [[ $def == true ]]; fi; }

if ! eso_store_ready; then
  die "ClusterSecretStore ${ESO_STORE:-openbao} 未就绪(OpenBao sealed? token 过期?), 外部依赖的凭据无法物化"
fi

want=("$@")
fail=0
for d in "$HERE"/*/; do
  [[ -f $d/component.env ]] || continue
  comp_load_meta "${d%/}"
  [[ $EXTERNAL == true ]] || continue
  (( ${#want[@]} )) && { printf '%s\n' "${want[@]}" | grep -qx "$ID" || continue; }
  enabled_by_config "${CONFIG_VAR:-}" "${DEFAULT_ENABLED:-false}" || { log_skip "$ID 未启用"; continue; }
  [[ -n $CRED_SECRET || -n $CA_REF ]] || { log_skip "$ID 没有凭据/CA 声明(纯地址), 不需要物化"; continue; }
  ns_ensure "$NAMESPACE" >/dev/null
  out=$(mktemp); render_tpl "$HERE/externalsecret.tpl.yaml" "$out" ID
  retry 3 5 kctl apply -f "$out" >/dev/null; rm -f "$out"
  eso_force_sync "$NAMESPACE" "$ID"
  if wait_for "ESO 物化 $NAMESPACE/$ID" 60 _es_synced "$NAMESPACE" "$ID"; then
    log_ok "$ID: Secret $NAMESPACE/$ID 已物化(键: $(kctl -n "$NAMESPACE" get secret "$ID" -o jsonpath='{.data}' | jq -r 'keys|join(" ")'))"
  else
    log_warn "$ID: 未同步 → $(kctl -n "$NAMESPACE" get externalsecret "$ID" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)
  先播种: bash tools/openbao-seed.sh $ID"
    fail=1
  fi
done
exit $fail
