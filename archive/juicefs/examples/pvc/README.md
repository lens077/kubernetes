https://juicefs.com/docs/zh/csi/guide/pv/#mount-pod-extra-files


静态配置（如果你尚不清楚什么是静态配置，先阅读「静态配置」）：

注意
使用静态配置方式，必须注意让 volumeHandle 保持唯一，否则将会出现 timed out waiting for the condition 错误，详见 PVC 异常中的「volumeHandle 冲突，导致 PVC 创建失败」一小节。

为了防止此类错误的发生，建议开启 Validating webhook。
```yml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vol-1
spec:
  ...
  csi:
    driver: csi.juicefs.com
    # 该字段必须全局唯一，建议直接设置为 PV 名称
    volumeHandle: vol-1
    fsType: juicefs
    nodePublishSecretRef:
      name: vol-secret-1
      namespace: default
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vol-2
spec:
  ...
  csi:
    driver: csi.juicefs.com
    volumeHandle: vol-2
    fsType: juicefs
    nodePublishSecretRef:
      name: vol-secret-2
      namespace: kube-system
```

动态配置（如果你尚不清楚什么是动态配置，先阅读「动态配置」）：
```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vol-1
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: vol-1
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-publish-secret-name: vol-1
  csi.storage.k8s.io/node-publish-secret-namespace: default
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vol-2
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: vol-2
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
  csi.storage.k8s.io/node-publish-secret-name: vol-2
  csi.storage.k8s.io/node-publish-secret-namespace: kube-system
```
