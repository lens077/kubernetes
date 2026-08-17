#!/bin/bash

sudo vgs
#VG        #PV #LV #SN Attr   VSize   VFree
#ubuntu-vg   1   1   0 wz--n- <60.95g 30.47g

lsblk
#NAME                      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
#sda                         8:0    0  300G  0 disk
#├─sda1                      8:1    0    1G  0 part /boot/efi
#├─sda2                      8:2    0    2G  0 part /boot
#└─sda3                      8:3    0 60.9G  0 part
#  └─ubuntu--vg-ubuntu--lv 252:0    0 30.5G  0 lvm  /
#sr0                        11:0    1 1024M  1 rom

# 如果你的盘还有大量空间没用：sda 共 300G，但只分了约 64G（sda1+sda2+sda3），还有约 236G
# 完全未分区；另外 ubuntu-vg 里还有 30.47G 空闲没分给根分区。建议这样分配：
# - 根分区：把 ubuntu-vg 里空闲的 30.47G 全部扩给 /（根变成 60G）。K8s
# 的容器镜像、日志都落在根分区，30G 跑你这套基础设施很快会满。
# - 新建独立 VG 给 OpenEBS：用剩余 236G 建新分区 sda4 → 专用 VG（如
# openebs-vg）。和系统 VG 分开,避免 PV 卷把根分区空间挤爆。
#  操作步骤（每个节点都执行）

#1. 扩展根分区（用掉 ubuntu-vg 的 30.47G 空闲）：
sudo lvextend -r -l +100%FREE ubuntu-vg/ubuntu-lv
#-r 会自动扩文件系统，执行后 df -h / 应显示约 60G。

#2. 用剩余空间创建 sda4：
sudo apt install -y gdisk
sudo sgdisk -n 4:0:0 -t 4:8e00 -c 4:openebs /dev/sda
sudo partx -u /dev/sda

#（-n 4:0:0 表示第 4 分区、起止都取默认即占满剩余空间；8e00 是 Linux LVM 类型。）

#用 lsblk 确认出现了约 236G 的 sda4。
lsblk

# 3. 建 PV 和专用 VG：
sudo pvcreate /dev/sda4
sudo vgcreate openebs-vg /dev/sda4
sudo vgs

# 此时应看到两个 VG：ubuntu-vg（60.9G，无空闲）和 openebs-vg（约 236G 全空闲）。
# 不需要在 openebs-vg 里手动建 LV——OpenEBS LocalPV-LVM 的 CSI 驱动会在创建 PVC
# 时自动 lvcreate

# VG         #PV #LV #SN Attr   VSize    VFree
# openebs-vg   1   0   0 wz--n- <236.00g <236.00g
# ubuntu-vg    1   1   0 wz--n-  <60.95g       0
