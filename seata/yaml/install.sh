#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# https://seata.apache.org/zh-cn/docs/ops/deploy-by-kubernetes/

cat > seata-server.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: seata-route
  namespace: seata
spec:
  parentRefs:
    - name: cilium-gateway
      namespace: default
      sectionName: http # 对应 Gateway 的监听器名称
  hostnames:
    - "seata.app.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: seata-server
          port: 8091
---
apiVersion: v1
kind: Service
metadata:
  name: seata-server
  labels:
    k8s-app: seata-server
spec:
  type: ClusterIP
  ports:
    - port: 8091
      protocol: TCP
      name: http
  selector:
    k8s-app: seata-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seata-server
  labels:
    k8s-app: seata-server
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: seata-server
  template:
    metadata:
      labels:
        k8s-app: seata-server
    spec:
      containers:
        - name: seata-server
          image: docker.io/apache/seata-server:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: SEATA_PORT
              value: "8091"
            - name: STORE_MODE
              value: file
          ports:
            - name: http
              containerPort: 8091
              protocol: TCP
EOF
kubectl create ns seata
kubectl apply -f seata-server.yaml -n seata
