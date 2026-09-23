#!/usr/bin/env bash
# =============================================================================
# ES 索引契约引导: index-mappings.json → 7 个 index template(ecommerce-cdc-<alias>, pattern <alias>_v*,
# shards 1 / replicas 0, dynamic strict + IK) → <alias>_v1 → write alias。幂等, install.sh 末尾调用, 也可单独跑:
#   bash components/elasticsearch/bootstrap-indices.sh
#
# 必须在 ES sink 起来之前跑: sink 自动建的索引是动态 mapping(标准分词、price float、没有 spu_code.search),
# search 服务的 multi_match 查 name^4/spu_code.search^3/description 在那种索引上中文按单字切、子字段不存在。
# 2026-09-23 新集群实测: install.sh 没有这一步, 7 个索引全是 sink 建的, replicas=1 还把单节点集群钉在 YELLOW。
#
# 已有错 mapping 的索引不能原地改(mapping 不可变): 用 --rotate 建 <alias>_v<N+1> 并把 write alias 切过去,
# 然后重灌 sink(components/kafka/cdc/README.md「重灌」)。旧索引留着, 确认新索引文档数追平后再手动删。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

ROTATE=0
[[ ${1:-} == --rotate ]] && ROTATE=1

MAPPINGS="$DIR/index-mappings.json"
[[ -s $MAPPINGS ]] || die "缺 $MAPPINGS(契约真相源: postgres-kafka-es-streaming-pipeline/deploy/docker-node3/index-mappings.json)"
has_cmd jq || die "需要 jq"

POD="elasticsearch-0"
# 所有 curl 在 Pod 里执行, 密码从 Pod 已挂载的文件读, 不经过本机 shell 参数/环境
es() {  # es <method> <path> [json-body-from-stdin]
  local m=$1 p=$2
  kctl -n "$NAMESPACE" exec -i "$POD" -c elasticsearch -- sh -c \
    "curl -sS -u \"elastic:\$(cat /run/secrets/elastic/password)\" -X $m -H 'Content-Type: application/json' \"http://127.0.0.1:9200$p\" --data-binary @-"
}
es_get() { printf '' | es GET "$1"; }

kctl -n "$NAMESPACE" get pod "$POD" >/dev/null || die "$NAMESPACE/$POD 不存在"
_es_ready() { es_get "/_cluster/health" | jq -e '.status=="green" or .status=="yellow"' >/dev/null; }
wait_for "ES 就绪" 120 _es_ready
es_get "/_cat/plugins?h=component" | grep -q analysis-ik || die "ES 没有 analysis-ik 插件, 契约 mapping 用了 ik_max_word/ik_smart"

log_step "索引模板 ← $MAPPINGS"
for alias in $(jq -r 'keys[]' "$MAPPINGS"); do
  jq -c --arg a "$alias" '{index_patterns:[($a+"_v*")], priority:200,
    template:{settings:{"index.number_of_shards":1,"index.number_of_replicas":0}, mappings:.[$a]}}' "$MAPPINGS" \
    | es PUT "/_index_template/ecommerce-cdc-$alias" | jq -e '.acknowledged==true' >/dev/null \
    || die "模板 ecommerce-cdc-$alias 写入失败"
done
log_ok "7 个模板已就位(pattern <alias>_v*, replicas 0, dynamic strict)"

# 现有索引的 mapping 是否等于契约: 模板只管新建索引, 已存在的错 mapping 要 --rotate
# ES 回显 mapping 时会把整数写成浮点(scaling_factor 100 → 100.0), 比对前把数字统一成 number 再序列化
_index_matches_contract() {  # <alias> <index>
  local a=$1 i=$2 live want norm='walk(if type=="number" then .+0 else . end)'
  live=$(es_get "/$i/_mapping" | jq -cS ".\"$i\".mappings | $norm")
  want=$(jq -cS --arg a "$a" ".[\$a] | $norm" "$MAPPINGS")
  [[ $live == "$want" ]]
}

log_step "索引 + write alias"
for alias in $(jq -r 'keys[]' "$MAPPINGS"); do
  # 当前 write index(可能不存在)
  cur=$(es_get "/_alias/$alias" | jq -r 'to_entries[]? | select(.value.aliases[]?.is_write_index==true) | .key' 2>/dev/null | head -1)
  if [[ -z $cur ]]; then
    idx="${alias}_v1"
    es_get "/_cat/indices/$idx?h=index" | grep -qx "$idx" || printf '' | es PUT "/$idx" | jq -e '.acknowledged==true' >/dev/null || die "建索引 $idx 失败"
    jq -nc --arg i "$idx" --arg a "$alias" '{actions:[{add:{index:$i,alias:$a,is_write_index:true}}]}' | es POST "/_aliases" | jq -e '.acknowledged==true' >/dev/null || die "alias $alias → $idx 失败"
    log_ok "$alias → $idx (新建)"
  elif _index_matches_contract "$alias" "$cur"; then
    log_ok "$alias → $cur (mapping 与契约一致)"
  elif [[ $ROTATE == 1 ]]; then
    n=${cur##*_v}; next="${alias}_v$((n+1))"
    printf '' | es PUT "/$next" | jq -e '.acknowledged==true' >/dev/null || die "建索引 $next 失败"
    if ! _index_matches_contract "$alias" "$next"; then
      printf '' | es DELETE "/$next" >/dev/null   # 别留悬空索引
      die "$next 建出来的 mapping 仍不等于契约(模板没命中? pattern ${alias}_v*)"
    fi
    jq -nc --arg o "$cur" --arg i "$next" --arg a "$alias" \
      '{actions:[{remove:{index:$o,alias:$a}},{add:{index:$i,alias:$a,is_write_index:true}}]}' | es POST "/_aliases" | jq -e '.acknowledged==true' >/dev/null || die "alias 切换失败"
    log_ok "$alias: $cur(错 mapping, 保留待删) → $next (write)"
    ROTATED=1
  else
    log_warn "$alias → $cur 的 mapping 与契约不一致(sink 自动建的?), 重跑加 --rotate 建新版本并切 alias"
    MISMATCH=1
  fi
done

if [[ ${ROTATED:-0} == 1 ]]; then
  log_warn "已切到新索引, 它们是空的 → 重灌 sink: bash components/kafka/cdc/reflow-sink.sh(或按 cdc/README「重灌」手工); 追平后删旧 _v<N>"
fi
[[ ${MISMATCH:-0} == 0 ]] || exit 2
