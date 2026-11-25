# OpenTelemetry Collector Contrib 配置：四个本机控制面端点 → VictoriaMetrics。
#
# 四个静态 Pod 都是 hostNetwork + 绑定 127.0.0.1，因此采集器必须 hostNetwork
# 并固定在 k1，才能从宿主网络命名空间访问这些端点。不改任何静态 Pod manifest。
#
# 认证：apiserver(6443) / scheduler(10259) / controller-manager(10257) 返回 403，
# 用 projected SA token 走 bearer_token_file；etcd(2381) 是明文 metrics 端口，
# 无需证书。TLS 证书 SAN 里已有 127.0.0.1，保留 insecure_skip_verify 是为了
# 节点 IP 访问与证书轮换期间不中断抓取（只影响本机回环，不跨网络）。
receivers:
  prometheus:
    config:
      global:
        scrape_interval: 30s
        scrape_timeout: 10s
      scrape_configs:
        - job_name: control-plane-etcd
          scheme: http
          static_configs:
            - targets: ["127.0.0.1:2381"]
          relabel_configs:
            - target_label: component
              replacement: etcd

        - job_name: control-plane-apiserver
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          static_configs:
            - targets: ["127.0.0.1:6443"]
          relabel_configs:
            - target_label: component
              replacement: apiserver

        - job_name: control-plane-scheduler
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          static_configs:
            - targets: ["127.0.0.1:10259"]
          relabel_configs:
            - target_label: component
              replacement: scheduler

        - job_name: control-plane-controller-manager
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          static_configs:
            - targets: ["127.0.0.1:10257"]
          relabel_configs:
            - target_label: component
              replacement: controller-manager

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  prometheusremotewrite:
    endpoint: http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/write
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 5m

service:
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [batch]
      exporters: [prometheusremotewrite]
  telemetry:
    logs:
      level: info
