#!/usr/bin/env bash

# ---------------------------------------------------------
# 3. 使用 Helm 安装 OpenEBS LVM 驱动
# ---------------------------------------------------------
echo "========================================================="
echo " 开始安装 OpenEBS Helm Chart"
echo "========================================================="

# 检查 Helm 是否安装
if ! command -v helm &> /dev/null; then
    echo "提示: 系统未安装 Helm，正在安装 Helm"
else
    echo "提示: 系统已安装 Helm，脚本将退出以避免干扰。"
    exit 0
fi

# 更新包索引并安装必要工具
sudo apt-get update
sudo apt-get install -y curl gpg apt-transport-https

# 获取并安装 Helm GPG 密钥
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | sudo gpg --dearmor -o /etc/apt/keyrings/helm.gpg

# 添加 Helm APT 仓库
echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

# 更新包列表并安装 Helm
sudo apt-get update
sudo apt-get install -y helm

helm repo add openebs https://openebs.github.io/openebs
helm repo update

# 精简安装：仅开启 LVM 驱动，关闭不必要的 ZFS 和 Mayastor(架构重且单机不需要)
# 按照 OpenEBS 的文档，使用 Helm 安装 lvm-localpv 驱动程序，并确保在 StorageClass 配置中将 volgroup 名称设置为 lvmvg。
# --set engines.local.lvm.enabled=true \ 逻辑卷
# --set engines.local.zfs.enabled=false \ 不安装zfs
#  --set engines.replicated.mayastor.enabled=false 不安装replicated， 即复制卷， 这是高可用的基础，对于单机价值不大
helm pull openebs/openebs
tar -zxvf openebs-*.tgz
#helm uninstall openebs -n openebs
cat > openebs-values.yml <<EOF
# 1. 核心引擎开关：精简至仅保留 LVM
engines:
  local:
    lvm:
      enabled: true
    zfs:
      enabled: false
    rawfile:
      enabled: false
    hostpath:
      enabled: false  # 如果不需要传统的 hostpath（基于目录的PV），也可以关掉
  replicated:
    mayastor:
      enabled: false  # 彻底关闭昂贵的 Mayastor 引擎


# 2. 彻底关闭可观测性组件（节省大量 CPU/内存）

loki:
  enabled: false      # 关闭内置的 Loki 日志栈
  minio:
    enabled: false    # 同步关闭给 Loki 做对象存储的 MinIO

alloy:
  enabled: false      # 满足你的要求：彻底不使用 Alloy 日志采集器


# 3. 清理不需要的 CRD 安装

zfs-localpv:
  crds:
    zfsLocalPv:
      enabled: false  # 不安装 ZFS 的相关 CRD
lvm-localpv:
  crds:
    lvmLocalPv:
      enabled: true   # 仅保留 LVM CRD
rawfile-localpv:
  crds:
    csi:
      volumeSnapshots:
        enabled: false


# 4. LVM 引擎性能与资源限制优化

# 注意：OpenEBS 伞架构下，子 Chart 的资源限制需要穿透传递到对应的子模块中。
# 以下是针对 lvm-localpv 子模块的规格裁剪：
lvm-localpv:
  # Controller 负责监听 PVC 并创建/销毁 LVM 卷
  controller:
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 64Mi
  # Node 是 DaemonSet，运行在每个节点上，负责实际的 LVM 挂载和 CGroup 隔离
  node:
    resources:
      limits:
        cpu: 300m
        memory: 256Mi
      requests:
        cpu: 100m
        memory: 64Mi

# 如果保留了 localpv-provisioner（即 hostpath），同样需要对其进行降配
localpv-provisioner:
  analytics:
    enabled: false    # 关闭匿名数据上报
  # 对其组件限制资源
  provisioner:
    resources:
      limits:
        cpu: 100m
        memory: 128Mi
      requests:
        cpu: 20m
        memory: 4Mi
EOF
helm upgrade --install openebs ./openebs \
  --namespace openebs \
  --create-namespace \
  -f openebs-values.yml

# ---------------------------------------------------------
# 4. 创建 Kubernetes StorageClass (关键配置修正)
# ---------------------------------------------------------
echo "步骤 6: 创建 OpenEBS LVM StorageClass..."

# 创建lvm的sc https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-lvm/configuration/lvm-create-storageclass#lvm-supported-storageclass-parameters
cat > lvm-sc.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-lvmpv
parameters:
  storage: "lvm"
  volgroup: "${VG_NAME}"  # 指定我们在上面创建的卷组
provisioner: local.csi.openebs.io
# 【关键优化】: WaitForFirstConsumer
# 延迟绑定。让 K8s 先调度 Pod，确定 Pod 在哪个节点后，再在该节点创建 LVM 卷。
# 彻底避免多节点集群下 Pod 与存储错开在不同节点的尴尬。
volumeBindingMode: WaitForFirstConsumer
# 允许后期直接对 PVC 进行编辑扩容
allowVolumeExpansion: true
EOF

kubectl apply -f lvm-sc.yaml

# 将其设为集群默认的 StorageClass (可选)
kubectl patch storageclass openebs-lvmpv \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'


# ---------------------------------------------------------
# 5. 自动化部署验证测试
# ---------------------------------------------------------
echo "========================================================="
echo " 正在进行存储功能自动化验证..."
echo "========================================================="

# 创建 PVC
cat > test-lvm-pvc.yml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-lvm-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: openebs-lvmpv
EOF
kubectl apply -f test-lvm-pvc.yml

# 创建测试 Pod 挂载 PVC
cat > test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: default
spec:
  containers:
  - name: my-app-container
    image: busybox
    command: ["/bin/sh", "-c", "echo 'Hello from OpenEBS LVM!' > /data/test.txt; sleep 10; cat /data/test.txt"]
    volumeMounts:
    - name: my-lvm-storage
      mountPath: "/data"
  volumes:
  - name: my-lvm-storage
    persistentVolumeClaim:
      claimName: my-lvm-pvc
EOF
kubectl apply -f test-pod.yaml

echo "等待测试 Pod 启动并运行..."
# 等待最多 60 秒直到 Pod 变为运行状态
kubectl wait --for=condition=Ready pod/my-app --timeout=60s

echo "检查 Pod 日志输出："
kubectl logs my-app

echo "========================================================="
echo " 🎉 OpenEBS LVM 部署与测试圆满成功！"
echo "========================================================="
