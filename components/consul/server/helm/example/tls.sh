#!/usr/bin/env bash
# 启用 POSIX 模式并设置严格的错误处理机制
set -o posix errexit -o pipefail
# 查询ca,crt和key的名称
kubectl describe secret consul-gateway-tls-secret -n consul

cat > consul-tls-values.yml <<EOF
# Source Config 1: https://developer.hashicorp.com/consul/tutorials/get-started-kubernetes/kubernetes-gs-deploy?variants=consul-deploy%3Aself-managed
# Source Config 2: https://developer.hashicorp.com/consul/docs/k8s/helm
# Source Config 3: https://juejin.cn/post/6993723824667639845
# Source Config 4: https://developer.hashicorp.com/consul/docs/secure-mesh/certificate/existing

global:
  tls:
    enabled: true
    # This configuration sets `verify_outgoing`, `verify_server_hostname`,
    # and `verify_incoming` to `false` on servers and clients,
    # which allows TLS-disabled nodes to join the cluster.

    # 是否自动签发
    enableAutoEncrypt: true
    caCert:
      # 存储 CA 证书的 Kubernetes 或 Vault 名称。
      secretName: "consul-root-ca-secret"
      # Kubernetes 或 Vault 秘密中保存 CA 证书的密钥。
      secretKey: "ca.crt"
    # 必须提供 CA 的 Key，以便 Consul 自动为内部 Server/Client 签发证书
    caKey:
      secretName: "consul-root-ca-secret"
      secretKey: "tls.key"

    # 是否强制开启 HTTPS, 如果是true,那么端口号+1,例如8500就是8501,而不是默认的8500的HTTP端口
    httpsOnly: true

    # 如果你的 Gateway 需要通过特定的域名访问 UI 或 API
    serverAdditionalDNSSANs:
      - "consul.app.com" # 换成你证书里对应的域名
      - "localhost"
    # 是否需要验证证书
    verify: false
  #  enable: true
  name: consul
  enablePodSecurityPolicies: false # true创建 Pod 安全策略, 防止consul client pod存储到同一个目录, 与client.dataDirectoryHostPath一起使用

# Configures and installs the automatic Consul Connect sidecar injector.
connectInject:
  enabled: false # 如果你需要服务网格（Sidecar 注入）
  apiGateway:
    # 核心配置：设为 false，防止 Consul 尝试再次安装 gatewayclasses 等 CRD 导致报错
    manageExternalCRDs: false

    # 选填：如果你的 Cilium 只安装了最核心的 CRD（Gateway/HTTPRoute），
    # 但你又想用 Consul 特有的扩展（如 TCPRoute），可以把这个设为 true
    manageNonStandardCRDs: false
ui:
  enable: true
  service:
    enable: true
    #    type: LoadBalancer
    type: LoadBalancer
#    port:
#      http: 80
#      https: 443
#    nodePort:
#      http: 31080
#      https: 31443
  # Enables displaying metrics in the Consul UI.
  metrics:
    enabled: false
    # The metrics provider specification.
    provider: "prometheus"
    # The URL of the prometheus metrics server.
    baseURL: http://prometheus.istio-system.svc.cluster.local

server:
  enable: true
  # number_of_server_replicas
  updatePartition: 1
  affinity: "" # 允许每个节点上运行更多的Pod
  storage: '3Gi' # 定义用于配置服务器的 StatefulSet 存储的磁盘大小
  storageClass: "openebs-lvmpv" # 使用Kubernetes集群的默认 StorageClass 用于服务器的 StatefulSet 存储的 StorageClass。如果要自动创建存储，则必须能够动态预配它。例如，要使用 local（ https://kubernetes.io/docs/concepts/storage/storage-classes/#local） 存储类，需要手动创建 PersistentVolumeClaims。值 null 将使用 Kubernetes 集群的默认 StorageClass。如果默认 StorageClass 不存在，则需要创建一个。请参阅服务器性能要求文档的读/写调整部分，了解有关选择高性能存储类的注意事项
  exposeService:
    enabled: true
    type: LoadBalancer
    # type: NodePort #参考https://developer.hashicorp.com/consul/docs/k8s/helm#v-server-exposeservice-nodeport
    # nodePort:
    #   http:
    #     32080
    #   https:
    #     32443
  securityContext: # 服务器 Pod 的安全上下文，以 root 用户运行
    fsGroup: 2000
    runAsGroup: 2000
    runAsNonRoot: false
    runAsUser: 0
  # 要使 k8s 集群外部的客户端代理能够加入数据中心，您需要启用:
  # server.exposeGossipAndRPCPorts
  # client.exposeGossipPorts ，并将其设置为 server.ports.serflan.port 主机上未使用的端口。
  # 由于 client.exposeGossipPorts 使用 hostPort 8301， server.ports.serflan.port 因此必须设置为 8301 以外的其他值
  #  exposeGossipAndRPCPorts: true # 将服务器的 gossip 和 RPC 端口公开为 hostPort
  #  ports:
  #    serflan:
  #      port: 31079
  replicas: 1 # 要运行的服务器的数量，即集群数
  # 单机时建议配合
  # hostNetwork: true和dnsPolicy: ClusterFirstWithHostNet
  # 让 Consul Pod 直接使用宿主机的网络栈，以 节点内网 IP 作为广告地址。只要节点 IP 在虚拟机重启后保持不变（大部分云平台 / 内网 DHCP 预留都满足），Consul 集群就不会因 Pod IP 变动而出错。
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
EOF

helm uninstall consul -n consul
kubectl delete pvc -n consul data-consul-consul-server-0
helm upgrade --install consul ./consul \
  --create-namespace \
  -n consul \
  -f consul-tls-values.yml

#
#cat /tmp/consul-local-kv.json | consul kv import -http-addr=https://localhost:8501 -ca-file=/tmp/consul-ca1.crt -
#cat /tmp/consul-local-kv.json | consul kv import -http-addr=http://localhost:8501 -ca-file=/tmp/consul-ca1.crt -
#cat /tmp/consul-local-kv.json | consul kv import -http-addr=http://localhost:8501 -ca-file=/tmp/consul-ca2.crt -
#cat /tmp/consul-local-kv.json | consul kv import -http-addr=https://localhost:8501 -ca-file=/tmp/consul-ca2.crt -
