# https://docs.greptime.cn/user-guide/deployments-administration/deploy-on-kubernetes/deploy-greptimedb-standalone/

cd /home/kubernetes/
mkdir -p greptime
cd greptime

kubectl create ns greptimedb

helm repo add greptime https://greptimeteam.github.io/helm-charts/
helm repo update

cat > values.yaml <<EOF
# https://github.com/GreptimeTeam/helm-charts/tree/main/charts/greptimedb-standalone
resources:
  requests:
    cpu: "1"
    memory: "1Gi"
  limits:
    cpu: "3"
    memory: "2Gi"
persistence:
  size: 10Gi
  storageClass: openebs-lvmpv
EOF

helm upgrade --install greptimedb-standalone greptime/greptimedb-standalone -n greptimedb -f values.yaml

# 对于K8S的内部Pod连接, 推荐使用DNS
# http://greptimedb-standalone.greptimedb.svc.cluster.local:4000

# 对外开放
#kubectl patch svc -n greptimedb greptimedb-standalone -p '{"spec":{"type":"LoadBalancer"}}'

# grafana安装greptimedb插件
# https://docs.greptime.cn/user-guide/integrations/grafana/
# https://github.com/GreptimeTeam/greptimedb-grafana-datasource/releases/latest

#kubectl exec -it -n observability pod/grafana-566c4ff4f-tbg2h -- sh
# 如果滚动更新策略如下, 你的Pod数量设置为1时,很可能会出现两个Pod同时挂载到同一个路径,取决于你的SCI
# strategy:
#   rollingUpdate:
#     maxSurge: 25%
#     maxUnavailable: 25%
#   type: RollingUpdate

# 如果冲突,那么可以尝试编辑为
#strategy:
#  type: RollingUpdate
#  rollingUpdate:
#    maxSurge: 0
#    maxUnavailable: 1
