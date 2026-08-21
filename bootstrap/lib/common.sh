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
source "$K8S_BASE_DIR/config.env" || { echo "无法加载 $K8S_BASE_DIR/config.env" >&2; exit 1; }

# CLI 角色覆写(start.sh --worker): 不改 config.env 即可按工作节点安装;
# config 里的 NODE_NAME 属于控制面机器, 覆写时节点名取本机 hostname
if [[ ${K8S_ROLE_OVERRIDE:-} == worker ]]; then
  NODE_ROLE=worker
  NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')
fi

ASSUME_YES=${ASSUME_YES:-false}              # start.sh --yes 时置 true

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
  if [[ $what == all ]]; then rm -f "$STATE_DIR/state/"*.done 2>/dev/null || true
  else rm -f "$STATE_DIR/state/${what}"*.done 2>/dev/null || true; fi
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
Environment="NO_PROXY=localhost,127.0.0.1,$NODE_IP,$POD_CIDR,$SERVICE_CIDR,.cluster.local,10.0.0.0/8,192.168.0.0/16"
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
