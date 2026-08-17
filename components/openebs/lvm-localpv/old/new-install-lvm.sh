#!/bin/bash

# 脚本遇到任何错误时立即退出
set -e

echo "========================================================="
echo " 开始配置 OpenEBS LVM 本地存储底座"
echo "========================================================="

# ---------------------------------------------------------
# 1. 创建虚拟磁盘文件并进行 LVM 首次初始化
# ---------------------------------------------------------
IMG_FILE="/openebs-lvm-pool.img"
VG_NAME="lvmvg"

echo "步骤 1: 创建 250GB 映像文件 (稀疏文件)..."
# 注意：如果是在物理生产环境，推荐使用 dd 占满空间防止宿主机爆盘
sudo truncate -s 250G "${IMG_FILE}"

echo "步骤 2: 动态寻找并关联空闲的环回设备..."
# --show 会返回实际绑定的 loop 设备名（如 /dev/loop0），避免并发和命名冲突
LOOP_DEV=$(sudo losetup -f --show "${IMG_FILE}")
echo "成功将文件绑定到设备: ${LOOP_DEV}"

echo "步骤 3: 初始化 LVM 物理卷(PV)和卷组(VG)..."
sudo pvcreate "${LOOP_DEV}"
sudo vgcreate "${VG_NAME}" "${LOOP_DEV}"

echo "当前 LVM 卷组状态："
sudo vgs "${VG_NAME}"


# ---------------------------------------------------------
# 2. 写入开机自动挂载与激活的 Systemd 服务
# ---------------------------------------------------------
echo "步骤 4: 写入守护服务以确保宿主机重启后自动激活该 VG..."

# 使用 unmask 防止系统之前留有同名的失效服务屏蔽软链接
sudo systemctl unmask openebs-lvm-init.service || true

sudo cat > /etc/systemd/system/openebs-lvm-init.service <<'EOF'
[Unit]
Description=OpenEBS LVM Pool Initialization
# 尽早启动，不依赖默认的常规网络和服务
DefaultDependencies=no
# 在系统模块加载和本地文件系统挂载之后执行
After=systemd-modules-load.service local-fs.target
# 必须在 Kubelet 启动之前完成，否则 K8s 找不到该存储
Before=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes

# 【启动逻辑】：
# 1. 动态寻找空闲 loop 设备挂载 img 文件
# 2. 刷新 LVM 缓存使其认到刚挂载的设备
# 3. 激活名为 lvmvg 的卷组
ExecStart=/bin/sh -c '\
    LOOP_DEV=$(/usr/sbin/losetup -f --show /openebs-lvm-pool.img); \
    /sbin/pvscan --cache $LOOP_DEV; \
    /sbin/vgchange -ay lvmvg'

# 【停止逻辑】：
# 1. 停机时先安全地去激活该卷组（防止数据损坏）
# 2. 找到指向该 img 文件的所有 loop 设备并释放
ExecStop=/bin/sh -c '\
    /sbin/vgchange -an lvmvg; \
    /usr/sbin/losetup -j /openebs-lvm-pool.img | cut -d: -f1 | xargs -r /usr/sbin/losetup -d'

[Install]
WantedBy=multi-user.target
EOF

echo "步骤 5: 重新加载并启用 Systemd 服务..."
sudo systemctl daemon-reload
sudo systemctl enable openebs-lvm-init.service
sudo systemctl start openebs-lvm-init.service
