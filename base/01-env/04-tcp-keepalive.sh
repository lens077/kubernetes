#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 如果使用较短的 nf_conntrack_tcp_timeout_established（如 180 秒），则需开启 TCP keepalive 避免长连接被中断：

cat <<EOF | sudo tee -a /etc/sysctl.d/99-k8s-optimized.conf
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
EOF
sudo sysctl --system

# 确保应用代码（如 PostgreSQL 客户端、Kafka 生产者）启用了 SO_KEEPALIVE。

# 查看当前连接数
#cat /proc/sys/net/netfilter/nf_conntrack_count
## 监控日志是否有 table full 警告
#dmesg | grep nf_conntrack
