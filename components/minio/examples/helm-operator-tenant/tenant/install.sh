#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

mkdir -pv /home/kubernetes/minio
cd /home/kubernetes/minio

# 安装: https://github.com/minio/operator/tree/v6.0.4/helm/operator
# 配置: https://www.minio.org.cn/docs/minio/kubernetes/upstream/reference/operator-chart-values.html

helm search repo minio/tenant
helm pull minio/tenant
tar -zxvf tenant-*.tgz

# 修改values.yaml, 推荐修改pools.servers与pools.size和configSecret
# vi values.yaml Minio推荐使用分布式的SC
cat > new-values.yml <<EOF
tenant:
  pools:
    ###
    # The number of MinIO Tenant Pods / Servers in this pool.
    # For standalone mode, supply 1. For distributed mode, supply 4 or more.
    # Note that the operator does not support upgrading from standalone to distributed mode.
    - servers: 1
      ###
      # Custom name for the pool
      name: pool-0
      ###
      # The number of volumes attached per MinIO Tenant Pod / Server.
      volumesPerServer: 1
      ###
      # The capacity per volume requested per MinIO Tenant Pod.
      size: 20Gi
      ###
      # The `storageClass <https://kubernetes.io/docs/concepts/storage/storage-classes/>`__ to associate with volumes generated for this pool.
      #
      # If using Amazon Elastic Block Store (EBS) CSI driver
      # Please make sure to set xfs for "csi.storage.k8s.io/fstype" parameter under StorageClass.parameters.
      # Docs: https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/parameters.md
      storageClassName: openebs-lvmpv
  image:
    repository: pgsty/minio
    tag: latest
    pullPolicy: IfNotPresent
EOF

# 全新安装
helm upgrade --install tenant ./tenant \
  --create-namespace  \
  --namespace minio \
  -f new-values.yml

kubectl get po -n minio -owide
kubectl get svc -n minio

# 获取账户密码
kubectl get secrets -n minio \
myminio-env-configuration \
-ojsonpath='{.data.config\.env}' | base64 -d

svc_type="NodePort"
#SVC_TYPE="LoadBalancer"
kubectl patch svc myminio-console -n minio -p '{"spec":{"type":"NodePort"}}'

kubectl get svc/myminio-hl -n minio -o yaml > myminio-hl-svc.yaml.back
kubectl delete svc myminio-hl -n minio

cat > myminio-hl-svc.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    v1.min.io/tenant: myminio
  name: myminio-hl
  namespace: minio
spec:
  ports:
  - name: https-minio
    port: 9000
    protocol: TCP
    targetPort: 9000
  publishNotReadyAddresses: true
  selector:
    v1.min.io/tenant: myminio
  type: $svc_type
EOF
kubectl apply -f myminio-hl-svc.yamlkl

# 自动TLS， 使用k8s dns：https://minio.minio.svc.cluster.local
# 完整文档：https://docs.min.io/community/minio-object-store/operations/network-encryption.html#minio-tls-kubernetes
