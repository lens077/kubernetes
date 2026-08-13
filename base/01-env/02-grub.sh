#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail
echo "减少虚拟机开销、关闭大页透明化（避免数据库延迟抖动）"
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 nmi_watchdog=0 numa=off transparent_hugepage=never"/' /etc/default/grub
sudo update-grub
