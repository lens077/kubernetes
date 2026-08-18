# shellcheck shell=bash
# shellcheck disable=SC2034  # 同 common.sh: 大量变量供 source 方(组件 install.sh)使用
# =============================================================================
# components/_lib/env.sh —— 组件脚本的统一自举
#
# 每个 components/<组件>/install.sh 的开头 source 它:
#   source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
#
# 两种运行方式行为一致:
#   1. bootstrap/scripts/80-components.sh 以子进程调用(带 K8S_COMP_PARENT=1)
#   2. 直接 bash components/<组件>/install.sh 单独执行(自己回溯 bootstrap/config.env)
#
# 与安装器的边界: 这里只操作集群(kubectl/helm), 不碰节点系统。因此除节点本机外,
# 任何有 kubectl + helm 且能连到 apiserver 的机器都能执行(kubeconfig 自动适配)。
# =============================================================================

[[ -n ${_K8S_COMP_ENV_LOADED:-} ]] && return 0
_K8S_COMP_ENV_LOADED=1

# bash 版本闸门(必须在用到 bash4 语法之前, 因此这段只用 3.2 也能解析的写法)。
# 不加这段的话, 在 macOS 自带 bash 3.2 上执行组件脚本会静默退出 127 —— 实测踩过。
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "组件脚本需要 bash >= 4.2(关联数组 / printf %(%T)), 当前是 ${BASH_VERSION:-未知}" >&2
  echo "  macOS 自带的是 bash 3.2 —— 用 brew install bash 后以新 bash 执行, 或直接登到节点上跑" >&2
  exit 1
fi

COMP_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
COMPONENTS_DIR=$(dirname "$COMP_LIB_DIR")
REPO_ROOT=$(dirname "$COMPONENTS_DIR")
BOOTSTRAP_DIR="$REPO_ROOT/bootstrap"

[[ -f $BOOTSTRAP_DIR/lib/common.sh ]] \
  || { echo "找不到 $BOOTSTRAP_DIR/lib/common.sh (组件目录是否被单独拷出了仓库?)" >&2; exit 1; }

# common.sh 自带 _K8S_COMMON_LOADED 守卫, 重复 source 无副作用;
# 它只定义变量与函数(外加 source config.env), 不会写系统
# shellcheck source=../../bootstrap/lib/common.sh
source "$BOOTSTRAP_DIR/lib/common.sh"

# --------------------------- 状态目录适配 -----------------------------------
# common.sh 默认把状态/日志放 /var/lib|/var/log(节点上 root 运行的前提)。
# 非 root 或非节点机器上回退到用户目录, 否则第一条日志就会 mkdir 失败。
if [[ ! -w /var/lib && ! -w $STATE_DIR ]]; then
  _fallback="${XDG_STATE_HOME:-$HOME/.local/state}/k8s-installer"
  STATE_DIR="$_fallback"
  BACKUP_DIR="$STATE_DIR/backups"
  CACHE_DIR="$_fallback/cache"
  LOG_DIR="$_fallback/log"
  VERSIONS_LOCK="$STATE_DIR/versions.lock"
  MAIN_LOG="$LOG_DIR/install.log"
  mkdir -p "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR"
  unset _fallback
fi

# --------------------------- kubeconfig 适配 --------------------------------
# common.sh 的 kctl/helm_cmd 写死 /etc/kubernetes/admin.conf(节点上正确)。
# 该文件不存在时改用调用者环境的 KUBECONFIG / ~/.kube/config。
if [[ ! -r /etc/kubernetes/admin.conf ]]; then
  kctl()     { kubectl "$@"; }
  helm_cmd() { with_proxy helm "$@"; }
fi

comp_require_cluster() {
  command -v kubectl >/dev/null || die "未找到 kubectl"
  command -v helm    >/dev/null || die "未找到 helm"
  kctl version -o json >/dev/null 2>&1 || kctl cluster-info >/dev/null 2>&1 \
    || die "kubectl 连不上集群(检查 KUBECONFIG 或在节点上执行)"
}

# --------------------------- 凭据 -------------------------------------------
# 密码只生成一次, 之后重复执行取同一个值 → 重装不改密码。
# (原先定义在 80-addons.sh 里, 组件独立执行时取不到, 现在收进公共库)
get_cred() {  # get_cred <名字>
  local f="$STATE_DIR/creds/$1"
  if [[ ! -f $f ]]; then
    mkdir -p "$STATE_DIR/creds"
    openssl rand -hex 12 > "$f"
    chmod 600 "$f"
  fi
  cat "$f"
}

# --------------------------- 组件元数据 -------------------------------------
# component.env 字段见 components/_template/component.env
comp_load_meta() {  # comp_load_meta <组件目录>
  local dir=$1
  [[ -f $dir/component.env ]] || die "缺少 $dir/component.env"
  ID="" NAMESPACE="" DEFAULT_ENABLED=true DEPENDS_ON="" EST_MEM_MI=0
  HELM_REPO="" HELM_CHART="" RELEASE="" EXPOSE=none HOSTNAME=""
  # shellcheck disable=SC1090
  source "$dir/component.env"
  [[ -n $ID ]] || die "$dir/component.env 未定义 ID"
  [[ -n $HOSTNAME ]] || HOSTNAME="$ID.${CLUSTER_DOMAIN:-dev.test}"
}

# 组件目录(供 install.sh 自定位): comp_dir "${BASH_SOURCE[0]}"
comp_dir() { cd -- "$(dirname -- "$1")" &>/dev/null && pwd; }

# --------------------------- 常用动作 ---------------------------------------
ns_ensure() { kctl create namespace "$1" --dry-run=client -o yaml | kctl apply -f -; }

# 模板渲染: 只替换白名单里的 ${VAR}, 不做 shell 求值(避免 values 里的 $ 被误展开)
render_tpl() {  # render_tpl <模板> <输出> [额外变量名...]
  local src=$1 out=$2; shift 2
  local vars=(SC_NAME SC_FS_TYPE CLUSTER_DOMAIN TIMEZONE NAMESPACE RELEASE HOSTNAME
              CILIUM_LB_POOL_START CILIUM_LB_POOL_STOP
              # config.env 里各组件的容量/保留期旋钮
              VM_STORAGE_SIZE LOKI_STORAGE_SIZE LOKI_RETENTION GRAFANA_STORAGE_SIZE
              MEILI_STORAGE_SIZE MINIO_STORAGE_SIZE JAEGER_STORAGE_SIZE CONSUL_STORAGE_SIZE
              HARBOR_REGISTRY_STORAGE_SIZE HARBOR_JOB_STORAGE_SIZE
              HARBOR_DATABASE_STORAGE_SIZE HARBOR_REDIS_STORAGE_SIZE HARBOR_TRIVY_STORAGE_SIZE
              DRAGONFLY_MAXMEMORY DRAGONFLY_PROACTOR_THREADS
              KURED_REBOOT_WINDOW_START KURED_REBOOT_WINDOW_END "$@")
  local sed_args=() v
  for v in "${vars[@]}"; do sed_args+=(-e "s|\${$v}|${!v-}|g"); done
  sed "${sed_args[@]}" "$src" > "$out"

  # 白名单漏了变量的话, 占位符会原样进集群且不报任何错(实测: kured 的
  # --start-time 变成了字面量 "${KURED_REBOOT_WINDOW_START}")。这里兜底拦一下。
  local leftover
  leftover=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out" | sort -u | tr '\n' ' ') || true
  [[ -z ${leftover// /} ]] \
    || die "$(basename "$src") 渲染后仍有未替换的占位符: $leftover
  → 把变量名加进 components/_lib/env.sh 的 render_tpl 白名单"
}

# 目录下的有效清单文件(排除隐藏文件与 macOS 的 ._ 伴随文件)。
# 不要直接 kubectl apply -f <目录>: 目录里任何非清单文件(编辑器 .swp、备份、跨平台
# 拷贝产生的 ._*)都会被当 YAML 解析, 整条 apply 失败 —— 实测踩过。
manifest_files() {  # manifest_files <目录>
  local f
  for f in "$1"/*.yaml "$1"/*.yml; do
    [[ -f $f ]] || continue
    case $(basename "$f") in ._*|.*) continue ;; esac
    printf '%s\n' "$f"
  done
}

# 渲染并应用 gateway/ 下的路由清单
# 约定: Gateway 一律不写 addresses, 由 Cilium 从 CiliumLoadBalancerIPPool 自动分配,
#       分配结果用 kubectl get gateway -o wide 查看(旧清单里硬编码 IP 是历史包袱)
routes_apply() {  # routes_apply <组件目录>
  local dir=$1 f out
  [[ -d $dir/gateway ]] || return 0
  if [[ ${CILIUM_ENABLE_GATEWAY_API:-true} != true ]]; then
    log_skip "未启用 Gateway API, 跳过 $ID 的路由"
    return 0
  fi
  if ! kctl get gatewayclass cilium >/dev/null 2>&1; then
    log_warn "GatewayClass cilium 不存在, 跳过 $ID 的路由(先跑 bootstrap 的 60-cilium)"
    return 0
  fi
  out=$(mktemp -d)
  while read -r f; do
    [[ -n $f ]] || continue
    render_tpl "$f" "$out/$(basename "$f")"
    kctl apply -f "$out/$(basename "$f")"
  done < <(manifest_files "$dir/gateway")
  rm -rf "$out"
}

# helm 仓库 + 安装(幂等)。values 走渲染后的临时文件, 不污染仓库工作区。
helm_install_component() {  # helm_install_component <组件目录> [附加 helm 参数...]
  local dir=$1; shift
  [[ -n $HELM_CHART ]] || die "$ID 未定义 HELM_CHART"
  [[ -n $HELM_REPO ]] && helm_repo_add ${HELM_REPO}   # 形如 "vm https://..."; 故意不加引号
  local values_arg=() rendered=""
  if [[ -f $dir/values.yaml ]]; then
    rendered=$(mktemp)
    render_tpl "$dir/values.yaml" "$rendered"
    values_arg=(-f "$rendered")
  fi
  retry 2 10 helm_cmd upgrade --install "${RELEASE:-$ID}" "$HELM_CHART" \
    --namespace "$NAMESPACE" --create-namespace "${values_arg[@]}" "$@"
  [[ -n $rendered ]] && rm -f "$rendered"
  return 0
}

# 某组件是否已装(供依赖判断; 查集群而非查选择清单, 独立执行时也准确)
comp_installed() {  # comp_installed <命名空间> <Service 名>
  kctl -n "$1" get svc "$2" >/dev/null 2>&1
}
