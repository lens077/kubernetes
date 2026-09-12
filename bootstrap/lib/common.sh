# shellcheck shell=bash
# shellcheck disable=SC2034  # 公共库: 大量变量供 source 方(阶段脚本)使用
# =============================================================================
# lib/common.sh —— 公共函数库(被 start.sh 与所有阶段脚本 source)
#
# 设计原则:
#   1. 幂等: 每个写系统的动作要么"整文件托管覆盖", 要么"标记块替换", 重复执行结果一致
#   2. 可恢复: 步骤完成后落盘状态; 失败重跑自动跳过已完成步骤
#   3. 原文件保护: 修改非托管的系统文件前 backup_once 备份一次(永不覆盖已有备份)
#   4. 日志分流: 正常输出→stdout, 警告/错误→stderr; 命令替换捕获不会被日志污染
# =============================================================================

[[ -n ${_K8S_COMMON_LOADED:-} ]] && return 0
_K8S_COMMON_LOADED=1

# --------------------------- 路径与配置 -------------------------------------
K8S_BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
K8S_SCRIPTS_DIR="$K8S_BASE_DIR/scripts"
K8S_FILES_DIR="$K8S_BASE_DIR/files"          # 生成的 kubeadm.yml / helm values 等
STATE_DIR="/var/lib/k8s-installer"
BACKUP_DIR="$STATE_DIR/backups"              # 系统原文件镜像备份
CACHE_DIR="/var/cache/k8s-installer"         # 下载缓存(含校验, 支持断点续跑)
LOG_DIR="/var/log/k8s-installer"
VERSIONS_LOCK="$STATE_DIR/versions.lock"     # 首次解析后锁定版本, 保证重复执行一致
MAIN_LOG="$LOG_DIR/install.log"

# shellcheck source=../config.env
# K8S_CONFIG_ENV: 从非节点机器(如 Mac)对着另一套集群跑组件脚本/工具时, 指定要加载的 config 文件
#   (例 K8S_CONFIG_ENV=bootstrap/config.hosting.env bash tools/verify-contracts.sh); 节点上不用。
_k8s_cfg=${K8S_CONFIG_ENV:-$K8S_BASE_DIR/config.env}
[[ $_k8s_cfg == /* ]] || _k8s_cfg="$PWD/$_k8s_cfg"
# shellcheck disable=SC1090
source "$_k8s_cfg" || { echo "无法加载 $_k8s_cfg" >&2; exit 1; }
unset _k8s_cfg

# CLI 角色覆写(start.sh --worker): 不改 config.env 即可按工作节点安装;
# config 里的 NODE_NAME 属于控制面机器, 覆写时节点名取本机 hostname
if [[ ${K8S_ROLE_OVERRIDE:-} == worker ]]; then
  NODE_ROLE=worker
  NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')
fi

ASSUME_YES=${ASSUME_YES:-false}              # start.sh --yes 时置 true

# --------------------------- Cilium LB-IPAM 与 L2 通告(解耦) --------------------------
# 池(CiliumLoadBalancerIPPool)决定 LoadBalancer Service 能否拿到地址; L2 通告决定同链路主机能否
# ARP 到该地址。只经 newt/Pod 访问的集群内 VIP 只需要池, 不需要在共享 VLAN 上通告。
#   CILIUM_ENABLE_LB_IPAM: true / false / auto(默认; = Gateway API 或 L2 任一开启即开)
#   CILIUM_ENABLE_L2_ANNOUNCEMENTS: true / false(开启时必须有池)
# 三个地址(CILIUM_GATEWAY_LB_IP / CILIUM_LB_POOL_START / _STOP)只有使用者能决定: config.env 没写时,
# 00-preflight 有终端就询问并存到 $LB_IPAM_ANSWERS(安装器状态目录, 不改 config.env, 重跑自动复用);
# 无终端则报错退出。
LB_IPAM_ANSWERS="$STATE_DIR/lb-ipam.env"

lb_ipam_enabled() {
  case ${CILIUM_ENABLE_LB_IPAM:-auto} in
    true)    return 0 ;;
    false)   return 1 ;;
    auto|"") [[ ${CILIUM_ENABLE_GATEWAY_API:-false} == true || ${CILIUM_ENABLE_L2_ANNOUNCEMENTS:-false} == true ]] ;;
    *)       die "CILIUM_ENABLE_LB_IPAM 必须是 true / false / auto, 当前: $CILIUM_ENABLE_LB_IPAM" ;;
  esac
}
l2_enabled() { [[ ${CILIUM_ENABLE_L2_ANNOUNCEMENTS:-false} == true ]]; }

# config.env 留空的地址项用询问时保存的答案补上(config.env 显式写了的永远优先)
load_lb_ipam_answers() {
  [[ -f $LB_IPAM_ANSWERS ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    [[ $k =~ ^CILIUM_(GATEWAY_LB_IP|LB_POOL_START|LB_POOL_STOP)$ ]] || continue
    v=${v%\"}; v=${v#\"}
    [[ -n ${!k:-} ]] || printf -v "$k" '%s' "$v"
  done < "$LB_IPAM_ANSWERS"
}
load_lb_ipam_answers

lb_ipam_addresses_missing() {
  [[ -z ${CILIUM_GATEWAY_LB_IP:-} || -z ${CILIUM_LB_POOL_START:-} || -z ${CILIUM_LB_POOL_STOP:-} ]]
}

# 在终端上逐项询问缺失的地址, 校验 IPv4 格式后写入 $LB_IPAM_ANSWERS。无终端返回 1(由调用方报错)。
# LB_IPAM_TTY 允许测试用文件代替 /dev/tty。
prompt_lb_ipam_addresses() {
  local tty=${LB_IPAM_TTY:-/dev/tty} tty_in
  [[ -n ${LB_IPAM_TTY:-} ]] || has_tty || return 1
  # 读用独立 fd(顺序消费多行答案), 写用追加(对 /dev/tty 等价于直接写; 对文件不会截断答案)
  exec {tty_in}<"$tty" || return 1
  local ip_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  local var desc ans
  {
    echo
    echo "${C_YEL}${I_ASK} Cilium LB-IPAM 需要地址池, 但 config.env 没有填写。这些地址只有你能决定:${C_RST}"
    echo "  - 共享 Gateway 固定 VIP(单地址, Pangolin/newt 的 target, 之后不会漂移)"
    echo "  - 其它 LoadBalancer Service 的默认池起止(不能包含上面的 VIP, 不能包含节点 IP)"
    echo "  开了 L2 通告时它们会在局域网被 ARP 通告, 必须是网络所有者分配给你的地址;"
    echo "  只经 newt/Pod 访问(L2 关闭)时可用与 LAN/Pod/Service 都不重叠的集群内网段。"
    echo "  答案保存到 $LB_IPAM_ANSWERS, 重跑自动复用; 想改就改 config.env 或删掉该文件。"
  } >>"$tty"
  for var in CILIUM_GATEWAY_LB_IP CILIUM_LB_POOL_START CILIUM_LB_POOL_STOP; do
    [[ -z ${!var:-} ]] || continue
    case $var in
      CILIUM_GATEWAY_LB_IP) desc="共享 Gateway 固定 VIP" ;;
      CILIUM_LB_POOL_START) desc="默认池起始 IP" ;;
      CILIUM_LB_POOL_STOP)  desc="默认池结束 IP(含)" ;;
    esac
    while true; do
      printf '%s%s %s (%s): %s' "$C_CYA" "$I_ASK" "$desc" "$var" "$C_RST" >>"$tty"
      if ! read -r ans <&"$tty_in"; then
        exec {tty_in}<&-
        echo "  输入结束, 未得到 $var" >>"$tty"
        return 1
      fi
      [[ $ans =~ $ip_re ]] && break
      echo "  不是合法的 IPv4 地址: '${ans}'" >>"$tty"
    done
    printf -v "$var" '%s' "$ans"
  done
  exec {tty_in}<&-
  mkdir -p "$(dirname "$LB_IPAM_ANSWERS")"
  {
    echo "# k8s-installer: 00-preflight 询问得到的 LB-IPAM 地址(config.env 留空时生效; 改 config.env 优先)"
    echo "CILIUM_GATEWAY_LB_IP=\"$CILIUM_GATEWAY_LB_IP\""
    echo "CILIUM_LB_POOL_START=\"$CILIUM_LB_POOL_START\""
    echo "CILIUM_LB_POOL_STOP=\"$CILIUM_LB_POOL_STOP\""
  } > "$LB_IPAM_ANSWERS"
  chmod 600 "$LB_IPAM_ANSWERS"
  log_info "LB-IPAM 地址已记录到 $LB_IPAM_ANSWERS: Gateway=$CILIUM_GATEWAY_LB_IP 默认池=$CILIUM_LB_POOL_START-$CILIUM_LB_POOL_STOP"
}

# --------------------------- 颜色与图标 -------------------------------------
if [[ -z ${NO_COLOR:-} ]] && { [[ -t 1 ]] || [[ ${K8S_FORCE_COLOR:-} == 1 ]]; }; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_MAG=$'\e[35m'; C_CYA=$'\e[36m'; C_BLD=$'\e[1m';  C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_BLU='' C_MAG='' C_CYA='' C_BLD='' C_DIM='' C_RST=''
fi
I_OK="✔"; I_ERR="✘"; I_WARN="⚠"; I_RUN="➜"; I_SKIP="↷"; I_ASK="?"

_ts() { printf '%(%H:%M:%S)T' -1; }
_plain_log() { mkdir -p "$LOG_DIR"; printf '[%s] %s\n' "$(_ts)" "$*" >> "$MAIN_LOG"; }

log_info() { printf '%s[%s]%s %s\n'  "$C_DIM" "$(_ts)" "$C_RST" "$*";               _plain_log "INFO  $*"; }
log_step() { printf '%s%s[%s] %s %s%s\n' "$C_BLU" "$C_BLD" "$(_ts)" "$I_RUN" "$*" "$C_RST"; _plain_log "STEP  $*"; }
log_ok()   { printf '%s[%s] %s %s%s\n' "$C_GRN" "$(_ts)" "$I_OK" "$*" "$C_RST";     _plain_log "OK    $*"; }
log_skip() { printf '%s[%s] %s %s%s\n' "$C_DIM" "$(_ts)" "$I_SKIP" "$*" "$C_RST";   _plain_log "SKIP  $*"; }
log_warn() { printf '%s[%s] %s %s%s\n' "$C_YEL" "$(_ts)" "$I_WARN" "$*" "$C_RST" >&2; _plain_log "WARN  $*"; }
log_error(){ printf '%s%s[%s] %s %s%s\n' "$C_RED" "$C_BLD" "$(_ts)" "$I_ERR" "$*" "$C_RST" >&2; _plain_log "ERROR $*"; }
die()      { log_error "$*"; exit 1; }
hr()       { printf '%s%s%s\n' "$C_DIM" "──────────────────────────────────────────────────────────────" "$C_RST"; }

# --------------------------- 运行环境 ---------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "请以 root 运行: sudo bash $0"; }

TARGET_USER=${SUDO_USER:-root}
# || true 必带:macOS 没有 getent,而组件脚本在 set -eo pipefail 下 source 本文件,
# 127 会把整个脚本静默杀死(2>/dev/null 又吞了报错),下一行的 /root 兜底永远走不到 —— 实测踩过
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
TARGET_HOME=${TARGET_HOME:-/root}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    arm64)   echo arm64 ;;   # macOS 的写法(组件脚本允许在 Mac 上执行,见 components/_lib/env.sh)
    *) die "不支持的架构: $(uname -m) (仅支持 amd64/arm64)" ;;
  esac
}
ARCH=$(detect_arch)

os_id()  { ( . /etc/os-release && echo "${ID:-unknown}" ); }
os_ver() { ( . /etc/os-release && echo "${VERSION_ID:-0}" ); }

# 版本比较: ver_ge 1.36 1.30 → true
ver_ge()    { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# 语义版本接近度(既有安装接管策略): 同主版本 且 中版本差<=2 且 小版本差<=3 → 0(兼容)
ver_close() {  # ver_close <现有 X.Y.Z> <目标 X.Y.Z>
  local a=${1#v} b=${2#v}
  local ax=${a%%.*} bx=${b%%.*} ar=${a#*.} br=${b#*.}
  local ay=${ar%%.*} by=${br%%.*} az=${ar#*.} bz=${br#*.}
  az=${az%%[!0-9]*}; bz=${bz%%[!0-9]*}
  [[ $ax == "$bx" ]] || return 1
  local dy=$(( ay > by ? ay - by : by - ay ))
  local dz=$(( az > bz ? az - bz : bz - az ))
  (( dy <= 2 && dz <= 3 ))
}
kernel_ge() { local cur; cur=$(uname -r); ver_ge "${cur%%-*}" "$1"; }

detect_node_ip()       { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
detect_default_iface() { ip -4 route show default 2>/dev/null | awk '{print $5; exit}'; }

# 节点角色(config.env: NODE_ROLE)
is_control_plane() { [[ ${NODE_ROLE:-control-plane} == control-plane ]]; }
is_worker()        { [[ ${NODE_ROLE:-control-plane} == worker ]]; }

# GracefulNodeShutdown 时长只接受 Go duration 的整数字段组合(h/m/s),
# 例如 90s、1m30s、2h。关机预算不需要亚秒精度,主动拒绝小数和裸数字。
duration_to_seconds() {
  local rest=$1 total=0 amount unit
  local full_re='^((0|[1-9][0-9]*)(h|m|s))+$'
  local token_re='^([0-9]+)(h|m|s)(.*)$'
  [[ $rest =~ $full_re ]] || return 1
  while [[ -n $rest ]]; do
    [[ $rest =~ $token_re ]] || return 1
    amount=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
    rest=${BASH_REMATCH[3]}
    case $unit in
      h) total=$(( total + amount * 3600 )) ;;
      m) total=$(( total + amount * 60 )) ;;
      s) total=$(( total + amount )) ;;
    esac
  done
  printf '%s\n' "$total"
}

# 输出「总预算秒数 关键 Pod 预算秒数」;失败时给出可直接修 config.env 的原因。
node_shutdown_budget_seconds() {
  local total_value=$1 critical_value=$2 total critical
  total=$(duration_to_seconds "$total_value") || {
    printf 'KUBELET_SHUTDOWN_GRACE=%q 格式无效;仅支持整数 h/m/s 组合(如 90s、1m30s)\n' \
      "$total_value" >&2
    return 1
  }
  critical=$(duration_to_seconds "$critical_value") || {
    printf 'KUBELET_SHUTDOWN_GRACE_CRITICAL=%q 格式无效;仅支持整数 h/m/s 组合(如 30s、1m)\n' \
      "$critical_value" >&2
    return 1
  }
  if (( critical > total )); then
    printf '关键 Pod 预算(%ss)不能大于优雅关机总预算(%ss)\n' "$critical" "$total" >&2
    return 1
  fi
  printf '%s %s\n' "$total" "$critical"
}

# 读取 kubelet 已落盘的运行预算,输出同样的「总秒数 关键 Pod 秒数」。
kubelet_shutdown_budget_seconds() {
  local file=${1:-/var/lib/kubelet/config.yaml} values total_value critical_value
  [[ -f $file ]] || return 1
  values=$(awk '
    $1 == "shutdownGracePeriod:" { total=$2 }
    $1 == "shutdownGracePeriodCriticalPods:" { critical=$2 }
    END { if (total != "" && critical != "") print total, critical }
  ' "$file")
  [[ -n $values ]] || return 1
  read -r total_value critical_value <<<"$values"
  node_shutdown_budget_seconds "$total_value" "$critical_value"
}

# 通过 login1 D-Bus 读取正在运行的 systemd-logind 值,不是只看磁盘上的 drop-in。
logind_effective_inhibit_seconds() {
  local output signature usec
  output=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager InhibitDelayMaxUSec 2>/dev/null) || return 1
  read -r signature usec <<<"$output"
  [[ $signature == t && $usec =~ ^[0-9]+$ ]] || return 1
  (( usec % 1000000 == 0 )) || return 1
  printf '%s\n' "$(( usec / 1000000 ))"
}

# 同时检查配置入口、安装器托管的 logind drop-in、systemd 生效值；已有 kubelet
# 运行配置时再与它比对,避免「模板改了但节点仍在跑旧预算」。
verify_graceful_node_shutdown_config() {
  local budget expected_total expected_critical file_value effective
  local runtime_budget runtime_total runtime_critical
  local dropin=${NODE_SHUTDOWN_LOGIND_DROPIN:-/etc/systemd/logind.conf.d/zzz-kubelet.conf}
  local kubelet_config=${NODE_SHUTDOWN_KUBELET_CONFIG:-/var/lib/kubelet/config.yaml}
  budget=$(node_shutdown_budget_seconds \
    "$KUBELET_SHUTDOWN_GRACE" "$KUBELET_SHUTDOWN_GRACE_CRITICAL") || return 1
  read -r expected_total expected_critical <<<"$budget"

  [[ -f $dropin ]] || { log_error "缺少 GracefulNodeShutdown logind 配置: $dropin"; return 1; }
  file_value=$(awk -F= '
    $1 ~ /^[[:space:]]*InhibitDelayMaxSec[[:space:]]*$/ { value=$2 }
    END { gsub(/[[:space:]]/, "", value); print value }
  ' "$dropin")
  [[ $file_value == "$expected_total" ]] || {
    log_error "logind drop-in 与 KUBELET_SHUTDOWN_GRACE 不一致: want=${expected_total}s got=${file_value:-<empty>}"
    return 1
  }

  effective=$(logind_effective_inhibit_seconds) || {
    log_error "无法解析 systemd-logind 的有效 InhibitDelayMaxSec"
    return 1
  }
  [[ $effective == "$expected_total" ]] || {
    log_error "logind 有效上限与 KUBELET_SHUTDOWN_GRACE 不一致: want=${expected_total}s got=${effective}s"
    return 1
  }

  if [[ -f $kubelet_config ]]; then
    runtime_budget=$(kubelet_shutdown_budget_seconds "$kubelet_config") || {
      log_error "kubelet 运行配置缺少或无法解析 shutdownGracePeriod 字段"
      return 1
    }
    read -r runtime_total runtime_critical <<<"$runtime_budget"
    [[ $runtime_total == "$expected_total" && $runtime_critical == "$expected_critical" ]] || {
      log_error "kubelet 运行预算与 config.env 不一致: want=${expected_total}s/${expected_critical}s got=${runtime_total}s/${runtime_critical}s"
      return 1
    }
  fi
}

# PodGC 的 kube-controller-manager 参数是 int32；0 和负数会直接关闭终态 Pod GC。
validate_terminated_pod_gc_threshold() {
  local value=$1 max=2147483647
  [[ $value =~ ^[1-9][0-9]*$ ]] || {
    printf 'KCM_TERMINATED_POD_GC_THRESHOLD=%q 无效;必须是正整数,0 会关闭终态 Pod GC\n' \
      "$value" >&2
    return 1
  }
  if (( ${#value} > ${#max} )) \
    || (( ${#value} == ${#max} && 10#$value > max )); then
    printf 'KCM_TERMINATED_POD_GC_THRESHOLD=%s 超出 int32 上限 %s\n' "$value" "$max" >&2
    return 1
  fi
}

# 原子更新 kubeadm 托管的静态 Pod command 参数。存在旧值时替换并去重；不存在时
# 插入到目标可执行文件之后。输出 changed/unchanged，便于调用方决定是否等待 Pod 重建。
ensure_static_pod_command_arg() {
  local manifest=$1 executable=$2 flag=$3 value=$4
  local prefix="--${flag}=" desired="--${flag}=${value}"
  local anchor_stats executable_count anchor_count command_indent_width
  local flag_stats all_flag_count existing_count exact_count split_count
  local dir base tmp staged
  [[ -f $manifest ]] || return 1

  anchor_stats=$(awk -v executable="$executable" '
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line == "- " executable) {
        executable_count++
        if (previous == "- command:" || previous == "command:") {
          match($0, /^[[:space:]]*/)
          anchor_count++
          width=RLENGTH
        }
      }
      previous=line
    }
    END { print executable_count + 0, anchor_count + 0, width + 0 }
  ' "$manifest")
  read -r executable_count anchor_count command_indent_width <<<"$anchor_stats"
  (( executable_count == 1 && anchor_count == 1 )) || return 1

  flag_stats=$(awk -v flag="$flag" -v desired="$desired" -v width="$command_indent_width" '
    {
      match($0, /^[[:space:]]*/)
      indent=RLENGTH
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line == "- --" flag || index(line, "- --" flag "=") == 1) {
        all_count++
        if (line == "- --" flag) split_count++
        if (indent == width && index(line, "- --" flag "=") == 1) equal_count++
        if (indent == width && line == "- " desired) exact_count++
      }
    }
    END { print all_count + 0, equal_count + 0, exact_count + 0, split_count + 0 }
  ' "$manifest")
  read -r all_flag_count existing_count exact_count split_count <<<"$flag_stats"
  # 拒绝 `--flag value` 和出现在其他 YAML 位置的同名参数，避免静默保留冲突值。
  (( split_count == 0 && all_flag_count == existing_count )) || return 1
  if (( existing_count == 1 && exact_count == 1 )); then
    printf 'unchanged\n'
    return 0
  fi

  dir=$(dirname "$manifest")
  base=$(basename "$manifest")
  # kubelet 会扫描 staticPodPath 下的普通文件；临时文件必须以点开头，避免被当成第二份清单。
  tmp=$(mktemp "${dir}/.${base}.tmp.XXXXXX") || return 1
  staged="${tmp}.staged"
  if ! cp -p "$manifest" "$staged"; then
    rm -f "$tmp" "$staged"
    return 1
  fi

  if (( existing_count > 0 )); then
    if ! awk -v prefix="$prefix" -v desired="$desired" -v width="$command_indent_width" '
      {
        match($0, /^[[:space:]]*/)
        indent=RLENGTH
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (indent == width && index(line, "- " prefix) == 1) {
          if (!done) {
            print substr($0, RSTART, RLENGTH) "- " desired
            done=1
          }
          next
        }
        print
      }
      END { if (!done) exit 2 }
    ' "$manifest" > "$tmp"; then
      rm -f "$tmp" "$staged"
      return 1
    fi
  else
    if ! awk -v executable="$executable" -v desired="$desired" -v width="$command_indent_width" '
      {
        print
        match($0, /^[[:space:]]*/)
        indent=RLENGTH
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (!done && indent == width && line == "- " executable) {
          print substr($0, RSTART, RLENGTH) "- " desired
          done=1
        }
      }
      END { if (!done) exit 2 }
    ' "$manifest" > "$tmp"; then
      rm -f "$tmp" "$staged"
      return 1
    fi
  fi

  if ! cat "$tmp" > "$staged" || ! mv -f "$staged" "$manifest"; then
    rm -f "$tmp" "$staged"
    return 1
  fi
  rm -f "$tmp"
  printf 'changed\n'
}

# 只改 live ClusterConfiguration 的 controllerManager.extraArgs，保留升级或人工维护的其他字段。
ensure_kubeadm_controller_manager_arg_file() {
  local config_file=$1 flag=$2 value=$3 dir base tmp staged
  [[ -f $config_file ]] || return 1
  dir=$(dirname "$config_file")
  base=$(basename "$config_file")
  tmp=$(mktemp "${dir}/.${base}.tmp.XXXXXX") || return 1
  staged="${tmp}.staged"
  if ! cp -p "$config_file" "$staged"; then
    rm -f "$tmp" "$staged"
    return 1
  fi

  if ! awk -v flag="$flag" -v value="$value" '
    function emit_target() {
      print "  - name: " flag
      print "    value: \"" value "\""
      inserted=1
    }
    {
      line=$0
      if (in_extra && (line ~ /^  [^[:space:]-][^:]*:/ || line ~ /^[^[:space:]#]/)) {
        if (!inserted) emit_target()
        in_extra=0
      }
      if (line == "controllerManager:") {
        seen_component=1
        in_component=1
      } else if (line ~ /^[^[:space:]#][^:]*:/) {
        in_component=0
      }
      if (in_component && line == "  extraArgs:") {
        print
        seen_extra=1
        in_extra=1
        next
      }
      if (in_extra && line == "  - name: " flag) {
        if (!inserted) emit_target()
        skip_value=1
        next
      }
      if (skip_value) {
        if (line ~ /^    value:/) {
          skip_value=0
          next
        }
        exit 2
      }
      print
    }
    END {
      if (skip_value) exit 2
      if (in_extra && !inserted) emit_target()
      if (!seen_component || !seen_extra) exit 2
    }
  ' "$config_file" > "$tmp"; then
    rm -f "$tmp" "$staged"
    return 1
  fi

  if cmp -s "$config_file" "$tmp"; then
    rm -f "$tmp" "$staged"
    printf 'unchanged\n'
    return 0
  fi
  if ! cat "$tmp" > "$staged" || ! mv -f "$staged" "$config_file"; then
    rm -f "$tmp" "$staged"
    return 1
  fi
  rm -f "$tmp"
  printf 'changed\n'
}

verify_terminated_pod_gc_runtime() {
  local expected=${KCM_TERMINATED_POD_GC_THRESHOLD:-}
  local manifest=${KCM_STATIC_POD_MANIFEST:-/etc/kubernetes/manifests/kube-controller-manager.yaml}
  local manifest_stats manifest_all manifest_exact manifest_split controller_json pod_count container_count
  local commands prefix_count expected_count split_count ready
  validate_terminated_pod_gc_threshold "$expected" || return 1
  [[ -f $manifest ]] || return 1

  manifest_stats=$(awk -v flag=terminated-pod-gc-threshold \
    -v expected="--terminated-pod-gc-threshold=${expected}" '
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line == "- --" flag || index(line, "- --" flag "=") == 1) all_count++
      if (line == "- --" flag) split_count++
      if (line == "- " expected) exact_count++
    }
    END { print all_count + 0, exact_count + 0, split_count + 0 }
  ' "$manifest")
  read -r manifest_all manifest_exact manifest_split <<<"$manifest_stats"
  (( manifest_all == 1 && manifest_exact == 1 && manifest_split == 0 )) || return 1

  controller_json=$(kctl -n kube-system get pods -l component=kube-controller-manager \
    --field-selector="spec.nodeName=$NODE_NAME" -o json 2>/dev/null) || return 1
  pod_count=$(jq -r '.items | length' <<<"$controller_json") || return 1
  container_count=$(jq -r '[.items[].spec.containers[] | select(.name == "kube-controller-manager")] | length' \
    <<<"$controller_json") || return 1
  (( pod_count == 1 && container_count == 1 )) || return 1
  commands=$(jq -r '.items[].spec.containers[] | select(.name == "kube-controller-manager") | .command[]' \
    <<<"$controller_json") || return 1
  prefix_count=$(grep -Fc -- '--terminated-pod-gc-threshold=' <<<"$commands" || true)
  expected_count=$(grep -Fxc -- "--terminated-pod-gc-threshold=${expected}" <<<"$commands" || true)
  split_count=$(grep -Fxc -- '--terminated-pod-gc-threshold' <<<"$commands" || true)
  (( prefix_count == 1 && expected_count == 1 && split_count == 0 )) || return 1

  ready=$(jq -r '.items[].status.containerStatuses[] | select(.name == "kube-controller-manager") | .ready' \
    <<<"$controller_json") || return 1
  [[ $ready == true ]]
}

verify_terminated_pod_gc_persisted_config() {
  local expected=${KCM_TERMINATED_POD_GC_THRESHOLD:-} cluster_config stats entries matches
  cluster_config=$(kctl -n kube-system get configmap kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null) || return 1
  stats=$(awk -v expected="$expected" '
    $1 == "-" && $2 == "name:" && $3 == "terminated-pod-gc-threshold" {
      entries++
      want=1
      next
    }
    want && $1 == "value:" {
      value=$2
      gsub(/^"|"$/, "", value)
      if (value == expected) matches++
      want=0
    }
    END { print entries + 0, matches + 0 }
  ' <<<"$cluster_config")
  read -r entries matches <<<"$stats"
  (( entries == 1 && matches == 1 ))
}

verify_terminated_pod_gc_config() {
  verify_terminated_pod_gc_persisted_config && verify_terminated_pod_gc_runtime
}

controller_manager_ready() {
  local controller_json pod_count ready
  controller_json=$(kctl -n kube-system get pods -l component=kube-controller-manager \
    --field-selector="spec.nodeName=$NODE_NAME" -o json 2>/dev/null) || return 1
  pod_count=$(jq -r '.items | length' <<<"$controller_json") || return 1
  ready=$(jq -r '.items[].status.containerStatuses[] | select(.name == "kube-controller-manager") | .ready' \
    <<<"$controller_json") || return 1
  (( pod_count == 1 )) && [[ $ready == true ]]
}

active_unhealthy_pods_from_json() {
  jq -r '
    .items[]
    | ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "False") as $ready
    | select(.metadata.deletionTimestamp == null)
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.status.phase != "Running" or $ready != "True")
    | "\(.metadata.name)(\(.status.phase)/\(.status.reason // "no-reason"))"
  '
}

terminal_pod_count() {
  kctl get pods -A -o json 2>/dev/null | jq -r '
    [.items[]
      | select(
          (.status.phase == "Succeeded" or .status.phase == "Failed")
          and (.metadata.deletionTimestamp == null)
        )]
    | length
  '
}

terminated_pod_gc_converged() {
  local count
  count=$(terminal_pod_count) || return 1
  (( count <= KCM_TERMINATED_POD_GC_THRESHOLD ))
}

# --------------------------- Cilium LB-IPAM / L2 / Gateway 纯校验 ---------------------
# 输入完整对象 JSON, 每行输出一个问题; 无输出即通过。只比较 CR/Service 字段, 不证明网络可达。
# 60-cilium 的 l2 步骤、90-verify 与 components/gateway 共用同一套判据(tests/test-l2-policy.sh)。
#
# lb_pool_problems <pool json> <期望起> <期望止> [selector 要求]
#   selector 要求二选一:
#     <namespace> <service 名>   专属池: serviceSelector.matchLabels 必须同时含两把特殊键
#     exclude=<service 名>       默认池: serviceSelector.matchExpressions 必须有 NotIn 排除该名字
#   - blocks 必须恰好一段且起止相等于期望(单地址池起=止)
#   - spec.disabled 不能为 true(disabled 保留已分配地址但停止新分配)
#   - 状态: 当前 generation 的 cilium.io/PoolConflict 必须为 False; 条件缺失/过期视为未收敛
lb_pool_problems() {
  local json=$1 start=$2 stop=$3 ns=${4:-} svc=${5:-} exclude=""
  if [[ $ns == exclude=* ]]; then exclude=${ns#exclude=}; ns=""; fi
  jq -r --arg start "$start" --arg stop "$stop" --arg ns "$ns" --arg svc "$svc" --arg exclude "$exclude" '
    def problem(p; c): if c then [] else [p] end;
    (.metadata.name // "?") as $name
    | (.spec.blocks // []) as $blocks
    | ([.status.conditions[]? | select(.type == "cilium.io/PoolConflict")] | last) as $conflict
    | problem("\($name): blocks 应恰好 1 段, 实际 \($blocks | length)"; ($blocks | length) == 1)
    + problem("\($name): 地址段 \($blocks[0].start // "?")-\($blocks[0].stop // "?") 与期望 \($start)-\($stop) 不一致";
        ($blocks | length) == 1 and $blocks[0].start == $start and $blocks[0].stop == $stop and ($blocks[0].cidr == null))
    + problem("\($name): spec.disabled=true, 池已停止分配"; (.spec.disabled // false) != true)
    + (if $ns == "" then [] else
        problem("\($name): serviceSelector 未同时限定 namespace=\($ns) 与 name=\($svc)";
          (.spec.serviceSelector.matchLabels["io.kubernetes.service.namespace"] // "") == $ns
          and (.spec.serviceSelector.matchLabels["io.kubernetes.service.name"] // "") == $svc)
      end)
    + (if $exclude == "" then [] else
        problem("\($name): serviceSelector 未用 NotIn 排除 \($exclude), 共享 Gateway 的 Service 可能从本池取到非固定地址";
          any(.spec.serviceSelector.matchExpressions[]?;
              .key == "io.kubernetes.service.name" and .operator == "NotIn" and ((.values // []) | index($exclude)) != null))
      end)
    + problem("\($name): 缺少 cilium.io/PoolConflict 条件(operator 尚未调和)"; $conflict != null)
    + (if $conflict == null then [] else
        problem("\($name): PoolConflict=\($conflict.status) (\($conflict.reason // "-"): \($conflict.message // "-"))";
          $conflict.status == "False")
        + problem("\($name): PoolConflict 条件 observedGeneration=\($conflict.observedGeneration // "null") 落后于 generation=\(.metadata.generation)";
          ($conflict.observedGeneration // -1) == .metadata.generation)
      end)
    | .[]
  ' <<<"$json"
}

# l2_policy_problems <policy json>: loadBalancerIPs 必须为 true, interfaces 非空
l2_policy_problems() {
  jq -r '
    def problem(p; c): if c then [] else [p] end;
    (.metadata.name // "?") as $name
    | problem("\($name): spec.loadBalancerIPs 不是 true"; .spec.loadBalancerIPs == true)
    + problem("\($name): spec.interfaces 为空, 不会在任何网卡应答 ARP"; ((.spec.interfaces // []) | length) > 0)
    | .[]
  ' <<<"$1"
}

# shared_gateway_problems <gateway json> <生成的 Service json 或空串> <期望 VIP>
#   - Programmed=True 且 observedGeneration 等于当前 generation(旧 generation 的 True 不算)
#   - status.addresses[0] 等于固定 VIP
#   - 生成的 Service 必须是 LoadBalancer, 请求注解 io.cilium/lb-ipam-ips 含 VIP,
#     status.loadBalancer.ingress 含 VIP, 且 cilium.io/IPAMRequestSatisfied=True
shared_gateway_problems() {
  local gw_json=$1 svc_json=$2 vip=$3
  jq -r --arg vip "$vip" '
    def problem(p; c): if c then [] else [p] end;
    ([.status.conditions[]? | select(.type == "Programmed")] | last) as $prog
    | problem("Gateway 缺少 Programmed 条件"; $prog != null)
    + (if $prog == null then [] else
        problem("Gateway Programmed=\($prog.status) (\($prog.reason // "-"): \($prog.message // "-"))"; $prog.status == "True")
        + problem("Gateway Programmed 条件 observedGeneration=\($prog.observedGeneration // "null") 落后于 generation=\(.metadata.generation)";
          ($prog.observedGeneration // -1) == .metadata.generation)
      end)
    + problem("Gateway 地址 \(.status.addresses[0].value // "<none>") 不等于固定 VIP \($vip)";
        (.status.addresses[0].value // "") == $vip)
    | .[]
  ' <<<"$gw_json"
  if [[ -z $svc_json ]]; then
    echo "未找到 Cilium 为共享 Gateway 生成的 Service(default/cilium-gateway-cilium-gateway)"
    return 0
  fi
  jq -r --arg vip "$vip" '
    def problem(p; c): if c then [] else [p] end;
    ([.status.conditions[]? | select(.type == "cilium.io/IPAMRequestSatisfied")] | last) as $sat
    | problem("生成的 Service 类型是 \(.spec.type // "?"), 不是 LoadBalancer(hostNetwork 模式会变成 NodePort)"; .spec.type == "LoadBalancer")
    + problem("生成的 Service 请求注解 io.cilium/lb-ipam-ips=\(.metadata.annotations["io.cilium/lb-ipam-ips"] // "<none>") 不含 \($vip)";
        ((.metadata.annotations["io.cilium/lb-ipam-ips"] // "") | split(",") | map(gsub("\\s"; "")) | index($vip)) != null)
    + problem("生成的 Service 实际 LB 地址 \([.status.loadBalancer.ingress[]?.ip] | join(",")) 不含 \($vip)";
        ([.status.loadBalancer.ingress[]?.ip] | index($vip)) != null)
    + problem("生成的 Service 缺少 cilium.io/IPAMRequestSatisfied 条件"; $sat != null)
    + (if $sat == null then [] else
        problem("IPAMRequestSatisfied=\($sat.status) (\($sat.reason // "-"): \($sat.message // "-"))"; $sat.status == "True")
      end)
    | .[]
  ' <<<"$svc_json"
}

# 从整条 `kubeadm join <ep> --token <t> --discovery-token-ca-cert-hash <h>` 命令
# 解析出三个参数并写入 JOIN_* 全局(worker 交互模式粘贴用)
parse_join_cmd() {
  local cmd=$1
  JOIN_ENDPOINT=$(awk '{for(i=1;i<=NF;i++) if($i=="join"){print $(i+1); exit}}' <<<"$cmd")
  JOIN_TOKEN=$(awk '{for(i=1;i<=NF;i++) if($i=="--token"){print $(i+1); exit}}' <<<"$cmd")
  JOIN_CA_CERT_HASH=$(awk '{for(i=1;i<=NF;i++) if($i=="--discovery-token-ca-cert-hash"){print $(i+1); exit}}' <<<"$cmd")
  [[ -n $JOIN_ENDPOINT && -n $JOIN_TOKEN && -n $JOIN_CA_CERT_HASH ]]
}

# NODE_IP 允许留空自动检测, 解析一次后全局可用
resolve_node_ip() {
  if [[ -z $NODE_IP ]]; then
    NODE_IP=$(detect_node_ip)
    [[ -n $NODE_IP ]] || die "无法自动检测本机 IP, 请在 config.env 里显式设置 NODE_IP"
  fi
}

# --------------------------- CIDR 工具 --------------------------------------
ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
# cidr_contains 10.244.0.0/16 10.244.1.2 → 0(包含)
cidr_contains() {
  local net=${1%/*} bits=${1#*/} ip=$2 mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ( $(ip2int "$ip") & mask ) == ( $(ip2int "$net") & mask ) ))
}

# --------------------------- 状态(断点续跑) ----------------------------------
ensure_dirs() { mkdir -p "$STATE_DIR/state" "$BACKUP_DIR" "$CACHE_DIR" "$LOG_DIR" "$K8S_FILES_DIR"; }

state_done() { [[ -f "$STATE_DIR/state/${STAGE_ID}:$1.done" ]]; }
mark_done()  { ensure_dirs; touch "$STATE_DIR/state/${STAGE_ID}:$1.done"; }
state_reset() {  # state_reset [stage前缀|all]
  local what=${1:-all}
  if [[ $what == all ]]; then
    rm -f "$STATE_DIR/state/"*.done "$STATE_DIR/components.selected" 2>/dev/null || true
  else
    rm -f "$STATE_DIR/state/${what}"*.done 2>/dev/null || true
    if [[ $what == 80-components ]]; then
      rm -f "$STATE_DIR/components.selected"
    fi
  fi
}

# 把期望状态摘要收进步骤状态模块：输入变化时只使指定下游步骤失效，避免调用方
# 依赖「记得手工 reset 整个阶段」这一隐含接口。返回 0 表示指纹变化，1 表示未变。
state_reconcile_fingerprint() {  # state_reconcile_fingerprint <name> <fingerprint> <step...>
  local name=$1 current=$2
  shift 2
  [[ -n $name && -n $current && $# -gt 0 ]] || return 2
  ensure_dirs

  local file="$STATE_DIR/state/${STAGE_ID}:${name}.fingerprint.done"
  local previous="" key tmp
  [[ -f $file ]] && previous=$(<"$file")
  [[ $previous != "$current" ]] || return 1

  for key in "$@"; do
    rm -f "$STATE_DIR/state/${STAGE_ID}:$key.done"
  done
  tmp="${file}.tmp.$$"
  printf '%s' "$current" > "$tmp"
  mv -f "$tmp" "$file"
  return 0
}

# --------------------------- 错误陷阱 ---------------------------------------
_on_err() {
  local ec=$1
  trap - ERR
  echo >&2
  log_error "阶段 [${STAGE_TITLE:-${STAGE_ID:-?}}] 执行失败 (exit=$ec)"
  [[ -n ${CURRENT_STEP_DESC:-} ]] && log_error "失败步骤: ${CURRENT_STEP_KEY:-?} — ${CURRENT_STEP_DESC}"
  log_error "出错命令: ${BASH_COMMAND}"
  log_error "阶段日志: $LOG_DIR/${STAGE_ID:-install}.log"
  log_error "处理办法: 修复问题后重新执行 sudo bash start.sh, 已完成步骤会自动跳过, 从失败处继续"
  exit "$ec"
}

# --------------------------- 阶段/步骤框架 -----------------------------------
# 用法(阶段脚本):
#   stage_begin "10-system-base" "系统基础配置"
#   add_step key "描述" fn [verify_fn]     # verify_fn 只做检查, 返回非 0 视为校验失败
#   run_steps
#   stage_end
declare -a STEPS=()
_STEP_IDX=0; _STEP_TOTAL=0

stage_begin() {
  STAGE_ID=$1; STAGE_TITLE=$2; STAGE_T0=$SECONDS
  require_root; ensure_dirs; resolve_node_ip
  trap '_on_err $?' ERR
  # 后台模式(K8S_BG=1)输出全部进日志文件; 前台模式 tee 到屏幕+日志
  if [[ ${K8S_BG:-0} == 1 ]]; then
    exec >>"$LOG_DIR/$STAGE_ID.log" 2>&1
  else
    exec > >(tee -a "$LOG_DIR/$STAGE_ID.log") 2> >(tee -a "$LOG_DIR/$STAGE_ID.log" >&2)
  fi
  hr; printf '%s%s◆ 阶段 %s — %s%s\n' "$C_MAG" "$C_BLD" "$STAGE_ID" "$STAGE_TITLE" "$C_RST"; hr
  # 预热代理探活缓存(子 shell/并行任务继承结果, 避免重复探测与重复告警)
  proxy_alive || true
}

add_step() { STEPS+=("$1|$2|$3|${4:-}"); }

run_step() {
  local key=$1 desc=$2 fn=$3 verify=${4:-}
  _STEP_IDX=$(( _STEP_IDX + 1 ))
  local tag="[$_STEP_IDX/$_STEP_TOTAL]"
  if state_done "$key"; then
    log_skip "$tag $desc (已完成, 跳过)"
    return 0
  fi
  log_step "$tag $desc"
  CURRENT_STEP_KEY=$key; CURRENT_STEP_DESC=$desc
  local t0=$SECONDS
  "$fn"
  if [[ -n $verify ]]; then
    "$verify" || die "校验未通过: $desc (verify=$verify)"
    log_info "校验通过: $desc"
  fi
  mark_done "$key"
  CURRENT_STEP_KEY=""; CURRENT_STEP_DESC=""
  log_ok "$tag $desc (耗时 $(( SECONDS - t0 ))s)"
}

run_steps() {
  _STEP_TOTAL=${#STEPS[@]}; _STEP_IDX=0
  local entry key desc fn verify
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r key desc fn verify <<<"$entry"
    run_step "$key" "$desc" "$fn" "$verify"
  done
}

stage_end() {
  hr
  log_ok "阶段 [$STAGE_TITLE] 全部完成 (耗时 $(( SECONDS - STAGE_T0 ))s)"
}

# --------------------------- 交互 -------------------------------------------
is_interactive() { [[ $ASSUME_YES != true ]] && [[ -c /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

# 有无终端(不看 --yes): 磁盘选择/擦除这类高危决策即使 --yes 也要弹终端菜单,
# 只有真正无终端(systemd/cron/nohup)时才回退到显式配置授权
has_tty() { [[ -c /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

# 磁盘总览: 菜单询问前先给用户完整现场(lsblk + 各盘可分配空间)
print_disk_overview() {
  {
    echo
    echo "── 磁盘总览(lsblk) ──"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    echo
    echo "── 可分配空间 ──"
    local d free
    while read -r d; do
      if list_free_disks | grep -qx "$d"; then
        echo "  [整盘空闲]   $d ($(lsblk -dno SIZE "$d" | tr -d ' '))"
      else
        free=$(disk_tail_free_gb "$d")
        (( free >= 1 )) && echo "  [尾部未分配] $d 约 ${free}G"
      fi
    done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
    local p
    while read -r p; do
      echo "  [空分区]     ${p%%:*} (约 ${p##*:}G, 无文件系统)"
    done < <(list_empty_partitions)
    echo
  } >/dev/tty
}

# 空分区探测(无文件系统/非 PV/未挂载), 输出 "路径:大小GiB"
list_empty_partitions() {
  lsblk -bnpo NAME,TYPE,FSTYPE,SIZE -P 2>/dev/null \
    | awk -F'"' '$4 == "part" && $6 == "" { printf "%s:%d\n", $2, $8/1073741824 }'
}

# confirm "继续吗" [Y|N]  → 0=是; 非交互模式直接返回默认值
confirm() {
  local msg=$1 def=${2:-Y} ans hint
  if ! is_interactive; then [[ $def == Y ]]; return; fi
  hint="[Y/n]"; [[ $def == N ]] && hint="[y/N]"
  while true; do
    printf '%s%s %s %s: %s' "$C_YEL" "$I_ASK" "$msg" "$hint" "$C_RST" >/dev/tty
    read -r ans </dev/tty || ans=""
    ans=${ans:-$def}
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# 三态配置项: true/false/ask → resolve_opt "$CONFIGURE_SSHD" "要配置 sshd 吗" N
resolve_opt() {
  case "$1" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     confirm "$2" "${3:-N}" ;;
  esac
}

# 危险操作: 必须原样输入确认词; 只要有终端就询问(--yes 不豁免高危操作),
# 真正无终端时返回失败(由调用方依据显式配置放行)
confirm_danger() {
  local msg=$1 word=${2:-yes}
  has_tty || return 1
  log_warn "$msg"
  printf '%s%s 危险操作! 输入 "%s" 继续, 其他任意输入取消: %s' "$C_RED" "$C_BLD" "$word" "$C_RST" >/dev/tty
  local ans; read -r ans </dev/tty || ans=""
  [[ $ans == "$word" ]]
}

prompt_input() {  # prompt_input "提示" "默认值" → 输出结果
  local msg=$1 def=${2:-} ans
  if ! is_interactive; then echo "$def"; return; fi
  printf '%s%s %s [%s]: %s' "$C_CYA" "$I_ASK" "$msg" "$def" "$C_RST" >/dev/tty
  read -r ans </dev/tty || ans=""
  echo "${ans:-$def}"
}

# --------------------------- 重试/下载 ---------------------------------------
retry() {  # retry 次数 间隔秒 命令...
  local n=$1 delay=$2 i; shift 2
  for (( i = 1; i <= n; i++ )); do
    "$@" && return 0
    (( i < n )) && { log_warn "第 $i/$n 次失败: $1 ... ${delay}s 后重试"; sleep "$delay"; }
  done
  return 1
}

# 代理探活: PROXY_URL 是"按需开启"的(平时不常驻), 探活失败自动降级直连
# 结果缓存在进程内(_PROXY_ALIVE); stage_begin 会预热一次, 后续子 shell 继承不再重复探测
proxy_alive() {
  [[ -n $PROXY_URL ]] || return 1
  if [[ -z ${_PROXY_ALIVE:-} ]]; then
    local hp=${PROXY_URL#*://} host port
    hp=${hp%%/*}; host=${hp%%:*}; port=${hp##*:}
    if [[ $port == "$host" || -z $port ]]; then port=80; fi
    local _probe_ok=1
    if has_cmd timeout; then
      timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null || _probe_ok=0
    else
      # 无 timeout 命令时裸连(局域网 connection refused 毫秒级返回)
      bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null || _probe_ok=0
    fi
    if [[ $_probe_ok == 1 ]]; then
      _PROXY_ALIVE=1
    else
      _PROXY_ALIVE=0
      log_warn "代理 $PROXY_URL 未启动/不可达, 本次自动降级为直连(需要时开启代理重跑即可, 无需改配置)"
    fi
  fi
  [[ ${_PROXY_ALIVE} == 1 ]]
}

# 仅对显式包裹的命令启用代理(不污染 apt / 集群内流量); 代理不在线时透明直连
with_proxy() {
  if proxy_alive; then
    http_proxy=$PROXY_URL https_proxy=$PROXY_URL \
    HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL \
    no_proxy="localhost,127.0.0.1,${NODE_IP:-},10.0.0.0/8,192.168.0.0/16,.cluster.local" \
      "$@"
  else
    "$@"
  fi
}

# GitHub 下载地址加速前缀
gh_url() { echo "${GITHUB_PROXY:+${GITHUB_PROXY%/}/}$1"; }

_curl_dl() { with_proxy curl -fL --connect-timeout 10 --max-time 1800 --retry 2 -C - -o "$1" "$2"; }

fetch() {  # fetch <url> <目标文件>; 支持断点续传, 续传状态损坏时清掉重来一次
  local url=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  if ! retry 2 3 _curl_dl "${dest}.part" "$url"; then
    rm -f "${dest}.part"
    retry 2 5 _curl_dl "${dest}.part" "$url" || return 1
  fi
  mv -f "${dest}.part" "$dest"
}

# sha256 校验: 支持 "单哈希文件" 与 "哈希+文件名清单" 两种格式
sha256_ok() {  # sha256_ok <文件> <校验文件> [清单内文件名]
  local file=$1 sumfile=$2 name=${3:-$(basename "$1")} want got
  want=$(awk -v n="$name" 'index($0, n) { print $1; exit }' "$sumfile")
  [[ -z $want ]] && want=$(awk 'NF >= 1 { print $1; exit }' "$sumfile")
  got=$(sha256sum "$file" | awk '{print $1}')
  [[ -n $want && $got == "$want" ]]
}

# --------------------------- 版本解析与锁定 ----------------------------------
lock_get() { [[ -f $VERSIONS_LOCK ]] && awk -F= -v k="$1" '$1 == k { print $2 }' "$VERSIONS_LOCK" || true; }
lock_set() {
  ensure_dirs
  local tmp; tmp=$(mktemp)
  { [[ -f $VERSIONS_LOCK ]] && grep -v "^$1=" "$VERSIONS_LOCK" || true; echo "$1=$2"; } > "$tmp"
  mv -f "$tmp" "$VERSIONS_LOCK"
}

gh_latest_tag() {  # gh_latest_tag owner/repo → tag 或空
  with_proxy curl -fsSL --connect-timeout 8 --max-time 20 \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4 || true
}

# resolve_version 名字 owner/repo 兜底版本 [config显式指定]
# 顺序: 显式指定 > versions.lock > GitHub API > 兜底; 结果写入 lock 保证下次一致
resolve_version() {
  local name=$1 repo=$2 fallback=$3 explicit=${4:-} v
  if [[ -n $explicit ]]; then
    v=$explicit
  else
    v=$(lock_get "$name")
    if [[ -z $v ]]; then
      v=$(gh_latest_tag "$repo")
      if [[ -z $v ]]; then
        v=$fallback
        log_warn "$name: GitHub API 不可达, 使用兜底版本 $v (可设置 GITHUB_PROXY/PROXY_URL 后重试)"
      else
        # 本函数经命令替换捕获输出, 日志必须走 stderr, 否则污染版本变量(argocd/dragonfly 实测翻车)
        log_info "$name: 解析到最新版 $v" >&2
      fi
    fi
  fi
  lock_set "$name" "$v"
  echo "$v"
}

# --------------------------- 文件托管 ---------------------------------------
# 非托管系统文件修改前备份一次(镜像目录结构, 永不覆盖已有备份) → 可随时人工还原
backup_once() {
  local f=$1 dst
  [[ -e $f ]] || return 0
  dst="$BACKUP_DIR$f"
  [[ -e $dst ]] && return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$f" "$dst"
  log_info "原文件已备份: $f → $dst"
}

# 标记块整块替换(用于 /etc/hosts、bashrc 等多方共用文件, 幂等)
ensure_block() {  # ensure_block <文件> <块名> <内容>
  local file=$1 name=$2 content=$3
  local b="# >>> k8s-installer:${name} >>>" e="# <<< k8s-installer:${name} <<<"
  touch "$file"
  local tmp; tmp=$(mktemp)
  awk -v b="$b" -v e="$e" '$0 == b { skip = 1 } skip && $0 == e { skip = 0; next } !skip' "$file" > "$tmp"
  { cat "$tmp"; printf '%s\n%s\n%s\n' "$b" "$content" "$e"; } > "$file"
  rm -f "$tmp"
}

# --------------------- containerd 临时代理(安装器镜像预拉专用) -----------------
# 50(控制面镜像)与 60(Cilium 镜像)共用: 挂上→拉取→立即撤除, 不留常驻代理
PREPULL_DROPIN=/etc/systemd/system/containerd.service.d/zz-prepull-proxy.conf

containerd_tmp_proxy_off() {
  if [[ -f $PREPULL_DROPIN ]]; then
    rm -f "$PREPULL_DROPIN"
    systemctl daemon-reload
    systemctl restart containerd
    log_info "预拉临时代理已撤除, containerd 恢复常规拉取通道"
  fi
}

containerd_tmp_proxy_on() {
  mkdir -p "$(dirname "$PREPULL_DROPIN")"
  cat > "$PREPULL_DROPIN" <<EOF
# k8s-installer 临时文件: 仅镜像预拉期间生效, 完成后自动删除
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=localhost,127.0.0.1,$NODE_IP,$POD_CIDR,$SERVICE_CIDR,.cluster.local,10.0.0.0/8,192.168.0.0/16${CONTAINERD_NO_PROXY_EXTRA:+,$CONTAINERD_NO_PROXY_EXTRA}"
EOF
  systemctl daemon-reload
  systemctl restart containerd
  log_info "镜像预拉临时借道代理 $PROXY_URL (完成后自动撤除)"
}

# --------------------------- apt / systemd ----------------------------------
apt_env() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$@"; }
apt_update()  { retry 3 5 apt_env apt-get update -o DPkg::Lock::Timeout=600; }
pkg_install() {
  retry 3 5 apt_env apt-get install -y \
    -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold "$@"
}

svc_active() { systemctl is-active --quiet "$1"; }
svc_exists() { [[ -n $(systemctl list-unit-files --no-legend "$1.service" 2>/dev/null) ]]; }

# --------------------------- 常用校验 ---------------------------------------
need_cmd()     { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
has_cmd()      { command -v "$1" >/dev/null 2>&1; }
verify_sysctl(){ [[ $(sysctl -n "$1" 2>/dev/null) == "$2" ]]; }

wait_for() {  # wait_for "描述" 超时秒 命令...
  local desc=$1 timeout=$2 t=0; shift 2
  until "$@" >/dev/null 2>&1; do
    (( t += 5 ))
    (( t >= timeout )) && { log_error "等待超时(${timeout}s): $desc"; return 1; }
    sleep 5
  done
  return 0
}

# 磁盘尾部未分配空间(GiB 整数; 适用于 PD/虚拟化层扩容后未划分的场景)
# 用"盘总大小 - 最后一个分区结束位置"计算, 不依赖 GPT 备份头位置(扩容后备份头还在旧位置)
disk_tail_free_gb() {
  local disk=$1 out size_gib last_end
  out=$(parted -ms "$disk" unit GiB print 2>/dev/null) || { echo 0; return 0; }
  size_gib=$(awk -F: -v d="$disk" '$1 == d { gsub(/GiB/,"",$2); print $2 }' <<<"$out")
  last_end=$(awk -F: '/^[0-9]+:/ { gsub(/GiB/,"",$3); e = $3 } END { print e + 0 }' <<<"$out")
  awk -v s="${size_gib:-0}" -v e="${last_end:-0}" 'BEGIN { f = s - e; if (f < 0) f = 0; printf "%d", f }'
}

# 在磁盘尾部未分配空间新建 GPT 分区, 输出新分区设备路径
# 用法: create_tail_partition <整盘> <大小(如 16G; 0=用尽剩余)> <类型码(8300/8e00)> <GPT名>
# 安全措施: 先备份分区表到 $BACKUP_DIR(恢复: sgdisk --load-backup=<bak> <盘>);
#           sgdisk -e 把扩容后滞留在旧位置的 GPT 备份头挪到盘尾, 否则新空间不可用
create_tail_partition() {
  local disk=$1 size=$2 typecode=$3 name=$4
  local endspec="+$size" before after newpart
  [[ $size == 0 ]] && endspec="0"
  mkdir -p "$BACKUP_DIR"
  sgdisk --backup="$BACKUP_DIR/sgdisk-$(basename "$disk")-$name.bak" "$disk" >/dev/null
  sgdisk -e "$disk" >/dev/null
  before=$(lsblk -nrpo NAME "$disk")
  sgdisk -n "0:0:$endspec" -t "0:$typecode" -c "0:$name" "$disk" >/dev/null
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1
  after=$(lsblk -nrpo NAME "$disk")
  newpart=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)
  [[ -b $newpart ]] || { log_error "在 $disk 上创建分区后未发现新设备"; return 1; }
  echo "$newpart"
}

# 空闲磁盘探测: 整盘、无分区、无文件系统签名、未挂载(45-etcd-disk 与 70-storage 共用)
list_free_disks() {
  local dev fstype
  while read -r dev; do
    [[ $(lsblk -n "$dev" 2>/dev/null | wc -l) -eq 1 ]] || continue      # 有分区/子设备
    fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
    [[ -z $fstype ]] || continue                                        # 已有文件系统/LVM 签名
    [[ -z $(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null | tr -d '[:space:]') ]] || continue
    echo "$dev"
  done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
}

# kubectl 封装(admin.conf 就绪后可用)
kctl() { KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"; }

# helm 封装(走代理, 指定 kubeconfig)
helm_cmd() { KUBECONFIG=/etc/kubernetes/admin.conf with_proxy helm "$@"; }

# 添加 helm 仓库: 带重试; 代理路径失败后自动退直连再试
# (--force-update 本身会拉取 index.yaml, 成功即代表索引就绪, 无需再单独 repo update)
helm_repo_add() {  # helm_repo_add <名字> <URL>
  local name=$1 url=$2
  if retry 3 5 helm_cmd repo add "$name" "$url" --force-update; then
    return 0
  fi
  log_warn "添加 helm 仓库 $name 失败(经代理), 改为直连重试"
  retry 2 5 helm repo add "$name" "$url" --force-update
}

# --------------------------- 版本集与工件路径 --------------------------------
# K8s 版本特殊处理: 走 dl.k8s.io stable 而不是 GitHub API; minor 决定 apt 仓库分流
resolve_k8s_versions() {
  local stable minor
  stable=$(lock_get K8S_STABLE)
  if [[ -z $stable ]]; then
    stable=$(with_proxy curl -fsSL --connect-timeout 8 --max-time 20 \
      https://dl.k8s.io/release/stable.txt 2>/dev/null) || true
    if [[ -z $stable ]]; then
      stable=$FALLBACK_K8S_STABLE
      log_warn "K8s: dl.k8s.io 不可达, 使用兜底版本 $stable"
    else
      log_info "K8s: 解析到最新稳定版 $stable"
    fi
  fi
  lock_set K8S_STABLE "$stable"
  K8S_STABLE_V=$stable
  minor=$K8S_MINOR
  if [[ -z $minor ]]; then minor=${stable#v}; minor=${minor%.*}; fi
  lock_set K8S_MINOR_EFF "$minor"
  K8S_MINOR_V=$minor
}

# 解析全部组件版本(首跑访问网络并写入 versions.lock; 之后完全离线、结果恒定)
ensure_versions() {
  [[ -n ${_VERSIONS_READY:-} ]] && return 0
  resolve_k8s_versions
  RUNC_V=$(resolve_version        RUNC        opencontainers/runc          "$FALLBACK_RUNC"        "$RUNC_VERSION")
  CONTAINERD_V=$(resolve_version  CONTAINERD  containerd/containerd        "$FALLBACK_CONTAINERD"  "$CONTAINERD_VERSION")
  CRICTL_V=$(resolve_version      CRICTL      kubernetes-sigs/cri-tools    "$FALLBACK_CRICTL"      "$CRICTL_VERSION")
  CILIUM_V=$(resolve_version      CILIUM      cilium/cilium                "$FALLBACK_CILIUM"      "$CILIUM_VERSION")
  CILIUM_CLI_V=$(resolve_version  CILIUM_CLI  cilium/cilium-cli            "$FALLBACK_CILIUM_CLI"  "$CILIUM_CLI_VERSION")
  HELM_V=$(resolve_version        HELM        helm/helm                    "$FALLBACK_HELM"        "$HELM_VERSION")
  GATEWAY_API_V=$(resolve_version GATEWAY_API kubernetes-sigs/gateway-api  "$FALLBACK_GATEWAY_API" "$GATEWAY_API_VERSION")
  OPENEBS_V=$(resolve_version     OPENEBS     openebs/openebs              "$FALLBACK_OPENEBS"     "$OPENEBS_VERSION")

  # 工件缓存路径(30 下载, 40/60 安装共用同一真相源)
  A_RUNC="$CACHE_DIR/runc/$RUNC_V/runc.$ARCH"
  A_RUNC_SUM="$CACHE_DIR/runc/$RUNC_V/runc.sha256sum"
  A_CONTAINERD_TGZ="$CACHE_DIR/containerd/$CONTAINERD_V/containerd-${CONTAINERD_V#v}-linux-$ARCH.tar.gz"
  A_CONTAINERD_SVC="$CACHE_DIR/containerd/$CONTAINERD_V/containerd.service"
  A_CRICTL_TGZ="$CACHE_DIR/crictl/$CRICTL_V/crictl-$CRICTL_V-linux-$ARCH.tar.gz"
  A_CILIUM_CLI_TGZ="$CACHE_DIR/cilium-cli/$CILIUM_CLI_V/cilium-linux-$ARCH.tar.gz"
  A_HELM_TGZ="$CACHE_DIR/helm/$HELM_V/helm-$HELM_V-linux-$ARCH.tar.gz"
  A_GWAPI_YAML="$CACHE_DIR/gateway-api/$GATEWAY_API_V/standard-install.yaml"
  _VERSIONS_READY=1
}

print_versions() {
  ensure_versions
  log_info "版本集(versions.lock 已锁定, 删除该文件可重新解析最新版):"
  log_info "  Kubernetes $K8S_STABLE_V (仓库 v$K8S_MINOR_V) | containerd $CONTAINERD_V | runc $RUNC_V | crictl $CRICTL_V"
  log_info "  Cilium $CILIUM_V (CLI $CILIUM_CLI_V) | Helm $HELM_V | Gateway-API $GATEWAY_API_V | OpenEBS $OPENEBS_V"
}
