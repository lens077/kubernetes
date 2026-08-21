#!/usr/bin/env bash
# =============================================================================
# 80-components —— 组件安装编排器(交互多选; --yes 时按 config.env)
#
#   本阶段**不含任何 helm values**。每个组件的安装细节都在 components/<id>/ 里:
#     component.env  元数据(命名空间/依赖/开关/就绪判据)
#     install.sh     幂等安装(helm 优先), 也可脱离安装器单独执行
#     values.yaml    values 模板(${SC_NAME} 等占位符)
#     gateway/       Cilium Gateway API 路由
#
#   编排器只做四件事: 扫描 → 选择 → 拓扑排序后并行调用 install.sh → 就绪等待与凭据汇总
#
#   选择结果持久化: 重跑沿用上次选择; 变更选择用 start.sh --reset-state 80-components
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

COMPONENTS_DIR="$(dirname "$K8S_BASE_DIR")/components"
SELECTED_FILE="$STATE_DIR/components.selected"
CREDS_FILE="/root/.k8s-installer-credentials"

[[ -d $COMPONENTS_DIR ]] || die "找不到组件目录 $COMPONENTS_DIR"

# --- 1. 扫描组件 --------------------------------------------------------------------------
# 组件目录以 _ 开头的是基础设施(_lib/_template), 不参与扫描
declare -a COMP_IDS=()
declare -A C_NS=() C_GROUP=() C_DEFAULT=() C_DEPS=() C_MEM=() C_DESC=() C_VAR=() C_READY=()

scan_components() {
  local dir id
  for dir in "$COMPONENTS_DIR"/*/; do
    id=$(basename "$dir")
    [[ $id == _* ]] && continue
    [[ -f $dir/component.env ]] || { log_warn "跳过 $id: 缺 component.env(尚未迁移)"; continue; }
    [[ -f $dir/install.sh ]]    || { log_warn "跳过 $id: 缺 install.sh(尚未迁移)"; continue; }
    (
      # 子 shell 里读, 避免组件变量污染编排器
      # shellcheck disable=SC1091
      source "$dir/component.env"
      # 分隔符用 \x1f(unit separator)而不是制表符: tab 属于 IFS 空白字符, 连续两个
      # 会被 read 折叠成一个 —— DEPENDS_ON 为空时后面字段全部左移一位, CONFIG_VAR
      # 拿到 READY_CHECK 的值, 报 "deploy/xxx: invalid variable name"(实测踩过)
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "${ID:-$id}" "${NAMESPACE:-default}" "${GROUP:-infra}" "${DEFAULT_ENABLED:-false}" \
        "${DEPENDS_ON:-}" "${EST_MEM_MI:-100}" "${CONFIG_VAR:-}" "${READY_CHECK:-}"
    )
  done
}

load_components() {
  local id ns group def deps mem var ready desc
  while IFS=$'\x1f' read -r id ns group def deps mem var ready; do
    [[ -n $id ]] || continue
    COMP_IDS+=("$id")
    C_NS[$id]=$ns; C_GROUP[$id]=$group; C_DEFAULT[$id]=$def
    C_DEPS[$id]=$deps; C_MEM[$id]=$mem; C_VAR[$id]=$var; C_READY[$id]=$ready
    desc=$(sed -n '1{/^#!/d}; s/^# *//p' "$COMPONENTS_DIR/$id/README.md" 2>/dev/null | head -1)
    C_DESC[$id]=${desc:-$id}
  done < <(scan_components)
  (( ${#COMP_IDS[@]} > 0 )) || die "$COMPONENTS_DIR 下没有可安装的组件"
  log_info "发现 ${#COMP_IDS[@]} 个组件: ${COMP_IDS[*]}"
}

# config.env 里的开关(CONFIG_VAR 显式声明, 避免目录名与变量名的映射靠猜)
comp_default_on() {
  local id=$1 var=${C_VAR[$1]}
  if [[ -n $var && -n ${!var:-} ]]; then
    [[ ${!var} == true ]]
  else
    [[ ${C_DEFAULT[$id]} == true ]]
  fi
}

comp_selected() { grep -qx "$1" "$SELECTED_FILE" 2>/dev/null; }

# --- 2. 选择组件 --------------------------------------------------------------------------
select_components() {
  local i sel=() choice mem_avail id
  for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do
    comp_default_on "${COMP_IDS[i]}" && sel[i]=1 || sel[i]=0
  done

  if is_interactive; then
    mem_avail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
    while true; do
      {
        echo
        echo "可选组件(当前可用内存 ${mem_avail}Mi; 编号切换, a=全选, n=全不选, o=可观测性组全选, 回车=确认):"
        local total=0 prev_group=""
        for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do
          id=${COMP_IDS[i]}
          if [[ ${C_GROUP[$id]} != "$prev_group" ]]; then
            prev_group=${C_GROUP[$id]}
            case $prev_group in
              base)  echo "  ── 基础 ──" ;;
              obs)   echo "  ── 可观测性 ──" ;;
              infra) echo "  ── 基础设施 ──" ;;
              *)     echo "  ── $prev_group ──" ;;
            esac
          fi
          printf '  [%s] %d) %-16s %-30s ~%sMi\n' \
            "$( ((sel[i])) && echo x || echo ' ')" "$((i+1))" "$id" "${C_DESC[$id]:0:30}" "${C_MEM[$id]}"
          ((sel[i])) && total=$(( total + C_MEM[$id] ))
        done
        echo "  已选组件预估内存: ~${total}Mi"
      } >/dev/tty
      printf '选择> ' >/dev/tty
      read -r choice </dev/tty || choice=""
      case $choice in
        "") break ;;
        a|A) for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do sel[i]=1; done ;;
        n|N) for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do sel[i]=0; done ;;
        o|O) for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do [[ ${C_GROUP[${COMP_IDS[i]}]} == obs ]] && sel[i]=1; done ;;
        *[!0-9]*) ;;
        *) (( choice >= 1 && choice <= ${#COMP_IDS[@]} )) && sel[choice-1]=$(( 1 - sel[choice-1] )) ;;
      esac
    done
  fi

  : > "$SELECTED_FILE"
  local total=0
  for ((i = 0; i < ${#COMP_IDS[@]}; i++)); do
    if ((sel[i])); then
      echo "${COMP_IDS[i]}" >> "$SELECTED_FILE"
      total=$(( total + C_MEM[${COMP_IDS[i]}] ))
    fi
  done

  # 依赖补全: 选了 A 但没选 A 依赖的 B, 自动补上(否则 A 装完是半残的)
  local changed=1 dep
  while (( changed )); do
    changed=0
    for id in $(cat "$SELECTED_FILE"); do
      for dep in ${C_DEPS[$id]:-}; do
        if [[ -n ${C_NS[$dep]:-} ]] && ! comp_selected "$dep"; then
          echo "$dep" >> "$SELECTED_FILE"
          total=$(( total + C_MEM[$dep] ))
          log_info "按依赖自动补选: $dep (被 $id 依赖)"
          changed=1
        fi
      done
    done
  done
  log_info "已选组件: $(tr '\n' ' ' < "$SELECTED_FILE")(预估 ~${total}Mi)"

  local mem_avail_now=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
  if (( total > mem_avail_now * 8 / 10 )); then
    log_warn "预估内存(${total}Mi)超过当前可用内存(${mem_avail_now}Mi)的 80%, 可能出现 OOM/Pending"
    if is_interactive; then
      confirm "内存偏紧, 仍然继续安装所选组件?" N || die "已取消, 请重新选择(start.sh --reset-state 80-components)"
    else
      log_warn "非交互模式: 按 config.env 配置继续, 请自行确认内存余量"
    fi
  fi
  return 0
}

# --- 3. 拓扑排序(同层并行, 层间串行) -------------------------------------------------------
# 输出: 每行一层, 层内组件空格分隔
topo_layers() {
  local -A remaining=()
  local id
  while read -r id; do [[ -n $id ]] && remaining[$id]=1; done < "$SELECTED_FILE"

  local guard=0
  # 判断放在 OR 条件链中，避免 process substitution 继承 ERR trap 后把正常退出误报为失败。
  while :; do
    [[ ${#remaining[@]} -gt 0 ]] || break
    local layer=() dep ready
    for id in "${!remaining[@]}"; do
      ready=1
      for dep in ${C_DEPS[$id]:-}; do
        # 只等"这次也要装"的依赖; 已装过或没选的不阻塞
        [[ -n ${remaining[$dep]:-} ]] && ready=0
      done
      (( ready )) && layer+=("$id")
    done
    if (( ${#layer[@]} == 0 )); then
      log_warn "组件依赖存在环, 剩余组件改为同层安装: ${!remaining[*]}"
      layer=("${!remaining[@]}")
    fi
    # 层内按 id 排序, 保证重复执行输出一致
    printf '%s\n' "$(printf '%s\n' "${layer[@]}" | sort | tr '\n' ' ')"
    for id in "${layer[@]}"; do unset 'remaining[$id]'; done
    (( ++guard > 20 )) && die "拓扑排序未收敛(层数 > 20)"
  done
}

# --- 4. 并行调用各组件 install.sh -----------------------------------------------------------
declare -A JOB_PID=() JOB_LOG=()
start_job() {
  local id=$1
  local logf="$LOG_DIR/component-$id.log"
  : > "$logf"
  (
    # 组件脚本是独立子进程: 通过环境变量传上下文, 不共享函数栈
    export K8S_COMP_PARENT=1 ASSUME_YES=true
    bash "$COMPONENTS_DIR/$id/install.sh"
  ) >>"$logf" 2>&1 &
  JOB_PID[$id]=$!
  JOB_LOG[$id]=$logf
  log_info "并行安装启动: $id"
}

wait_layer() {
  local id pid failed=()
  local deadline=$(( SECONDS + ${COMPONENT_INSTALL_TIMEOUT:-900} ))
  for id in "${!JOB_PID[@]}"; do
    pid=${JOB_PID[$id]}
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 5; done
    if kill -0 "$pid" 2>/dev/null; then
      # 看门狗: 超时杀进程树, 防单个组件挂死拖垮整个阶段
      pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true
      failed+=("$id")
      log_error "安装超时(>${COMPONENT_INSTALL_TIMEOUT:-900}s)已终止: $id (日志: ${JOB_LOG[$id]})"
      continue
    fi
    if wait "$pid"; then
      log_ok "安装提交完成: $id"
      touch "$STATE_DIR/state/80-components:component-$id.done"
    else
      failed+=("$id")
      log_error "安装失败: $id (日志: ${JOB_LOG[$id]})"
      tail -n 8 "${JOB_LOG[$id]}" >&2 || true
    fi
  done
  JOB_PID=(); JOB_LOG=()
  (( ${#failed[@]} == 0 )) || { FAILED_ALL+=("${failed[@]}"); return 1; }
  return 0
}

FAILED_ALL=()
install_selected() {
  if [[ ! -s $SELECTED_FILE ]]; then
    log_info "未选择任何组件, 跳过"
    return 0
  fi
  local layer id n=0
  while read -r layer; do
    [[ -n ${layer// /} ]] || continue
    n=$((n + 1))
    log_step "第 $n 层: $layer"
    for id in $layer; do
      if [[ -f "$STATE_DIR/state/80-components:component-$id.done" ]]; then
        log_skip "组件已装过, 跳过: $id"
        continue
      fi
      start_job "$id"
    done
    # 依赖层失败就不再往下装(下一层大概率也会失败, 早停比堆一屏错误强)
    wait_layer || die "第 $n 层有组件失败: ${FAILED_ALL[*]} — 修复后重跑本阶段"
  done < <(topo_layers)
}

# --- 5. 就绪等待(镜像拉取受网络影响, 未就绪降级为警告, 不阻断主流程) -----------------------
# READY_CHECK 语法: "deploy/名字" 或 "statefulset/名字|deploy/名字"(候选依次尝试), 空则跳过
wait_components() {
  [[ -s $SELECTED_FILE ]] || return 0
  local id pending=() cand ok
  while read -r id; do
    [[ -n ${C_READY[$id]:-} ]] || continue
    ok=0
    for cand in ${C_READY[$id]//|/ }; do
      if kctl -n "${C_NS[$id]}" rollout status "$cand" --timeout=300s 2>/dev/null; then ok=1; break; fi
    done
    (( ok )) || pending+=("$id")
  done < "$SELECTED_FILE"
  if (( ${#pending[@]} > 0 )); then
    log_warn "以下组件尚未就绪(通常是镜像仍在拉取): ${pending[*]}"
    log_warn "稍后可用 kubectl get pods -A 观察; 或重跑 90 阶段复检"
  fi
  return 0
}

# --- 6. 凭据与入口汇总 ----------------------------------------------------------------------
# 每个组件可选提供 summary.sh: 打印一行"怎么访问/密码在哪", 由本函数汇总落盘
write_creds_summary() {
  [[ -s $SELECTED_FILE ]] || return 0
  touch "$CREDS_FILE"; chmod 600 "$CREDS_FILE"
  local id content="" line
  while read -r id; do
    [[ -f "$COMPONENTS_DIR/$id/summary.sh" ]] || continue
    line=$(bash "$COMPONENTS_DIR/$id/summary.sh" 2>/dev/null) || continue
    [[ -n $line ]] && content+="$line"$'\n'
  done < "$SELECTED_FILE"
  [[ -n $content ]] && ensure_block "$CREDS_FILE" "component-credentials" "${content%$'\n'}"
  log_info "组件访问凭据已写入 $CREDS_FILE (chmod 600)"
  return 0
}

main() {
  stage_begin "80-components" "组件安装(可选)"
  load_components
  add_step select  "选择组件"                select_components
  add_step install "调用各组件 install.sh"   install_selected
  add_step wait    "等待组件就绪(软性)"      wait_components
  add_step creds   "汇总访问凭据"            write_creds_summary
  run_steps
  stage_end
}
main "$@"
