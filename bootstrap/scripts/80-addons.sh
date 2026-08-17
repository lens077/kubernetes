#!/usr/bin/env bash
# =============================================================================
# ⚠ 已停用 —— 本文件正在被拆解到 components/<组件>/ 下, start.sh 已不再调用它
#   （编排器换成了同目录的 80-components.sh）。保留它只为迁移期间对照 values,
#   14 个组件全部迁完后删除。不要再往这里加东西。
# =============================================================================
# 80-addons —— 可选基础设施组件(交互多选; --yes 时按 config.env)
#   数据库(CloudNativePG) / 缓存(Redis) / 搜索(Meilisearch) / MQ(Strimzi Kafka)
#   GitOps(ArgoCD, yaml 安装) / 观测(VictoriaMetrics+Grafana) / 对象存储(MinIO) / metrics-server
#   - helm 安装全部并行执行(独立命名空间互不干扰), 大幅缩短镜像拉取等待
#   - 密码只生成一次(存 $STATE_DIR/creds), 重复执行结果一致
#   - 选择结果持久化: 重跑沿用上次选择; 变更选择用 start.sh --reset-state 80-addons
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

SELECTED_FILE="$STATE_DIR/addons.selected"
CREDS_FILE="/root/.k8s-installer-credentials"
EXAMPLES_DIR="$K8S_FILES_DIR/examples"
ADDONS_DIR="$K8S_FILES_DIR/addons"

# 注册表: id | 说明 | 预估内存(Mi) | config.env 变量名(四个数组按下标一一对应)
ADDON_IDS=(metrics vm grafana loki otel jaeger argocd cnpg strimzi meilisearch dragonfly minio certmanager kured)
ADDON_DESCS=("metrics-server (kubectl top/HPA)"
             "VictoriaMetrics single (指标后端)"
             "Grafana (数据源按所选后端动态预置)"
             "Loki (日志后端, 采集端 fluent-bit/OTel)"
             "OTel Collector (pipelines 按后端动态生成)"
             "Jaeger v2 (badger 持久化, 你的精修 manifests)"
             "ArgoCD (GitOps, yaml 安装便于自定义)"
             "CloudNativePG (PostgreSQL 操作器)"
             "Strimzi (Kafka 操作器)"
             "Meilisearch (商品即时搜索, 中文分词开箱)"
             "Dragonfly (Redis 兼容缓存, 既有选型)"
             "MinIO (S3 对象/静态文件存储)"
             "cert-manager (GatewayAPI HTTPS 证书)"
             "kured (维护窗口自动重启协调)")
ADDON_RAM=(100 500 300 600 200 400 500 150 300 400 512 300 150 50)
ADDON_VARS=(ADDON_METRICS_SERVER ADDON_VM ADDON_GRAFANA ADDON_LOKI ADDON_OTEL ADDON_JAEGER
            ADDON_ARGOCD ADDON_CNPG ADDON_STRIMZI ADDON_MEILISEARCH ADDON_DRAGONFLY
            ADDON_MINIO ADDON_CERTMANAGER ADDON_KURED)
# 菜单分组(与上面下标一一对应): base=基础 obs=可观测性 infra=基础设施
ADDON_GROUPS=(base obs obs obs obs obs infra infra infra infra infra infra infra infra)

# 密码只生成一次, 后续执行复用 → 幂等
get_cred() {
  local f="$STATE_DIR/creds/$1"
  if [[ ! -f $f ]]; then
    mkdir -p "$STATE_DIR/creds"
    openssl rand -hex 12 > "$f"
    chmod 600 "$f"
  fi
  cat "$f"
}

addon_selected() { grep -qx "$1" "$SELECTED_FILE" 2>/dev/null; }

# --- 1. 选择组件 ----------------------------------------------------------------------
select_addons() {
  local i sel=() choice mem_avail
  # 初始值来自 config.env
  for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do
    [[ ${!ADDON_VARS[i]} == true ]] && sel[i]=1 || sel[i]=0
  done

  if is_interactive; then
    mem_avail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
    while true; do
      {
        echo
        echo "可选组件(当前可用内存 ${mem_avail}Mi; 编号切换, a=全选, n=全不选, o=可观测性组全选, 回车=确认):"
        local total=0 prev_group=""
        for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do
          if [[ ${ADDON_GROUPS[i]} != "$prev_group" ]]; then
            prev_group=${ADDON_GROUPS[i]}
            case $prev_group in
              base)  echo "  ── 基础 ──" ;;
              obs)   echo "  ── 可观测性 ──" ;;
              infra) echo "  ── 基础设施 ──" ;;
            esac
          fi
          if [[ ${sel[i]} == 1 ]]; then
            printf '  [x] %d) %-45s ~%sMi\n' "$((i+1))" "${ADDON_DESCS[i]}" "${ADDON_RAM[i]}"
            total=$(( total + ADDON_RAM[i] ))
          else
            printf '  [ ] %d) %-45s ~%sMi\n' "$((i+1))" "${ADDON_DESCS[i]}" "${ADDON_RAM[i]}"
          fi
        done
        echo "  已选组件预估内存: ~${total}Mi"
      } >/dev/tty
      printf '选择> ' >/dev/tty
      read -r choice </dev/tty || choice=""
      case $choice in
        "") break ;;
        a|A) for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do sel[i]=1; done ;;
        n|N) for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do sel[i]=0; done ;;
        o|O) for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do [[ ${ADDON_GROUPS[i]} == obs ]] && sel[i]=1; done ;;
        *[!0-9]*) ;;
        *) (( choice >= 1 && choice <= ${#ADDON_IDS[@]} )) && sel[choice-1]=$(( 1 - sel[choice-1] )) ;;
      esac
    done
  fi

  : > "$SELECTED_FILE"
  local total=0
  for ((i = 0; i < ${#ADDON_IDS[@]}; i++)); do
    if [[ ${sel[i]} == 1 ]]; then
      echo "${ADDON_IDS[i]}" >> "$SELECTED_FILE"
      total=$(( total + ADDON_RAM[i] ))
    fi
  done
  log_info "已选组件: $(tr '\n' ' ' < "$SELECTED_FILE")(预估 ~${total}Mi)"

  local mem_avail_now=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
  if (( total > mem_avail_now * 8 / 10 )); then
    log_warn "预估内存(${total}Mi)超过当前可用内存(${mem_avail_now}Mi)的 80%, 可能出现 OOM/Pending"
    if is_interactive; then
      confirm "内存偏紧, 仍然继续安装所选组件?" N || die "已取消, 请重新选择(start.sh --reset-state 80-addons)"
    else
      log_warn "非交互模式: 按 config.env 配置继续, 请自行确认内存余量"
    fi
  fi
  return 0
}

# --- 2. helm 仓库(串行添加, helm repo 文件不可并发写) -------------------------------------
add_helm_repos() {
  addon_selected metrics     && helm_repo_add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  addon_selected vm          && helm_repo_add vm https://victoriametrics.github.io/helm-charts/
  addon_selected otel        && helm_repo_add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  # argocd 走 yaml manifest 安装, 无需 helm 仓库
  addon_selected cnpg        && helm_repo_add cnpg https://cloudnative-pg.github.io/charts
  addon_selected strimzi     && helm_repo_add strimzi https://strimzi.io/charts/
  addon_selected meilisearch && helm_repo_add meilisearch https://meilisearch.github.io/meilisearch-kubernetes
  addon_selected certmanager && helm_repo_add jetstack https://charts.jetstack.io
  # grafana 仓库: loki 与独立 Grafana 共用
  { addon_selected loki || addon_selected grafana; } && helm_repo_add grafana https://grafana.github.io/helm-charts
  addon_selected kured       && helm_repo_add kubereboot https://kubereboot.github.io/charts
  # add --force-update 已各自拉好索引; 这里的全量刷新只作尽力而为
  if [[ -s $SELECTED_FILE ]]; then
    retry 2 5 helm_cmd repo update || log_warn "部分仓库索引刷新失败, 以各仓库添加时的索引为准"
  fi
  return 0
}

# --- 各组件安装(幂等: helm upgrade --install / kubectl apply) ------------------------------
install_metrics() {
  helm_cmd upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system --set 'args={--kubelet-insecure-tls}'
}

# ============ 可观测性组(vm/grafana/loki/otel/jaeger 各自独立可选) ============
VM_SVC="vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428"
LOKI_SVC="loki.logging.svc.cluster.local:3100"
JAEGER_SVC="jaeger.observability.svc.cluster.local"

# VictoriaMetrics single: 照 cloud-native-deploy/victoriametrics/single
install_vm() {
  mkdir -p "$ADDONS_DIR"
  cat > "$ADDONS_DIR/vm-values.yaml" <<EOF
server:
  # OTel 写入支持: /opentelemetry/v1/metrics 端点用 Prometheus 命名
  extraArgs:
    opentelemetry.usePrometheusNaming: true
  persistentVolume:
    storageClassName: $SC_NAME
    size: $VM_STORAGE_SIZE
  service:
    type: ClusterIP
EOF
  retry 2 10 helm_cmd upgrade --install vm-single vm/victoria-metrics-single \
    --namespace victoriametrics --create-namespace -f "$ADDONS_DIR/vm-values.yaml"
}

# 独立 Grafana: 照 cloud-native-deploy/grafana/helm; 数据源按所选后端动态预置
install_grafana() {
  local pass; pass=$(get_cred grafana-admin)
  kctl create namespace observability --dry-run=client -o yaml | kctl apply -f -

  local ds=""
  if addon_selected vm; then
    ds+="      - name: VictoriaMetrics
        type: prometheus
        url: http://$VM_SVC
        isDefault: true
"
  fi
  if addon_selected loki; then
    ds+="      - name: Loki
        type: loki
        url: http://$LOKI_SVC
"
  fi
  if addon_selected jaeger; then
    ds+="      - name: Jaeger
        type: jaeger
        url: http://$JAEGER_SVC:16686
"
  fi
  local ds_block=""
  if [[ -n $ds ]]; then
    ds_block="datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
$ds"
  fi

  mkdir -p "$ADDONS_DIR"
  cat > "$ADDONS_DIR/grafana-values.yaml" <<EOF
adminPassword: "$pass"
persistence:
  type: pvc
  enabled: true
  storageClassName: $SC_NAME
  size: $GRAFANA_STORAGE_SIZE
service:
  enabled: true
  type: ClusterIP
  port: 80
  targetPort: 3000
resources:
  limits:
    cpu: 0.5
    memory: 512Mi
grafana.ini:
  metrics:
    enable_metrics_source_cache: true
    metrics_source_cache_ttl_seconds: 300
  dataproxy:
    concurrent_query_count: 20
sidecar:
  alerts:
    enabled: true
    label: grafana_alert
$ds_block
EOF
  retry 2 10 helm_cmd upgrade --install grafana grafana/grafana \
    --namespace observability -f "$ADDONS_DIR/grafana-values.yaml"
}

# OTel Collector: 以 cloud-native-deploy/victoriametrics/single/otel-values.yaml 为底,
# exporters/pipelines 按"实际选择的后端"动态生成(vm→metrics, loki→logs, jaeger→traces)
# 组件名用新命名(otlp_http / otlp_grpc / delta_to_cumulative): 旧别名 otlphttp/otlp/deltatocumulative
# 在 collector 0.130+ 每次启动都刷 deprecation warn, 新名自 0.130 起可用(当前 contrib 0.158 实测通过)
install_otel() {
  local exporters="" m_exp="" l_exp="" t_exp="" pipelines=""
  if addon_selected vm; then
    exporters+="    otlp_http/victoriametrics:
      compression: gzip
      encoding: proto
      metrics_endpoint: http://$VM_SVC/opentelemetry/v1/metrics
      tls:
        insecure: true
"
    m_exp="otlp_http/victoriametrics"
  fi
  if addon_selected loki; then
    # Loki 3.x 原生 OTLP 摄入端点 /otlp (应用侧 otelzap 推送的日志走这条; 容器日志仍由 fluent-bit 负责)
    exporters+="    otlp_http/loki:
      endpoint: http://$LOKI_SVC/otlp
      tls:
        insecure: true
"
    l_exp="otlp_http/loki"
  fi
  if addon_selected jaeger; then
    exporters+="    otlp_grpc/jaeger:
      endpoint: $JAEGER_SVC:4317
      tls:
        insecure: true
"
    t_exp="otlp_grpc/jaeger"
  fi
  if [[ -z $exporters ]]; then
    log_warn "未选择任何观测后端(vm/loki/jaeger), 跳过 OTel Collector 安装"
    return 0
  fi
  # prometheus receiver 抓 collector 自身的 8888(chart 默认已生成该 receiver 但没挂进任何
  # pipeline, 等于死配置) —— 挂上后 otelcol_* 自观测指标才会进后端, 队列积压/丢点才看得见;
  # k8s_cluster 由 clusterMetrics preset 自动追加, 这里不用写
  [[ -n $m_exp ]] && pipelines+="      metrics:
        receivers: [otlp, prometheus]
        processors: [delta_to_cumulative]
        exporters: [$m_exp]
"
  [[ -n $l_exp ]] && pipelines+="      logs:
        receivers: [otlp]
        processors: []
        exporters: [$l_exp]
"
  [[ -n $t_exp ]] && pipelines+="      traces:
        receivers: [otlp]
        processors: []
        exporters: [$t_exp]
"

  mkdir -p "$ADDONS_DIR"
  cat > "$ADDONS_DIR/otel-values.yaml" <<EOF
mode: deployment
image:
  repository: "otel/opentelemetry-collector-contrib"
presets:
  clusterMetrics:
    enabled: true
  # 容器日志已由 fluent-bit 采集, 这里保持关闭避免双份(原 otel-values 开着是 victoria-logs 试验期)
  logsCollection:
    enabled: false
config:
  processors:
    delta_to_cumulative:
      max_stale: 5m
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  exporters:
$exporters
  service:
    pipelines:
$pipelines
EOF
  retry 2 10 helm_cmd upgrade --install otel open-telemetry/opentelemetry-collector \
    --namespace opentelemetry --create-namespace -f "$ADDONS_DIR/otel-values.yaml"
}

# Jaeger v2 all-in-one: 原样应用你的精修 manifests(files/jaeger/, 自动替换 StorageClass)
install_jaeger() {
  local src="$K8S_BASE_DIR/files/jaeger"
  [[ -d $src ]] || die "缺少 $src (安装器目录应包含 files/jaeger/, 来自 cloud-native-deploy/jaeger/manifests)"
  kctl create namespace observability --dry-run=client -o yaml | kctl apply -f -
  local f
  for f in "$src"/*.yaml; do
    # 旧集群 SC 名 openebs-lvmpv → 当前集群 SC
    sed "s/openebs-lvmpv/$SC_NAME/g" "$f" | kctl apply -f -
  done
  # 网关暴露示例已放 files/examples/jaeger-httproute.yaml(UI 16686) 与 jaeger-otlp-httproute.yaml
}

# ArgoCD 用官方 yaml manifest 安装(习惯: 便于自定义; helm 弃用)
install_argocd() {
  local ver=$ARGOCD_VERSION
  [[ -z $ver ]] && ver=$(resolve_version ARGOCD argoproj/argo-cd "v3.5.1" "")
  mkdir -p "$ADDONS_DIR" "$EXAMPLES_DIR"
  kctl create namespace argocd --dry-run=client -o yaml | kctl apply -f -

  local manifest="$ADDONS_DIR/argocd-install-$ver.yaml"
  [[ -s $manifest ]] || fetch "$(gh_url "https://raw.githubusercontent.com/argoproj/argo-cd/$ver/manifests/install.yaml")" "$manifest"
  # CRD 体积超 client-side apply 注解上限(同 strimzi 笔记的坑), 必须 server-side
  kctl apply -n argocd --server-side --force-conflicts -f "$manifest"

  # Gateway TLS 终结友好: server 走明文, HTTPS 由网关做(配 examples/argocd-httproute.yaml)
  kctl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
  kctl -n argocd rollout restart deploy argocd-server

  # 习惯对齐(argo/server/install-cli.sh): 顺带装 argocd CLI, 失败不阻塞服务端
  if [[ ! -x /usr/local/bin/argocd ]]; then
    with_proxy curl -fL --connect-timeout 10 --max-time 300 -o /tmp/argocd.bin \
      "$(gh_url "https://github.com/argoproj/argo-cd/releases/download/$ver/argocd-linux-$ARCH")" \
      && install -m 755 /tmp/argocd.bin /usr/local/bin/argocd \
      && rm -f /tmp/argocd.bin \
      || log_warn "argocd CLI 下载失败(不影响服务端), 稍后可手动安装"
  fi

  cat > "$EXAMPLES_DIR/argocd-httproute.yaml" <<'EOF'
# 通过 Gateway API 暴露 ArgoCD(server 已配 insecure, 由网关终结 TLS)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-redirect-route
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: http
  hostnames:
    - "argocd.app.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            port: 443
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-https-route
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: https
  hostnames:
    - "argocd.app.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
EOF
  return 0
}

install_cnpg() {
  helm_cmd upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace
  # 操作器就绪后, 数据库实例按需 apply 示例(不自动创建, 由用户决定规格)
  mkdir -p "$EXAMPLES_DIR"
  cat > "$EXAMPLES_DIR/postgres-cluster.yaml" <<EOF
# 示例: kubectl create ns postgresql && kubectl apply -f postgres-cluster.yaml
# (命名空间沿用既有习惯 postgresql; 旧 bitnami postgresql-ha 方案由 CNPG 取代,
#  bitnami 镜像 2025 年起受限, 且 CNPG 无需 pgpool/repmgr 附加组件)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
  namespace: postgresql
spec:
  instances: 1
  storage:
    size: 10Gi
    storageClass: $SC_NAME
  postgresql:
    parameters:
      shared_buffers: 512MB
      max_connections: "200"
      random_page_cost: "1.1"        # SSD/NVMe
      effective_io_concurrency: "200"
EOF
}

install_strimzi() {
  # 用 helm 装算子(规避你 2026-08-06 笔记里 YAML bundle 的三个坑:
  # 版本化 URL 404 / myproject 命名空间残留 / CRD 超 client-side apply 上限)
  helm_cmd upgrade --install strimzi strimzi/strimzi-kafka-operator \
    --namespace kafka --create-namespace
  mkdir -p "$EXAMPLES_DIR"
  cat > "$EXAMPLES_DIR/kafka-kraft.yaml" <<EOF
# 示例: kubectl apply -f kafka-kraft.yaml (KRaft 单节点)
# 对齐既有习惯: 集群名 my-cluster(kafka-ui 的 bootstrap 地址依赖它);
# Kafka 4.3.0 与 Debezium 插件自带 jar 匹配(2026-08-06 算子升级笔记), 需算子 >= 1.1.0
# 注意: 算子 1.0+ 的 CRD 只支持 v1 API(v1beta2 已移除)
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        class: $SC_NAME
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: 4.3.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF

  # kafka-ui(原 kafka/yaml/kafka.yaml 习惯: NodePort 31092, bootstrap 指向 my-cluster)
  cat > "$EXAMPLES_DIR/kafka-ui.yaml" <<'EOF'
# 示例: Kafka 集群起来后 kubectl apply -f kafka-ui.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-ui-deployment
  namespace: kafka
  labels: {app: kafka-ui}
spec:
  replicas: 1
  selector:
    matchLabels: {app: kafka-ui}
  template:
    metadata:
      labels: {app: kafka-ui}
    spec:
      containers:
        - name: kafka-ui
          image: provectuslabs/kafka-ui:latest
          env:
            - name: KAFKA_CLUSTERS_0_NAME
              value: "K8 Kafka Cluster"
            - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
              value: my-cluster-kafka-brokers.kafka.svc.cluster.local:9092
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {cpu: 1000m, memory: 1024Mi}
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-ui-service
  namespace: kafka
spec:
  selector: {app: kafka-ui}
  type: ClusterIP
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
---
# 对外暴露走 Gateway API(替代原 NodePort 31092 习惯)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kafka-ui-redirect-route
  namespace: kafka
spec:
  parentRefs:
    - name: kafka-gateway
      sectionName: http
  hostnames:
    - "kafka-ui.app.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            port: 443
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kafka-ui-https-route
  namespace: kafka
spec:
  parentRefs:
    - name: kafka-gateway
      sectionName: https
  hostnames:
    - "kafka-ui.app.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kafka-ui-service
          port: 8080
EOF
}

install_meilisearch() {
  # 官方 chart: https://github.com/meilisearch/meilisearch-kubernetes (未 pin=最新版)
  # 部署副本已同步到 cloud-native-deploy/meilisearch/; 客户端迁移任务见 ecommerce 仓 TODO.md
  local key; key=$(get_cred meili-master-key)
  kctl create namespace search --dry-run=client -o yaml | kctl apply -f -
  kctl -n search create secret generic meilisearch-master-key \
    --from-literal=MEILI_MASTER_KEY="$key" \
    --dry-run=client -o yaml | kctl apply -f -

  mkdir -p "$ADDONS_DIR"
  cat > "$ADDONS_DIR/meili-values.yaml" <<EOF
environment:
  MEILI_ENV: production
  MEILI_NO_ANALYTICS: "true"
auth:
  existingMasterKeySecret: meilisearch-master-key
persistence:
  enabled: true
  storageClass: $SC_NAME
  size: $MEILI_STORAGE_SIZE
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 1Gi
service:
  type: ClusterIP
  port: 7700
EOF
  retry 2 10 helm_cmd upgrade --install meilisearch meilisearch/meilisearch \
    --namespace search -f "$ADDONS_DIR/meili-values.yaml"
}

# Dragonfly: 对齐 cloud-native-deploy/dragonflydb/helm 的既有部署(OCI chart + 密码 secret +
# LoadBalancer 暴露); Redis 协议兼容, ecommerce 的 go-redis 客户端零改动
install_dragonfly() {
  local pass; pass=$(get_cred dragonfly-password)
  kctl create namespace dragonfly --dry-run=client -o yaml | kctl apply -f -
  kctl -n dragonfly create secret generic dragonfly-password-secret \
    --from-literal=password="$pass" \
    --dry-run=client -o yaml | kctl apply -f -

  mkdir -p "$ADDONS_DIR"
  cat > "$ADDONS_DIR/dragonfly-values.yaml" <<EOF
replicaCount: 1
service:
  # 沿用既有习惯: LB 暴露到局域网(走 L2 通告 IP 池)
  type: LoadBalancer
  port: 6379
# 缓存语义: 上限内存 + 满时淘汰(等价 redis maxmemory + allkeys-lru)
# proactor_threads 必须显式钉死: Dragonfly 启动时校验 maxmemory >= 256MiB * io 线程数,
# 不指定就按节点 CPU 核数起线程(4 核 => 要 1GiB), 256mb 会直接 "Exiting..." 崩溃循环
extraArgs:
  - --maxmemory=$DRAGONFLY_MAXMEMORY
  - --proactor_threads=$DRAGONFLY_PROACTOR_THREADS
  - --cache_mode=true
passwordFromSecret:
  enable: true
  existingSecret:
    name: dragonfly-password-secret
    key: password
serviceMonitor:
  enabled: false
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  # 原部署 limits.cpu=100m 会造成缓存限流抖动, 特意只限内存不限 CPU
  limits:
    memory: 512Mi
EOF
  # 版本: 空=解析最新并锁进 versions.lock(重复执行一致), 兜底 v1.40.1
  local dfly_ver=$DRAGONFLY_CHART_VERSION
  [[ -z $dfly_ver ]] && dfly_ver=$(resolve_version DRAGONFLY dragonflydb/dragonfly "v1.40.1" "")
  retry 2 10 helm_cmd upgrade --install dragonfly \
    oci://ghcr.io/dragonflydb/dragonfly/helm/dragonfly \
    --version "$dfly_ver" \
    --namespace dragonfly -f "$ADDONS_DIR/dragonfly-values.yaml"
}

install_minio() {
  # 对齐 cloud-native-deploy/minio/yaml/single.yaml 的既有习惯:
  #   pgsty/silo 镜像(官方社区版 2025 年阉割了控制台, silo 保留完整 console)
  #   控制台 9090 / Service 名 minio-service / ClusterIP + Gateway HTTPRoute 暴露
  # 改进保留: 密码走 creds 机制(原文件是明文 minio123)
  local user pass
  user="admin"
  pass=$(get_cred minio-root)
  mkdir -p "$ADDONS_DIR" "$EXAMPLES_DIR"
  cat > "$ADDONS_DIR/minio.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC_NAME
  resources:
    requests:
      storage: $MINIO_STORAGE_SIZE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: minio
  name: minio
  namespace: minio
spec:
  selector:
    matchLabels: {app: minio}
  strategy:
    type: Recreate
  template:
    metadata:
      labels: {app: minio}
    spec:
      containers:
        - name: minio
          image: docker.io/pgsty/silo
          command: [/bin/bash, -c]
          args:
            # 二进制名是 silo 不是 minio(pgsty/silo 镜像里只有 /usr/bin/silo),
            # 但仍读 MINIO_* 环境变量, 所以 root user/password 保持原样
            - silo server /data --console-address :9090
          env:
            - name: MINIO_ROOT_USER
              value: "$user"
            - name: MINIO_ROOT_PASSWORD
              value: "$pass"
          ports:
            - containerPort: 9090
              name: console
            - containerPort: 9000
              name: api
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests: {cpu: 100m, memory: 256Mi}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio-service
  namespace: minio
spec:
  type: ClusterIP
  selector: {app: minio}
  ports:
    - name: console
      port: 9090
      targetPort: 9090
    - name: api
      port: 9000
      targetPort: 9000
EOF
  kctl apply -f "$ADDONS_DIR/minio.yaml"

  # 对外暴露示例: 沿用你 minio/yaml/http_route.yaml 的形态(http→https 重定向 + 业务路由)
  cat > "$EXAMPLES_DIR/minio-httproute.yaml" <<'EOF'
# 示例: 通过 Gateway API 暴露 MinIO 控制台(改 hostname/Gateway 名后 kubectl apply)
# HTTP -> HTTPS
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: minio-ui-redirect-route
  namespace: minio
spec:
  parentRefs:
    - name: minio-gateway
      sectionName: http
  hostnames:
    - "minio-ui.app.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            port: 443
            statusCode: 301
---
# HTTPS 业务路由 (443 -> 9090)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: minio-ui-https-route
  namespace: minio
spec:
  parentRefs:
    - name: minio-gateway
      sectionName: https
  hostnames:
    - "minio-ui.app.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: minio-service
          port: 9090
EOF
}

install_certmanager() {
  mkdir -p "$ADDONS_DIR" "$EXAMPLES_DIR"
  cat > "$ADDONS_DIR/cert-manager-values.yaml" <<'EOF'
crds:
  enabled: true
replicaCount: 1
# 开启 Gateway API 支持: 在 Gateway 上加 cert-manager.io/cluster-issuer 注解即可自动签发
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: true
EOF
  helm_cmd upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace -f "$ADDONS_DIR/cert-manager-values.yaml"

  # 签发体系示例(不自动 apply, 按需执行; 详见 README "HTTPS 全链路")
  # 命名对齐 cloud-native-deploy/cert-manager/public-web-gw: 根证书 global-root-ca,
  # 消费者统一引用 ClusterIssuer global-ca-issuer。与原文件的差异: 原方案 01/03 用
  # 同名 issuer 先 selfsigned 后覆盖为 CA——单文件一次 apply 会死锁(证书等 issuer,
  # issuer 等证书的 secret), 这里保留独立的 selfsigned 引导 issuer 规避
  cat > "$EXAMPLES_DIR/cert-manager-issuers.yaml" <<'EOF'
# 自签 CA 三件套: selfsigned 引导 → global-root-ca 根证书 → global-ca-issuer
# 用法: kubectl apply -f cert-manager-issuers.yaml
#       客户端信任: kubectl -n cert-manager get secret global-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > global-root-ca.crt
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: global-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: my-global-root-ca
  secretName: global-root-ca-secret
  duration: 87600h            # 10 年
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: global-ca-issuer
spec:
  ca:
    secretName: global-root-ca-secret
---
# 公网域名走 Let's Encrypt(需要域名解析到你的公网出口):
# HTTP-01 经由 Gateway 完成挑战; 国内域名也可改用 DNS-01(阿里云 webhook)
# apiVersion: cert-manager.io/v1
# kind: ClusterIssuer
# metadata:
#   name: letsencrypt
# spec:
#   acme:
#     server: https://acme-v02.api.letsencrypt.org/directory
#     email: you@example.com
#     privateKeySecretRef:
#       name: letsencrypt-account-key
#     solvers:
#       - http01:
#           gatewayHTTPRoute:
#             parentRefs:
#               - name: main-gateway
#                 namespace: default
#                 kind: Gateway
EOF

  cat > "$EXAMPLES_DIR/gateway-https.yaml" <<'EOF'
# Cilium Gateway + cert-manager 自动 HTTPS 示例
# 前置: kubectl apply -f cert-manager-issuers.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: global-ca-issuer   # 有公网域名换成 letsencrypt
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "app.lan.example"
      tls:
        mode: Terminate
        certificateRefs:
          - name: app-lan-tls               # cert-manager 依据注解自动创建该 Secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-route
  namespace: default
spec:
  parentRefs:
    - name: main-gateway
  hostnames: ["app.lan.example"]
  rules:
    - backendRefs:
        - name: demo-svc
          port: 80
EOF
}

install_loki() {
  mkdir -p "$ADDONS_DIR" "$EXAMPLES_DIR"
  cat > "$ADDONS_DIR/loki-values.yaml" <<EOF
# 单体模式(SingleBinary): 单机集群足够, 内存占用最小
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    retention_period: $LOKI_RETENTION
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: $SC_NAME
    size: $LOKI_STORAGE_SIZE
# 关闭 SimpleScalable 模式组件与多余附件, 采集端用集群里已有的 fluent-bit
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
EOF
  helm_cmd upgrade --install loki grafana/loki \
    --namespace logging --create-namespace -f "$ADDONS_DIR/loki-values.yaml"

  cat > "$EXAMPLES_DIR/fluent-bit-loki-output.conf" <<'EOF'
# 已有 fluent-bit 对接 Loki: 在 OUTPUT 段追加(无需安装 Alloy/Promtail)
# 集群内地址: loki.logging.svc.cluster.local:3100
[OUTPUT]
    name                   loki
    match                  *
    host                   loki.logging.svc.cluster.local
    port                   3100
    line_format            json
    auto_kubernetes_labels on
    labels                 job=fluent-bit, cluster=node1
# Grafana 数据源: http://loki.logging.svc.cluster.local:3100
EOF
}

install_kured() {
  # 只在维护窗口内重启; 单节点 drain 会短暂中断业务, forceReboot 防 PDB 卡死
  helm_cmd upgrade --install kured kubereboot/kured \
    --namespace kube-system \
    --set configuration.startTime="$KURED_REBOOT_WINDOW_START" \
    --set configuration.endTime="$KURED_REBOOT_WINDOW_END" \
    --set configuration.timeZone="$TIMEZONE" \
    --set configuration.rebootDays="{mo,tu,we,th,fr,sa,su}" \
    --set configuration.forceReboot=true \
    --set configuration.period=10m
}

# --- 3. 并行安装 ---------------------------------------------------------------------------
declare -A JOB_PID=() JOB_LOG=()
start_job() {
  local name=$1; shift
  local logf="$LOG_DIR/addon-$name.log"
  : > "$logf"
  ( "$@" ) >>"$logf" 2>&1 &
  JOB_PID[$name]=$!
  JOB_LOG[$name]=$logf
  log_info "并行安装启动: $name"
}

install_selected() {
  if [[ ! -s $SELECTED_FILE ]]; then
    log_info "未选择任何组件, 跳过"
    return 0
  fi
  # 逐组件成功标记: 重跑只补失败的, 已装过的直接跳过(既有 release 由 helm upgrade 幂等接管)
  maybe_install() {
    local id=$1 fn=$2
    addon_selected "$id" || return 0
    if [[ -f "$STATE_DIR/state/80-addons:addon-$id.done" ]]; then
      log_skip "组件已装过, 跳过: $id"
      return 0
    fi
    start_job "$id" "$fn"
  }
  maybe_install metrics     install_metrics
  maybe_install vm          install_vm
  maybe_install grafana     install_grafana
  maybe_install otel        install_otel
  maybe_install jaeger      install_jaeger
  maybe_install argocd      install_argocd
  maybe_install cnpg        install_cnpg
  maybe_install strimzi     install_strimzi
  maybe_install meilisearch install_meilisearch
  maybe_install dragonfly   install_dragonfly
  maybe_install minio       install_minio
  maybe_install certmanager install_certmanager
  maybe_install loki        install_loki
  maybe_install kured       install_kured

  # 看门狗: 共享截止时间(并行任务同时开跑), 超时杀进程树防整段挂死
  local name failed=() pid
  local deadline=$(( SECONDS + ${ADDON_INSTALL_TIMEOUT:-900} ))
  for name in "${!JOB_PID[@]}"; do
    pid=${JOB_PID[$name]}
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 5; done
    if kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      failed+=("$name")
      log_error "安装超时(>${ADDON_INSTALL_TIMEOUT:-900}s)已终止: $name (日志: ${JOB_LOG[$name]})"
      continue
    fi
    if wait "$pid"; then
      log_ok "安装提交完成: $name"
      touch "$STATE_DIR/state/80-addons:addon-$name.done"
    else
      failed+=("$name")
      log_error "安装失败: $name (日志: ${JOB_LOG[$name]})"
      tail -n 5 "${JOB_LOG[$name]}" >&2 || true
    fi
  done
  (( ${#failed[@]} == 0 )) || die "以下组件安装失败: ${failed[*]} — 修复后重跑本阶段"
}

# --- 4. 就绪等待(镜像拉取受网络影响, 未就绪降级为警告, 不阻断主流程) ---------------------------
wait_addons() {
  [[ -s $SELECTED_FILE ]] || return 0
  local pending=()
  addon_selected metrics    && { kctl -n kube-system rollout status deploy/metrics-server --timeout=300s || pending+=(metrics-server); }
  addon_selected vm         && { kctl -n victoriametrics rollout status deploy/vm-single-victoria-metrics-single-server --timeout=600s || pending+=(victoriametrics); }
  addon_selected grafana    && { kctl -n observability rollout status deploy/grafana --timeout=600s || pending+=(grafana); }
  addon_selected otel       && { kctl -n opentelemetry rollout status deploy/otel-opentelemetry-collector --timeout=600s || pending+=(otel); }
  addon_selected jaeger     && { kctl -n observability rollout status deploy/jaeger --timeout=600s || pending+=(jaeger); }
  addon_selected argocd     && { kctl -n argocd      rollout status deploy/argocd-server --timeout=600s || pending+=(argocd); }
  addon_selected cnpg       && { kctl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=300s || pending+=(cnpg); }
  addon_selected strimzi    && { kctl -n kafka       rollout status deploy/strimzi-cluster-operator --timeout=300s || pending+=(strimzi); }
  addon_selected meilisearch && { kctl -n search rollout status statefulset/meilisearch --timeout=600s 2>/dev/null \
                                    || kctl -n search rollout status deploy/meilisearch --timeout=600s \
                                    || pending+=(meilisearch); }
  # chart 单副本时创建的是 Deployment(多副本才是 StatefulSet), 两种都试一次
  addon_selected dragonfly  && { kctl -n dragonfly   rollout status statefulset/dragonfly --timeout=600s 2>/dev/null \
                                    || kctl -n dragonfly rollout status deploy/dragonfly --timeout=600s \
                                    || pending+=(dragonfly); }
  addon_selected minio      && { kctl -n minio       rollout status deploy/minio --timeout=300s || pending+=(minio); }
  addon_selected certmanager && { kctl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s || pending+=(cert-manager); }
  addon_selected loki       && { kctl -n logging     rollout status statefulset/loki --timeout=600s || pending+=(loki); }
  addon_selected kured      && { kctl -n kube-system rollout status ds/kured --timeout=300s || pending+=(kured); }
  if (( ${#pending[@]} > 0 )); then
    log_warn "以下组件尚未就绪(通常是镜像仍在拉取): ${pending[*]}"
    log_warn "稍后可用 kubectl get pods -A 观察; 或重跑 90 阶段复检"
  fi
  return 0
}

# --- 5. 凭据汇总 ------------------------------------------------------------------------------
write_creds_summary() {
  [[ -s $SELECTED_FILE ]] || return 0
  touch "$CREDS_FILE"; chmod 600 "$CREDS_FILE"
  local content=""
  addon_selected grafana    && content+="Grafana    → 用户 admin / 密码 $(get_cred grafana-admin) (svc: observability/grafana:80)"$'\n'
  addon_selected vm         && content+="VictoriaMetrics → http://$VM_SVC (OTel 写入 /opentelemetry/v1/metrics)"$'\n'
  addon_selected otel       && content+="OTel Collector → otel-opentelemetry-collector.opentelemetry.svc:4317(gRPC)/4318(HTTP), 应用 OTLP 推这里"$'\n'
  addon_selected jaeger     && content+="Jaeger     → UI $JAEGER_SVC:16686 (HTTPRoute 示例 files/examples/jaeger-httproute.yaml)"$'\n'
  addon_selected meilisearch && content+="Meilisearch→ master key $(get_cred meili-master-key) (svc: search/meilisearch:7700, GET /health)"$'\n'
  addon_selected minio      && content+="MinIO      → 用户 admin / 密码 $(get_cred minio-root) (svc: minio/minio-service, API 9000 / 控制台 9090; 对外暴露示例 files/examples/minio-httproute.yaml)"$'\n'
  addon_selected dragonfly  && content+="Dragonfly  → 密码 $(get_cred dragonfly-password) (svc: dragonfly/dragonfly:6379, LoadBalancer; Redis 协议)"$'\n'
  addon_selected argocd     && content+="ArgoCD     → 用户 admin / 初始密码: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"$'\n'
  [[ -n $content ]] && ensure_block "$CREDS_FILE" "addon-credentials" "${content%$'\n'}"
  log_info "组件访问凭据已写入 $CREDS_FILE (chmod 600)"
}

main() {
  stage_begin "80-addons" "可选基础设施组件"
  if is_worker; then
    log_skip "NODE_ROLE=worker: 组件为集群级安装(控制面执行), 跳过本阶段"
    stage_end
    return 0
  fi
  add_step select  "选择要安装的组件"        select_addons
  add_step repos   "添加 helm 仓库"          add_helm_repos
  add_step install "并行安装所选组件"        install_selected
  add_step wait    "等待组件就绪(软性)"      wait_addons
  add_step creds   "写入凭据汇总"            write_creds_summary
  run_steps
  stage_end
}
main "$@"
