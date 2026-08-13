#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 设置网卡多队列数（假设最大8队列，按需调整）
#sudo ethtool -L enp0s5 combined 4   # 4核节点设为4

# 开启 RPS（将软中断分散到所有 CPU）
sudo mkdir -p /usr/local/bin
cat > /usr/local/bin/set-rps.sh <<'EOF'
#!/bin/bash
set -e

INTERFACE="enp0s5"

# 检查网卡是否存在
if [ ! -d "/sys/class/net/$INTERFACE" ]; then
    echo "Interface $INTERFACE does not exist, exiting."
    exit 1
fi

# 计算所有 CPU 的掩码
CPU_MASK=$(printf "%x" $(( (1 << $(nproc)) - 1 )))

# 写入所有接收队列的 rps_cpus
for rxq in /sys/class/net/$INTERFACE/queues/rx-*; do
    if [ -f "$rxq/rps_cpus" ]; then
        echo "Setting mask $CPU_MASK for $rxq/rps_cpus"
        echo "$CPU_MASK" > "$rxq/rps_cpus"
    fi
done
EOF
chmod +x /usr/local/bin/set-rps.sh

cat > /etc/systemd/system/set-rps.service <<EOF
[Unit]
Description=Set Network RPS CPU Mask for enp0s5
After=network.target sys-subsystem-net-devices-enp0s5.device
BindsTo=sys-subsystem-net-devices-enp0s5.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/set-rps.sh

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable set-rps.service
sudo systemctl start set-rps.service

sudo systemctl status set-rps.service
# 查看 rps_cpus 的值是否已经成功改变
cat /sys/class/net/enp0s5/queues/rx-0/rps_cpus

# 永久设置 rps_sock_flow_entries
echo "net.core.rps_sock_flow_entries = 32768" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
