#!/usr/bin/env bash
# =============================================================================
# 70-storage —— OpenEBS LVM LocalPV
#   - 交互式选择空闲磁盘建 VG(擦盘属危险操作, 必须原样输入确认词)
#   - 无空闲磁盘时可选回环文件兜底(仅测试; 含开机自动重挂 systemd 单元)
#   - StorageClass 默认 xfs + WaitForFirstConsumer, 面向数据库负载
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

ensure_versions
declare -a SELECTED_DISKS=()

# 空闲磁盘探测函数 list_free_disks 已提取到 lib/common.sh(与 45-etcd-disk 共用)

select_disks_interactive() {
  local free=("$@") sel=() i choice line
  for ((i = 0; i < ${#free[@]}; i++)); do sel[i]=0; done
  while true; do
    {
      echo
      echo "可用于 OpenEBS LVM 的空闲磁盘(输入编号切换选中, a=全选, 回车=完成):"
      for ((i = 0; i < ${#free[@]}; i++)); do
        line=$(lsblk -dno NAME,SIZE,MODEL "${free[i]}" 2>/dev/null || echo "${free[i]}")
        if [[ ${sel[i]} == 1 ]]; then printf '  [x] %d) %s\n' "$((i+1))" "$line"
        else printf '  [ ] %d) %s\n' "$((i+1))" "$line"; fi
      done
    } >/dev/tty
    printf '选择> ' >/dev/tty
    read -r choice </dev/tty || choice=""
    case $choice in
      "") break ;;
      a|A) for ((i = 0; i < ${#free[@]}; i++)); do sel[i]=1; done ;;
      *[!0-9]*) ;;
      *) (( choice >= 1 && choice <= ${#free[@]} )) && sel[choice-1]=$(( 1 - sel[choice-1] )) ;;
    esac
  done
  SELECTED_DISKS=()
  for ((i = 0; i < ${#free[@]}; i++)); do
    [[ ${sel[i]} == 1 ]] && SELECTED_DISKS+=("${free[i]}")
  done
  return 0
}

# --- 回环文件兜底(仅测试环境; 性能与数据安全都不如真实磁盘) ---------------------------
setup_loopback() {
  mkdir -p "$(dirname "$LVM_LOOPBACK_FILE")"
  [[ -f $LVM_LOOPBACK_FILE ]] || truncate -s "$LVM_LOOPBACK_SIZE" "$LVM_LOOPBACK_FILE"
  local dev
  dev=$(losetup -j "$LVM_LOOPBACK_FILE" | cut -d: -f1 | head -1)
  if [[ -z $dev ]]; then
    dev=$(losetup --find --show "$LVM_LOOPBACK_FILE")
  fi
  SELECTED_DISKS=("$dev")

  # loop 设备重启即失, 用 oneshot 单元开机重挂并激活 VG
  cat > /etc/systemd/system/openebs-lvm-loop.service <<EOF
[Unit]
Description=Attach OpenEBS LVM loopback device
DefaultDependencies=no
After=local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'losetup -j "$LVM_LOOPBACK_FILE" | grep -q . || losetup --find "$LVM_LOOPBACK_FILE"; vgchange -ay $LVM_VG_NAME || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable openebs-lvm-loop.service
  log_warn "使用回环文件 $LVM_LOOPBACK_FILE($LVM_LOOPBACK_SIZE) 作为 LVM 底座 — 仅建议测试环境"
}

# --- 1. 建立卷组 -----------------------------------------------------------------------
create_vg() {
  if vgs "$LVM_VG_NAME" &>/dev/null; then
    log_info "卷组 $LVM_VG_NAME 已存在: $(vgs --noheadings -o vg_size,vg_free "$LVM_VG_NAME" | tr -s ' ')"
    return 0
  fi

  local _carved=0
  # "ask" 与留空等价: 划分区选项已并入下方交互菜单
  [[ $LVM_PARTITION_OF == ask ]] && LVM_PARTITION_OF=""

  # 路线一(优先): 显式指定盘时从其尾部未分配空间划分区并入 VG(无终端全自动场景)
  if [[ -n $LVM_PARTITION_OF ]]; then
    if [[ -f $STATE_DIR/lvm.part ]] && [[ -b $(<"$STATE_DIR/lvm.part") ]]; then
      # 崩溃重入: 分区已划过, 复用而不是再划一块
      SELECTED_DISKS=("$(<"$STATE_DIR/lvm.part")")
      _carved=1
      log_info "复用已划出的 LVM 分区: ${SELECTED_DISKS[0]}"
    else
      [[ -b $LVM_PARTITION_OF ]] || die "LVM_PARTITION_OF=$LVM_PARTITION_OF 不是块设备"
      local free_gb want_gb size_desc
      free_gb=$(disk_tail_free_gb "$LVM_PARTITION_OF")
      want_gb=${LVM_PARTITION_SIZE//[!0-9]/}
      size_desc=$LVM_PARTITION_SIZE
      if [[ $LVM_PARTITION_SIZE == 0 ]]; then want_gb=1; size_desc="全部剩余空间(约 ${free_gb}G)"; fi
      (( free_gb >= want_gb )) || die "$LVM_PARTITION_OF 尾部未分配空间仅 ${free_gb}G, 不足 $size_desc"
      # 有终端一律输入确认词; 无终端才要求显式配置授权
      if has_tty; then
        confirm_danger "将在 $LVM_PARTITION_OF 尾部新建分区($size_desc)并入卷组 $LVM_VG_NAME (分区表已自动备份到 $BACKUP_DIR)" \
          "write-partition-table" || die "用户取消, 中止存储分区划分"
      else
        [[ $LVM_WIPE_OK == true ]] || die "无终端确认且未设置 LVM_WIPE_OK=true, 拒绝修改分区表"
      fi
      local part
      part=$(create_tail_partition "$LVM_PARTITION_OF" "$LVM_PARTITION_SIZE" 8e00 openebs)
      SELECTED_DISKS=("$part")
      _carved=1
      echo "$part" > "$STATE_DIR/lvm.part"
      log_ok "已从 $LVM_PARTITION_OF 划出分区: $part"
    fi
  elif (( ${#LVM_DISKS[@]} > 0 )); then
    SELECTED_DISKS=("${LVM_DISKS[@]}")
    # 显式指定的磁盘也必须是"空闲盘", 防止误擦有数据的盘
    local d
    for d in "${SELECTED_DISKS[@]}"; do
      [[ -b $d ]] || die "LVM_DISKS 指定的 $d 不是块设备"
      list_free_disks | grep -qx "$d" || die "$d 非空闲磁盘(存在分区/文件系统/挂载), 拒绝擦除"
    done
  else
    # 统一交互菜单(只要有终端, --yes 也弹): 整盘空闲 / 空分区 / 从尾部未分配空间划分区
    local labels=() kinds=() vals=() sel=() d free_gb entry line i _confirmed=0
    if has_tty; then
      while read -r d; do
        line=$(lsblk -dno NAME,SIZE,MODEL "$d" 2>/dev/null || echo "$d")
        labels+=("[整盘] $line — 整盘擦除并入 VG"); kinds+=(disk); vals+=("$d"); sel+=(0)
      done < <(list_free_disks)
      while read -r entry; do
        d=${entry%%:*}; free_gb=${entry##*:}
        (( free_gb >= 10 )) || continue
        labels+=("[空分区] $d (约 ${free_gb}G) — 直接并入 VG"); kinds+=(part); vals+=("$d"); sel+=(0)
      done < <(list_empty_partitions)
      while read -r d; do
        list_free_disks | grep -qx "$d" && continue
        free_gb=$(disk_tail_free_gb "$d")
        (( free_gb >= 10 )) || continue
        labels+=("[划分区] $d 尾部未分配约 ${free_gb}G — 划分区并入 VG(大小可在确认时指定)")
        kinds+=(carve); vals+=("$d"); sel+=(0)
      done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
    fi

    if (( ${#labels[@]} > 0 )); then
      print_disk_overview
      while true; do
        {
          echo "选择并入卷组 $LVM_VG_NAME 的存储(编号切换选中, a=全选, 回车=完成):"
          for ((i = 0; i < ${#labels[@]}; i++)); do
            if [[ ${sel[i]} == 1 ]]; then printf '  [x] %d) %s\n' "$((i+1))" "${labels[i]}"
            else printf '  [ ] %d) %s\n' "$((i+1))" "${labels[i]}"; fi
          done
        } >/dev/tty
        printf '选择> ' >/dev/tty
        local choice; read -r choice </dev/tty || choice=""
        case $choice in
          "") break ;;
          a|A) for ((i = 0; i < ${#labels[@]}; i++)); do sel[i]=1; done ;;
          *[!0-9]*) ;;
          *) (( choice >= 1 && choice <= ${#labels[@]} )) && sel[choice-1]=$(( 1 - sel[choice-1] )) ;;
        esac
      done

      # 先汇总要整盘擦除的, 一次性确认; 空分区/新划分区无需擦除确认
      local wipe_list=()
      for ((i = 0; i < ${#labels[@]}; i++)); do
        [[ ${sel[i]} == 1 && ${kinds[i]} == disk ]] && wipe_list+=("${vals[i]}")
      done
      if (( ${#wipe_list[@]} > 0 )); then
        confirm_danger "将擦除以下整盘全部数据并入卷组 $LVM_VG_NAME: ${wipe_list[*]}" "wipe-disks" \
          || die "用户取消擦盘, 中止存储配置(可重跑本阶段重新选择)"
      fi
      for ((i = 0; i < ${#labels[@]}; i++)); do
        [[ ${sel[i]} == 1 ]] || continue
        case ${kinds[i]} in
          disk)
            wipefs -a "${vals[i]}"
            SELECTED_DISKS+=("${vals[i]}")
            ;;
          part)
            SELECTED_DISKS+=("${vals[i]}")
            ;;
          carve)
            local size
            size=$(ASSUME_YES=false prompt_input "从 ${vals[i]} 尾部划分区大小(0=全部剩余)" "$LVM_PARTITION_SIZE")
            confirm_danger "将在 ${vals[i]} 尾部新建分区(${size}; 0=全部剩余)并入 $LVM_VG_NAME(分区表自动备份到 $BACKUP_DIR)" \
              "write-partition-table" || { log_warn "已取消 ${vals[i]} 的划分"; continue; }
            local part
            part=$(create_tail_partition "${vals[i]}" "$size" 8e00 openebs)
            echo "$part" > "$STATE_DIR/lvm.part"
            SELECTED_DISKS+=("$part")
            log_ok "已从 ${vals[i]} 划出分区: $part"
            ;;
        esac
      done
      _confirmed=1
    fi

    if (( ${#SELECTED_DISKS[@]} == 0 )); then
      # 有终端时明确问一次回环兜底(默认否); 无终端按 LVM_ALLOW_LOOPBACK 配置走
      local want_loop=false
      if has_tty; then
        ASSUME_YES=false confirm "未选择任何存储, 用回环文件(${LVM_LOOPBACK_SIZE})兜底? 仅建议测试环境" N && want_loop=true
      elif resolve_opt "$LVM_ALLOW_LOOPBACK" "没有选中空闲磁盘, 用回环文件(${LVM_LOOPBACK_SIZE})兜底? 仅建议测试环境" Y; then
        want_loop=true
      fi
      if [[ $want_loop == true ]]; then
        setup_loopback
      elif is_worker; then
        # worker 提供本地存储是可选项: 没有盘就不当存储节点
        log_warn "worker 未配置本地存储盘, 跳过 VG 创建(本节点不提供 LVM 本地卷)"
        touch "$STATE_DIR/worker-no-storage"
        return 0
      else
        die "未选择任何存储且未启用回环兜底 — 请加盘/腾出未分配空间后重跑本阶段"
      fi
    fi
    [[ $_confirmed == 1 ]] && _carved=1   # 菜单路径的擦除/确认已就地完成, 跳过下方通用确认块
  fi

  # 真实磁盘需要擦除确认(回环文件/刚划出的分区/菜单路径已就地确认的, 不再走这里)
  if [[ ${SELECTED_DISKS[0]} != /dev/loop* && $_carved != 1 ]]; then
    if has_tty; then
      confirm_danger "将擦除以下磁盘上的全部数据并创建卷组 $LVM_VG_NAME: ${SELECTED_DISKS[*]}" "wipe-disks" \
        || die "用户取消擦盘, 中止存储配置(可重跑本阶段重新选择)"
    else
      [[ $LVM_WIPE_OK == true ]] || die "无终端确认且未设置 LVM_WIPE_OK=true, 拒绝擦盘"
    fi
    local d
    for d in "${SELECTED_DISKS[@]}"; do wipefs -a "$d"; done
  fi

  vgcreate "$LVM_VG_NAME" "${SELECTED_DISKS[@]}"
  log_ok "卷组已创建: $LVM_VG_NAME ← ${SELECTED_DISKS[*]}"
}
verify_vg() {
  # worker 明确跳过存储时放行
  if is_worker && [[ -f $STATE_DIR/worker-no-storage ]]; then return 0; fi
  vgs "$LVM_VG_NAME" &>/dev/null
}

# --- 2. 安装 OpenEBS(umbrella chart, 仅启用 LVM LocalPV 引擎; 优先离线 chart) --------------
install_openebs() {
  local chart="openebs/openebs" version_args=(--version "${OPENEBS_V#v}")
  local local_tgz="$CACHE_DIR/charts/openebs-${OPENEBS_V#v}.tgz"
  if [[ -f $local_tgz ]]; then
    log_info "使用离线 chart: $local_tgz"
    chart=$local_tgz; version_args=()
  else
    helm_repo_add openebs https://openebs.github.io/openebs
  fi
  retry 2 10 helm_cmd upgrade --install openebs "$chart" \
    --namespace openebs --create-namespace \
    "${version_args[@]}" \
    --set engines.local.lvm.enabled=true \
    --set engines.local.zfs.enabled=false \
    --set engines.replicated.mayastor.enabled=false \
    --set loki.enabled=false \
    --set alloy.enabled=false
}

wait_openebs_ready() {
  # 用 Deployment Available + CSI 驱动注册作为就绪信号
  # (不能等所有 Pod Ready: chart 的 hook Job 结束后是 Completed 状态)
  kctl -n openebs wait --for=condition=Available deployment --all --timeout=600s
  wait_for "LVM CSI 驱动注册" 300 \
    bash -c "kubectl --kubeconfig /etc/kubernetes/admin.conf get csinode '$NODE_NAME' -o jsonpath='{.spec.drivers[*].name}' | grep -q local.csi.openebs.io"
}

# --- 3. StorageClass ---------------------------------------------------------------------
create_storageclass() {
  cat > "$K8S_FILES_DIR/storageclass.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $SC_NAME
  annotations:
    storageclass.kubernetes.io/is-default-class: "$SC_SET_DEFAULT"
provisioner: local.csi.openebs.io
allowVolumeExpansion: true
# 等 Pod 调度落点确定后再建卷, LocalPV 的正确姿势
volumeBindingMode: WaitForFirstConsumer
parameters:
  storage: "lvm"
  volgroup: "$LVM_VG_NAME"
  fsType: "$SC_FS_TYPE"
EOF
  kctl apply -f "$K8S_FILES_DIR/storageclass.yaml"
}
verify_storageclass() { kctl get sc "$SC_NAME" >/dev/null; }

main() {
  stage_begin "70-storage" "OpenEBS LVM 存储"
  if is_worker; then
    # OpenEBS/StorageClass 是集群级(控制面已装); worker 只需备好同名 VG,
    # lvm-localpv 的 node DaemonSet 会自动调度过来并在 VG 上切卷
    log_info "NODE_ROLE=worker: 仅准备本地 VG(可选), OpenEBS 与 StorageClass 由控制面负责"
    add_step vg "LVM 卷组准备($LVM_VG_NAME, 可选)"        create_vg           verify_vg
  else
    add_step vg      "LVM 卷组准备($LVM_VG_NAME)"          create_vg           verify_vg
    add_step openebs "helm 安装 OpenEBS $OPENEBS_V"        install_openebs
    add_step wait    "等待 OpenEBS LVM 就绪"               wait_openebs_ready
    add_step sc      "创建 StorageClass $SC_NAME"          create_storageclass verify_storageclass
  fi
  run_steps
  stage_end
}
main "$@"
