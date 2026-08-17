#!/usr/bin/env bash
# Jaeger v2 + badger(本地 PVC)部署脚本。
#
# 取代原来的 Helm 方案(已删除),不再依赖 Elasticsearch。
# 迁移背景与取舍见同目录 README.md。
set -o errexit -o nounset -o pipefail

NS=observability
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 1/4 清理原 Helm release(如果还在)"
if helm status jaeger -n "$NS" >/dev/null 2>&1; then
  # 会一并删掉:Deployment / Service / ServiceAccount / ConfigMap(user-config)
  # / esIndexCleaner CronJob。HTTPRoute 与 GRPCRoute 是 kubectl apply 管理的,
  # 不受影响。
  helm uninstall jaeger -n "$NS"
else
  echo "    未发现 Helm release,跳过"
fi

echo "==> 2/4 应用清单"
kubectl apply -f "$SCRIPT_DIR/01-serviceaccount.yaml"
kubectl apply -f "$SCRIPT_DIR/02-pvc.yaml"
kubectl apply -f "$SCRIPT_DIR/03-configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/04-deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/05-service.yaml"

echo "==> 3/4 等待就绪"
kubectl rollout status deployment/jaeger -n "$NS" --timeout=180s

echo "==> 4/4 断言(失败即非零退出)"

# 断言 1:PVC 真的挂上了。
# 这是最关键的一条 —— 若挂载丢失,badger 会静默改写容器可写层,
# Pod 照常 Ready,但 trace 一重启就没,且没有任何报错。
mounted=$(kubectl get deploy jaeger -n "$NS" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')
if [ "$mounted" != "jaeger-badger" ]; then
  echo "    ✗ PVC 未挂载(实际: '${mounted}')" >&2
  exit 1
fi
echo "    ✓ PVC jaeger-badger 已挂载"

# 断言 2:确认后端是 badger,而且再无任何 elasticsearch 残留。
if kubectl logs deployment/jaeger -n "$NS" --tail=200 2>/dev/null | grep -qi "Elasticsearch detected"; then
  echo "    ✗ 日志中仍出现 Elasticsearch" >&2
  exit 1
fi
if ! kubectl logs deployment/jaeger -n "$NS" --tail=200 2>/dev/null | grep -q "Badger storage configuration"; then
  echo "    ✗ 未见 badger 初始化日志" >&2
  exit 1
fi
echo "    ✓ 后端为 badger,无 ES 依赖"

# 断言 3:Service 的 14 个端口一个不少(otel / HTTPRoute / GRPCRoute 都依赖它们)。
ports=$(kubectl get svc jaeger -n "$NS" -o jsonpath='{.spec.ports[*].port}' | wc -w | tr -d ' ')
if [ "$ports" != "14" ]; then
  echo "    ✗ Service 端口数为 ${ports},预期 14" >&2
  exit 1
fi
echo "    ✓ Service 端口齐全(14 个)"

echo
echo "完成。UI: http://jaeger-ui.app.com   (路由清单在 ../gateway/*-route.yml)"
