#!/usr/bin/env bash
# =============================================================================
# start.sh —— K8s 高性能单机集群安装器(编排入口)
#
#   Ubuntu(20.04+) | containerd | Cilium eBPF(完全替代 kube-proxy) | OpenEBS LVM
#
# 用法:
#   sudo bash start.sh                 # 全流程交互安装(可随时中断, 重跑自动续)
#   sudo bash start.sh --yes           # 非交互(按 config.env 取值, 危险项需显式配置)
#   sudo bash start.sh --worker        # 按工作节点安装(不改 config.env; 节点名=本机 hostname)
#   sudo bash start.sh --from 60-cilium
#   sudo bash start.sh --only 30-download
#   sudo bash start.sh --verify        # 只跑验收
#   sudo bash start.sh --list          # 查看阶段与完成进度
#   sudo bash start.sh --reset-state [阶段|all]
#   sudo bash start.sh --reset-cluster # 危险: kubeadm reset(保留系统调优与下载缓存)
#   sudo bash start.sh --pack-offline k8s-offline.tgz    # 在有网机器上打离线包
#   sudo bash start.sh --unpack-offline k8s-offline.tgz  # 在目标机上展开后正常安装
#
# 设计:
#   - 每阶段一个独立脚本(scripts/*.sh), 也可单独执行
#   - 预检通过后, 30-download 立刻转入后台, 与 10/20 系统配置并行
#   - 步骤级断点: 失败修复后重跑, 已完成步骤自动跳过
#   - 需要重启的变更(cgroup v2/HWE 内核)会明确提示, 重启后重跑即续
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "$SCRIPT_DIR/lib/common.sh"

STAGES=(
  "00-preflight|环境预检"
  "10-system-base|系统基础配置"
  "20-kernel-tuning|内核与系统调优"
  "30-download|工件并行下载"
  "40-container-runtime|容器运行时"
  "45-etcd-disk|etcd 专用磁盘(可选)"
  "50-kubernetes|Kubernetes 控制面"
  "60-cilium|Cilium eBPF 网络"
  "70-storage|OpenEBS LVM 存储"
  "80-components|组件安装(可选)"
  "90-verify|全局验收"
)

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

stage_ids()   { local e; for e in "${STAGES[@]}"; do echo "${e%%|*}"; done; }
stage_title() { local e; for e in "${STAGES[@]}"; do [[ ${e%%|*} == "$1" ]] && { echo "${e#*|}"; return; }; done; echo "$1"; }

list_stages() {
  local e id n
  echo "阶段列表(已完成步骤数):"
  for e in "${STAGES[@]}"; do
    id=${e%%|*}
    n=$(find "$STATE_DIR/state" -name "${id}:*.done" 2>/dev/null | wc -l | tr -d ' ')
    printf '  %-22s %-18s 完成步骤: %s\n' "$id" "${e#*|}" "$n"
  done
}

reset_cluster() {
  require_root
  confirm_danger "将执行 kubeadm reset: 清空集群与 etcd 数据(系统调优/下载缓存/LVM 卷组保留)" "reset-cluster" \
    || die "已取消"
  kubeadm reset -f 2>/dev/null || true
  rm -rf /etc/cni/net.d/* 2>/dev/null || true
  ip link delete cilium_host 2>/dev/null || true
  ip link delete cilium_vxlan 2>/dev/null || true
  rm -f /root/.kube/config "$TARGET_HOME/.kube/config"
  local s
  for s in 50-kubernetes 60-cilium 70-storage 80-components 90-verify; do state_reset "$s"; done
  log_ok "集群已重置, 重新执行 sudo bash start.sh 可重建(系统准备阶段将自动跳过)"
}

# 离线打包: GitHub 工件缓存 + versions.lock + 核心 helm chart(cilium/openebs)
# 注意: 容器镜像与 apt 仓库不在包内 —— 目标机仍需 registry mirror/apt 源可达
pack_offline() {
  local out=$1
  require_root; ensure_dirs; ensure_versions
  bash "$K8S_SCRIPTS_DIR/30-download.sh"
  if ! has_cmd helm; then
    local tmp; tmp=$(mktemp -d)
    tar -xzf "$A_HELM_TGZ" -C "$tmp"
    install -m 755 "$tmp/linux-$ARCH/helm" /usr/local/bin/helm
    rm -rf "$tmp"
  fi
  mkdir -p "$CACHE_DIR/charts"
  helm_cmd repo add cilium https://helm.cilium.io/ --force-update
  helm_cmd repo add openebs https://openebs.github.io/openebs --force-update
  retry 3 5 helm_cmd repo update cilium openebs
  [[ -f "$CACHE_DIR/charts/cilium-${CILIUM_V#v}.tgz" ]] \
    || with_proxy helm pull cilium/cilium --version "${CILIUM_V#v}" -d "$CACHE_DIR/charts"
  [[ -f "$CACHE_DIR/charts/openebs-${OPENEBS_V#v}.tgz" ]] \
    || with_proxy helm pull openebs/openebs --version "${OPENEBS_V#v}" -d "$CACHE_DIR/charts"
  tar -czf "$out" -C / "${CACHE_DIR#/}" "${VERSIONS_LOCK#/}"
  log_ok "离线包已生成: $out ($(du -h "$out" | cut -f1))"
  log_info "目标机使用: sudo bash start.sh --unpack-offline $(basename "$out") && sudo bash start.sh"
}

unpack_offline() {
  local in=$1
  require_root; ensure_dirs
  [[ -f $in ]] || die "找不到离线包: $in"
  tar -xzf "$in" -C /
  log_ok "离线包已展开: 工件缓存 $CACHE_DIR, 版本锁定 $VERSIONS_LOCK"
  log_info "后续执行 sudo bash start.sh 时, 30 阶段将秒过(校验命中), cilium/openebs 使用本地 chart"
}

# --------------------------- 参数解析 ---------------------------------------
FROM="" ONLY=""
while (( $# > 0 )); do
  case $1 in
    -y|--yes)      export ASSUME_YES=true ;;
    work|--work|--worker)
      # 角色直通开关: 不动 config.env, 本次按工作节点安装(跳过 etcd盘/Cilium/组件等集群级阶段)
      export K8S_ROLE_OVERRIDE=worker
      NODE_ROLE=worker
      NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')
      ;;
    --from)        FROM=${2:?--from 需要阶段名}; shift ;;
    --only)        ONLY=${2:?--only 需要阶段名}; shift ;;
    --verify)      ONLY="90-verify" ;;
    --list)        list_stages; exit 0 ;;
    --reset-state)
      require_root
      state_reset "${2:-all}"
      # 50 阶段重置时连带清掉缓存的加入参数(worker 换 token 场景)
      case "${2:-all}" in all|50-kubernetes) rm -f "$STATE_DIR/join.params" ;; esac
      log_ok "状态已重置: ${2:-all}"
      exit 0 ;;
    --reset-cluster) reset_cluster; exit 0 ;;
    --pack-offline)   pack_offline "${2:?--pack-offline 需要输出文件名}"; exit 0 ;;
    --unpack-offline) unpack_offline "${2:?--unpack-offline 需要离线包路径}"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "未知参数: $1 (见 --help)" ;;
  esac
  shift
done

require_root
ensure_dirs
resolve_node_ip

# 防重入(后台下载器是子进程, 不受影响)
exec 200>"$STATE_DIR/.lock"
flock -n 200 || die "检测到另一个安装进程正在运行, 中止"

# --------------------------- 运行列表 ---------------------------------------
# worker 角色跳过集群级阶段(阶段脚本内部也有守卫, 此处过滤只为进度显示干净)
WORKER_SKIP_STAGES=(45-etcd-disk 60-cilium 80-components)
stage_skipped_for_role() {
  local s
  is_worker || return 1
  for s in "${WORKER_SKIP_STAGES[@]}"; do [[ $s == "$1" ]] && return 0; done
  return 1
}

RUN_LIST=()
if [[ -n $ONLY ]]; then
  stage_ids | grep -qx "$ONLY" || die "未知阶段: $ONLY (--list 查看)"
  RUN_LIST=("$ONLY")
else
  local_found=true
  if [[ -n $FROM ]]; then
    stage_ids | grep -qx "$FROM" || die "未知阶段: $FROM (--list 查看)"
    local_found=false
  fi
  for e in "${STAGES[@]}"; do
    id=${e%%|*}
    [[ $local_found == false && $id == "$FROM" ]] && local_found=true
    [[ $local_found == true ]] && ! stage_skipped_for_role "$id" && RUN_LIST+=("$id")
  done
fi

# --------------------------- 后台并行下载 -----------------------------------
DL_PID=""
cleanup() { [[ -n $DL_PID ]] && kill "$DL_PID" 2>/dev/null || true; }
trap cleanup EXIT

maybe_start_bg_download() {
  [[ -n $DL_PID ]] && return 0
  local s has30=false
  for s in "${RUN_LIST[@]}"; do [[ $s == 30-download ]] && has30=true; done
  [[ $has30 == true ]] || return 0
  NO_COLOR=1 K8S_BG=1 bash "$K8S_SCRIPTS_DIR/30-download.sh" &
  DL_PID=$!
  log_info "⇣ 工件下载已转入后台(与系统配置并行, 日志: $LOG_DIR/30-download.log)"
}

# --------------------------- 失败处理 ---------------------------------------
stage_failed() {
  local id=$1
  echo
  if [[ -f $STATE_DIR/reboot-required ]]; then
    printf '%s%s╔════════════════════════════════════════════════════════════╗%s\n' "$C_YEL" "$C_BLD" "$C_RST"
    printf '%s%s║  需要重启后继续(内核/cgroup 变更已写入, 进度已保存)        ║%s\n' "$C_YEL" "$C_BLD" "$C_RST"
    printf '%s%s║  重启后再次执行: sudo bash start.sh                        ║%s\n' "$C_YEL" "$C_BLD" "$C_RST"
    printf '%s%s╚════════════════════════════════════════════════════════════╝%s\n' "$C_YEL" "$C_BLD" "$C_RST"
    if confirm "现在立即重启?" N; then systemctl reboot; fi
    exit 0
  fi
  log_error "阶段 $id 失败 — 日志: $LOG_DIR/$id.log"
  log_error "修复后重跑: sudo bash start.sh   (已完成步骤自动跳过)"
  log_error "只重跑该阶段: sudo bash start.sh --only $id"
  exit 1
}

# --------------------------- 主流程 -----------------------------------------
hr
printf '%s%s  K8s 高性能集群安装器%s\n' "$C_MAG" "$C_BLD" "$C_RST"
printf '%s  Ubuntu %s | %s | 节点 %s(%s) | 角色: %s | 模式: %s%s\n' "$C_DIM" "$(os_ver)" "$ARCH" \
  "$NODE_NAME" "$NODE_IP" "$NODE_ROLE" "$([[ $ASSUME_YES == true ]] && echo 非交互 || echo 交互)" "$C_RST"
printf '%s  日志: %s | 断点续跑: 直接重复执行本脚本%s\n' "$C_DIM" "$LOG_DIR" "$C_RST"
hr

T_START=$SECONDS
declare -A STAGE_TIME=()
total=${#RUN_LIST[@]}
idx=0
for id in "${RUN_LIST[@]}"; do
  idx=$(( idx + 1 ))
  echo
  printf '%s%s━━━ [%d/%d] %s — %s ━━━%s\n' "$C_CYA" "$C_BLD" "$idx" "$total" "$id" "$(stage_title "$id")" "$C_RST"
  t0=$SECONDS
  case $id in
    30-download)
      if [[ -n $DL_PID ]]; then
        log_info "等待后台下载完成..."
        if wait "$DL_PID"; then
          DL_PID=""
          log_ok "后台下载全部完成"
        else
          DL_PID=""
          log_warn "后台下载有失败项, 转前台重试(已成功的工件自动跳过)"
          bash "$K8S_SCRIPTS_DIR/30-download.sh" || stage_failed "$id"
        fi
      else
        bash "$K8S_SCRIPTS_DIR/30-download.sh" || stage_failed "$id"
      fi
      ;;
    *)
      bash "$K8S_SCRIPTS_DIR/$id.sh" || stage_failed "$id"
      [[ $id == 00-preflight ]] && maybe_start_bg_download
      ;;
  esac
  STAGE_TIME[$id]=$(( SECONDS - t0 ))
done

# --------------------------- 完成总结 ---------------------------------------
echo
printf '%s%s╔════════════════════════════════════════════════════════════╗%s\n' "$C_GRN" "$C_BLD" "$C_RST"
printf '%s%s║  全部阶段执行完成 ✔  (总耗时 %d 分 %d 秒)%s\n' "$C_GRN" "$C_BLD" $(( (SECONDS-T_START)/60 )) $(( (SECONDS-T_START)%60 )) "$C_RST"
printf '%s%s╚════════════════════════════════════════════════════════════╝%s\n' "$C_GRN" "$C_BLD" "$C_RST"
for id in "${RUN_LIST[@]}"; do
  printf '%s  %-22s %4ds%s\n' "$C_DIM" "$id" "${STAGE_TIME[$id]}" "$C_RST"
done
[[ -f /root/k8s-install-report.txt ]] && log_info "安装报告: /root/k8s-install-report.txt"
if [[ -f $STATE_DIR/reboot-recommended ]]; then
  log_warn "存在建议重启的持久化变更(GRUB), 空闲时间执行一次 reboot 即可"
  if confirm "现在重启以验证持久化配置?" N; then systemctl reboot; fi
fi
