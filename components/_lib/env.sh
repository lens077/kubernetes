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

# --------------------------- 凭据: ESO 优先, get_cred 显式降级 ----------------
# 2026-09-11 起凭据真相源是 OpenBao/Vault(config.env ESO_STORE 指定的 ClusterSecretStore),
# 组件不再自己 create secret; 改为 apply 同目录的 externalsecret.yaml, 由 ESO 物化成同名 Secret。
# 降级: OFFLINE=1 或 store 未就绪 → 退回 get_cred + create secret(旧路径), 但要显式警告——
#   这时集群里的值与 OpenBao 不一致, 后续 openbao-seed.sh 会以集群现值为准回填。
eso_store_ready() {  # eso_store_ready [store名]
  local store=${1:-${ESO_STORE:-openbao}}
  [[ $(kctl get clustersecretstore "$store" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]
}

# 让 ESO 立刻刷新(不等 refreshInterval): 改 force-sync 注解
eso_force_sync() {  # eso_force_sync <ns> <externalsecret名>
  kctl -n "$1" annotate externalsecret "$2" "force-sync=$(date +%s)" --overwrite >/dev/null
}

_es_synced() { [[ $(kctl -n "$1" get externalsecret "$2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null) == SecretSynced ]]; }

# 用 ESO 物化凭据 Secret。成功返回 0 且 Secret 已 SecretSynced; 降级返回 2(调用方自己走 get_cred)。
#   cred_via_eso <组件目录> <ns> <ExternalSecret名(=目标 Secret 名)>
# 前置: <组件目录>/externalsecret.yaml 存在(模板, ${CLUSTER_NAME}/${ESO_STORE} 等由 render_tpl 替换)。
cred_via_eso() {  # cred_via_eso <dir> <ns> <name>
  local dir=$1 ns=$2 name=$3 out before after
  [[ -f $dir/externalsecret.yaml ]] || { log_warn "$ID: 没有 externalsecret.yaml, 走 get_cred"; return 2; }
  if [[ ${OFFLINE:-0} == 1 ]]; then
    log_warn "$ID: OFFLINE=1, 跳过 ESO, 走 get_cred(集群值与 OpenBao 可能不一致)"; return 2
  fi
  if ! eso_store_ready; then
    log_warn "$ID: ClusterSecretStore ${ESO_STORE:-openbao} 未就绪(OpenBao sealed? token 过期?), 走 get_cred 降级
  → 恢复后重跑本组件 install.sh 即切回 ESO; 或 OFFLINE=1 明确接受降级"
    return 2
  fi
  before=$(kctl -n "$ns" get secret "$name" -o jsonpath='{.data}' 2>/dev/null | sha256sum | cut -c1-12 || true)
  out=$(mktemp); render_tpl "$dir/externalsecret.yaml" "$out"
  retry 3 5 kctl apply -f "$out" >/dev/null; rm -f "$out"
  eso_force_sync "$ns" "$name"
  wait_for "ESO 物化 $ns/$name" 90 _es_synced "$ns" "$name" \
    || { log_warn "$ID: ExternalSecret $ns/$name 未同步: $(kctl -n "$ns" get externalsecret "$name" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)
  → OpenBao 里 $(comp_vault_path 2>/dev/null || echo 'k8s/<集群>/'"$ID") 是否已 seed(tools/openbao-seed.sh)?"; return 2; }
  after=$(kctl -n "$ns" get secret "$name" -o jsonpath='{.data}' | sha256sum | cut -c1-12)
  ESO_SECRET_CHANGED=$([[ -n $before && $before != "$after" ]] && echo 1 || echo 0)
  log_ok "$ID: 凭据 Secret $ns/$name 由 ESO 物化(${ESO_STORE:-openbao} ← $(comp_vault_path 2>/dev/null || true))$([[ $ESO_SECRET_CHANGED == 1 ]] && echo ', 值已变')"
  return 0
}

# --------------------------- 组件元数据 -------------------------------------
# component.env 字段见 components/_template/component.env
comp_load_meta() {  # comp_load_meta <组件目录>
  local dir=$1
  [[ -f $dir/component.env ]] || die "缺少 $dir/component.env"
  ID="" NAMESPACE="" DEFAULT_ENABLED=true DEPENDS_ON="" EST_MEM_MI=0
  HELM_REPO="" HELM_CHART="" RELEASE="" EXPOSE=none HOSTNAME=""
  # 依赖契约(2026-09-11, 见 _template/component.env「依赖契约」段): 消费方(Config Center harvest)
  # 只认这些字段, 不猜 svc 名/端口/凭据在哪。没有 PROVIDES 的组件不参与。
  PROVIDES="" SVC="" PORT="" SCHEME="" DEV_PORT="" DEV_SCHEME=""
  CRED_SECRET="" CRED_KEYS="" CRED_USER="" CA_REF="" VAULT_PATH="" EXTERNAL=false
  # shellcheck disable=SC1090
  source "$dir/component.env"
  [[ -n $ID ]] || die "$dir/component.env 未定义 ID"
  [[ -n $HOSTNAME ]] || HOSTNAME="$ID.${CLUSTER_DOMAIN:-dev.test}"
  [[ -n $DEV_PORT ]] || DEV_PORT=$PORT
  [[ -n $DEV_SCHEME ]] || DEV_SCHEME=$SCHEME
}

# --------------------------- 依赖契约 ---------------------------------------
# Vault/OpenBao 里的 KV 路径按集群分: k8s/<CLUSTER_NAME>/<组件>。两个集群共用一条路径意味着
# 任何一边轮换都会打断另一边(2026-09-11 定稿)。CLUSTER_NAME 来自 config.env。
comp_vault_path() {  # comp_vault_path → k8s/<集群>/<VAULT_PATH|ID>
  [[ -n ${CLUSTER_NAME:-} ]] || die "config.env 未定义 CLUSTER_NAME(Vault 路径按集群分, 不能省)"
  echo "k8s/$CLUSTER_NAME/${VAULT_PATH:-$ID}"
}

# 解析 CA_REF: "secret:<ns>/<name>:<key>" 或 "configmap:<ns>/<name>:<key>" → 打印 PEM
comp_ca_pem() {  # comp_ca_pem [CA_REF]
  local ref=${1:-$CA_REF} kind rest ns name key
  [[ -n $ref ]] || return 1
  kind=${ref%%:*}; rest=${ref#*:}
  ns=${rest%%/*}; rest=${rest#*/}; name=${rest%%:*}; key=${rest#*:}
  case $kind in
    secret)    kctl -n "$ns" get secret "$name" -o jsonpath="{.data.${key//./\\.}}" | base64 -d ;;
    configmap) kctl -n "$ns" get cm "$name" -o jsonpath="{.data.${key//./\\.}}" ;;
    *) die "CA_REF 格式错误: $ref(应为 secret:<ns>/<name>:<key> 或 configmap:<ns>/<name>:<key>)" ;;
  esac
}

# 校验已加载组件的契约与集群现状是否一致。声明优先于发现: chart 升级改了 svc 名/端口,
# 这里在部署阶段就报错, 不会把错地址带进 Config Center。输出问题行, 返回非 0 表示有问题。
contract_verify() {  # contract_verify → 问题列表(stdout), 0=通过
  [[ -n $PROVIDES ]] || return 0
  local bad=0 k ns name key
  [[ -n $SVC && -n $PORT && -n $SCHEME ]] || { echo "$ID: PROVIDES=$PROVIDES 但 SVC/PORT/SCHEME 不全"; bad=1; }
  if [[ $EXTERNAL != true && -n $SVC ]]; then
    # 集群内: SVC 形如 <name>.<ns>.svc[.cluster.local]; 必须真的有这个 Service 且开了这个端口
    name=${SVC%%.*}; ns=${SVC#*.}; ns=${ns%%.*}
    if ! kctl -n "$ns" get svc "$name" >/dev/null 2>&1; then
      echo "$ID: Service $ns/$name 不存在(声明 SVC=$SVC)"; bad=1
    else
      # 不用 cmd | grep -q: pipefail 下 grep -q 提前退出让上游吃 SIGPIPE, 整条管道非 0(节点上实测误报)
      local ports; ports=$(kctl -n "$ns" get svc "$name" -o jsonpath='{.spec.ports[*].port}')
      grep -qx "$PORT" <<<"${ports// /$'\n'}" || { echo "$ID: Service $ns/$name 没有端口 $PORT(实际: $ports)"; bad=1; }
    fi
  fi
  if [[ -n $CRED_SECRET ]]; then
    ns=${CRED_SECRET%%/*}; name=${CRED_SECRET#*/}
    if ! kctl -n "$ns" get secret "$name" >/dev/null 2>&1; then
      echo "$ID: 凭据 Secret $CRED_SECRET 不存在(ESO 未物化? ExternalSecret 状态: $(kctl -n "$ns" get externalsecret "$name" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo 无))"; bad=1
    else
      for k in $CRED_KEYS; do
        [[ -n $(kctl -n "$ns" get secret "$name" -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null) ]] \
          || { echo "$ID: Secret $CRED_SECRET 缺少键 $k"; bad=1; }
      done
    fi
  fi
  if [[ -n $CA_REF ]]; then
    local pem; pem=$(comp_ca_pem "$CA_REF" 2>/dev/null || true)
    [[ $pem == *"BEGIN CERTIFICATE"* ]] || { echo "$ID: CA_REF=$CA_REF 取不到 PEM"; bad=1; }
  fi
  return $bad
}

# 契约的机器可读形态(JSON, 不含凭据值; 凭据由消费方按 cred_secret 自己去读)。
# 地址按消费方位置给两份: pre(集群内 DNS) 与 dev(网关域名 + 必须带 CA)。
contract_json() {  # contract_json → 单行 JSON
  [[ -n $PROVIDES ]] || return 0
  local vp=""; [[ -n ${CLUSTER_NAME:-} ]] && vp=$(comp_vault_path)
  jq -nc --arg id "$ID" --arg provides "$PROVIDES" --arg external "$EXTERNAL" \
    --arg svc "$SVC" --arg port "$PORT" --arg scheme "$SCHEME" \
    --arg host "$HOSTNAME" --arg dport "$DEV_PORT" --arg dscheme "$DEV_SCHEME" \
    --arg cs "$CRED_SECRET" --arg ck "$CRED_KEYS" --arg cu "$CRED_USER" --arg ca "$CA_REF" --arg vp "$vp" \
    '{id:$id, provides:$provides, external:($external=="true"),
      pre:{host:$svc, port:($port|tonumber? // $port), scheme:$scheme},
      dev:{host:(if $external=="true" then $svc else $host end), port:($dport|tonumber? // $dport), scheme:$dscheme},
      cred:{secret:$cs, keys:($ck|split(" ")|map(select(.!=""))), user:$cu}, ca_ref:$ca, vault_path:$vp}'
}

# 组件目录(供 install.sh 自定位): comp_dir "${BASH_SOURCE[0]}"
comp_dir() { cd -- "$(dirname -- "$1")" &>/dev/null && pwd; }

# --------------------------- 常用动作 ---------------------------------------
ns_ensure() { kctl create namespace "$1" --dry-run=client -o yaml | kctl apply -f -; }

# 模板渲染: 只替换白名单里的 ${VAR}, 不做 shell 求值(避免 values 里的 $ 被误展开)
render_tpl() {  # render_tpl <模板> <输出> [额外变量名...]
  local src=$1 out=$2; shift 2
  local vars=(SC_NAME SC_FS_TYPE CLUSTER_DOMAIN CLUSTER_NAME ESO_STORE VAULT_KV_PATH TIMEZONE NAMESPACE RELEASE HOSTNAME
              CILIUM_LB_POOL_START CILIUM_LB_POOL_STOP CILIUM_GATEWAY_LB_IP
              # config.env 里各组件的容量/保留期旋钮
              VM_STORAGE_SIZE LOKI_STORAGE_SIZE LOKI_RETENTION GRAFANA_STORAGE_SIZE
              MEILI_STORAGE_SIZE MINIO_STORAGE_SIZE JAEGER_STORAGE_SIZE CONSUL_STORAGE_SIZE
              TEMPO_STORAGE_SIZE TEMPO_RETENTION REDIS_STORAGE_SIZE REDIS_MAXMEMORY
              SEATA_STORAGE_SIZE
              HARBOR_REGISTRY_STORAGE_SIZE HARBOR_JOB_STORAGE_SIZE
              HARBOR_DATABASE_STORAGE_SIZE HARBOR_REDIS_STORAGE_SIZE HARBOR_TRIVY_STORAGE_SIZE
              DRAGONFLY_MAXMEMORY DRAGONFLY_PROACTOR_THREADS
              KURED_REBOOT_WINDOW_START KURED_REBOOT_WINDOW_END
              # 2026-09-03 观测/告警/运维保障层(vmalert/alertmanager/victoria-traces/gatus/healthchecks/bugsink)
              VT_STORAGE_SIZE VT_RETENTION VT_DISK_CAP ALERTMANAGER_STORAGE_SIZE
              GATUS_STORAGE_SIZE HEALTHCHECKS_STORAGE_SIZE BUGSINK_STORAGE_SIZE BUGSINK_EVENT_RETENTION_DAYS "$@")
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

# 不少 helm 仓库(prometheus-community/autoscaler/vector/openbao/open-telemetry...)的 index 把 chart 包
# 指到 github.com/<org>/<repo>/releases/download/...; 机房直连 github.com 极不稳定(2026-09-06 五个组件
# 同时超时)。安装器自己的工件下载走 GITHUB_PROXY 前缀, 这里让 chart 包也走同一条路:
# 从本地 helm 仓库索引解析出 tgz URL, 是 github.com 且配置了 GITHUB_PROXY 就经代理下载到缓存,
# 再用本地包安装。任一步失败都回退到原来的 repo/chart 方式, 不改变行为。
# 输出: 可直接交给 helm 的 chart 引用(本地 tgz 路径, 或原样 HELM_CHART)。
helm_chart_ref_via_github_proxy() {  # helm_chart_ref_via_github_proxy <repo/chart> <version>
  local chart=$1 version=$2
  [[ -n ${GITHUB_PROXY:-} && -n $version && $chart == */* && $chart != oci://* ]] || { echo "$chart"; return 0; }
  local repo=${chart%%/*} name=${chart#*/}
  local index="${HELM_CACHE_HOME:-$HOME/.cache/helm}/repository/${repo}-index.yaml"
  [[ -f $index ]] || { echo "$chart"; return 0; }
  local url
  url=$(python3 - "$index" "$name" "$version" <<'PY' 2>/dev/null
import sys, yaml
index, name, version = sys.argv[1:]
with open(index, encoding="utf-8") as f:
    doc = yaml.safe_load(f) or {}
for entry in (doc.get("entries") or {}).get(name) or []:
    if str(entry.get("version")) == version and entry.get("urls"):
        print(entry["urls"][0]); break
PY
  ) || url=""
  [[ $url == https://github.com/* ]] || { echo "$chart"; return 0; }
  local out="$CACHE_DIR/charts/${name}-${version}.tgz"
  mkdir -p "$CACHE_DIR/charts"
  if [[ ! -s $out ]]; then
    local proxied; proxied=$(gh_url "$url")
    if ! retry 3 5 curl -fsSL --connect-timeout 10 --max-time 120 -o "$out.part" "$proxied" >&2; then
      rm -f "$out.part"
      log_warn "$name-$version: 经 GITHUB_PROXY 下载 chart 失败, 回退 helm 直连" >&2
      echo "$chart"; return 0
    fi
    mv -f "$out.part" "$out"
    log_info "$name-$version: chart 已经 GITHUB_PROXY 缓存到 $out" >&2
  fi
  echo "$out"
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
  # 从附加参数里找 --version, 决定能否走 GITHUB_PROXY 缓存包
  local version="" i chart_ref
  for ((i = 1; i <= $#; i++)); do
    [[ ${!i} == --version ]] && { local j=$(( i + 1 )); version=${!j:-}; break; }
    [[ ${!i} == --version=* ]] && { version=${!i#--version=}; break; }
  done
  chart_ref=$(helm_chart_ref_via_github_proxy "$HELM_CHART" "$version")
  retry 2 10 helm_cmd upgrade --install "${RELEASE:-$ID}" "$chart_ref" \
    --namespace "$NAMESPACE" --create-namespace "${values_arg[@]}" "$@"
  [[ -n $rendered ]] && rm -f "$rendered"
  return 0
}

# 某组件是否已装(供依赖判断; 查集群而非查选择清单, 独立执行时也准确)
comp_installed() {  # comp_installed <命名空间> <Service 名>
  kctl -n "$1" get svc "$2" >/dev/null 2>&1
}
