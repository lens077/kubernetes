#!/usr/bin/env bash
#
# 配置Kubernetes所需要的基本依赖项, 例如内核参数, 启用和使用社区广泛推荐的内核参数

set -e -o posix -o pipefail -x

declare resolve_dns=1.1.1.1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --trace=*)
            trace=true
            shift
            ;;
        --resolve_dns=*)
            resolve_dns="${1#*=}"
            shift
            ;;
        *)  # 处理未知选项
            echo "Error: Unsupported argument $1."
            exit 1
            ;;
    esac
done

sudo apt update && sudo apt full-upgrade -y
sudo apt autoremove
sudo apt autoclean

# 运行前清理
pre_clear(){
  declare describe="运行前清理, 还原到被修改的文件前的配置"
  echo $describe

  if [ -f /etc/security/limits.conf.back ];then
    mv /etc/security/limits.conf{.back,}
  fi
  if [ -f /etc/profile.back ];then
    mv /etc/profile{.back,}
  fi
  if [ -f /etc/hosts.back ];then
    mv /etc/hosts{.back,}
  fi
  if [ -f /etc/fstab.back ];then
    mv /etc/fstab{.back,}
  fi

  rm -rf /etc/sysctl.d/99-kubernetes-cri.conf
}

# 内核参数设置
set_kernel_parameters() {
  echo "配置内核参数"
  # 确保内核模块加载
  sudo modprobe br_netfilter
  sudo modprobe nf_conntrack
  sudo modprobe overlay
  sudo modprobe xt_socket

  cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf > /dev/null
# 启用桥接流量到 iptables/ip6tables 的传递。
# 这是 kube-proxy 和一些 CNI 插件依赖的基础，用于 Service 路由和网络策略。
net.bridge.bridge-nf-call-iptables        = 1
net.bridge.bridge-nf-call-ip6tables       = 1

# 启用 IPv4 路由/IP 转发。容器网络通信的必备条件。
net.ipv4.ip_forward                       = 1

# 禁用整个系统的 IPv6。在不使用 IPv6 的集群中可以简化网络。
net.ipv6.conf.all.disable_ipv6            = 1

# 提高连接跟踪表 (conntrack) 的最大容量，用于处理高并发连接。
# 避免在高负载下连接跟踪表满导致的网络错误。
net.netfilter.nf_conntrack_max            = 25000000

# ----------------------------------------
# 🧠 内存管理参数 (Memory)
# ----------------------------------------

# 禁用或极力避免使用 Swap 交换空间 (设置为 0)。
# 确保容器数据尽量保留在物理内存中以保证性能。
vm.swappiness                             = 0

# 内存过量分配策略：
# 0 (启发式)：允许一定程度的超额分配，是 Linux 默认设置。
vm.overcommit_memory                      = 0

# OOM (Out Of Memory) 策略：
# 0 (OOM Killer)：内存耗尽时，内核尝试杀死占用大量内存的进程，而非立即宕机。
vm.panic_on_oom                           = 0

# ----------------------------------------
# 📁 文件系统参数 (Filesystem)
# ----------------------------------------

# 限制系统范围内和单个进程可打开的最大文件句柄数。
# 为高密度容器环境提供足够的句柄资源。
fs.file-max                               = 52706963
fs.nr_open                                = 52706963

# 设置每个用户可创建的最大 inotify 实例数和可监控的文件/目录数。
# 用于文件系统事件监控，对开发工具和容器内服务很重要。
fs.inotify.max_user_instances             = 8192
fs.inotify.max_user_watches               = 1048576
EOF

  # 正确加载内核模块
  mkdir -p /etc/modules-load.d
  cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
nf_conntrack
overlay
xt_socket
EOF

  sudo systemctl restart systemd-modules-load.service
  sudo sysctl --system
}

# 修正3: 修复swap处理（Kubernetes v1.22+支持swap，但必须明确禁用）
disable_swap() {
  echo "禁用swap"
  # 修正：使用正确语法检查swap
  if grep -q swap /proc/swaps; then
    echo "发现swap分区，正在禁用..."
    sudo swapoff -a
    # 修正：正确注释/etc/fstab中的swap
    sudo sed -i '/swap/s/^/#/' /etc/fstab
    # 修正：验证swap已禁用
    if grep -q swap /proc/swaps; then
      echo "❌ Swap禁用失败，请手动检查"
      exit 1
    fi
  fi
}

# 修正4: 修复DNS配置（Kubernetes要求systemd-resolved被禁用）
#set_dns() {
#  echo "配置DNS"
#  # 修正：正确禁用systemd-resolved
#  sudo systemctl stop systemd-resolved
#  sudo systemctl disable systemd-resolved
#  sudo rm -f /etc/resolv.conf  # 修复：使用rm -f避免错误
#  cat > /etc/resolv.conf <<EOF
#nameserver $resolve_dns
#EOF
#}

# 修改默认的文件限制（Kubernetes要求ulimit设置）
set_file_limits() {
  echo "设置文件限制"
  cp /etc/security/limits.conf{,.back}
  cat > /etc/security/limits.conf <<EOF
* soft nofile 655350
* hard nofile 655350
* soft nproc 655350
* hard nproc 655350
* soft core unlimited
* hard core unlimited
EOF
}

set_timezone() {
  echo "设置时区"
  sudo timedatectl set-timezone Asia/Shanghai
}

disable_selinux() {
  echo "禁用SELinux"
  if command -v setenforce >/dev/null 2>&1; then
    sudo setenforce 0
  fi
  if [[ -e /etc/selinux/config ]]; then
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  fi
}

main() {
  "$trace" && set -x
  pre_clear

  # 验证MAC和product_uuid（Kubernetes要求唯一性）
  echo "验证MAC地址: $(cat /sys/class/net/eth0/address 2>/dev/null || echo 'N/A')"
  echo "验证product_uuid: $(sudo cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo 'N/A')"

  # 按照Kubernetes文档顺序执行
  set_timezone
#  set_dns
  disable_selinux
  disable_swap
  set_kernel_parameters
  set_file_limits

  echo "✅ Kubernetes前置配置完成！"
  echo "检查内核参数:"
  sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
  echo "检查swap:"
  grep -q swap /proc/swaps && echo "❌ Swap未禁用" || echo "✅ Swap已禁用"
}

main "$trace"
