#!/bin/bash
set -x
# 先修改blocks的IP池范围和interfaces为你的网卡设备名称

devices="enp0s5"  # 你的机器的网卡设备
ip_blocks_start="192.168.3.104"  # IP地址范围开始的IP
ip_blocks_stop="192.168.3.250" # IP地址范围结束的IP
cat > pool-poilcy.yml <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  # IP池范围
  blocks:
    - start: ${ip_blocks_start}
      stop: ${ip_blocks_stop}
---
# https://docs.cilium.io/en/latest/network/l2-announcements/#policies
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-policy
spec:
#  serviceSelector: {}
#  nodeSelector: {}
  externalIPs: false
  loadBalancerIPs: true
  interfaces:
    - ${devices}
EOF

kubectl apply -f pool-poilcy.yml

set +x
