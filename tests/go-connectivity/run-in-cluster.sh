#!/usr/bin/env bash
# =============================================================================
# 在集群里运行 Go 客户端连通性测试(tests/go-connectivity)。
#
#   bash tests/go-connectivity/run-in-cluster.sh            # Pod 网络: 全部组件(除 Tetragon gRPC)
#   bash tests/go-connectivity/run-in-cluster.sh --host     # hostNetwork: 只跑 Tetragon gRPC(localhost:54321)
#   bash tests/go-connectivity/run-in-cluster.sh --run TestNATS   # 只跑匹配的测试
#   SKIP_OPENFGA=1 bash tests/go-connectivity/run-in-cluster.sh   # 跳过未安装的组件
#
# 做法: 源码打成 ConfigMap → Job 用 golang 镜像 go test(模块经 GOPROXY 下载) → 收日志 → 清理。
#   - 凭据只从集群 Secret 注入(pg-main-app / consul-bootstrap-acl-token / dragonfly-password-secret),
#     不落盘、不进仓库; 某个 Secret 不存在时对应测试自动 Skip(不假装通过)。
#   - 集群根 CA 来自 trust-manager 分发的 ConfigMap global-root-ca(TLS 校验 Dragonfly/Gateway 证书)。
#   - 在控制面节点执行(需要 /etc/kubernetes/admin.conf); 也可 KUBECONFIG=... 在任意机器执行。
# =============================================================================
set -Eeuo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_ENV="${CONFIG_ENV:-$DIR/../../bootstrap/config.env}"

NS=${CONNTEST_NAMESPACE:-conntest}
IMAGE=${CONNTEST_GO_IMAGE:-docker.io/library/golang:1.26}
GOPROXY_URL=${CONNTEST_GOPROXY:-https://goproxy.cn,direct}
TIMEOUT=${CONNTEST_TIMEOUT:-20m}
HOST_MODE=false RUN_FILTER=""
while (( $# > 0 )); do
  case $1 in
    --host) HOST_MODE=true ;;
    --run)  RUN_FILTER=${2:?--run 需要正则}; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
k() { kubectl "$@"; }

# Gateway 固定 VIP 从 config.env 读(与安装器同源), 没有就跳过该测试
GATEWAY_VIP=""
if [[ -f $CONFIG_ENV ]]; then
  GATEWAY_VIP=$(sed -nE 's/^CILIUM_GATEWAY_LB_IP="([^"]*)".*/\1/p' "$CONFIG_ENV" | head -1)
fi

JOB=conntest
[[ $HOST_MODE == true ]] && JOB=conntest-host
echo "== 命名空间 $NS, Job $JOB, 镜像 $IMAGE"
k create ns "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k delete job "$JOB" -n "$NS" --ignore-not-found --wait=true >/dev/null

# 源码 → ConfigMap(只放 go 源与 go.mod/go.sum; 二进制大小上限 1MiB, 当前远小于)
src_args=(--from-file="$DIR/go.mod" --from-file="$DIR/go.sum")
for f in "$DIR"/*.go; do src_args+=(--from-file="$f"); done
k -n "$NS" create configmap conntest-src "${src_args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null

# RBAC: 只读节点/Deployment(TestKubernetesAPI)
cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: {name: conntest, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: conntest-readonly}
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [list, get]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [list, get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: conntest-readonly}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: conntest-readonly}
subjects: [{kind: ServiceAccount, name: conntest, namespace: $NS}]
EOF

# 凭据 Secret 复制到测试命名空间(Secret 不能跨命名空间引用); 源不存在就跳过对应测试
copy_secret() {  # copy_secret <源ns> <源名> <目标名>
  local json
  if json=$(k -n "$1" get secret "$2" -o json 2>/dev/null); then
    jq --arg n "$3" --arg ns "$NS" '{apiVersion, kind, type, data, metadata:{name:$n, namespace:$ns}}' <<<"$json" \
      | k apply -f - >/dev/null
    return 0
  fi
  echo "   (Secret $1/$2 不存在: 对应测试将 Skip)"
  k -n "$NS" delete secret "$3" --ignore-not-found >/dev/null
  return 1
}
copy_secret postgresql pg-main-app conntest-pg || true
copy_secret consul consul-bootstrap-acl-token conntest-consul || true
copy_secret dragonfly dragonfly-password-secret conntest-dragonfly || true

# 环境变量: 可选凭据用 optional: true, 缺失时测试自身 Skip
env_yaml() {
  cat <<EOF
            - {name: GOPROXY, value: "$GOPROXY_URL"}
            - {name: GOFLAGS, value: "-mod=mod"}
            - {name: GOTOOLCHAIN, value: "local"}
            - {name: GATEWAY_VIP, value: "$GATEWAY_VIP"}
            - name: PG_URI
              valueFrom: {secretKeyRef: {name: conntest-pg, key: uri, optional: true}}
            - name: CONSUL_HTTP_TOKEN
              valueFrom: {secretKeyRef: {name: conntest-consul, key: token, optional: true}}
            - name: DRAGONFLY_PASSWORD
              valueFrom: {secretKeyRef: {name: conntest-dragonfly, key: password, optional: true}}
EOF
  # 透传调用方的 SKIP_* 与显式地址覆盖
  local v
  for v in $(compgen -e | grep -E '^(SKIP_[A-Z]+|[A-Z_]+_URL|[A-Z_]+_ADDR|OTLP_GRPC_ENDPOINT|GATEWAY_PROBE_HOST|OPERATOR_NAMESPACES)$'); do
    printf '            - {name: %s, value: "%s"}\n' "$v" "${!v}"
  done
}

RUN_ARGS='./...'
if [[ $HOST_MODE == true ]]; then
  RUN_FILTER=${RUN_FILTER:-TestTetragonGRPC}
  HOST_SPEC='      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet'
  EXTRA_ENV='            - {name: TETRAGON_GRPC_ADDR, value: "localhost:54321"}'
else
  HOST_SPEC=''
  EXTRA_ENV=''   # Pod 网络下 TETRAGON_GRPC_ADDR 不设置, TestTetragonGRPC 自行 Skip
fi
GO_TEST="go test $RUN_ARGS -count=1 -v -timeout $TIMEOUT"
[[ -n $RUN_FILTER ]] && GO_TEST+=" -run '$RUN_FILTER'"

cat <<EOF | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB, namespace: $NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      serviceAccountName: conntest
      restartPolicy: Never
$HOST_SPEC
      containers:
        - name: go
          image: $IMAGE
          workingDir: /work
          command: [bash, -ec]
          args:
            - |
              set -o pipefail   # go test 的退出码必须穿过 tee, 否则有 FAIL 的 Job 也会 Complete
              cp /src/* /work/ && go version && go mod download
              rc=0; $GO_TEST 2>&1 | tee /tmp/out.txt || rc=\$?
              grep -E '^(--- (PASS|FAIL|SKIP)|ok|FAIL)' /tmp/out.txt > /tmp/summary.txt || true
              echo "=== SUMMARY ==="; cat /tmp/summary.txt; exit \$rc
          env:
$(env_yaml)
$EXTRA_ENV
          volumeMounts:
            - {name: src, mountPath: /src}
            - {name: work, mountPath: /work}
            - {name: gocache, mountPath: /go}            # GOPATH: 模块缓存
            - {name: cluster-ca, mountPath: /etc/cluster-ca, readOnly: true}
          resources:
            requests: {cpu: 500m, memory: 512Mi}
            limits: {memory: 2Gi}
      volumes:
        - {name: src, configMap: {name: conntest-src}}
        - {name: work, emptyDir: {}}
        - name: gocache
          hostPath: {path: /var/cache/conntest-gopath, type: DirectoryOrCreate}   # 模块缓存落节点, 重跑不重下
        - name: cluster-ca
          configMap: {name: global-root-ca, optional: true}
EOF

echo "== 等待 Job 完成(最多 $TIMEOUT + 拉镜像/下模块)..."
k -n "$NS" wait --for=condition=ready pod -l job-name="$JOB" --timeout=10m >/dev/null 2>&1 || true
pod=$(k -n "$NS" get pod -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
k -n "$NS" logs -f "$pod" 2>/dev/null || true
# 结束状态
if k -n "$NS" wait --for=condition=complete job/"$JOB" --timeout=60s >/dev/null 2>&1; then
  echo "== Job $JOB: 全部通过"
  exit 0
fi
echo "== Job $JOB: 有失败用例(见上方 --- FAIL)" >&2
exit 1
