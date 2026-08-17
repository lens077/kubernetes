#!/bin/bash
set -x

helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

mkdir /home/kubernetes/fluentbit/
cd /home/kubernetes/fluentbit/

helm pull fluent/fluent-bit
tar -zxvf fluent-bit*.tgz

# https://docs.fluentbit.io/manual/data-pipeline/outputs/opentelemetry

cat > otel-fluent-bit-values.yml <<'EOF'
config:
  service: |
    [SERVICE]
        Daemon Off
        Flush {{ .Values.flush }}
        Log_Level {{ .Values.logLevel }}
        Parsers_File /fluent-bit/etc/parsers.conf
        Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
        HTTP_Server On
        HTTP_Listen 0.0.0.0
        Coro_Stack_Size 24576
        HTTP_Port {{ .Values.metricsPort }}
        Health_Check On
        scheduler.cap 2000
        scheduler.base 5
        # 优化：磁盘缓冲保护
        storage.path /var/log/fluent-bit/buffer
        storage.sync normal
        storage.checksum off
        storage.backlog.mem_limit 10M

  inputs: |
    [INPUT]
        Name tail
        Path /var/log/containers/*.log
        multiline.parser docker, cri
        Tag kube.*
        Mem_Buf_Limit 15MB
        Skip_Long_Lines On
        storage.type filesystem

    [INPUT]
        Name systemd
        Tag host.kubelet
        Systemd_Filter _SYSTEMD_UNIT=kubelet.service
        Read_From_Tail On

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            On
        Labels              On
        # 开发环境关闭注解采集，极大减小元数据体积与内存消耗
        Annotations         Off
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Meta_Cache_TTL 600
        Use_Kubelet         Off

    # 合规数据脱敏
    [FILTER]
        Name                lua
        Match               kube.*
        call                sanitize_log
        code                function sanitize_log(tag, timestamp, record) if record["email"] ~= nil then record["email"] = string.gsub(record["email"], "(.+)@", "***@") end if record["phone"] ~= nil then record["phone"] = string.gsub(record["phone"], "(%d{3})%d{4}(%d{4})", "%1****%2") end record["business_line"] = "ecommerce" return 2, timestamp, record end

    [FILTER]
        Name                nest
        Match               kube.*
        Operation           lift
        Nested_under        kubernetes
        Add_prefix          k8s.

    [FILTER]
        Name                throttle
        Match               kube.*
        Rate                500
        Window              5
        Print_Status        true

  outputs: |
    # Loki: 专用于接收规范化后的 K8s 容器日志
    [OUTPUT]
        Name                 loki
        Match                kube.*
        Host                 loki.loki.svc
        Port                 3100
        Label_keys           $k8s.pod_name, $k8s.namespace_name, $k8s.container_name, $business_line
        Line_format          json
        Labels               job=kube-logs
        buffer_size          1MB
        Retry_Limit          5
        Tls                  Off

    # OpenTelemetry: 专用于接收非容器的系统级组件日志
    [OUTPUT]
        Name                  opentelemetry
        Match                 host.*
        Host                  otel-collector.observability.svc
        Port                  4318
        Logs_uri              /v1/logs
        compress              gzip
        http2                 on
        Tls                   Off
        logs_body_key         $message
        logs_severity_text_message_key log_level
        add_label             app fluent-bit
        add_label             env production
        add_label             region cn-east
        net.connect_timeout   10s
        net.io_timeout        30s
        Retry_Limit           3
        workers               1
EOF
cat > image.yml <<EOF
image:
  #repository: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/fluent/fluent-bit
  repository: docker.io/fluent/fluent-bit
  tag: 5.0.7-arm64
  digest:
  pullPolicy: IfNotPresent
EOF

helm uninstall fluent-bit -n observability
helm upgrade --install fluent-bit ./fluent-bit \
  --create-namespace \
  -n observability \
  -f otel-fluent-bit-values.yml \
  -f image.yml
