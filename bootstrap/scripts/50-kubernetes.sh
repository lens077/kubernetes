#!/usr/bin/env bash
# =============================================================================
# 50-kubernetes —— kubelet/kubeadm/kubectl 与集群初始化/加入(按 NODE_ROLE 分流)
#   control-plane: kubeadm init(跳过 kube-proxy, 由 Cilium eBPF 完全替代)
#                  + defrag 定时器 + kubectl 别名
#   worker       : kubeadm join(参数来自 config.env 的 JOIN_*, 或交互粘贴
#                  控制面 `kubeadm token create --print-join-command` 的输出)
#   - sandbox(pause) 镜像与 kubeadm 输出精确对齐, 两种角色都需要
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

ensure_versions
KUBEADM_YML="$K8S_FILES_DIR/kubeadm.yml"
JOIN_YML="$K8S_FILES_DIR/kubeadm-join.yml"

k8s_image_repo() {
  # 与 USE_CN_MIRRORS 解耦: 显式指定 K8S_IMAGE_REPO 优先(如"仓库用阿里云,但 mirror 用自带 certs.d")
  if [[ -n $K8S_IMAGE_REPO ]]; then echo "$K8S_IMAGE_REPO"
  elif [[ $USE_CN_MIRRORS == true ]]; then echo "registry.aliyuncs.com/google_containers"
  else echo "registry.k8s.io"; fi
}

# --- 1. apt 仓库(pkgs.k8s.io 按 minor 分流) ---------------------------------------
setup_apt_repo() {
  # 部分精简镜像没有该目录, 显式创建(权限 755)
  install -d -m 755 /etc/apt/keyrings
  # key 先落盘再喂 gpg: 带重试, 代理失败退直连, 内容校验防半截文件(node1 实测代理 TLS 抽风)
  local key_url="https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR_V/deb/Release.key"
  local key_tmp="$CACHE_DIR/k8s-Release.key"
  rm -f "$key_tmp"
  if ! fetch "$key_url" "$key_tmp"; then
    log_warn "经代理获取 Release.key 失败, 改为直连重试"
    retry 3 5 curl -fsSL --connect-timeout 10 --max-time 60 -o "$key_tmp" "$key_url"
  fi
  grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$key_tmp" || die "Release.key 内容异常(非 PGP 公钥), 检查网络通道"
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$key_tmp"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR_V/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt_update
}
verify_apt_repo() {
  # pkgs.k8s.io 会 302 重定向到 prod-cdn.packages.k8s.io, 新版 apt 按生效域名显示,
  # 不能死板匹配 "pkgs.k8s.io"; 校验语义: 有候选版本 + 来自 k8s.io 域 + minor 对得上
  local out
  out=$(LC_ALL=C apt-cache policy kubeadm 2>/dev/null)
  [[ $out == *k8s.io* \
     && $out == *Candidate:* \
     && $out != *"Candidate: (none)"* \
     && $out == *"$K8S_MINOR_V."* ]]
}

# --- 2. 安装并锁定版本(原脚本注释说 pin 但没做, 这里补上 apt-mark hold) --------------
install_k8s_packages() {
  pkg_install kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet   # init 前 crashloop 属正常现象
}
verify_k8s_packages() {
  has_cmd kubeadm && has_cmd kubectl \
    && apt-mark showhold | grep -q kubeadm
}

configure_graceful_node_shutdown() {
  local budget total critical runtime_budget runtime_total runtime_critical
  local file desired changed=false
  budget=$(node_shutdown_budget_seconds \
    "$KUBELET_SHUTDOWN_GRACE" "$KUBELET_SHUTDOWN_GRACE_CRITICAL") \
    || die "GracefulNodeShutdown 预算配置无效"
  read -r total critical <<<"$budget"

  # 已运行节点先检查 kubelet,避免先改 logind 后才发现两边预算不一致。
  if [[ -f /var/lib/kubelet/config.yaml ]]; then
    runtime_budget=$(kubelet_shutdown_budget_seconds) \
      || die "kubelet 运行配置缺少或无法解析 shutdownGracePeriod 字段"
    if [[ $runtime_budget != "$budget" ]]; then
      read -r runtime_total runtime_critical <<<"$runtime_budget"
      die "config.env 预算(${total}s/${critical}s)与 kubelet 运行预算(${runtime_total}s/${runtime_critical}s)不一致;先更新 kubelet 配置"
    fi
  fi

  # unattended-upgrades 自带 InhibitDelayMaxSec=30。文件名必须用 zzz- 前缀,
  # 确保 systemd 按字典序合并 drop-in 时,安装器派生的值最后生效。
  file=/etc/systemd/logind.conf.d/zzz-kubelet.conf
  desired=$(printf '[Login]\nInhibitDelayMaxSec=%s' "$total")
  install -d -m 755 "$(dirname "$file")"
  if [[ -e /etc/systemd/logind.conf.d/99-kubelet.conf ]]; then
    rm -f /etc/systemd/logind.conf.d/99-kubelet.conf
    changed=true
  fi
  if [[ ! -f $file || $(<"$file") != "$desired" ]]; then
    printf '%s\n' "$desired" > "$file"
    chmod 644 "$file"
    changed=true
  fi
  if [[ $changed == true ]]; then
    systemctl restart systemd-logind
    log_info "已更新 logind 优雅关机上限: InhibitDelayMaxSec=${total}s"
  else
    log_info "logind 优雅关机上限已匹配: InhibitDelayMaxSec=${total}s"
  fi
  log_info "GracefulNodeShutdown 预算: 普通 Pod=$(( total - critical ))s, 关键 Pod=${critical}s"
}

# --- 3. sandbox(pause) 镜像与 kubeadm 对齐 ------------------------------------------
align_pause_image() {
  local kver pause
  kver=$(kubeadm version -o short)
  pause=$(kubeadm config images list --image-repository "$(k8s_image_repo)" \
            --kubernetes-version "$kver" 2>/dev/null | grep '/pause:') || true
  [[ -n $pause ]] || die "无法从 kubeadm 获取 pause 镜像名"
  sed -i "s|^\([[:space:]]*\)sandbox = .*|\1sandbox = '$pause'|" /etc/containerd/config.toml
  systemctl restart containerd
  log_info "sandbox 镜像已对齐: $pause"
}
verify_pause_image() {
  grep -q "sandbox = '$(k8s_image_repo)/pause:" /etc/containerd/config.toml \
    && svc_active containerd
}

# --- 4. 生成 kubeadm.yml -------------------------------------------------------------
gen_kubeadm_config() {
  local kver taints_line="" san sans=""
  kver=$(kubeadm version -o short)

  # 单节点集群去掉控制面污点, 允许业务负载调度
  [[ $SINGLE_NODE == true ]] && taints_line="  taints: []"

  # certSANs: 配置项 + 本机 IP/主机名去重合并
  local all_sans=("$NODE_IP" "$NODE_NAME" "${API_CERT_SANS[@]}")
  local seen=" "
  for san in "${all_sans[@]}"; do
    [[ $seen == *" $san "* ]] && continue
    seen+="$san "
    sans+="    - $san"$'\n'
  done

  cat > "$KUBEADM_YML" <<EOF
# k8s-installer 生成(每次执行重新生成; 不含 token, 由 kubeadm 自动随机签发)
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $NODE_IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  imagePullSerial: false
  name: $NODE_NAME
  kubeletExtraArgs:
    - name: node-ip
      value: "$NODE_IP"
$taints_line
timeouts:
  controlPlaneComponentHealthCheck: 4m0s
  discovery: 5m0s
  etcdAPICall: 2m0s
  kubeletHealthCheck: 4m0s
  kubernetesAPICall: 1m0s
  tlsBootstrap: 5m0s
  upgradeManifests: 5m0s
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: kubernetes
kubernetesVersion: $kver
imageRepository: $(k8s_image_repo)
apiServer:
  certSANs:
$sans
caCertificateValidityPeriod: 87600h0m0s
certificateValidityPeriod: 8760h0m0s
certificatesDir: /etc/kubernetes/pki
encryptionAlgorithm: RSA-2048
controllerManager:
  extraArgs:
    - name: allocate-node-cidrs
      value: "true"
etcd:
  local:
    dataDir: /var/lib/etcd
networking:
  dnsDomain: $CLUSTER_DNS_DOMAIN
  podSubnet: $POD_CIDR
  serviceSubnet: $SERVICE_CIDR
---
# kubelet 低延迟/高吞吐调优
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
maxPods: $KUBELET_MAX_PODS
serializeImagePulls: false
maxParallelImagePulls: 4
containerLogMaxSize: 50Mi
containerLogMaxFiles: 3
# 优雅节点关机(默认 0=关闭): shutdown/kured 重启时 kubelet 先按序优雅终止 Pod
shutdownGracePeriod: $KUBELET_SHUTDOWN_GRACE
shutdownGracePeriodCriticalPods: $KUBELET_SHUTDOWN_GRACE_CRITICAL
EOF
}
verify_kubeadm_config() { kubeadm config validate --config "$KUBEADM_YML"; }

# --- 5. 端口占用预检(已有集群/已加入则交给幂等逻辑) --------------------------------------
check_ports() {
  local guard=/etc/kubernetes/admin.conf
  local ports=(6443 2379 2380 10250 10257 10259)
  if is_worker; then
    guard=/etc/kubernetes/kubelet.conf
    ports=(10250)
  fi
  [[ -f $guard ]] && return 0
  local p busy=()
  for p in "${ports[@]}"; do
    [[ -n $(ss -Hltn "sport = :$p" 2>/dev/null) ]] && busy+=("$p")
  done
  (( ${#busy[@]} == 0 )) || die "端口被占用: ${busy[*]} — 请先释放(lsof -i:端口 查看占用进程)"
}

# --- 6. 预拉镜像(init 之前全部拉齐; 可临时借道按需代理, 拉完即撤) --------------------------
#   镜像仓库(kubeadm.yml 的 imageRepository)与拉取通道(certs.d mirror/临时代理)互相独立:
#   仓库决定"拉什么名字", 通道决定"从哪条路拉"
pull_images() {
  # 清理上次中断可能遗留的临时代理
  containerd_tmp_proxy_off

  local want_proxy=false
  case $PREPULL_VIA_PROXY in
    true)  proxy_alive || die "PREPULL_VIA_PROXY=true 但代理 $PROXY_URL 不可达, 请先开启代理"
           want_proxy=true ;;
    auto)  proxy_alive && want_proxy=true ;;
  esac
  [[ $want_proxy == true ]] && containerd_tmp_proxy_on

  if ! retry 3 10 kubeadm config images pull --config "$KUBEADM_YML"; then
    containerd_tmp_proxy_off
    die "控制面镜像预拉失败(仓库: $(k8s_image_repo))"
  fi
  containerd_tmp_proxy_off
}
# grep 不带 -q(读完全部输入再退出), 避免早关管道被 pipefail 误判
verify_images() { crictl images 2>/dev/null | grep kube-apiserver >/dev/null; }

# --- 7. kubeadm init(幂等: 健康集群跳过; 残留数据需人工确认 reset) ----------------------
run_kubeadm_init() {
  if [[ -f /etc/kubernetes/admin.conf ]] && kctl get --raw /readyz &>/dev/null; then
    log_info "检测到健康的现有集群, 跳过 kubeadm init"
  else
    if [[ -f /etc/kubernetes/admin.conf ]] || [[ -n $(ls -A /etc/kubernetes/manifests 2>/dev/null) ]]; then
      confirm_danger "检测到不健康或残留的集群数据(/etc/kubernetes), 执行 kubeadm reset 后重新初始化? etcd 数据将清空" \
        "reset-cluster" || die "存在残留集群数据, 未确认清理, 中止。手动处理: kubeadm reset -f 后重跑"
      kubeadm reset -f
      rm -rf /etc/cni/net.d/* 2>/dev/null || true
    fi
    kubeadm init --config "$KUBEADM_YML" --upload-certs
  fi

  # kubeconfig: root 与执行 sudo 的普通用户都可直接 kubectl(修复原脚本改写 HOME 的错误)
  install -d -m 700 /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if [[ $TARGET_USER != root ]]; then
    install -d -m 700 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$TARGET_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$TARGET_HOME/.kube/config"
    chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.kube/config"
    chmod 600 "$TARGET_HOME/.kube/config"
  fi
}
verify_cluster_up() {
  [[ $(kctl get --raw /readyz 2>/dev/null) == ok ]] \
    && kctl get node "$NODE_NAME" >/dev/null
}

# --- 8. 彻底清除 kube-proxy 残留(skipPhases 已不装; 此处兜底保证语义) --------------------
purge_kube_proxy() {
  kctl -n kube-system delete daemonset kube-proxy --ignore-not-found
  kctl -n kube-system delete configmap kube-proxy --ignore-not-found
}
verify_no_kube_proxy() { ! kctl -n kube-system get daemonset kube-proxy &>/dev/null; }

# =============================================================================
# worker 专属: kubeadm join
# =============================================================================

# --- W1. 加入参数: config 显式 > 状态缓存(断点续跑) > 交互粘贴/逐项输入 --------------------
resolve_join_params() {
  if [[ -f $STATE_DIR/join.params ]]; then
    # shellcheck source=/dev/null
    source "$STATE_DIR/join.params"
    log_info "复用已保存的加入参数(换 token 请先: rm $STATE_DIR/join.params)"
  fi
  if [[ -z $JOIN_ENDPOINT || -z $JOIN_TOKEN || -z $JOIN_CA_CERT_HASH ]]; then
    is_interactive || die "缺少加入参数 — 在控制面执行: kubeadm token create --print-join-command, 结果填入 config.env 的 JOIN_*"
    log_info "请先在控制面节点执行: kubeadm token create --print-join-command"
    local line
    printf '%s%s 粘贴整条 kubeadm join 命令(单行; 直接回车则逐项输入): %s' "$C_CYA" "$I_ASK" "$C_RST" >/dev/tty
    read -r line </dev/tty || line=""
    if [[ $line == *"kubeadm join"* ]]; then
      parse_join_cmd "$line" || die "无法从粘贴内容解析出 endpoint/token/ca-hash, 请确认命令完整且为单行"
    elif [[ -n $line ]]; then
      die "无法识别的输入(应为以 kubeadm join 开头的完整命令)"
    else
      JOIN_ENDPOINT=$(prompt_input "apiserver 地址:端口" "${JOIN_ENDPOINT:-192.168.3.201:6443}")
      JOIN_TOKEN=$(prompt_input "bootstrap token" "")
      JOIN_CA_CERT_HASH=$(prompt_input "ca-cert-hash(sha256:...)" "")
    fi
  fi
  [[ -n $JOIN_ENDPOINT && -n $JOIN_TOKEN && -n $JOIN_CA_CERT_HASH ]] || die "加入参数不完整"
  {
    echo "JOIN_ENDPOINT=$JOIN_ENDPOINT"
    echo "JOIN_TOKEN=$JOIN_TOKEN"
    echo "JOIN_CA_CERT_HASH=$JOIN_CA_CERT_HASH"
  } > "$STATE_DIR/join.params"
  chmod 600 "$STATE_DIR/join.params"
}

# --- W2. 生成 JoinConfiguration(kubelet 全量配置加入后自动从集群下发, 无需本地重复) --------
gen_join_config() {
  resolve_join_params
  cat > "$JOIN_YML" <<EOF
# k8s-installer 生成(含 bootstrap token, 权限 600)
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $JOIN_ENDPOINT
    token: $JOIN_TOKEN
    caCertHashes:
      - $JOIN_CA_CERT_HASH
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: $NODE_NAME
  kubeletExtraArgs:
    - name: node-ip
      value: "$NODE_IP"
EOF
  chmod 600 "$JOIN_YML"
}
verify_join_config() { kubeadm config validate --config "$JOIN_YML"; }

# --- W3. kubeadm join(幂等: 已加入跳过; 半途残留需确认 reset) -------------------------------
run_kubeadm_join() {
  if [[ -f /etc/kubernetes/kubelet.conf ]] && svc_active kubelet; then
    log_info "节点已加入集群, 跳过 kubeadm join"
    return 0
  fi
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    confirm_danger "检测到上次未完成加入的残留(/etc/kubernetes), kubeadm reset 后重新加入?" "reset-node" \
      || die "存在残留配置且未确认清理。手动处理: kubeadm reset -f 后重跑"
    kubeadm reset -f
  fi
  kubeadm join --config "$JOIN_YML"
  # token 过期会在此失败: 控制面重新 print-join-command 后
  # rm $STATE_DIR/join.params && start.sh --reset-state 50-kubernetes 重跑
}
verify_joined() { svc_active kubelet && [[ -f /etc/kubernetes/kubelet.conf ]]; }

# --- 9. etcd 周期性碎片整理(systemd timer; 见 README "etcd 维护") -------------------------
setup_etcd_defrag() {
  if [[ $ETCD_DEFRAG_TIMER != true ]]; then
    log_info "未启用 etcd defrag 定时器, 跳过"
    return 0
  fi
  cat > /usr/local/sbin/k8s-etcd-defrag.sh <<'EOF'
#!/usr/bin/env bash
# k8s-installer 托管: etcd 碎片整理(单节点, 通过 etcd 静态 Pod 内的 etcdctl 执行)
# 说明: compaction(逻辑清理)由 kube-apiserver 每 5 分钟自动做, 但物理空间只有
#       defrag 才会归还; 单节点 defrag 期间 etcd 阻塞写入(小库通常 <1s)。
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
POD=$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')
etcdctl_exec() {
  kubectl -n kube-system exec "$POD" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key "$@"
}
echo "[etcd-defrag] before: $(etcdctl_exec endpoint status --write-out=fields | grep -E 'DbSize|DbSizeInUse' | tr '\n' ' ')"
etcdctl_exec defrag --command-timeout=60s
etcdctl_exec alarm disarm
echo "[etcd-defrag] after : $(etcdctl_exec endpoint status --write-out=fields | grep -E 'DbSize|DbSizeInUse' | tr '\n' ' ')"
EOF
  chmod 755 /usr/local/sbin/k8s-etcd-defrag.sh

  cat > /etc/systemd/system/k8s-etcd-defrag.service <<'EOF'
[Unit]
Description=etcd defragmentation (k8s-installer)
After=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/k8s-etcd-defrag.sh
EOF
  cat > /etc/systemd/system/k8s-etcd-defrag.timer <<EOF
[Unit]
Description=Weekly etcd defragmentation (k8s-installer)

[Timer]
OnCalendar=$ETCD_DEFRAG_CALENDAR
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now k8s-etcd-defrag.timer
}
verify_etcd_defrag() {
  [[ $ETCD_DEFRAG_TIMER != true ]] || systemctl is-enabled --quiet k8s-etcd-defrag.timer
}

# --- 10. kubectl 补全与别名(托管块, 不重复追加) --------------------------------------------
setup_kubectl_alias() {
  kubectl completion bash > /etc/bash_completion.d/kubectl
  local content='alias k=kubectl
complete -o default -F __start_kubectl k'
  ensure_block /root/.bashrc "kubectl-alias" "$content"
  [[ $TARGET_HOME != /root ]] && ensure_block "$TARGET_HOME/.bashrc" "kubectl-alias" "$content"
  return 0
}

main() {
  local title="Kubernetes 控制面" budget shutdown_total shutdown_critical
  is_worker && title="Kubernetes 工作节点加入"
  stage_begin "50-kubernetes" "$title"
  budget=$(node_shutdown_budget_seconds \
    "$KUBELET_SHUTDOWN_GRACE" "$KUBELET_SHUTDOWN_GRACE_CRITICAL") \
    || die "GracefulNodeShutdown 预算配置无效"
  read -r shutdown_total shutdown_critical <<<"$budget"
  log_info "GracefulNodeShutdown 配置校验通过: ${shutdown_total}s/${shutdown_critical}s"

  # 两种角色共用: 仓库/软件包/节点关机预算/pause 对齐/端口预检。
  # 预算进入 step key: config.env 改值后会自动产生新步骤,不被旧状态标记跳过。
  add_step repo     "配置 pkgs.k8s.io v$K8S_MINOR_V 仓库"     setup_apt_repo       verify_apt_repo
  add_step pkgs     "安装 kubelet/kubeadm/kubectl 并 hold"    install_k8s_packages verify_k8s_packages
  add_step "shutdown-${shutdown_total}-${shutdown_critical}" "配置并校验 GracefulNodeShutdown 预算" \
    configure_graceful_node_shutdown verify_graceful_node_shutdown_config
  add_step pause    "对齐 sandbox(pause) 镜像"                align_pause_image    verify_pause_image

  if is_worker; then
    add_step joincfg "生成 kubeadm-join.yml(含加入参数)"     gen_join_config      verify_join_config
    add_step ports   "kubelet 端口占用预检"                  check_ports
    add_step join    "kubeadm join 加入集群"                 run_kubeadm_join     verify_joined
  else
    add_step cfg     "生成 kubeadm.yml"                      gen_kubeadm_config   verify_kubeadm_config
    add_step ports   "控制面端口占用预检"                    check_ports
    add_step images  "预拉控制面镜像"                        pull_images          verify_images
    add_step init    "kubeadm init(跳过 kube-proxy)"         run_kubeadm_init     verify_cluster_up
    add_step noproxy "清除 kube-proxy 残留"                  purge_kube_proxy     verify_no_kube_proxy
    add_step defrag  "etcd 碎片整理定时器"                   setup_etcd_defrag    verify_etcd_defrag
    add_step alias   "kubectl 补全与 k 别名"                 setup_kubectl_alias
  fi
  run_steps
  stage_end
}
main "$@"
