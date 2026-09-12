#!/usr/bin/env bash
# =============================================================================
# verify-contracts.sh —— 核对组件依赖契约(component.env 的 PROVIDES/SVC/PORT/CRED_SECRET/CA_REF)与集群现状
#
#   bash tools/verify-contracts.sh                 # 所有启用的提供方(按 config.env 开关) + _external/*
#   bash tools/verify-contracts.sh --selected <文件>  # 只看 80 阶段选中的组件(编排器调用)
#   bash tools/verify-contracts.sh --json          # 只输出契约 JSON(每行一个, 含 chosen 标记), 供 harvest 消费; 不校验
#
# 声明优先、发现校验: 声明的 Service/端口/Secret 键/CA 必须真的存在, 否则列出并返回 1。
# 同一能力(PROVIDES)多个启用提供方时按 config.env 的 CC_PROVIDERS 选; 没指定即报错。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../components/_lib" &>/dev/null && pwd)/env.sh"

MODE=verify SELECTED=""
while (($#)); do
  case $1 in
    --selected) SELECTED=$2; shift 2 ;;
    --json) MODE=json; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) die "未知参数 $1" ;;
  esac
done

# 启用判断: 与 80-components.sh 的 comp_default_on 同义(CONFIG_VAR 显式 > DEFAULT_ENABLED)
enabled_by_config() {  # enabled_by_config <CONFIG_VAR> <DEFAULT_ENABLED>
  local var=$1 def=$2
  if [[ -n $var && -n ${!var:-} ]]; then [[ ${!var} == true ]]; else [[ $def == true ]]; fi
}

# 候选目录: components/<id>(非 _ 前缀) + components/_external/<id>
candidates() {
  local d
  for d in "$COMPONENTS_DIR"/*/ "$COMPONENTS_DIR"/_external/*/; do
    [[ -f $d/component.env ]] || continue
    [[ $(basename "$d") == _* ]] && continue
    echo "${d%/}"
  done
}

# 收集: id → 目录, 只保留声明了 PROVIDES 且启用的
declare -A DIR_OF=() CAP_OF=()
declare -A CAP_CANDIDATES=()
while read -r d; do
  ( comp_load_meta "$d"; [[ -n $PROVIDES ]] || exit 3
    if [[ -n $SELECTED && $EXTERNAL != true ]]; then
      grep -qx "$ID" "$SELECTED" || exit 3
    else
      enabled_by_config "${CONFIG_VAR:-}" "${DEFAULT_ENABLED:-false}" || exit 3
    fi
    printf '%s\x1f%s\n' "$ID" "$PROVIDES" ) > /tmp/.contract.$$ 2>/dev/null && {
      IFS=$'\x1f' read -r id cap < /tmp/.contract.$$
      DIR_OF[$id]=$d; CAP_OF[$id]=$cap
      CAP_CANDIDATES[$cap]+="$id "
    } || true
done < <(candidates)
rm -f /tmp/.contract.$$

# 每个能力选定一个提供方
declare -A CHOSEN=()
for cap in "${!CAP_CANDIDATES[@]}"; do
  read -ra ids <<<"${CAP_CANDIDATES[$cap]}"
  if (( ${#ids[@]} == 1 )); then CHOSEN[$cap]=${ids[0]}; continue; fi
  pick=""
  for kv in ${CC_PROVIDERS:-}; do [[ ${kv%%=*} == "$cap" ]] && pick=${kv#*=}; done
  if [[ -z $pick ]]; then
    log_warn "能力 $cap 有多个启用提供方(${ids[*]}), config.env 的 CC_PROVIDERS 未指定 → 跳过该能力"
    continue
  fi
  [[ -n ${DIR_OF[$pick]:-} && ${CAP_OF[$pick]} == "$cap" ]] || { log_warn "CC_PROVIDERS 指定的 $cap=$pick 不是启用的 $cap 提供方(${ids[*]})"; continue; }
  CHOSEN[$cap]=$pick
done
(( ${#CHOSEN[@]} > 0 )) || { log_warn "没有任何声明了 PROVIDES 的启用组件"; exit 0; }

fail=0
if [[ $MODE == json ]]; then
  # 全部启用提供方都输出(消费方可能按 consumers.<x>.providers 点名未被全局选中的那个), chosen 标记全局选择
  for id in $(printf '%s\n' "${!DIR_OF[@]}" | sort); do
    cap=${CAP_OF[$id]}; chosen=false; [[ ${CHOSEN[$cap]:-} == "$id" ]] && chosen=true
    comp_load_meta "${DIR_OF[$id]}"
    contract_json | jq -c --argjson c "$chosen" '. + {chosen:$c}'
  done
  exit 0
fi
for cap in $(printf '%s\n' "${!CHOSEN[@]}" | sort); do
  id=${CHOSEN[$cap]}
  comp_load_meta "${DIR_OF[$id]}"
  if out=$(contract_verify); then
    log_ok "$cap ← $id: $SVC:$PORT ($SCHEME)${CRED_SECRET:+, 凭据 $CRED_SECRET}${CA_REF:+, CA $CA_REF}"
  else
    fail=1
    while IFS= read -r line; do [[ -n $line ]] && log_warn "$line"; done <<<"$out"
  fi
done
exit $fail
