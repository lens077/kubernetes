mkdir -p /home/kubernetes/elastic
cd /home/kubernetes/elastic

helm repo add elastic https://helm.elastic.co
helm repo update

# 前置条件
# https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/install-using-helm-chart
# 集群范围（全局）安装
helm install elastic-operator elastic/eck-operator -n elastic-system --create-namespace

# Install an eck-managed Elasticsearch and Kibana using the default values, which deploys the quickstart examples.
helm pull elastic/eck-stack
tar -zxvf eck-stack-*.tgz

# 禁用内部TLS，在网关层来作为tls
cat > es-disable-tls.yml <<EOF
eck-elasticsearch:
  http:
    tls:
      selfSignedCertificate:
        disabled: true

# 禁用 Kibana 内部 TLS
eck-kibana:
  http:
    tls:
      selfSignedCertificate:
        disabled: true
EOF

#cat > es-disable-tls.yml <<EOF
## 必须是子 Chart 的真实注册名称：elasticsearch
#elasticsearch:
#  spec:
#    http:
#      tls:
#        selfSignedCertificate:
#          disabled: true
#
## 必须是子 Chart 的真实注册名称：kibana
#kibana:
#  spec:
#    http:
#      tls:
#        selfSignedCertificate:
#          disabled: true
#EOF

kubectl get pvc -n elastic-stack
kubectl delete pvc -n eck-stack elasticsearch-data-elasticsearch-es-default-0
helm uninstall es-kb-quickstart -n elastic-stack || true
helm upgrade --install es-kb-quickstart \
  ./eck-stack \
  -n elastic-stack \
  --create-namespace \
  -f es-disable-tls.yml

# 获取默认密码, 账号默认为elastic
kubectl get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}' -n elastic-stack

# ── 2026-08-06：给 Kibana 限定内存 ───────────────────────────────────────────
#
# eck-stack 默认不给 Kibana 设 resources，ECK 于是按自己的默认值给了 2Gi
# requests/limits，而实测常驻只有 929Mi —— 1.1Gi 是纯空占。
#
# 这在别的集群可能无所谓，但本集群 node3 的内存 requests 一度占到 99%，
# 而 node1 是 control-plane 带 NoSchedule 污点（那 6GB 空闲用不上），
# 实际可用的只有 node2 和 node3 两个节点。Kibana 这 2Gi 又恰好压在 node3 上，
# 把 Kafka broker（PV 是 openebs-lvmpv 硬亲和 node3，换不了节点）挤得没有
# requests 可用，broker 只能以 BestEffort 运行并被 OOMKill 了 41 次。
#
# 下调到 1408Mi（VPA 实测推荐 target 1114Mi、lowerBound 1038Mi，留约 25% 余量）。
# Kibana 无 PVC，改完重建时调度器会自动把它挪到 node2，node3 因此腾出 2Gi。
#
# 查看依据：kubectl -n elastic-stack describe vpa kibana-vpa
# （该 VPA 定义在 vpa/examples/example1/elastic-stack.yml，updateMode 是 "Off"，
#   因为 ECK 会 reconcile 掉 VPA 的写入，只能由人改 CR。）
kubectl -n elastic-stack patch kibana es-kb-quickstart-eck-kibana --type=merge -p '{
  "spec": {"podTemplate": {"spec": {"containers": [{
    "name": "kibana",
    "resources": {"requests": {"cpu": "100m", "memory": "1408Mi"},
                  "limits":   {"memory": "1408Mi"}}
  }]}}}
}'
