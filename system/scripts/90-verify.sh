#!/usr/bin/env bash
# =============================================================================
# 90-verify —— 全局验收与报告
#   - 控制面/CNI/存储/组件逐项复检(核心项失败即报错, 可选组件仅警告)
#   - 冒烟测试: PVC 读写(默认开) / LoadBalancer L2 通告(默认关)
#               可观测链路 OTLP 打点→后端查回(默认开, 只测已启用的 vm/loki/jaeger)
#   - 生成 /root/k8s-install-report.txt
#   注意: 本阶段所有步骤不做状态跳过(每次执行都完整复检)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

ensure_versions
REPORT="/root/k8s-install-report.txt"
SMOKE_NS="k8s-smoke"

# 验收阶段每次都要真实复检 → 先清掉本阶段历史状态
state_reset "90-verify"

# --- 1. 控制面与节点 ------------------------------------------------------------------
check_control_plane() {
  [[ $(kctl get --raw /readyz 2>/dev/null) == ok ]] || die "apiserver /readyz 异常"
  kctl get nodes -o wide
  local not_ready
  not_ready=$(kctl get nodes --no-headers | awk '$2 != "Ready" {print $1}')
  [[ -z $not_ready ]] || die "存在未就绪节点: $not_ready"

  # 核心命名空间不允许有异常 Pod
  local bad
  bad=$(kctl get pods -n kube-system --no-headers 2>/dev/null \
        | awk '$3 != "Running" && $3 != "Completed" {print $1"("$3")"}')
  [[ -z $bad ]] || die "kube-system 存在异常 Pod: $bad"
  log_info "控制面健康, 节点全部 Ready"
}

# --- 2. kube-proxy 已被完全替代 ---------------------------------------------------------
check_kube_proxy_free() {
  if kctl -n kube-system get daemonset kube-proxy &>/dev/null; then
    die "检测到 kube-proxy DaemonSet 仍存在(应已被 Cilium 完全替代)"
  fi
  local kube_rules
  kube_rules=$(iptables-save 2>/dev/null | grep -c '^-A KUBE-SVC' || true)
  if (( kube_rules > 0 )); then
    log_warn "iptables 中仍有 $kube_rules 条 KUBE-SVC 规则(历史残留), 可重启节点清理"
  fi
  # 先落变量再匹配: kubectl exec 是流式输出, 接 grep -q 会因早关管道被 pipefail 误判
  local status_out
  status_out=$(kctl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null) || true
  grep -iE 'KubeProxyReplacement|Host Routing|Masquerading|BandwidthManager' <<<"$status_out" || true
  grep -qiE 'KubeProxyReplacement:[[:space:]]*True' <<<"$status_out" \
    || die "Cilium KubeProxyReplacement 未生效"
  log_info "kube-proxy 已完全移除, Cilium eBPF 接管服务转发"
}

# --- 3. 系统调优抽检 ---------------------------------------------------------------------
check_tuning() {
  verify_sysctl net.ipv4.tcp_congestion_control bbr || die "BBR 未生效"
  verify_sysctl net.ipv4.ip_forward 1              || die "ip_forward 未开启"
  grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled || die "透明大页未关闭"
  [[ -z $(swapon --noheadings 2>/dev/null) ]]      || die "Swap 仍处于开启状态"
  log_info "系统调优抽检通过(BBR/转发/THP/Swap)"
}

# --- 4. 存储冒烟(PVC 创建→写→读→清理) ------------------------------------------------------
smoke_storage() {
  if [[ $VERIFY_PVC_SMOKE_TEST != true ]]; then
    log_info "已关闭 PVC 冒烟测试, 跳过"
    return 0
  fi
  if ! kctl get sc "$SC_NAME" &>/dev/null; then
    log_warn "StorageClass $SC_NAME 不存在(存储阶段可能被跳过), 跳过冒烟测试"
    return 0
  fi
  kctl delete ns "$SMOKE_NS" --ignore-not-found --timeout=120s
  cat <<EOF | kctl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $SMOKE_NS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-pvc
  namespace: $SMOKE_NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC_NAME
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-pod
  namespace: $SMOKE_NS
spec:
  restartPolicy: Never
  containers:
    - name: t
      image: docker.io/library/busybox:stable
      command: [sh, -c, "echo smoke-ok > /mnt/f && cat /mnt/f && sync"]
      volumeMounts:
        - name: v
          mountPath: /mnt
  volumes:
    - name: v
      persistentVolumeClaim:
        claimName: smoke-pvc
EOF
  kctl -n "$SMOKE_NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/smoke-pod --timeout=300s \
    || { kctl -n "$SMOKE_NS" describe pod smoke-pod | tail -20 >&2; die "PVC 冒烟测试失败"; }
  [[ $(kctl -n "$SMOKE_NS" get pvc smoke-pvc -o jsonpath='{.status.phase}') == Bound ]] \
    || die "PVC 未 Bound"
  local smoke_log
  smoke_log=$(kctl -n "$SMOKE_NS" logs smoke-pod 2>/dev/null) || true
  grep -q smoke-ok <<<"$smoke_log" || die "PVC 读写内容校验失败"
  kctl delete ns "$SMOKE_NS" --timeout=120s
  log_info "存储链路冒烟测试通过(创建→写→读→清理)"
}

# --- 5. LoadBalancer L2 冒烟(可选) -----------------------------------------------------------
smoke_loadbalancer() {
  if [[ $VERIFY_LB_SMOKE_TEST != true || $CILIUM_ENABLE_L2_ANNOUNCEMENTS != true ]]; then
    log_info "LB 冒烟测试未启用, 跳过"
    return 0
  fi
  kctl delete ns lb-smoke --ignore-not-found --timeout=120s
  cat <<EOF | kctl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: lb-smoke
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: lb-smoke
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: nginx
          image: docker.io/library/nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: lb-smoke
spec:
  type: LoadBalancer
  selector: {app: web}
  ports:
    - port: 80
EOF
  local ip="" i
  for ((i = 0; i < 36; i++)); do
    ip=$(kctl -n lb-smoke get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n $ip ]] && break
    sleep 5
  done
  [[ -n $ip ]] || die "LoadBalancer 服务未分配到外部 IP(检查 CiliumLoadBalancerIPPool)"
  kctl -n lb-smoke rollout status deploy/web --timeout=300s

  # L2 通告的 VIP 面向局域网"其他"主机(ARP 应答), 节点自访不走该路径 —— 已知行为,
  # 因此判定标准是: Cilium 已编程该 LB 服务 + L2 通告租约存在; 节点自访通了算加分
  local svc_prog
  svc_prog=$(kctl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null) || true
  grep -q "$ip" <<<"$svc_prog" || die "Cilium 未编程 LB 服务($ip), 数据面异常"
  if ! kctl -n kube-system get lease cilium-l2announce-lb-smoke-web &>/dev/null; then
    log_warn "未见 L2 通告租约(cilium-l2announce-lb-smoke-web), 外部可达性存疑"
  fi
  local lb_body=""
  if lb_body=$(curl -fsS --max-time 5 "http://$ip/" 2>/dev/null) && grep -qi nginx <<<"$lb_body"; then
    log_info "节点自访 VIP 也通(加分项)"
  else
    log_info "节点自访 VIP 未通 —— L2 通告的已知行为(ARP 只应答外部主机); 从局域网其他机器执行 curl http://$ip/ 验证"
  fi
  kctl delete ns lb-smoke --timeout=120s
  log_ok "LoadBalancer 冒烟通过: VIP $ip 已分配并由 Cilium 编程(外部可达性从局域网内其他主机验证)"
}

# --- 6. 可观测链路冒烟(OTLP 打点 → 回查后端确认落库) ---------------------------------------
#   为什么要打真数据: Pod Running / 端口通 只能证明进程活着, 证明不了 exporter 写得进后端
#   (实测踩过: collector 早于后端启动会刷一屏 connection refused, 靠重试自愈——光看日志分不清
#    是"已自愈的历史噪声"还是"至今没通")。这里按信号逐条打点再回查, 只校验实际启用的后端。
OTEL_SMOKE_NS="otel-smoke"
# 组件是否在 80 阶段被选中(addon_selected 定义在 80-addons.sh 里, 本阶段自带一份)
addon_on() { grep -qx "$1" "$STATE_DIR/addons.selected" 2>/dev/null; }

smoke_observability() {
  if [[ $VERIFY_OTEL_SMOKE_TEST != true ]]; then
    log_info "已关闭可观测链路冒烟测试, 跳过"
    return 0
  fi
  if ! addon_on otel; then
    log_info "未安装 OTel Collector, 跳过可观测链路冒烟"
    return 0
  fi
  if ! kctl -n opentelemetry get deploy otel-opentelemetry-collector &>/dev/null; then
    log_warn "otel 在已选清单里但 Collector 不存在(80 阶段可能失败), 跳过可观测链路冒烟"
    return 0
  fi

  # 三条 pipeline 各自独立可选: 后端没装就不打对应信号(collector 里根本没有那条 pipeline,
  # 打过去会 404), 也不回查
  local ck_vm=false ck_loki=false ck_jaeger=false signals=()
  addon_on vm     && kctl -n victoriametrics get svc vm-single-victoria-metrics-single-server &>/dev/null \
    && { ck_vm=true;     signals+=("metrics→VictoriaMetrics"); }
  addon_on loki   && kctl -n logging get svc loki &>/dev/null \
    && { ck_loki=true;   signals+=("logs→Loki"); }
  addon_on jaeger && kctl -n observability get svc jaeger &>/dev/null \
    && { ck_jaeger=true; signals+=("traces→Jaeger"); }
  if (( ${#signals[@]} == 0 )); then
    log_info "未启用任何观测后端(vm/loki/jaeger), 跳过可观测链路冒烟"
    return 0
  fi
  log_info "可观测链路冒烟: ${signals[*]}"

  kctl delete ns "$OTEL_SMOKE_NS" --ignore-not-found --timeout=120s
  # 说明: 容器内脚本用 \$ 转义(本 heredoc 未加引号, 只放行 VM_SVC/LOKI_SVC/JAEGER_SVC 等安装器变量)
  cat <<EOF | kctl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $OTEL_SMOKE_NS
---
apiVersion: v1
kind: Pod
metadata:
  name: otel-smoke
  namespace: $OTEL_SMOKE_NS
spec:
  restartPolicy: Never
  containers:
    - name: t
      image: docker.io/curlimages/curl:latest
      env:
        - {name: CK_VM,     value: "$ck_vm"}
        - {name: CK_LOKI,   value: "$ck_loki"}
        - {name: CK_JAEGER, value: "$ck_jaeger"}
        - {name: VM_SVC,    value: "$VM_SVC"}
        - {name: LOKI_SVC,  value: "$LOKI_SVC"}
        - {name: JAEGER_SVC, value: "$JAEGER_SVC"}
      command: [sh, -c]
      args:
        - |
          set -u
          RUN=\$(date +%s)
          TS=\${RUN}000000000
          SVC="otel-smoke-\$RUN"           # 每次跑都换名字: 避免查到上一轮的残留数据误判为通过
          OTLP="http://otel-opentelemetry-collector.opentelemetry.svc.cluster.local:4318"
          fail=0

          push() {  # \$1=信号 \$2=OTLP 路径 \$3=载荷文件
            code=\$(curl -s -o /tmp/resp -w '%{http_code}' -X POST \\
                     -H 'Content-Type: application/json' --data-binary @"\$3" "\$OTLP\$2")
            if [ "\$code" = 200 ]; then
              echo "  push  \$1: ok"
            else
              echo "  push  \$1: 失败 http=\$code \$(cat /tmp/resp)"; fail=1; return 1
            fi
          }

          poll() {  # \$1=信号 \$2=期望子串 \$3=回查命令(eval)
            n=0
            while [ \$n -lt 40 ]; do    # 40×3s=120s: VM 默认 -search.latencyOffset=30s, 要留够
              out=\$(eval "\$3" 2>/dev/null || true)
              case "\$out" in
                *"\$2"*) echo "  查回  \$1: ok (第 \$((n+1)) 次)"; return 0 ;;
              esac
              n=\$((n + 1)); sleep 3
            done
            echo "  查回  \$1: 失败(120s 内没查到 \$2)"; fail=1; return 1
          }

          if [ "\$CK_VM" = true ]; then
            cat > /tmp/m.json <<JSON
          {"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"\$SVC"}}]},
          "scopeMetrics":[{"metrics":[{"name":"otel_smoke_probe","gauge":{"dataPoints":[
          {"asDouble":1,"timeUnixNano":"\$TS","attributes":[{"key":"run","value":{"stringValue":"\$RUN"}}]}]}}]}]}]}
          JSON
            push metrics /v1/metrics /tmp/m.json && poll metrics '"result":[{' \\
              "curl -sG 'http://\$VM_SVC/api/v1/query' --data-urlencode 'query=otel_smoke_probe{run=\\"\$RUN\\"}'"
          fi

          if [ "\$CK_LOKI" = true ]; then
            cat > /tmp/l.json <<JSON
          {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"\$SVC"}}]},
          "scopeLogs":[{"logRecords":[{"timeUnixNano":"\$TS","severityText":"INFO",
          "body":{"stringValue":"otel pipeline smoke \$RUN"}}]}]}]}
          JSON
            push logs /v1/logs /tmp/l.json && poll logs "otel pipeline smoke \$RUN" \\
              "curl -sG 'http://\$LOKI_SVC/loki/api/v1/query_range' --data-urlencode 'query={service_name=\\"\$SVC\\"}' --data-urlencode 'limit=5'"
          fi

          if [ "\$CK_JAEGER" = true ]; then
            cat > /tmp/t.json <<JSON
          {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"\$SVC"}}]},
          "scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174",
          "name":"smoke-span","kind":1,"startTimeUnixNano":"\$TS","endTimeUnixNano":"\$TS"}]}]}]}
          JSON
            push traces /v1/traces /tmp/t.json && poll traces "\$SVC" \\
              "curl -s 'http://\$JAEGER_SVC:16686/api/services'"
          fi

          [ \$fail -eq 0 ] && echo "SMOKE-RESULT ok" || echo "SMOKE-RESULT failed"
          exit \$fail
EOF

  local phase="" i
  for ((i = 0; i < 90; i++)); do   # 最长 450s: 首次要拉 curl 镜像
    phase=$(kctl -n "$OTEL_SMOKE_NS" get pod otel-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ $phase == Succeeded || $phase == Failed ]] && break
    sleep 5
  done
  local out
  out=$(kctl -n "$OTEL_SMOKE_NS" logs otel-smoke 2>/dev/null) || true
  [[ -n $out ]] && printf '%s\n' "$out"

  if [[ $phase == Succeeded ]]; then
    kctl delete ns "$OTEL_SMOKE_NS" --timeout=120s
    log_ok "可观测链路冒烟通过: ${signals[*]}(打点→后端查回)"
  else
    # 观测属可选组件: 只警告不中断验收, 现场留给用户查(命名空间不删)
    kctl -n "$OTEL_SMOKE_NS" describe pod otel-smoke 2>/dev/null | tail -15 >&2
    log_warn "可观测链路冒烟未通过(phase=${phase:-Unknown}); 现场保留在命名空间 $OTEL_SMOKE_NS, 排查后手动 kubectl delete ns $OTEL_SMOKE_NS"
  fi
  return 0
}

# --- 7. 汇总报告 ------------------------------------------------------------------------------
write_report() {
  local kver hubble_hint="" addons=""
  kver=$(kubeadm version -o short 2>/dev/null || echo "?")
  [[ -f $STATE_DIR/addons.selected ]] && addons=$(tr '\n' ' ' < "$STATE_DIR/addons.selected")
  [[ $CILIUM_ENABLE_HUBBLE_UI == true ]] && hubble_hint="cilium hubble ui   # 打开流量观测界面(自动端口转发)"

  cat > "$REPORT" <<EOF
==============================================================
 K8s 单控制面集群安装报告   $(date '+%F %T')
==============================================================
节点        : $NODE_NAME ($NODE_IP)  [$ARCH]
Kubernetes  : $kver (kube-proxy 已由 Cilium eBPF 完全替代)
containerd  : $CONTAINERD_V   runc: $RUNC_V   crictl: $CRICTL_V
Cilium      : $CILIUM_V (CLI $CILIUM_CLI_V)  路由: $CILIUM_ROUTING_MODE
Helm        : $HELM_V   Gateway-API: $GATEWAY_API_V
OpenEBS     : $OPENEBS_V (VG: $LVM_VG_NAME → SC: $SC_NAME/$SC_FS_TYPE)
Pod CIDR    : $POD_CIDR    Service CIDR: $SERVICE_CIDR
LB IP 池    : $CILIUM_LB_POOL_START - $CILIUM_LB_POOL_STOP (L2 通告: $CILIUM_ENABLE_L2_ANNOUNCEMENTS)
已装组件    : ${addons:-无}

常用入口:
  kubectl get pods -A
  cilium status
  $hubble_hint
  组件密码   : /root/.k8s-installer-credentials
  安装日志   : $LOG_DIR/
  版本锁定   : $VERSIONS_LOCK (删除后重跑可升级到新版)

扩容工作节点:
  kubeadm token create --print-join-command   # 生成加入命令
$( [[ -f $STATE_DIR/reboot-recommended ]] && echo "
提示: 存在建议重启的变更(GRUB/内核参数持久化), 空闲时执行 reboot 一次" )
==============================================================
EOF
  hr
  cat "$REPORT"
  log_ok "报告已写入 $REPORT"
}

# =============================================================================
# worker 专属轻量验收(本机没有 admin kubeconfig, 集群级检查在控制面做)
# =============================================================================
check_worker_runtime() {
  svc_active containerd || die "containerd 未运行"
  svc_active kubelet    || die "kubelet 未运行"
  [[ -f /etc/kubernetes/kubelet.conf ]] || die "未发现 kubelet.conf, 节点尚未加入集群"
  log_info "containerd/kubelet 运行中, 节点已加入集群"
}

check_worker_cilium() {
  # Cilium agent 由控制面调度过来, 到位时间取决于镜像拉取; 未到位仅警告
  if wait_for "Cilium agent 调度到本节点" 300 bash -c 'crictl pods 2>/dev/null | grep cilium >/dev/null'; then
    log_info "Cilium agent 已在本节点运行"
  else
    log_warn "Cilium agent 尚未出现(可能仍在拉镜像); 在控制面用 kubectl -n kube-system get pods -o wide 观察"
  fi
  return 0
}

write_worker_report() {
  local joined="?"
  [[ -f $STATE_DIR/join.params ]] && joined=$(awk -F= '$1=="JOIN_ENDPOINT"{print $2}' "$STATE_DIR/join.params")
  local vg_state="未提供本地存储"
  vgs "$LVM_VG_NAME" &>/dev/null && vg_state="VG $LVM_VG_NAME: $(vgs --noheadings -o vg_size,vg_free "$LVM_VG_NAME" 2>/dev/null | tr -s ' ')"
  cat > "$REPORT" <<EOF
==============================================================
 K8s 工作节点加入报告   $(date '+%F %T')
==============================================================
节点        : $NODE_NAME ($NODE_IP)  [$ARCH]  角色: worker
控制面      : $joined
containerd  : $CONTAINERD_V   runc: $RUNC_V   crictl: $CRICTL_V
本地存储    : $vg_state

后续确认(在控制面节点执行):
  kubectl get nodes -o wide          # 本节点应为 Ready(CNI 就绪后)
  cilium status                      # agent 数量应 +1
$( [[ -f $STATE_DIR/reboot-recommended ]] && echo "
提示: 存在建议重启的持久化变更(GRUB), 空闲时执行 reboot 一次" )
==============================================================
EOF
  hr
  cat "$REPORT"
  log_ok "报告已写入 $REPORT"
}

main() {
  stage_begin "90-verify" "全局验收"
  if is_worker; then
    add_step tuning  "系统调优抽检"                    check_tuning
    add_step runtime "运行时与加入状态检查"            check_worker_runtime
    add_step cni     "Cilium agent 到位检查(软性)"     check_worker_cilium
    add_step report  "生成加入报告"                    write_worker_report
  else
    add_step cp      "控制面与节点健康检查"        check_control_plane
    add_step nokp    "kube-proxy 替代确认(eBPF)"   check_kube_proxy_free
    add_step tuning  "系统调优抽检"                check_tuning
    add_step pvc     "存储冒烟测试"                smoke_storage
    add_step lb      "LoadBalancer 冒烟测试(可选)" smoke_loadbalancer
    add_step otel    "可观测链路冒烟测试(可选)"    smoke_observability
    add_step report  "生成安装报告"                write_report
  fi
  run_steps
  stage_end
}
main "$@"
