#!/bin/bash
set -x

helm repo add juicefs https://juicedata.github.io/charts/
helm repo update

helm pull juicefs/juicefs-csi-driver
tar -zxvf juicefs-csi-driver-*.tgz

# 不论是初次安装还是后续的配置变更，都可以运行这一行命令达到效果
# CSI
helm upgrade --install juicefs-csi-driver \
 ./juicefs-csi-driver \
 -n kube-system

# 元数据存储
# redis
cat > juicefs-redis.conf <<EOF
# 设置最大内存限制，例如 2GB
maxmemory 2gb

# 当内存达到上限时，拒绝写入操作
maxmemory-policy noeviction
EOF

cat > juicefs-secret.yml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: juicefs-secret
  labels:
    # 增加该标签以启用认证信息校验
    juicefs.com/validate-secret: "true"
type: Opaque
stringData:
  name: juicefs
#  metaurl: redis://default:msdnmm@redis-service.redis:6379/15
  metaurl: redis://default:msdnmm@192.168.3.101:32379/15
  storage: minio
#  bucket: https://<BUCKET>.s3.<REGION>.amazonaws.com
  bucket: http://minio-service.minio.svc.cluster.local:9000
#  bucket: https://10.103.0.160/juicefs
  access-key: z4mYKNhTeNMMuidn5G9A
  secret-key: 2035Jq2GH2m781XxOBMILhj1n1u2aArJULySIUSj
  # 为 Mount Pod 注入环境变量，比如时区（默认 UTC），或者文件系统的 RSA 加密口令
  # envs: "{TZ: Asia/Shanghai, JFS_RSA_PASSPHRASE: xxx}"
  # juicefs format 命令参数
  # format-options: trash-days=1,block-size=4096
  # 如果文件系统启用了加密，还需要附上秘钥原文
  # encrypt_rsa_key: xxx
EOF
kubectl apply -f juicefs-secret.yml -n default

# 设置对象存储和元数据引擎
# redis+minio方案，有可以使用其他的
# 对象存储： https://juicefs.com/docs/zh/community/reference/how_to_set_up_object_storage/#minio
# 元数据引擎： https://juicefs.com/docs/zh/community/databases_for_metadata/
# url在填写时候注意，必须要让juicefs的Pod也能访问，可以通过NodePort开放端口
juicefs format \
    --storage minio \
    --bucket http://192.168.3.101:30306/juicefs \
    --access-key z4mYKNhTeNMMuidn5G9A \
    --secret-key 2035Jq2GH2m781XxOBMILhj1n1u2aArJULySIUSj \
    redis://default:msdnmm@192.168.3.101:32379/15 \
    juicefs

cat > juicefs.sc.yml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: juicefs-sc
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: juicefs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-publish-secret-name: juicefs-secret
  csi.storage.k8s.io/node-publish-secret-namespace: default
reclaimPolicy: Retain
EOF

kubectl apply -f juicefs.sc.yml

cat > test.yml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: juicefs-test-pod
  namespace: default
spec:
  containers:
  - name: app
    image: centos:latest
    command: ["/bin/sh", "-c"]
    args: ["while true; do echo $(date -u) >> /data/out.txt; sleep 5; done"]
    volumeMounts:
    - name: data-volume
      mountPath: /data
  volumes:
  - name: data-volume
    persistentVolumeClaim:
      claimName: juicefs-pvc-dynamic
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: juicefs-pvc-dynamic
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: juicefs-sc
EOF

# 按照教程安装时，默认安装在kube-systen里，如果测试不成功，可以通过juicefs-<node name>-pvc-xxx 这个Pod来查看日志
# kubectl logs -n kube-system po/juicefs-node3-pvc-03e6a8b3-fa64-4e5f-91aa-038a708f67fb-xdmiaxkube-sy

# 将 juicefs-sc 设置为默认 SC
kubectl annotate storageclass juicefs-sc storageclass.kubernetes.io/is-default-class=true --overwrite

set +x
