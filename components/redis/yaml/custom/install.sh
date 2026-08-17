#!/bin/bash

set -x

kubectl apply -f openebs-lvm-redis-sc.yaml
kubectl apply -f redis-config.yaml
kubectl apply -f redis-statefulset.yaml
kubectl apply -f redis-service.yaml

# 测试：cilium 18.4不支持Gateway TCPRoute，redis基于TCP，
# 所以任何TCP的服务都无法使用Cilium的Gateway TCPRoute
kubectl get pods -l app=redis
kubectl exec -it redis-0 -- redis-cli
# 在内部执行：
auth msdnmm
ping
config get appendonly
config get dir
set mykey "Hello from Redis"
get mykey
quit

# 2. 在外部执行，账号default，密码msdnmm，端口32379，IP是运行该Redis Pod的节点IP

set +x
