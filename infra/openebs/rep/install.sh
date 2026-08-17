#!/bin/bash
set -x

# 安装前必须设置的
sudo vi /etc/default/grub
#GRUB_CMDLINE_LINUX="<现有参数> nvme_core.multipath=Y"
sudo update-grub
sudo reboot
cat /proc/cmdline | grep "nvme_core.multipath=Y"
#如果输出中包含 nvme_core.multipath=Y，则表示启用成功。

# 加载 nvme-tcp 模块
sudo modprobe nvme-tcp
echo "nvme-tcp" | sudo tee /etc/modules-load.d/nvme-tcp.conf
sudo update-initramfs -u

grep HugePages /proc/meminfo
echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
echo vm.nr_hugepages = 1024 | sudo tee -a /etc/sysctl.conf


kubectl label node node1 openebs.io/engine=mayastor
kubectl label node node2 openebs.io/engine=mayastor
kubectl label node node3 openebs.io/engine=mayastor
systemctl restart kubelet

helm install openebs ./openebs --namespace openebs --create-namespace \
  --set engines.local.lvm.enabled=true \
  --set engines.local.zfs.enabled=false \
  --set engines.replicated.mayastor.enabled=true


set +x
