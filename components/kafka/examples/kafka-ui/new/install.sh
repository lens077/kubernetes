#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 版本 pin:chart 1.6.5 对应 appVersion v1.5.0
# 不 pin 会随 repo 漂移;kafbat 1.0 起用 CEL 替换 Groovy 过滤器,1.1 修复 CVE-2025-49127(JMX 反序列化 RCE)
CHART_VERSION="1.6.5"
IMAGE_TAG="v1.5.0"
NAMESPACE="kafka"

# 凭据从环境变量注入,不写进 values 文件、不入库
: "${KAFKA_UI_ADMIN_USER:=admin}"
: "${KAFKA_UI_ADMIN_PASSWORD:?必须设置,例如 export KAFKA_UI_ADMIN_PASSWORD=\$(openssl rand -base64 24)}"

mkdir -pv /home/kubernetes/kafka/ui
cd /home/kubernetes/kafka/ui

helm repo add kafbat-ui https://kafbat.github.io/helm-charts
helm repo update kafbat-ui

helm pull kafbat-ui/kafka-ui --version "${CHART_VERSION}"
tar -zxf "kafka-ui-${CHART_VERSION}.tgz"

# Secret 必须先于 helm 存在,所以命名空间单独建(helm 的 --create-namespace 太晚)
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# chart 的 existingSecret 会以 envFrom.secretRef 注入,env 优先级高于 yaml 配置文件
kubectl -n "${NAMESPACE}" create secret generic kafbat-ui-auth \
  --from-literal=SPRING_SECURITY_USER_NAME="${KAFKA_UI_ADMIN_USER}" \
  --from-literal=SPRING_SECURITY_USER_PASSWORD="${KAFKA_UI_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# https://github.com/kafbat/helm-charts/blob/main/charts/kafka-ui/CONFIGURATION.md
# https://github.com/kafbat/helm-charts/blob/main/charts/kafka-ui/values.yaml
# https://ui.docs.kafbat.io/configuration/authentication/basic-authentication
cat > kafka-ui-values.yml <<EOF
image:
  tag: ${IMAGE_TAG}

existingSecret: kafbat-ui-auth

yamlApplicationConfig:
  kafka:
    clusters:
      - name: my-cluster
        bootstrapServers: my-cluster-kafka-bootstrap:9092
  auth:
    type: LOGIN_FORM
  management:
    health:
      ldap:
        enabled: false
service:
  labels: {}
  type: ClusterIP
  port: 80

resources:
  limits:
    cpu: 200m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi
EOF

helm upgrade --install kafbat-ui \
 ./kafka-ui \
 -f kafka-ui-values.yml \
 --create-namespace \
 -n "${NAMESPACE}"
