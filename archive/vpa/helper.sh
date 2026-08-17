#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail

# 检查 VPA 组件健康状态（确认已安装）
kubectl get deploy -n kube-system | grep vpa

# 列出需要VPA的组件
kubectl get ns,deploy,statefulSet -A

# 查看所有命名空间下的 VPA
kubectl get vpa -A

# 查看指定命名空间的 VPA
kubectl get vpa -n postgres

# 查看特定 VPA 的详细信息，包括推荐值
kubectl describe vpa postgres-vpa -n postgres
# Recommendation:
#    Container Recommendations:
#        Container Name:  postgresql
#        Lower Bound:    # 资源下限
#            Cpu:     200m
#            Memory:  500Mi
#        Target:        # 目标推荐值（最重要的参考）
#            Cpu:     400m
#            Memory:  800Mi
#        Upper Bound:    # 资源上限
#            Cpu:     1
#            Memory:  2Gi
#        Uncapped Target:  # 不考虑 maxAllowed 限制的理论推荐值
#            Cpu:     400m
#            Memory:  800Mi

# 查看 VPA 的 YAML 定义
kubectl get vpa postgres-vpa -n postgres -o yaml

# 查看 VPA 事件（了解模式行为）
# 当 VPA 触发更新或驱逐 Pod 时，会记录事件。
kubectl describe vpa postgres-vpa -n postgres | grep -A5 Events
