#!/bin/bash
set -x

helm pull oci://ghcr.io/akuity/kargo-charts/kargo
tar -zxvf kargo-*.tgz

# helm值参考：https://github.com/akuity/kargo/tree/main/charts/kargo
# 1. 生成密码哈希
PASSWORD_HASH=$(argocd account bcrypt --password "你的安全密码")
NAMESPACE="kargo"
SECRET_NAME="kargo-admin-secret"

# 2. 生成 Token 签名密钥
TOKEN_SIGNING_KEY=$(openssl rand -base64 32 | tr -d '\n')
# 3. 生成 Base64 编码后的 Token Signing Key (用于 Kubernetes Secret 'data' 字段)
# 如果使用 stringData 则不需要 Base64 编码
TOKEN_KEY_B64=$(echo -n "$TOKEN_SIGNING_KEY" | base64)

kubectl create ns $NAMESPACE
kubectl create secret generic $SECRET_NAME -n ${NAMESPACE} \
  --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="${PASSWORD_HASH}" \
  --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="${TOKEN_SIGNING_KEY}"

cat > new-values.yml <<EOF
api:
  secret:
    name: $SECRET_NAME
  service:
    ## @param api.service.type If you're not going to use an ingress controller, you may want to change this value to `LoadBalancer` for production deployments. If running locally, you may want to change it to `NodePort` OR leave it as `ClusterIP` and use `kubectl port-forward` to map a port on the local network interface to the service.
    type: LoadBalancer
EOF

helm upgrade --install kargo \
  ./kargo \
  --namespace kargo \
  --create-namespace \
  -f new-values.yml \
#  --wait

kubectl get po,svc,secret -n kargo

set +x
