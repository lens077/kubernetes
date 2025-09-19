#!/bin/bash
set -x
# 先修改blocks的IP池范围和interfaces为你的网卡设备名称
kubectl apply -f ./ippools/examples/cilium-l2-config.yaml

set +x
