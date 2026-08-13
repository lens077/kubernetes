#!/usr/bin/env bash
set -e -o pipefail

# ----- 配置变量（可根据需要修改）-----
#RESOLVE_DNS="114.114.114.114"

echo "=========================================="
echo "  Kubernetes 系统初始化（7GB 内存版）"
echo "=========================================="

# 1. 更新系统并安装基础工具
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl wget vim net-tools ethtool iproute2

# 2. 时区设置
sudo timedatectl set-timezone Asia/Shanghai

timedatectl status
# 查看当前时间是否与标准时间一致
date

cp /etc/chrony/sources.d/ubuntu-ntp-pools.sources{,.back}

cat > /etc/chrony/sources.d/ubuntu-ntp-pools.sources <<'EOF'
# 使用国内稳定的阿里云 NTP（不支持 NTS，去掉 prefer 和 nts 参数）
pool ntp.aliyun.com iburst maxsources 4
pool ntp.tencent.com iburst maxsources 2
EOF
sudo chronyc -a makestep
sudo systemctl restart chrony

# 3. 禁用 SELinux（Ubuntu 默认不安装，此处仅作兼容）
if command -v setenforce &>/dev/null; then
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
fi

# 4. 禁用 Swap（K8s 强制要求）
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab

# 5. 加载内核模块（overlay, br_netfilter, conntrack, xt_socket）
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe nf_conntrack
sudo modprobe xt_socket
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nf_conntrack
xt_socket
EOF
sudo systemctl restart systemd-modules-load.service

# 6. 配置内核参数（基于 7GB 内存优化的安全参数）
sudo rm -f /etc/sysctl.d/99-kubernetes-cri.conf   # 删除旧的大厂参数文件
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-optimized.conf > /dev/null
# ========== 基础网络 ==========
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# 彻底禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# ========== TCP 内存安全 ==========
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 1048576 4194304
net.ipv4.tcp_wmem = 4096 1048576 4194304

net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# ========== eBPF 优化 ==========
net.core.bpf_jit_enable = 1
net.core.bpf_jit_kallsyms = 1
net.core.bpf_jit_harden = 0          # 内网安全，降低内存开销

# ========== 拥塞控制 ==========
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ========== 连接跟踪表（50 万条，约 160MB 内存）==========
net.netfilter.nf_conntrack_max = 500000
net.nf_conntrack_max = 500000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30

# ========== 其他网络优化 ==========
net.ipv4.tcp_slow_start_after_idle = 0
net.core.dev_weight = 64
net.core.dev_weight_rx_bias = 16
net.core.dev_weight_tx_bias = 16

# ========== 内存管理 ==========
vm.swappiness = 0
vm.overcommit_memory = 0
vm.panic_on_oom = 0
vm.vfs_cache_pressure = 50

# ========== 文件句柄 ==========
fs.file-max = 52706963
fs.nr_open = 52706963
fs.epoll.max_user_instances = 8192
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF

sudo sysctl --system

# 7. 设置 limits.conf（文件描述符、进程数）
sudo cp /etc/security/limits.conf /etc/security/limits.conf.bak 2>/dev/null || true
cat <<EOF | sudo tee /etc/security/limits.conf
* soft nofile 655350
* hard nofile 655350
* soft nproc 655350
* hard nproc 655350
* soft core unlimited
* hard core unlimited
EOF

# 8. 可选：设置 DNS（如需固定 DNS，可取消注释）
# sudo systemctl stop systemd-resolved && sudo systemctl disable systemd-resolved
# sudo rm -f /etc/resolv.conf
# echo "nameserver $RESOLVE_DNS" | sudo tee /etc/resolv.conf

for svc in irqbalance bluetooth avahi-daemon cups; do
    if systemctl list-unit-files | grep -q "^$svc.service"; then
        sudo systemctl disable --now "$svc"
    fi
done

# 9. 校验
echo "=========================================="
echo "✅ 系统初始化完成，请重启节点以完全生效"
echo "=========================================="
