#!/bin/bash
set -x

# 这是 "没有空闲磁盘/分区时"的替代lvm方案：
# 先创建一个大文件（/openebs-lvm-pool.img），用 losetup 把文件模拟成块设备（/dev/loopX），再在 loop 设备上建
# PV/VG。

# 你已经有真实的分区 /dev/sda4 并建好了 openebs-vg，完全用不着这套模拟，而且 loop
# 文件方案明显更差：

# - 性能差：IO 多绕一层文件系统 + loop 驱动，数据库/ES 这类负载受影响明显。
# - 重启不保留：loop 关联默认开机会丢，还要额外配 systemd 服务或 /etc/rc.local 重新
# losetup，否则 VG 消失、Pod 全部起不来。
# - 空间双重记账：镜像文件占根分区空间，容易把 / 撑爆

vgs

sudo losetup -f /openebs-lvm-pool.img --show

lvdisplay

#查看所有回环设备 (List all)
sudo losetup -a

#查看指定设备的信息 (List a specific device)
#如果你只想确认 /dev/loop2 的状态：
sudo losetup /dev/loop2

#删除指定回环设备
#如果 /dev/loop2 上没有活动的文件系统或 LVM：
# 使用 -d 选项解除 /dev/loop2 和文件的关联
sudo losetup -d /dev/loop2

set +x
