#!/usr/bin/env bash
# =============================================================================
# clone-namespace.sh —— 把一个命名空间的应用层对象从源集群复制到目标集群
#
#   bash tools/clone-namespace.sh <源 kubectl 前缀> <目标 kubectl 前缀> <namespace> [--dry-run]
#   例: bash tools/clone-namespace.sh "ssh root@192.168.3.101 kubectl" "ssh node4 kubectl" ecommerce
#
# 用途: 内网 node101~103 → 机房 node4/5 复现 config-center / ecommerce 这类"kubectl apply 出来的"
# 应用命名空间(2026-09-06)。对象经 ssh 管道直接进目标集群, 本机不落盘。
#
# 复制: Namespace, ConfigMap, Secret, ServiceAccount, Certificate(cert-manager), Service,
#       Deployment, StatefulSet, HTTPRoute, VerticalPodAutoscaler, PVC(只复制声明, 不搬数据)
# 跳过(目标集群自己会生成/不该跨集群搬):
#   - kube-root-ca.crt / global-root-ca(trust-manager 分发) / cert-manager 签出的 TLS Secret
#     (Certificate CR 会被目标集群的 cert-manager 重新签发, 根 CA 不同)
#   - ServiceAccount token Secret、default SA、Helm release Secret
#   - status / uid / resourceVersion / managedFields / ownerReferences 等集群私有元数据
# 不做: 数据迁移、公网切流、跨命名空间依赖(default/cilium-gateway 等由安装器保证同名存在)
# =============================================================================
set -Eeuo pipefail

SRC=${1:?源 kubectl 命令前缀}
DST=${2:?目标 kubectl 命令前缀}
NS=${3:?namespace}
DRY=false; [[ ${4:-} == --dry-run ]] && DRY=true

src() { bash -c "$SRC $*"; }
dst() { if [[ $DRY == true ]]; then cat >/dev/null; echo "   (dry-run) $*"; else bash -c "$DST $*"; fi; }

# 清洗: 去掉集群私有元数据; 返回 items 数组(可能为空)
clean() {
  jq '[.items[]
      | del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
            .metadata.managedFields, .metadata.ownerReferences, .metadata.generation, .metadata.selfLink)
      | .metadata.annotations |= (if . == null then null else
            del(.["kubectl.kubernetes.io/last-applied-configuration"], .["deployment.kubernetes.io/revision"]) end)
      | if .kind == "Service" then del(.spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies, .spec.ipFamilyPolicy, .spec.internalTrafficPolicy,
                                       .spec.healthCheckNodePort) | .spec.ports |= map(del(.nodePort)) else . end
      | if .kind == "PersistentVolumeClaim" then del(.spec.volumeName, .metadata.annotations["pv.kubernetes.io/bind-completed"],
                                                     .metadata.annotations["pv.kubernetes.io/bound-by-controller"],
                                                     .metadata.annotations["volume.kubernetes.io/storage-provisioner"],
                                                     .metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"]) else . end
      | if .kind == "ServiceAccount" then del(.secrets) else . end
    ]'
}

# 过滤规则(按 kind)
filter_secret='map(select(
    .type != "kubernetes.io/service-account-token"
    and (.type | startswith("helm.sh/") | not)
    and ((.metadata.annotations // {})["cert-manager.io/certificate-name"] == null)
    and (.metadata.name | startswith("sh.helm.release") | not)))'
filter_cm='map(select(.metadata.name != "kube-root-ca.crt" and .metadata.name != "global-root-ca"))'
filter_sa='map(select(.metadata.name != "default"))'

apply_kind() {  # apply_kind <kind> [jq 过滤]
  local kind=$1 flt=${2:-.} json n
  json=$(src -n "$NS" get "$kind" -o json 2>/dev/null | clean | jq "$flt") || { echo " - $kind: 源不可读, 跳过"; return 0; }
  n=$(jq 'length' <<<"$json")
  (( n > 0 )) || { echo " - $kind: 0"; return 0; }
  printf ' - %-28s %s: %s\n' "$kind" "$n" "$(jq -r '[.[].metadata.name] | join(" ")' <<<"$json" | cut -c1-120)"
  jq '{apiVersion:"v1", kind:"List", items:.}' <<<"$json" | dst apply -n "$NS" -f - | sed 's/^/     /'
}

echo "== 克隆命名空间 $NS: [$SRC] → [$DST] $([[ $DRY == true ]] && echo '(dry-run)')"
src get ns "$NS" -o json | jq '{apiVersion:"v1",kind:"Namespace",metadata:{name:.metadata.name,labels:(.metadata.labels // {} | del(.["kubernetes.io/metadata.name"]))}}' \
  | dst apply -f - | sed 's/^/     /'
apply_kind configmap "$filter_cm"
apply_kind secret "$filter_secret"
apply_kind serviceaccount "$filter_sa"
apply_kind certificate.cert-manager.io
apply_kind persistentvolumeclaim
apply_kind service
apply_kind deployment
apply_kind statefulset
apply_kind httproute.gateway.networking.k8s.io
apply_kind verticalpodautoscaler.autoscaling.k8s.io
echo "== 完成。目标侧核对: $DST -n $NS get deploy,sts,svc,httproute,certificate"
