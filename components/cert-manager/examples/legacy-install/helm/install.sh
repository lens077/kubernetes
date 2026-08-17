#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -p /home/kubernetes/cert-manager
cd /home/kubernetes/cert-manager

helm repo add jetstack https://charts.jetstack.io
helm repo update

# 生成 values.yaml

helm show values jetstack/cert-manager > values.yaml

#修改 values.yaml
cat > cert-manager-values.yaml <<EOF
prometheus:
  enabled: false
webhook:
  timeoutSeconds: 10
EOF

# 安装
#helm install cert-manager jetstack/cert-manager \
#  -n cert-manager \
#  --create-namespace \
#  --set crds.enabled=true \
#  -f cert-manager-values.yaml

# https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/grpc/
# cilium gateway的TLS和gateway api所需的参数
helm pull jetstack/cert-manager
tar -zxvf cert-manager-*.tgz

helm upgrade --install cert-manager ./cert-manager \
    --reuse-values \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
    --set config.kind="ControllerConfiguration" \
    --set config.enableGatewayAPI=true \
    -f cert-manager-values.yaml

# 等待完成
kubectl wait --for=condition=Ready pods --all -n cert-manager

# 创建一个 CA 颁发者
wget https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/kubernetes/servicemesh/ca-issuer.yaml
kubectl apply -f ca-issuer.yaml
# 设置一个简单的 gRPC 回显服务器和一个网关来公开它
wget https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/kubernetes/gateway/grpc-tls-termination.yaml
kubectl apply -f grpc-tls-termination.yaml
# 要告诉 cert-manager 此网关需要证书，请使用您之前创建的 CA 颁发者的名称对网关进行注释：
kubectl annotate gateway tls-gateway cert-manager.io/issuer=ca-issuer
# 这将创建一个 Certificate 对象以及一个包含 TLS 证书的 Secret。
kubectl get certificate,secret grpc-certificate
