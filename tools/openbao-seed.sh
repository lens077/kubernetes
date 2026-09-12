#!/usr/bin/env bash
# =============================================================================
# openbao-seed.sh —— 把凭据的真相源搬进 OpenBao(k8s/<CLUSTER_NAME>/<id>), 一次性迁移 + 轮换入口
#
#   bash tools/openbao-seed.sh                       # 全部: 集群内组件取现值(不改密码) + 外部依赖从 Config Center 现值抽取
#   bash tools/openbao-seed.sh dragonfly grafana     # 只播种这些
#   bash tools/openbao-seed.sh --rotate dragonfly    # 生成新随机密码写入(只允许「每次启动都读 Secret」的组件)
#   bash tools/openbao-seed.sh --dry-run             # 只打印将写哪些路径/键(值脱敏), 不写
#
# 值的来源(优先级): --rotate 新随机 > 集群现有 Secret(运行中的值, 零行为变化) > $STATE_DIR/creds/<name> > 新随机。
# 外部依赖(postgres-node3/casdoor/elasticsearch-node3)的来源是 Config Center 里的现值
# (tools/config-center/harvest.py --extract-externals), 顺带把 casdoor 的非机密固定值写进 overrides.yaml。
#
# 写入方式: kubectl exec openbao-0 -- bao kv put ... -(JSON 走 stdin, 不进参数、不落盘)。
# 需要写权限 token: BAO_TOKEN 环境变量, 或 $STATE_DIR/creds/openbao-init 里的 root token(节点上)。
# 播种之后: bash components/_external/apply.sh && 重跑各组件 install.sh(切到 ESO) && tools/config-center-harvest.sh
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" &>/dev/null && pwd)/env.sh"
TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
comp_require_cluster
[[ -n ${CLUSTER_NAME:-} ]] || die "config.env 未定义 CLUSTER_NAME"

ROTATE=0 DRY=0; want=()
while (($#)); do case $1 in --rotate) ROTATE=1;; --dry-run) DRY=1;; -h|--help) sed -n 2,20p "$0"; exit 0;; *) want+=("$1");; esac; shift; done

# 「每次启动都从 Secret 读」的组件才允许轮换; 其它(grafana/harbor/bugsink/healthchecks)首次初始化后存库, 改 Secret 不等于换密码
ROTATABLE="dragonfly meilisearch minio redis"

BAO_NS=openbao
bao_token() {
  [[ -n ${BAO_TOKEN:-} ]] && { echo "$BAO_TOKEN"; return; }
  local f="$STATE_DIR/creds/openbao-init"
  [[ -r $f ]] || die "没有写权限 token: 设 BAO_TOKEN, 或在节点上执行(读 $f 的 root token)"
  awk -F': ' '/Initial Root Token/{print $2}' "$f"
}
bao_put() {  # bao_put <路径段> <JSON 对象(stdin)>
  local path="k8s/$CLUSTER_NAME/$1"
  if [[ $DRY == 1 ]]; then
    log_info "[dry-run] secret/$path ← 键: $(jq -r 'keys|join(" ")')"; return 0
  fi
  kctl -n $BAO_NS exec -i openbao-0 -- env BAO_TOKEN="$(bao_token)" bao kv put -mount=secret "$path" - >/dev/null \
    && log_ok "secret/$path 已写入"
}
kctl -n $BAO_NS get pod openbao-0 >/dev/null 2>&1 || die "openbao-0 不存在(ADDON_OPENBAO?)"
kctl -n $BAO_NS exec openbao-0 -- bao status -format=json 2>/dev/null | grep -q '"sealed": *false' || die "OpenBao sealed: bash components/openbao/examples/unseal.sh"

secret_val() { kctl -n "$1" get secret "$2" -o jsonpath="{.data.${3//./\\.}}" 2>/dev/null | base64 -d || true; }
cred_file()  { [[ -r $STATE_DIR/creds/$1 ]] && cat "$STATE_DIR/creds/$1" || true; }
rand()       { openssl rand -hex 12; }
selected()   { (( ${#want[@]} == 0 )) || printf '%s\n' "${want[@]}" | grep -qx "$1"; }
pick() {  # pick <id> <值来源...>: 第一个非空; ROTATE 且可轮换时直接新随机
  local id=$1; shift
  if [[ $ROTATE == 1 ]]; then
    grep -qw "$id" <<<"$ROTATABLE" || die "$id 不允许轮换(首次初始化后存库, 改 Secret 无效); 只有: $ROTATABLE"
    rand; return
  fi
  local v; for v in "$@"; do [[ -n $v ]] && { echo "$v"; return; }; done
  rand
}

# ---- 集群内组件(值 = 运行中的现值, 保证切换到 ESO 后零行为变化) ----
if selected dragonfly; then
  jq -n --arg p "$(pick dragonfly "$(secret_val dragonfly dragonfly-password-secret password)" "$(cred_file dragonfly-password)")" '{password:$p}' | bao_put dragonfly
fi
if selected grafana; then
  jq -n --arg u admin --arg p "$(pick grafana "$(secret_val observability grafana-admin admin-password)" "$(secret_val observability grafana admin-password)" "$(cred_file grafana-admin)")" \
    '{"admin-user":$u,"admin-password":$p}' | bao_put grafana
fi
if selected bugsink; then
  su=$(secret_val ops bugsink-secret CREATE_SUPERUSER)   # 形如 email:password
  jq -n --arg k "$(pick bugsink "$(secret_val ops bugsink-secret SECRET_KEY)" "$(cred_file bugsink-secret-key)" "$(openssl rand -base64 60 | tr -d '\n=/+' | cut -c1-64)")" \
        --arg p "$(pick bugsink "${su#*:}" "$(cred_file bugsink-admin)")" '{"secret-key":$k,"admin-password":$p}' | bao_put bugsink
fi
if selected healthchecks; then
  jq -n --arg k "$(pick healthchecks "$(secret_val ops healthchecks-secret SECRET_KEY)" "$(cred_file healthchecks-secret-key)")" \
        --arg p "$(pick healthchecks "$(secret_val ops healthchecks-secret ADMIN_PASSWORD)" "$(cred_file healthchecks-admin)")" '{"secret-key":$k,"admin-password":$p}' | bao_put healthchecks
fi

# ---- redis-node3(值 = control-tower config 服务自举 Secret 里的现值; 它是唯一消费方) ----
if selected redis-node3; then
  [[ $ROTATE == 0 ]] || die "redis-node3 在 node3 Pigsty 上, 不能在这里轮换"
  cfg=$(kctl -n config-center get secret config-center-bootstrap -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d || true)
  if [[ -z $cfg ]]; then
    log_warn "config-center/config-center-bootstrap 不存在, 跳过 redis-node3"
  else
    CFG="$cfg" "${PYTHON:-python3}" - <<'PY' | bao_put redis-node3
import os, sys, json, yaml
d = yaml.safe_load(os.environ["CFG"])
r = d["data"]["cache"]["redis"]
out = {"password": r["password"]}
ca = (r.get("tls") or {}).get("ca_pem") or ""
if ca.strip(): out["ca.crt"] = ca.strip()
json.dump(out, sys.stdout)
PY
  fi
fi

# ---- 外部依赖(值 = Config Center 现值; 反向映射) ----
externals="postgres-node3 casdoor elasticsearch-node3"
need_ext=0; for e in $externals; do selected "$e" && need_ext=1; done
if [[ $need_ext == 1 ]]; then
  [[ $ROTATE == 0 ]] || die "外部依赖的凭据在外部系统里, 不能在这里轮换(去 Pigsty/Casdoor/ES 改后重新播种)"
  PY=${PYTHON:-python3}
  export CC_CONTRACTS_JSON; CC_CONTRACTS_JSON=$(bash "$TOOLS_DIR/verify-contracts.sh" --json 2>/dev/null) || true
  [[ -r ${KUBECONFIG:-/etc/kubernetes/admin.conf} ]] && export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
  ext=$("$PY" "$TOOLS_DIR/config-center/harvest.py" --extract-externals --env "${ENV:-pre}" 2>/dev/null | grep '^{') || die "抽取外部凭据失败(Config Center 可达? selector Secret 里有 service_token?)"
  for e in $externals; do
    selected "$e" || continue
    jq -e --arg e "$e" 'has($e)' <<<"$ext" >/dev/null || { log_warn "$e: 现值里没有可抽取的凭据, 跳过"; continue; }
    jq -c --arg e "$e" '.[$e]' <<<"$ext" | bao_put "$e"
  done
  # 非机密固定值 → overrides.yaml(harvest 用), 只在不存在时写
  ov="$STATE_DIR/config-center/overrides.yaml"
  if [[ ! -f $ov && $DRY == 0 ]] && jq -e '._overrides|length>0' <<<"$ext" >/dev/null; then
    mkdir -p "$(dirname "$ov")"
    jq -r '._overrides | to_entries[] | "\(.key):\n" + (.value | to_entries | map("  \(.key): \(.value|tojson)") | join("\n"))' <<<"$ext" > "$ov"
    chmod 600 "$ov"; log_ok "overrides 已写 $ov(非机密固定值: $(jq -r '._overrides|keys|join(" ")' <<<"$ext"))"
  fi
fi
log_info "下一步: bash components/_external/apply.sh; 重跑各组件 install.sh 切到 ESO; bash tools/config-center-harvest.sh --dry-run"
