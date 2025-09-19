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

# 修正1: 修复内核参数设置（必须在set_file_limits之前执行）
set_kernel_parameters() {
  echo "配置内核参数"
  # 确保内核模块加载
  sudo modprobe br_netfilter
  sudo modprobe nf_conntrack
  sudo modprobe overlay

  # 修正2: 修复内核参数设置（必须使用99-kubernetes-cri.conf）
  cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
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
set_dns() {
  echo "配置DNS"
  # 修正：正确禁用systemd-resolved
  sudo systemctl stop systemd-resolved
  sudo systemctl disable systemd-resolved
  sudo rm -f /etc/resolv.conf  # 修复：使用rm -f避免错误
  cat > /etc/resolv.conf <<EOF
nameserver $resolve_dns
EOF
}

# 修正5: 修复文件限制（Kubernetes要求ulimit设置）
set_file_limits() {
  echo "设置文件限制"
  # 修正：正确设置limits.conf
  cat > /etc/security/limits.conf <<EOF
* soft nofile 655350
* hard nofile 655350
* soft nproc 655350
* hard nproc 655350
* soft core unlimited
* hard core unlimited
EOF

  # 修正：使用正确文件名（99-kubernetes-cri.conf）
  cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables        = 1
net.bridge.bridge-nf-call-ip6tables       = 1
net.ipv4.ip_forward                       = 1
vm.swappiness                             = 0
vm.overcommit_memory                      = 0
vm.panic_on_oom                           = 0
fs.inotify.max_user_instances             = 8192
fs.inotify.max_user_watches               = 1048576
fs.file-max                               = 52706963
fs.nr_open                                = 52706963
net.ipv6.conf.all.disable_ipv6            = 1
net.netfilter.nf_conntrack_max            = 25000000
EOF

  # 修正：正确加载内核模块
  mkdir -p /etc/modules-load.d
  cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
nf_conntrack
overlay
EOF
  sudo systemctl restart systemd-modules-load.service
  sudo sysctl --system
}

set_timezone() {
  echo "设置时区"
  sudo timedatectl set-timezone Asia/Shanghai
}

set_hosts() {
  echo "配置hosts"
  cp /etc/hosts{,.back}
  cat > /etc/hosts <<EOF
127.0.1.1 localhost.localdomain VM-20-8-ubuntu
127.0.0.1 localhost

::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF
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

# 修正6: 移除set_static_route（Kubernetes节点通常用DHCP，静态IP非必须）
# set_static_route() { ... }

main() {
  "$trace" && set -x
  pre_clear

  # 验证MAC和product_uuid（Kubernetes要求唯一性）
  echo "验证MAC地址: $(cat /sys/class/net/eth0/address 2>/dev/null || echo 'N/A')"
  echo "验证product_uuid: $(sudo cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo 'N/A')"

  # 按照Kubernetes文档顺序执行
  set_timezone
  set_hosts
  set_dns
  disable_selinux
  disable_swap
  set_kernel_parameters  # 修正1: 必须在set_file_limits之前
  set_file_limits        # 修正5: 包含内核参数设置

  echo "✅ Kubernetes前置配置完成！"
  echo "检查内核参数:"
  sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
  echo "检查swap:"
  grep -q swap /proc/swaps && echo "❌ Swap未禁用" || echo "✅ Swap已禁用"
}

main "$trace"
