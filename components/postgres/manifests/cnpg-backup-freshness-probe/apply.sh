#!/bin/bash
# 应用备份新鲜度探针。
#
# ConfigMap 由 probe.py 现场生成 —— 不在 cronjob.yaml 里内联脚本，
# 否则同一个脚本会有两份副本并必然漂移。
#
# 用法：  ./apply.sh
# 验证：  kubectl -n postgresql logs job/cnpg-backup-freshness-probe-now
set -euo pipefail
cd "$(dirname "$0")"

NS=postgresql
CM=cnpg-backup-freshness-probe

# RBAC(SA/Role/RoleBinding) 与 CronJob 都在 cronjob.yaml 里
kubectl create configmap "$CM" --namespace="$NS" \
  --from-file=probe.py=probe.py \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NS" -f cronjob.yaml

# 不等第一个 30 分钟窗口，立刻跑一次拿到数据
kubectl -n "$NS" delete job cnpg-backup-freshness-probe-now --ignore-not-found
kubectl -n "$NS" create job cnpg-backup-freshness-probe-now \
  --from=cronjob/"$CM"

echo "已拉起一次性 Job，等待其结果："
echo "  kubectl -n $NS logs job/cnpg-backup-freshness-probe-now"
