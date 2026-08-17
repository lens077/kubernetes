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
gen_cilium_values() {
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
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - icmp
      - httpV2:exemplars=true;labelsContext=source_namespace,destination_namespace,traffic_direction
  relay:
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
  # 允许集群外主机访问 ClusterIP(配合到 Pod/Service 网段的路由使用)
  lbExternalClusterIP: true
  # 官方性能调优配方三件套: 每 CPU 分片 LRU 连接表 + 大表上限(8%内存) + 按需分配
  # (上限不是即时占用; 三者配套, 勿单独改 preallocateMaps=true)
  preallocateMaps: false
  distributedLRU:
    enabled: true
  mapDynamicSizeRatio: 0.08
$netkit_line

# CiliumEndpointSlice: 批量化 endpoint 上报, 降低 apiserver/etcd 压力
ciliumEndpointSlice:
  enabled: true
# 路径 MTU 发现传播到 Pod(ICMP frag-needed)
pmtuDiscovery:
  enabled: true

# 以下三项在 kubeProxyReplacement=true 下已隐含开启, 显式写出仅为自文档
socketLB:
  enabled: true
nodePort:
  enabled: true
hostPort:
  enabled: true
# Service ClientIP 会话亲和
sessionAffinity: true

# 数据面网卡显式钉住(自动探测结果; 多网卡在 config.env 的 CILIUM_DEVICES 指定)
devices:
$devices_yaml

loadBalancer:
  algorithm: $CILIUM_LB_ALGORITHM
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
externalIPs:
  enabled: true
# L2 通告的租约续期依赖较高的 apiserver 客户端速率
k8sClientRateLimit:
  qps: 50
  burst: 100

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
  # 单控制面只跑一个 operator 副本, 否则第二副本永远 Pending(chart 默认 2)
  replicas: 1
  rollOutPods: true
  prometheus:
    enabled: true
EOF
}
verify_cilium_values() { [[ -s $VALUES_FILE ]] && grep -q 'kubeProxyReplacement: "true"' "$VALUES_FILE"; }

# --- 3.5 预拉 Cilium 镜像(quay.io 直连很慢; 代理在线则临时借道, 拉完即撤) -----------------
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
    log_info "未启用 L2 通告, 跳过"
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
apiVersion: cilium.io/$pool_api
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  # IP 池用显式范围而非 CIDR, 与 control-plane/03-cni/cilium/l2 示例保持一致
  blocks:
    - start: "$CILIUM_LB_POOL_START"
      stop: "$CILIUM_LB_POOL_STOP"
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
}
verify_l2_policy() {
  [[ $CILIUM_ENABLE_L2_ANNOUNCEMENTS != true ]] \
    || kctl get ciliumloadbalancerippools.cilium.io default-pool >/dev/null
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
  # values 是 config.env + 内核探测的纯函数, 必须始终重新生成,
  # 否则修改配置/升级脚本后会拿旧 values 安装(本次 tproxy×netkit 冲突正是这么暴露的)
  rm -f "$STATE_DIR/state/60-cilium:values.done"
  add_step cli     "安装 cilium CLI $CILIUM_CLI_V 与 helm $HELM_V" install_cli_tools       verify_cli_tools
  add_step gwcrd   "Gateway API CRD $GATEWAY_API_V"                install_gateway_api_crds verify_gateway_api_crds
  add_step values  "生成 Cilium values(内核能力自适应)"            gen_cilium_values       verify_cilium_values
  add_step prepull "预拉 Cilium 镜像(代理在线则借道)"              prepull_cilium_images
  add_step ipsec   "IPsec 密钥(可选)"                              create_ipsec_secret
  add_step helm    "helm 安装 Cilium $CILIUM_V"                    helm_install_cilium
  add_step wait    "等待 Cilium/节点/CoreDNS 就绪"                 wait_cilium_ready       verify_cilium_ready
  add_step l2      "L2 通告与 LoadBalancer IP 池"                  apply_l2_policy         verify_l2_policy
  add_step conn    "连通性测试(可选)"                              run_connectivity_test
  run_steps
  stage_end
}
main "$@"
