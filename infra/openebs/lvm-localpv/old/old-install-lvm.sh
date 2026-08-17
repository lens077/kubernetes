#!/bin/bash
# https://openebs.io/docs/quickstart-guide/prerequisites

# 创建一个250GB的映像文件
#truncate -s 30G /tmp/disk.img
#
## 将映像文件关联到环回设备（例如 /dev/loop0）
#sudo losetup -f /tmp/disk.img --show
#
## 将环回设备（或你的物理磁盘）创建为物理卷（PV）
#sudo pvcreate /dev/loop0
#
## 创建一个名为 lvmvg 的卷组（VG）
#sudo vgcreate lvmvg /dev/loop0

sudo truncate -s 250G /openebs-lvm-pool.img
sudo losetup -f /openebs-lvm-pool.img  --show
sudo pvcreate /dev/loop0
sudo vgcreate lvmvg /dev/loop0
sudo vgs

# # 查找并卸载所有指向 /openebs-lvm-pool.img 的 loop 设备
#sudo losetup -a | grep /openebs-lvm-pool.img | cut -d: -f1 | xargs -r sudo losetup -d
cat > /etc/systemd/system/openebs-lvm-init.service <<EOF
[Unit]
Description=OpenEBS LVM Pool Initialization
Requires=local-fs.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 1. 启动时，找到一个空闲 loop 设备并挂载文件
ExecStartPre=/usr/sbin/losetup -f /openebs-lvm-pool.img
# 2. 激活 LVM 卷组
ExecStart=/sbin/vgchange -ay lvmvg
# 3. 验证 VG 状态
ExecStartPost=/sbin/vgs

# 停止时的逻辑：禁用 VG，然后卸载 Loop 设备
ExecStop=/bin/sh -c '/sbin/vgchange -an lvmvg; \
                    LOOP_DEV=$("/usr/sbin/losetup" -j /openebs-lvm-pool.img | cut -d: -f1); \
                    if [ -n "$LOOP_DEV" ]; then \
                        "/usr/sbin/losetup" -d "$LOOP_DEV"; \
                    fi'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable openebs-lvm-init.service
sudo systemctl start openebs-lvm-init.service


lvdisplay
sudo vgs

set +x
