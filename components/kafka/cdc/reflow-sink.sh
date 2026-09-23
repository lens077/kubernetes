#!/usr/bin/env bash
# =============================================================================
# 重灌 ES sink: 把 sink 的 consumer group offset 重置到 topic 最早, 让 Kafka 里保留的全部 CDC 事件重放进
# 当前 write alias 指向的索引。用于 bootstrap-indices.sh --rotate 切到空的新索引之后。
#
# 不动 PG 复制槽、不重快照: Kafka topic 是 compact/retain 的, 历史事件都在, 重放即可。
# 只有 topic 已被清理过(重快照场景)才需要 cdc/README「重快照」那条更重的路径。
#
# 步骤: 暂停 sink connector → 等 consumer group 无活跃成员 → reset offsets --to-earliest → 恢复 connector
#      → 等 lag 归零 → 比对 7 个 alias 的文档数 == topic 内唯一 key 数的近似(直接打印, 人看)。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../_lib" &>/dev/null && pwd)/env.sh"
comp_require_cluster

NS=kafka
SINK=ecommerce-elasticsearch-sink
GROUP="connect-$SINK"
BROKER_POD=my-cluster-dual-role-0
CONNECT_POD=$(kctl -n $NS get pod -l strimzi.io/cluster=my-connect-cluster -o jsonpath='{.items[0].metadata.name}')
kcg() { kctl -n $NS exec $BROKER_POD -- bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 "$@" 2>/dev/null; }
rest() { kctl -n $NS exec $CONNECT_POD -- curl -sS -X "$1" "http://127.0.0.1:8083/connectors/$SINK$2"; }

log_step "暂停 sink $SINK"
rest PUT /pause >/dev/null
# PAUSED 的 sink task 仍持有 consumer(组内有成员), reset-offsets 会拒绝。要 STOP: Connect 3.5+ 的 /stop 释放全部资源。
rest PUT /stop >/dev/null
_stopped() { [[ $(rest GET /status | jq -r '.connector.state') == STOPPED ]]; }
wait_for "sink STOPPED" 90 _stopped || die "sink 未进入 STOPPED: $(rest GET /status | jq -c .connector)"
_no_members() { ! kcg --describe --group "$GROUP" --members 2>/dev/null | grep -q "connector-consumer"; }
wait_for "consumer group 成员退出" 90 _no_members || die "sink STOPPED 后 consumer group 仍有活跃成员, 不能 reset"

log_step "reset offsets → earliest (ecommerce_cdc.* 全部 topic)"
kcg --group "$GROUP" --reset-offsets --to-earliest --all-topics --execute | awk '/ecommerce_cdc/ {print "  " $2, "→ offset", $NF}'

log_step "恢复 sink"
rest PUT /resume >/dev/null   # STOPPED → resume 会重新分配 task 并从已提交(刚 reset 的)offset 起读
_task_running() { [[ $(rest GET /status | jq -r '.tasks[0].state') == RUNNING ]]; }
wait_for "sink task RUNNING" 60 _task_running || die "sink 恢复后 task 非 RUNNING: $(rest GET /status | jq -c .tasks[0])"
_lag_zero() { [[ $(kcg --describe --group "$GROUP" | awk '/ecommerce_cdc/ {s+=$6} END {print s+0}') == 0 ]]; }
wait_for "sink lag 归零" 300 _lag_zero || log_warn "300s 内 lag 未归零: kafka-consumer-groups --describe --group $GROUP"

log_step "结果(alias → write index 文档数)"
# 密码在 ES Pod 内从挂载文件读, 脚本里没有值; 下一行的 gitleaks:allow 是压 curl-auth-user 规则的误报
es_cat() { kctl -n elasticsearch exec elasticsearch-0 -c elasticsearch -- sh -c "curl -sS -u \"elastic:\$(cat /run/secrets/elastic/password)\" \"http://127.0.0.1:9200$1\""; }  # gitleaks:allow
es_cat "/_cat/aliases/ecommerce_*?h=alias,index,is_write_index&s=alias" \
  | awk '$3=="true" {print $1, $2}' | while read -r alias idx; do
    n=$(es_cat "/$idx/_count" | jq -r .count)
    printf '  %-34s %-36s docs=%s\n' "$alias" "$idx" "$n"
  done
log_ok "重灌完成; 旧 _v<N> 索引确认后手动删: DELETE /<alias>_v<N>"
