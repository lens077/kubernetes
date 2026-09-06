#!/usr/bin/env bash
# =============================================================================
# 60-cilium —— Cilium CNI(eBPF 数据面, 完全替代 kube-proxy)
#   - helm 安装(values 落盘 files/cilium-values.yaml, 便于日后升级/审计)
#   - 按内核能力自动开关: eBPF Host-Routing(>=5.10) / BBR(>=5.18) /
#     BIG-TCP(>=6.3) / netkit(>=6.8)
#   - L7: 内置 Envoy 代理 + Gateway API; 流量控制: 带宽管理器 + maglev
#   - L2 通告 + LoadBalancer IP 池: 局域网内直接访问 LoadBalancer 服务
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

ensure_versions
VALUES_FILE="$K8S_FILES_DIR/cilium-values.yaml"
L2_FILE="$K8S_FILES_DIR/cilium-l2.yaml"

cilium_cli() { KUBECONFIG=/etc/kubernetes/admin.conf with_proxy cilium "$@"; }

ensure_artifacts() {
  [[ -f $CACHE_DIR/.complete ]] || bash "$K8S_SCRIPTS_DIR/30-download.sh"
}

# --- 1. cilium CLI 与 helm 二进制 --------------------------------------------------
install_cli_tools() {
  tar -xzf "$A_CILIUM_CLI_TGZ" -C /usr/local/bin
  local tmp; tmp=$(mktemp -d)
  tar -xzf "$A_HELM_TGZ" -C "$tmp"
  install -m 755 "$tmp/linux-$ARCH/helm" /usr/local/bin/helm
  rm -rf "$tmp"
}
verify_cli_tools() { cilium version --client >/dev/null && helm version >/dev/null; }

# --- 2. Gateway API CRD(Cilium gatewayAPI 依赖, 必须先于 cilium 安装) ----------------
install_gateway_api_crds() {
  if [[ $CILIUM_ENABLE_GATEWAY_API != true ]]; then
    log_info "未启用 Gateway API, 跳过 CRD 安装"
    return 0
  fi
  kctl apply -f "$A_GWAPI_YAML"
}
verify_gateway_api_crds() {
  [[ $CILIUM_ENABLE_GATEWAY_API != true ]] \
    || kctl get crd gateways.gateway.networking.k8s.io >/dev/null
}

# --- 3. 生成 helm values(按 config.env + 内核能力) -----------------------------------
validate_cilium_tuning() {
  awk -v ratio="$CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO" \
    'BEGIN { exit !(ratio > 0 && ratio <= 1) }' \
    || die "CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO 必须在 (0,1] 内"
  [[ $CILIUM_BPF_MAP_RESIZE_APPROVED == true || $CILIUM_BPF_MAP_RESIZE_APPROVED == false ]] \
    || die "CILIUM_BPF_MAP_RESIZE_APPROVED 必须是 true 或 false"
  [[ $CILIUM_OPERATOR_REPLICAS =~ ^[1-9][0-9]*$ ]] \
    || die "CILIUM_OPERATOR_REPLICAS 必须是正整数"
  [[ $CILIUM_K8S_CLIENT_QPS =~ ^[1-9][0-9]*$ && $CILIUM_K8S_CLIENT_BURST =~ ^[1-9][0-9]*$ ]] \
    || die "CILIUM_K8S_CLIENT_QPS/BURST 必须是正整数"
}

gen_cilium_values() {
  validate_cilium_tuning
  # 内核能力门控
  local host_legacy=false bbr=false
  kernel_ge 5.10 || { host_legacy=true; log_warn "内核<5.10, 回退 legacy host routing"; }
  case $CILIUM_BBR in
    true)  bbr=true ;;
    auto)  kernel_ge 5.18 && bbr=true ;;
  esac

  local lb_mode=$CILIUM_LB_MODE
  if [[ $CILIUM_ROUTING_MODE != native && ( $lb_mode == dsr || $lb_mode == hybrid ) ]]; then
    log_warn "DSR/hybrid 仅支持 native 路由模式, 已回退 snat"
    lb_mode=snat
  fi
  # DSR 用 IPv4 option 携带原始服务地址(opt 派发), 仅在 dsr/hybrid 下输出
  local dsr_line=""
  [[ $lb_mode != snat ]] && dsr_line="  dsrDispatch: opt"

  # 数据面网卡: 显式钉住, 避免 attach 到桥/虚拟设备(硬编码网卡名不可移植, 默认自动探测)
  local devices=$CILIUM_DEVICES
  [[ -z $devices ]] && devices=${NET_IFACE:-$(detect_default_iface)}
  [[ -n $devices ]] || die "无法确定数据面网卡, 请设置 CILIUM_DEVICES"
  local devices_yaml=""
  local d
  for d in ${devices//,/ }; do devices_yaml+="  - $d"$'\n'; done
  devices_yaml=${devices_yaml%$'\n'}

  local routing_block
  if [[ $CILIUM_ROUTING_MODE == native ]]; then
    routing_block="routingMode: native
ipv4NativeRoutingCIDR: $POD_CIDR
autoDirectNodeRoutes: true"
    # 原生路由 + eBPF masquerade: 跳过 iptables conntrack, 显著降低每包开销(IPsec 下不启用)
    [[ $CILIUM_ENABLE_IPSEC != true ]] && routing_block+=$'\n'"installNoConntrackIptablesRules: true"
  else
    routing_block="routingMode: tunnel
tunnelProtocol: vxlan"
  fi

  # netkit: 纯 Guest 内核特性(替代 veth), 与虚拟化平台无关; 需内核>=6.8 且编译了 CONFIG_NETKIT
  netkit_supported() {
    kernel_ge 6.8 && grep -qE '^CONFIG_NETKIT=(y|m)' "/boot/config-$(uname -r)" 2>/dev/null
  }
  local netkit_line=""
  case $CILIUM_NETKIT in
    true)
      if netkit_supported; then netkit_line="  datapathMode: netkit"
      else log_warn "内核不满足 netkit 要求(>=6.8 且 CONFIG_NETKIT), 忽略 CILIUM_NETKIT=true"; fi
      ;;
    auto)
      if netkit_supported; then
        netkit_line="  datapathMode: netkit"
        log_info "netkit 数据面: 自动启用(内核 $(uname -r), CONFIG_NETKIT 已编译)"
      else
        log_info "netkit 数据面: 内核不支持, 沿用 veth"
      fi
      ;;
  esac

  # bpf.tproxy 是 veth 数据面的 L7 重定向优化, chart 校验明确禁止与 netkit 同开
  # (validate.yaml: bpf.tproxy cannot be enabled with datapathMode=netkit)
  local tproxy_line="  tproxy: true"
  if [[ -n $netkit_line ]]; then
    tproxy_line="  # tproxy 与 netkit 互斥, 已自动省略(netkit 路径自带等效处理)"
    log_info "netkit 已启用 → bpf.tproxy 自动关闭(两者互斥)"
  fi

  local bigtcp_line=""
  if [[ $CILIUM_BIGTCP == true ]]; then
    if kernel_ge 6.3; then bigtcp_line="enableIPv4BIGTCP: true"
    else log_warn "内核<6.3 不支持 BIG-TCP, 忽略 CILIUM_BIGTCP"; fi
  fi

  local ipv6_enabled=true
  [[ $DISABLE_IPV6 == true ]] && ipv6_enabled=false

  local hubble_block="hubble:
  enabled: false"
  if [[ $CILIUM_ENABLE_HUBBLE == true ]]; then
    hubble_block="hubble:
  enabled: true
  eventBufferCapacity: \"$CILIUM_HUBBLE_EVENT_BUFFER_CAPACITY\"
  metrics:
    enableOpenMetrics: true
    enabled:
      - drop
      - dns:query;ignoreAAAA
      - tcp
      - flow
      - icmp
  redact:
    enabled: true
    http:
      urlQuery: true
      headers:
        deny:
          - Authorization
          - Cookie
          - Set-Cookie
          - X-API-Key
  relay:
    enabled: true
    tls:
      server:
        enabled: true
  ui:
    enabled: $CILIUM_ENABLE_HUBBLE_UI"
  fi

  local encryption_block=""
  if [[ $CILIUM_ENABLE_IPSEC == true ]]; then
    encryption_block="encryption:
  enabled: true
  type: ipsec"
  fi

  cat > "$VALUES_FILE" <<EOF
# k8s-installer 生成的 Cilium values (helm -f 引用; 升级时基于此文件调整)
# 参数集已对照 control-plane/03-cni/cilium/03-install-cni.sh 逐项审校合并:
#   - 吸收: rollout/tproxy/distributedLRU 大表配方/lbExternalClusterIP/hybrid+DSR/
#           best-effort XDP/CES/pmtu/sessionAffinity/devices 钉网卡/L7 LB 等
#   - 修正: LRP 的 CRD 字段误当 helm 值(无效)→ 正确键 localRedirectPolicy(默认关)
#   - 保留分歧: installNoConntrackIptablesRules=true(native 下的免费性能, 原脚本为默认 false)
# 注意: kubeProxyReplacement 为字符串枚举, 必须带引号
kubeProxyReplacement: "true"
k8sServiceHost: $NODE_IP
k8sServicePort: 6443

# 三节点集群每次只下线一个 agent，并要求新版至少稳定 10 秒后再继续。
minReadySeconds: 10
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
resources:
  requests:
    cpu: $CILIUM_AGENT_CPU_REQUEST
    memory: $CILIUM_AGENT_MEMORY_REQUEST

# 配置变更(helm upgrade)后自动滚动重启, 免手工 rollout restart
rollOutCiliumPods: true
# 节点注解 cilium 状态, 便于排障
annotateK8sNode: true
# 探测最优 BPF 时钟源(jiffies vs ktime)
bpfClockProbe: true

ipam:
  mode: kubernetes
k8s:
  # ipam=kubernetes 时等 PodCIDR 分配到位再启动, 防止竞态
  requireIPv4PodCIDR: true

$routing_block
$bigtcp_line

bpf:
  masquerade: true
  hostLegacyRouting: $host_legacy
$tproxy_line
  # 外部入口统一走 LoadBalancer/Gateway；没有 Service CIDR 外部路由时保持关闭。
  lbExternalClusterIP: false
  # 每 CPU 分片 LRU 连接表 + 动态 map 比例 + 按需分配。比例必须结合节点内存和
  # cilium_bpf_map_pressure 调整；改变比例会重建 CT/NAT map、打断现有长连接。
  preallocateMaps: false
  distributedLRU:
    enabled: true
  mapDynamicSizeRatio: $CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO
$netkit_line

# CiliumEndpointSlice: 批量化 endpoint 上报, 降低 apiserver/etcd 压力
ciliumEndpointSlice:
  enabled: true
# 路径 MTU 发现传播到 Pod(ICMP frag-needed)
pmtuDiscovery:
  enabled: true

# socketLB 仍是有效键；NodePort/HostPort/sessionAffinity 由 KPR 能力提供，
# Cilium 1.20 chart 已没有对应显式开关键，不写无效 values。
socketLB:
  enabled: true

# 数据面网卡显式钉住(自动探测结果; 多网卡在 config.env 的 CILIUM_DEVICES 指定)
devices:
$devices_yaml

loadBalancer:
  algorithm: $CILIUM_LB_ALGORITHM
  # 让 trafficDistribution: PreferSameNode 生效；用于 Spegel 的本节点优先镜像回源。
  serviceTopology: true
  # hybrid: TCP 走 DSR(保源IP/回程少一跳), UDP 走 SNAT(避开分片坑)
  mode: $lb_mode
  # best-effort: 网卡支持 XDP 才启用加速, 不支持自动回退
  acceleration: $CILIUM_LB_ACCELERATION
$dsr_line
  # 允许按 Service 注解启用 Envoy L7 负载均衡(gRPC 感知)
  l7:
    backend: envoy

# 流量控制: EDT 速率控制(Pod annotation 限速) + BBR 拥塞控制
bandwidthManager:
  enabled: true
  bbr: $bbr

# L7 代理(HTTP/gRPC/Kafka 策略与可观测)
l7Proxy: true

# Local Redirect Policy 能力开关(node-local-dns 等场景; 还需另行 apply LRP CR)
localRedirectPolicy: $CILIUM_ENABLE_LRP

gatewayAPI:
  enabled: $CILIUM_ENABLE_GATEWAY_API
  # ALPN: 默认关。关着时 HTTPS listener 不协商 h2 —— GRPCRoute 经 TLS 终结不工作
  # (旧集群那条 55 天从未生效的 jaeger GRPCRoute, 根因之一就是它)
  enableAlpn: $CILIUM_GATEWAY_API_ALPN
ingressController:
  enabled: $CILIUM_ENABLE_INGRESS

l2announcements:
  enabled: $CILIUM_ENABLE_L2_ANNOUNCEMENTS
# L2 通告的租约续期依赖较高的 apiserver 客户端速率。
k8sClientRateLimit:
  qps: $CILIUM_K8S_CLIENT_QPS
  burst: $CILIUM_K8S_CLIENT_BURST

# 未使用 mesh mTLS(SPIFFE), 裁掉相关机制
authentication:
  enabled: false

ipv6:
  enabled: $ipv6_enabled

$hubble_block

$encryption_block

prometheus:
  enabled: true

operator:
  replicas: $CILIUM_OPERATOR_REPLICAS
  rollOutPods: true
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
    maxUnavailable: null
  resources:
    requests:
      cpu: $CILIUM_OPERATOR_CPU_REQUEST
      memory: $CILIUM_OPERATOR_MEMORY_REQUEST
  prometheus:
    enabled: true

envoy:
  resources:
    requests:
      cpu: $CILIUM_ENVOY_CPU_REQUEST
      memory: $CILIUM_ENVOY_MEMORY_REQUEST
EOF
}
verify_cilium_values() { [[ -s $VALUES_FILE ]] && grep -q 'kubeProxyReplacement: "true"' "$VALUES_FILE"; }

cilium_desired_fingerprint() {
  local values_sha
  values_sha=$(sha256sum "$VALUES_FILE" | awk '{print $1}')
  # LB-IPAM/L2 CR 不在 Helm values 里；不把它们纳入指纹，改池后 l2.done 会错误保留，
  # 60 阶段看似成功但集群仍用旧池(2026-09-04 机房适配深查发现)。Gateway 固定 VIP 也放进来，
  # 让改入口地址时至少重跑 L2/连通性步骤并在日志里显式暴露变化。
  printf 'cilium=%s\nvalues=%s\nl2=%s\npool=%s-%s\ngateway=%s\n' \
    "$CILIUM_V" "$values_sha" "$CILIUM_ENABLE_L2_ANNOUNCEMENTS" \
    "$CILIUM_LB_POOL_START" "$CILIUM_LB_POOL_STOP" "$CILIUM_GATEWAY_LB_IP" \
    | sha256sum | awk '{print $1}'
}

reconcile_cilium_apply_state() {
  local current rc=0
  current=$(cilium_desired_fingerprint)
  state_reconcile_fingerprint desired "$current" preflight prepull helm wait l2 conn || rc=$?
  case $rc in
    0) log_info "Cilium 版本或 values 指纹已变化，下游应用步骤自动失效" ;;
    1) log_info "Cilium 版本与 values 指纹未变化，保留已完成的下游步骤" ;;
    *) die "无法更新 Cilium 期望状态指纹" ;;
  esac
}

verify_cilium_apply_state() {
  local file="$STATE_DIR/state/60-cilium:desired.fingerprint.done"
  [[ -f $file && $(<"$file") == "$(cilium_desired_fingerprint)" ]]
}

guard_bpf_map_resize() {
  local live
  live=$(kctl -n kube-system get configmap cilium-config \
    -o jsonpath='{.data.bpf-map-dynamic-size-ratio}' 2>/dev/null || true)
  [[ -n $live && $live != "$CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO" ]] || return 0
  if [[ $CILIUM_BPF_MAP_RESIZE_APPROVED != true ]]; then
    die "BPF map 比例将从 $live 改为 $CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO；先采集至少 24h 基线并安排维护窗口，再把 CILIUM_BPF_MAP_RESIZE_APPROVED=true"
  fi
  log_warn "已显式批准 BPF map 比例 $live → $CILIUM_BPF_MAP_DYNAMIC_SIZE_RATIO；本次 rollout 会重建 CT/NAT map并可能中断长连接"
}

# --- 3.5 官方升级 preflight + 镜像预拉 ----------------------------------------------------
run_cilium_preflight() {
  if ! helm_cmd status cilium --namespace kube-system >/dev/null 2>&1; then
    log_info "集群尚未安装 Cilium，跳过升级 preflight"
    return 0
  fi

  local chart="cilium/cilium" version_args=(--version "${CILIUM_V#v}")
  local local_tgz="$CACHE_DIR/charts/cilium-${CILIUM_V#v}.tgz"
  local manifest="$STATE_DIR/cilium-preflight-${CILIUM_V#v}.yaml"
  if [[ -f $local_tgz ]]; then
    chart=$local_tgz
    version_args=()
  else
    helm_repo_add cilium https://helm.cilium.io/ >/dev/null
  fi

  helm_cmd template cilium-pre-flight "$chart" "${version_args[@]}" \
    --namespace kube-system \
    --set preflight.enabled=true \
    --set agent=false \
    --set operator.enabled=false \
    --set-string k8sServiceHost="$NODE_IP" \
    --set k8sServicePort=6443 > "$manifest"
  kctl apply -f "$manifest"
  kctl -n kube-system rollout status daemonset/cilium-pre-flight-check --timeout=10m
  kctl -n kube-system rollout status deployment/cilium-pre-flight-check --timeout=5m

  local agents preflight
  agents=$(kctl -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}')
  preflight=$(kctl -n kube-system get daemonset cilium-pre-flight-check -o jsonpath='{.status.numberReady}')
  [[ -n $agents && $preflight == "$agents" ]] \
    || die "Cilium preflight DaemonSet 未覆盖全部 Ready agent（preflight=$preflight, agent=$agents）"

  kctl delete -f "$manifest" --ignore-not-found
  rm -f "$manifest"
  log_ok "Cilium $CILIUM_V 官方 preflight 与 CNP 校验通过"
}

# --- 3.6 预拉 Cilium 镜像(quay.io 直连很慢; 代理在线则临时借道, 拉完即撤) -----------------
#   镜像清单从 chart 按当前 values 精确渲染(含 digest), 不猜标签
prepull_cilium_images() {
  local want_proxy=false
  case $PREPULL_VIA_PROXY in
    true)  proxy_alive || die "PREPULL_VIA_PROXY=true 但代理 $PROXY_URL 不可达, 请先开启代理"
           want_proxy=true ;;
    auto)  proxy_alive && want_proxy=true ;;
  esac
  if [[ $want_proxy != true ]]; then
    log_info "代理未在线/未启用预拉, Cilium 镜像交由 kubelet 按 certs.d/直连拉取"
    return 0
  fi

  # 解析 chart 引用(离线包优先), 渲染出镜像清单
  local chart="cilium/cilium" version_args=(--version "${CILIUM_V#v}")
  local local_tgz="$CACHE_DIR/charts/cilium-${CILIUM_V#v}.tgz"
  if [[ -f $local_tgz ]]; then
    chart=$local_tgz; version_args=()
  else
    helm_repo_add cilium https://helm.cilium.io/ >/dev/null
  fi
  local imgs tpl_err="$LOG_DIR/cilium-template.err"
  imgs=$(helm_cmd template cilium "$chart" "${version_args[@]}" \
           --namespace kube-system -f "$VALUES_FILE" 2>"$tpl_err" \
         | grep -E '^[[:space:]]+image:' \
         | sed -E 's/.*image:[[:space:]]*"?([^"]+)"?.*/\1/' | sort -u) || true
  if [[ -z $imgs ]]; then
    if [[ -s $tpl_err ]]; then
      # 渲染失败 = values 有问题, 同样的错误会让后面的 helm 安装失败 → 在这里就报清楚
      log_error "helm 渲染失败(该错误同样会阻断安装), chart 校验输出:"
      head -6 "$tpl_err" >&2
      die "请检查 $VALUES_FILE 后重跑(values 每次执行都会按 config 重新生成)"
    fi
    log_warn "渲染成功但未解析出镜像行, 跳过预拉(不影响安装, 只是拉取会慢)"
    return 0
  fi

  containerd_tmp_proxy_off   # 清理上次中断遗留
  containerd_tmp_proxy_on
  local img fail=0
  while read -r img; do
    [[ -n $img ]] || continue
    log_info "预拉: $img"
    crictl pull "$img" >/dev/null 2>&1 || { log_warn "拉取失败: $img"; fail=1; }
  done <<<"$imgs"
  containerd_tmp_proxy_off
  if (( fail == 0 )); then
    log_ok "Cilium 镜像全部预拉完成, helm 安装将秒级就绪"
  else
    log_warn "部分镜像预拉失败, kubelet 稍后会按 certs.d/直连自行重试"
  fi
  return 0
}

# --- 4. IPsec 密钥(仅启用加密时) ------------------------------------------------------
create_ipsec_secret() {
  if [[ $CILIUM_ENABLE_IPSEC != true ]]; then
    return 0
  fi
  kctl -n kube-system create secret generic cilium-ipsec-keys \
    --from-literal=keys="3+ rfc4106(gcm(aes)) $(openssl rand -hex 20) 128" \
    --dry-run=client -o yaml | kctl apply -f -
}

# --- 5. helm 安装 Cilium(优先使用离线 chart 包, 见 start.sh --pack-offline) --------------
helm_install_cilium() {
  local local_tgz="$CACHE_DIR/charts/cilium-${CILIUM_V#v}.tgz"
  if [[ -f $local_tgz ]]; then
    log_info "使用离线 chart: $local_tgz"
    retry 2 10 helm_cmd upgrade --install cilium "$local_tgz" \
      --namespace kube-system -f "$VALUES_FILE"
  else
    helm_repo_add cilium https://helm.cilium.io/
    retry 2 10 helm_cmd upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version "${CILIUM_V#v}" \
      -f "$VALUES_FILE"
  fi
}

# --- 6. 等待就绪 -------------------------------------------------------------------------
wait_cilium_ready() {
  cilium_cli status --wait --wait-duration 12m
  kctl wait --for=condition=Ready "node/$NODE_NAME" --timeout=300s
  kctl -n kube-system rollout status deployment/coredns --timeout=300s
}
verify_cilium_ready() {
  # kube-proxy 必须不存在(完全替代), 且 agent 内确认 KPR=True
  ! kctl -n kube-system get daemonset kube-proxy &>/dev/null || return 1
  # 先落变量再匹配, 避免流式输出接 grep -q 的 pipefail 误判
  local out
  out=$(kctl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null) || return 1
  grep -qiE 'KubeProxyReplacement:[[:space:]]*True' <<<"$out"
}

# --- 7. L2 通告 + LoadBalancer IP 池 ------------------------------------------------------
apply_l2_policy() {
  if [[ $CILIUM_ENABLE_L2_ANNOUNCEMENTS != true ]]; then
    # 本安装器把 IPPool 与 L2Policy 视为同一个能力。显式关闭就清理旧 CR，不能只跳过，
    # 否则 values 指纹虽然变了，历史 VIP 仍会继续分配/通告。
    # CRD 不存在(从未启用过)是合法情况; CRD 存在时删除失败必须暴露, 不能吞成"已清理"。
    if kctl get crd ciliuml2announcementpolicies.cilium.io >/dev/null 2>&1; then
      kctl delete ciliuml2announcementpolicies.cilium.io default-l2 --ignore-not-found
    fi
    if kctl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1; then
      kctl delete ciliumloadbalancerippools.cilium.io gateway-pool default-pool --ignore-not-found
    fi
    log_info "L2/LB-IPAM 已关闭, 旧 default-l2/gateway-pool/default-pool 已清理"
    return 0
  fi
  wait_for "CiliumLoadBalancerIPPool CRD 注册" 120 kctl get crd ciliumloadbalancerippools.cilium.io
  # Pool 的 API 组随版本演进(v2alpha1 → v2), 从 CRD served versions 动态探测,
  # 有稳定版(v2/v1 这类不带 alpha/beta 后缀)时优先用稳定版
  pick_served_api() {
    local versions stable
    versions=$(kctl get crd "$1" -o jsonpath='{.spec.versions[?(@.served==true)].name}' | tr ' ' '\n')
    [[ -n ${versions//[[:space:]]/} ]] || return 1
    # grep 找不到稳定版(如只有 v2alpha1)是合法情况, 不能让 set -e 击杀 → || true
    stable=$(grep -E '^v[0-9]+$' <<<"$versions" | sort -V | tail -1) || true
    if [[ -n $stable ]]; then echo "$stable"; else sort -V <<<"$versions" | tail -1; fi
  }
  local pool_api l2_api
  pool_api=$(pick_served_api ciliumloadbalancerippools.cilium.io)
  l2_api=$(pick_served_api ciliuml2announcementpolicies.cilium.io)

  cat > "$L2_FILE" <<EOF
# 共享 HTTP Gateway 专属 /32 池：组件在 80 阶段按依赖分层并行安装，Consul 或独立 L4 Gateway
# 可能先创建 LoadBalancer Service。不给共享 Gateway 独占地址就存在固定 VIP 被提前分走的竞态。
apiVersion: cilium.io/$pool_api
kind: CiliumLoadBalancerIPPool
metadata:
  name: gateway-pool
spec:
  blocks:
    - start: "$CILIUM_GATEWAY_LB_IP"
      stop: "$CILIUM_GATEWAY_LB_IP"
  # Cilium 为 Gateway default/cilium-gateway 生成的 Service 名固定为 cilium-gateway-cilium-gateway。
  # 使用 LB-IPAM 特殊 selector 字段匹配 Service 元数据，不依赖实现生成的普通 label。
  serviceSelector:
    matchLabels:
      "io.kubernetes.service.namespace": "default"
      "io.kubernetes.service.name": "cilium-gateway-cilium-gateway"
---
# 其它 LoadBalancer Service 的默认池（Consul、Postgres/Dragonfly 独立 Gateway、可选 Kafka 等）。
apiVersion: cilium.io/$pool_api
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  # IP 池用显式范围而非 CIDR, 与 control-plane/03-cni/cilium/l2 示例保持一致
  blocks:
    - start: "$CILIUM_LB_POOL_START"
      stop: "$CILIUM_LB_POOL_STOP"
  # 共享 Gateway 的 Service 只能落在 gateway-pool: 无 selector 的池会匹配所有 Service, 一旦
  # 固定 IP 请求注解丢失(如 infrastructure.annotations 覆盖), 它就会从这里拿到一个非 .240 地址而
  # Gateway 仍显示 Programmed=True。NotIn 按名字排除(该名字在任何 namespace 都不该进本池)。
  serviceSelector:
    matchExpressions:
      - key: io.kubernetes.service.name
        operator: NotIn
        values: [cilium-gateway-cilium-gateway]
---
apiVersion: cilium.io/$l2_api
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2
spec:
  loadBalancerIPs: true
  interfaces:
    - ^en.*
    - ^eth.*
EOF
  kctl apply -f "$L2_FILE"
  # apply 成功只是写入了期望; 等 operator 在当前 generation 上给出 PoolConflict 结论再判定成功,
  # 否则两池重叠/与旧池冲突这类问题会被"apply 通过"掩盖。
  wait_for "LB-IPAM 池调和(PoolConflict 条件)" 120 l2_pools_reconciled
}

# 两个池都已被 operator 在当前 generation 上评估(结论好坏由 verify_l2_policy 判定)
l2_pools_reconciled() {
  local pool json
  for pool in gateway-pool default-pool; do
    json=$(kctl get ciliumloadbalancerippools.cilium.io "$pool" -o json 2>/dev/null) || return 1
    jq -e '
      ([.status.conditions[]? | select(.type == "cilium.io/PoolConflict")] | last) as $c
      | $c != null and ($c.observedGeneration // -1) == .metadata.generation
    ' <<<"$json" >/dev/null || return 1
  done
}

verify_l2_policy() {
  if [[ $CILIUM_ENABLE_L2_ANNOUNCEMENTS != true ]]; then
    ! kctl get ciliuml2announcementpolicies.cilium.io default-l2 >/dev/null 2>&1 \
      && ! kctl get ciliumloadbalancerippools.cilium.io gateway-pool >/dev/null 2>&1 \
      && ! kctl get ciliumloadbalancerippools.cilium.io default-pool >/dev/null 2>&1
    return
  fi
  # 一次读取完整对象, 用 lib/common.sh 的纯校验(blocks 全部段/selector/disabled/PoolConflict@generation)
  local gw_json def_json l2_json problems
  gw_json=$(kctl get ciliumloadbalancerippools.cilium.io gateway-pool -o json 2>/dev/null) || return 1
  def_json=$(kctl get ciliumloadbalancerippools.cilium.io default-pool -o json 2>/dev/null) || return 1
  l2_json=$(kctl get ciliuml2announcementpolicies.cilium.io default-l2 -o json 2>/dev/null) || return 1
  problems=$(
    lb_pool_problems "$gw_json" "$CILIUM_GATEWAY_LB_IP" "$CILIUM_GATEWAY_LB_IP" default cilium-gateway-cilium-gateway
    lb_pool_problems "$def_json" "$CILIUM_LB_POOL_START" "$CILIUM_LB_POOL_STOP" exclude=cilium-gateway-cilium-gateway
    l2_policy_problems "$l2_json"
  )
  if [[ -n $problems ]]; then
    log_error "LB-IPAM/L2 校验未通过:"$'\n'"$problems"
    return 1
  fi
  log_info "LB-IPAM/L2 CR 校验通过(gateway-pool=$CILIUM_GATEWAY_LB_IP/32 独占, default-pool=$CILIUM_LB_POOL_START-$CILIUM_LB_POOL_STOP, 两池 PoolConflict=False); 网络可达性由 90 阶段冒烟与 newt 实测判定"
}

# --- 8. 全量连通性测试(可选, 约 10 分钟) ----------------------------------------------------
run_connectivity_test() {
  if ! resolve_opt "$RUN_CILIUM_CONNECTIVITY_TEST" "运行 Cilium 全量连通性测试(约 10 分钟, 需拉测试镜像)?" N; then
    log_info "跳过连通性测试"
    return 0
  fi
  # 外网相关用例受环境影响大, 失败降级为警告
  cilium_cli connectivity test || log_warn "连通性测试存在失败用例, 请查看上方输出定位"
}

main() {
  stage_begin "60-cilium" "Cilium eBPF 网络"
  if is_worker; then
    log_skip "NODE_ROLE=worker: Cilium 由控制面以 DaemonSet 调度到本节点, 无需本地安装, 跳过"
    stage_end
    return 0
  fi
  ensure_artifacts
  # values 是 config.env + 内核探测的纯函数，必须始终重新生成；指纹步骤也必须每次比较。
  # 只有期望状态变化时才使 preflight/helm 等下游步骤失效，不重置 IPsec 步骤。
  # l2 步骤是幂等 apply + 完整对象校验, 每次重跑都重新执行: 指纹只覆盖 config.env 的变化,
  # 集群里被人工改过/删掉的池与 L2Policy(live 漂移)只能靠这里重新校验发现。
  rm -f "$STATE_DIR/state/60-cilium:values.done" \
        "$STATE_DIR/state/60-cilium:fingerprint.done" \
        "$STATE_DIR/state/60-cilium:mapguard.done" \
        "$STATE_DIR/state/60-cilium:l2.done"
  add_step cli         "安装 cilium CLI $CILIUM_CLI_V 与 helm $HELM_V" install_cli_tools             verify_cli_tools
  add_step gwcrd       "Gateway API CRD $GATEWAY_API_V"                install_gateway_api_crds       verify_gateway_api_crds
  add_step values      "生成 Cilium values(内核能力自适应)"            gen_cilium_values             verify_cilium_values
  add_step fingerprint "核对 Cilium 版本与 values 指纹"                reconcile_cilium_apply_state   verify_cilium_apply_state
  add_step mapguard    "检查 BPF map 缩容维护窗口授权"                  guard_bpf_map_resize
  add_step preflight   "运行 Cilium $CILIUM_V 官方升级 preflight"      run_cilium_preflight
  add_step prepull     "预拉 Cilium 镜像(代理在线则借道)"              prepull_cilium_images
  add_step ipsec       "IPsec 密钥(可选)"                              create_ipsec_secret
  add_step helm        "helm 安装 Cilium $CILIUM_V"                    helm_install_cilium
  add_step wait        "等待 Cilium/节点/CoreDNS 就绪"                 wait_cilium_ready             verify_cilium_ready
  add_step l2          "L2 通告与 LoadBalancer IP 池"                  apply_l2_policy               verify_l2_policy
  add_step conn        "连通性测试(可选)"                              run_connectivity_test
  run_steps
  stage_end
}
main "$@"
