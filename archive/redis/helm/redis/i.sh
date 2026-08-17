#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -p /home/kubernetes/redis
cd /home/kubernetes/redis

helm repo add bitnami https://charts.bitnami.com/bitnami
helm pull bitnami/redis
tar -zxvf redis-*.tgz

kubectl create secret \
generic redis-<REDACTED-20260817>-secret \
--from-literal=redis-<REDACTED-20260817>=<REDACTED-20260817> \
-n redis-ha

# rm
# kubectl delete secret \
# redis-<REDACTED-20260817>-secret \
# -n redis-ha

# TLS
# kubectl create secret generic certificates-tls-secret --from-file=./cert.pem --from-file=./cert.key --from-file=./ca.pem

helm uninstall redis-ha -n redis-ha
cp {values.yaml,.back}
cat > values.yaml <<EOF
auth:
  ## @param auth.enabled Enable <REDACTED-20260817> authentication
  ##
  enabled: true
  ## @param auth.sentinel Enable <REDACTED-20260817> authentication on sentinels too
  ##
  sentinel: true
  ## @param auth.<REDACTED-20260817> Redis&reg; <REDACTED-20260817>
  ## Defaults to a random 10-character alphanumeric string if not set
  ##
  <REDACTED-20260817>: "<REDACTED-20260817>"
  #existingSecret: "redis-<REDACTED-20260817>-secret"
  ## @param auth.existingSecretPasswordKey Password key to be retrieved from existing secret
  ## NOTE: ignored unless `auth.existingSecret` parameter is set
  ##
  #existingSecretPasswordKey: "<REDACTED-20260817>"
  ## @param auth.usePasswordFiles Mount credentials as files instead of using an environment variable
  ##
  usePasswordFiles: false
  ## @param auth.usePasswordFileFromSecret Mount <REDACTED-20260817> file from secret
  ##
  usePasswordFileFromSecret: false

tls:
  enabled: false

metrics:
  enabled: false

master:
  service:
    ports:
      redis: 6379
    type: LoadBalancer
  persistence:
    size: 8Gi

replica:
  replicaCount: 3
  service:
    type: LoadBalancer
    ports:
      redis: 6379
  resources
    persistence:
      size: 8Gi
    requests:
      cpu: 2
      memory: 512Mi
    limits:
      cpu: 3
      memory: 1024Mi
EOF

# --set <REDACTED-20260817>
helm upgrade --install \
redis-ha . \
-f values.yaml \
-n redis-ha \
--create-namespace

kubectl get po,svc -n redis-ha

# uninstall
# helm uninstall redis-ha -n redis-ha

# 添加节点
# helm upgrade --timeout 600s <release> \
# --set "<REDACTED-20260817>=${REDIS_PASSWORD} \
# --set cluster.nodes=7 \
# --set cluster.update.addNodes=true \
# --set cluster.update.currentNumberOfNodes=6" \
# --set oci://REGISTRY_NAME/REPOSITORY_NAME/redis

# Redis&reg; can be accessed on the following DNS names from within your cluster:
#
#     redis-ha-master.redis-ha.svc.cluster.local for read/write operations (port 6379)
#     redis-ha-replicas.redis-ha.svc.cluster.local for read-only operations (port 6379)
#
#
#
# To get your <REDACTED-20260817> run:
#
#     export REDIS_PASSWORD=$(kubectl get secret --namespace redis-ha redis-ha -o jsonpath="{.data.redis-<REDACTED-20260817>}" | base64 -d)
#
# To connect to your Redis&reg; server:
#
# 1. Run a Redis&reg; pod that you can use as a client:
#
#    kubectl run --namespace redis-ha redis-client --restart='Never'  --env REDIS_PASSWORD=$REDIS_PASSWORD  --image docker.io/bitnami/redis:7.2.5-debian-12-r0 --command -- sleep infinity
#
#    Use the following command to attach to the pod:
#
#    kubectl exec --tty -i redis-client \
#    --namespace redis-ha -- bash
#
# 2. Connect using the Redis&reg; CLI:
#    REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h redis-ha-master
#    REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h redis-ha-replicas
#
# To connect to your database from outside the cluster execute the following commands:
#
#     kubectl port-forward --namespace redis-ha svc/redis-ha-master 6379:6379 &
#     REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h 127.0.0.1 -p 6379
#
# WARNING: There are "resources" sections in the chart not set. Using "resourcesPreset" is not recommended for production. For production installations, please set the following values according to your workload needs:
#   - metrics.resources
#   - replica.resources
#   - master.resources
# +info https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/

