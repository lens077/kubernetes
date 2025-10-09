#!/bin/bash
set -x

使用了Gateway，那么应用的svc就可以设置成ClusterIP了，只通过Gateway的HTTTPRoute和Gateway的其他Kind使用
例如：
```yaml
# minio-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  # 必须指定 StorageClass，使用 OpenEBS LVM 的 StorageClass 名称
  storageClassName: openebs-lvmpv  # <-- **重点修改：指定 OpenEBS LVM 的 SC**

  # MinIO 通常部署为单个副本，适合使用 RWO 模式
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: minio
  name: minio
  namespace: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          # https://www.cnblogs.com/java365/articles/18922432
          # MinIO社区版在2025-05-24T17-08-30Z这个版本之后，移除了控制台大部分管理功能，想要完整minio，请安装旧版本。
          # https://quay.io/repository/minio/minio?tab=tags&tag=latest 版本
          image: quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z
          command:
            - /bin/bash
            - -c
          args:
            - minio server /data --console-address :9090
          volumeMounts:
            - mountPath: /data
              name: data
          ports:
            - containerPort: 9090
              name: console
            - containerPort: 9000
              name: api
          env:
            - name: MINIO_ROOT_USER # 指定用户名
              value: "admin"
            - name: MINIO_ROOT_PASSWORD # 指定密码，最少8位置
              value: "minioadmin"
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio-service
  namespace: minio
spec:
  type: ClusterIP
  selector:
    app: minio
  ports:
    - name: console
      port: 9090
      protocol: TCP
      targetPort: 9090
    - name: api
      port: 9000
      protocol: TCP
      targetPort: 9000

```
给他设置HTTPRoute
```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: minio-gateway
  namespace: minio
spec:
  addresses:
    - type: IPAddress
      value: 192.168.3.101
  # 替换成你集群中实际安装的 Gateway Controller Class 名称
  gatewayClassName: cilium
  listeners:
    - name: http-console
      protocol: HTTP
      port: 9090
    - name: http-api
      protocol: HTTP
      port: 9000
---
# minio-console-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: minio-console-route
  namespace: minio
spec:
  parentRefs:
    - name: minio-gateway # 绑定到上面创建的 Gateway
  hostnames:
    - "minio-console.app.com" # <-- 替换成你的实际域名
  rules:
    - matches:
        # 需要匹配的路径
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: minio-service
          port: 9090 # 路由到 MinIO Service 的 Console 端口
---
# minio-api-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: minio-api-route
  namespace: minio
spec:
  parentRefs:
    - name: minio-gateway # 绑定到上面创建的 Gateway
  hostnames:
    - "minio-api.app.com" # <-- 替换成你的实际域名
  rules:
    - matches:
        # 需要匹配的路径
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: minio-service
          port: 9000 # 路由到 MinIO Service 的 API 端口
```

# 安装
在 kube-system 命名空间中，为 cilium-envoy 容器添加缺失的 capabilities：
共享模式： --set ingressController.hostNetwork.sharedListenerPort=8080 默认值, 每个ingress使用该端口, Cilium 根据 Hostname 或 Path 来路由到不同后端服务。推荐大多数情况使用
专用模式： --set ingress.cilium.io/host-listener-port=8080 默认值, 每个ingress都必须指定端口, 可以用来区分相同路径的后端
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml

cilium upgrade cilium \
--namespace kube-system \
--reuse-values \
--set kubeProxyReplacement=true \
--set l7Proxy=true \
--set nodePort.enabled=true \
--set gatewayAPI.enabled=true \
--set ingressController.hostNetwork.sharedListenerPort=80

kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```
