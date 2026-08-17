#!/usr/bin/env bash
# =============================================================================
# 45-etcd-disk —— etcd 专用磁盘(可选, config.env: ETCD_DEDICATED_DISK)
#
#   为什么: etcd 对 fsync 延迟极其敏感(每次写都要落盘), 单机上与数据库/日志共
#   用一块盘时, 业务 IO 峰值会直接放大 apiserver 尾延迟。独立小盘(10-20G 足够)
#   是单机集群性价比最高的稳定性投资。
#
#   两种场景:
#     - 集群未初始化(推荐): 格式化→挂载 /var/lib/etcd, 后续 init 直接落在新盘
#     - 集群已运行: 停 kubelet→停 etcd 容器→迁移数据→挂载→原地恢复(有确认与备份)
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)/lib/common.sh"

ETCD_DIR="/var/lib/etcd"
ETCD_DISK=""

cluster_running() { [[ -f /etc/kubernetes/manifests/etcd.yaml ]]; }

# --- 选盘 -----------------------------------------------------------------------
choose_disk() {
  # "ask" 与留空等价: 划分区选项已并入下方交互菜单
  [[ $ETCD_PARTITION_OF == ask ]] && ETCD_PARTITION_OF=""

  # 断点续跑/崩溃重入: 已记录过目标盘(含已划出的分区)则直接复用, 绝不重复划分
  if [[ -f $STATE_DIR/etcd.disk ]] && [[ -b $(<"$STATE_DIR/etcd.disk") ]]; then
    ETCD_DISK=$(<"$STATE_DIR/etcd.disk")
    log_info "复用已记录的 etcd 目标盘: $ETCD_DISK"
    return 0
  fi

  # 路线一(优先): 从系统盘尾部未分配空间划出专用分区(虚拟化层扩容场景)
  # 提醒: 同盘分区无 IO 隔离收益, 见 config.env 注释; 有条件加独立小盘就别走这条路
  if [[ -n $ETCD_PARTITION_OF ]]; then
    [[ -b $ETCD_PARTITION_OF ]] || die "ETCD_PARTITION_OF=$ETCD_PARTITION_OF 不是块设备"
    local free_gb want_gb
    free_gb=$(disk_tail_free_gb "$ETCD_PARTITION_OF")
    want_gb=${ETCD_PARTITION_SIZE//[!0-9]/}
    (( free_gb >= want_gb )) || die "$ETCD_PARTITION_OF 尾部未分配空间仅 ${free_gb}G, 不足 $ETCD_PARTITION_SIZE"
    # 有终端一律输入确认词; 无终端才要求显式配置授权
    if has_tty; then
      confirm_danger "将在 $ETCD_PARTITION_OF 尾部新建 $ETCD_PARTITION_SIZE 分区用作 etcd 专用盘(分区表已自动备份到 $BACKUP_DIR)" \
        "write-partition-table" || die "用户取消, 中止 etcd 分区划分"
    else
      [[ $ETCD_DISK_WIPE_OK == true ]] || die "无终端确认且未设置 ETCD_DISK_WIPE_OK=true, 拒绝修改分区表"
    fi
    ETCD_DISK=$(create_tail_partition "$ETCD_PARTITION_OF" "$ETCD_PARTITION_SIZE" 8300 etcd)
    ETCD_DISK_CARVED=1
    echo "$ETCD_DISK" > "$STATE_DIR/etcd.disk"
    log_ok "已从 $ETCD_PARTITION_OF 划出 etcd 专用分区: $ETCD_DISK"
    return 0
  fi

  case $ETCD_DEDICATED_DISK in
    "")   log_info "未启用 etcd 专用磁盘(config.env: ETCD_DEDICATED_DISK), 跳过本阶段"; return 0 ;;
    ask)
      # ask 的语义: 只要有终端就弹菜单(--yes 也弹); 无终端才静默跳过
      if ! has_tty; then
        log_info "无终端可交互(systemd/cron 场景), 跳过 etcd 专用盘; 需要时补跑: start.sh --only 45-etcd-disk"
        return 0
      fi
      print_disk_overview
      # 三类候选: 整盘空闲 / 空分区 / 可从尾部未分配空间划分区的盘
      local labels=() kinds=() vals=() d free_gb entry line i
      while read -r d; do
        line=$(lsblk -dno NAME,SIZE,MODEL "$d" 2>/dev/null || echo "$d")
        labels+=("[整盘] $line — 整盘格式化给 etcd(推荐: 独立 IO 队列)")
        kinds+=(disk); vals+=("$d")
      done < <(list_free_disks)
      while read -r entry; do
        d=${entry%%:*}; free_gb=${entry##*:}
        (( free_gb >= 8 )) || continue
        labels+=("[空分区] $d (约 ${free_gb}G) — 直接格式化使用")
        kinds+=(part); vals+=("$d")
      done < <(list_empty_partitions)
      while read -r d; do
        list_free_disks | grep -qx "$d" && continue
        free_gb=$(disk_tail_free_gb "$d")
        (( free_gb >= 8 )) || continue
        labels+=("[划分区] $d 尾部未分配约 ${free_gb}G → 划出 $ETCD_PARTITION_SIZE (同盘无 IO 隔离, 见 README)")
        kinds+=(carve); vals+=("$d")
      done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')

      if (( ${#labels[@]} == 0 )); then
        log_warn "没有可用的整盘/空分区/未分配空间, 跳过 etcd 专用盘"
        return 0
      fi
      {
        echo "为 etcd 选择专用盘(输入编号, 0 或回车=跳过):"
        for ((i = 0; i < ${#labels[@]}; i++)); do printf '  %d) %s\n' "$((i+1))" "${labels[i]}"; done
      } >/dev/tty
      printf '选择> ' >/dev/tty
      local choice; read -r choice </dev/tty || choice=""
      if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#labels[@]} )); then
        log_info "未选择, 跳过 etcd 专用盘"
        return 0
      fi
      case ${kinds[choice-1]} in
        disk|part)
          ETCD_DISK=${vals[choice-1]}
          ;;
        carve)
          confirm_danger "将在 ${vals[choice-1]} 尾部新建 $ETCD_PARTITION_SIZE 分区用作 etcd(分区表自动备份到 $BACKUP_DIR)" \
            "write-partition-table" || { log_info "已取消, 跳过 etcd 专用盘"; return 0; }
          ETCD_DISK=$(create_tail_partition "${vals[choice-1]}" "$ETCD_PARTITION_SIZE" 8300 etcd)
          ETCD_DISK_CARVED=1
          ;;
      esac
      ;;
    /dev/*)
      [[ -b $ETCD_DEDICATED_DISK ]] || die "ETCD_DEDICATED_DISK=$ETCD_DEDICATED_DISK 不是块设备"
      list_free_disks | grep -qx "$ETCD_DEDICATED_DISK" \
        || die "$ETCD_DEDICATED_DISK 非空闲磁盘(存在分区/文件系统/挂载), 拒绝擦除"
      ETCD_DISK=$ETCD_DEDICATED_DISK
      ;;
    *) die "ETCD_DEDICATED_DISK 取值不合法: $ETCD_DEDICATED_DISK (\"\"/ask//dev/xxx)" ;;
  esac
  # 选盘结果落盘: choose 步骤跳过(断点续跑)时 mount 步骤仍能拿到目标盘
  if [[ -n $ETCD_DISK ]]; then
    echo "$ETCD_DISK" > "$STATE_DIR/etcd.disk"
    log_info "etcd 专用磁盘: $ETCD_DISK"
  else
    rm -f "$STATE_DIR/etcd.disk"
  fi
  return 0
}

# --- 格式化 + 挂载(+ 已有集群的数据迁移) --------------------------------------------
setup_etcd_disk() {
  # choose 步骤因断点续跑被跳过时, 从状态文件恢复选盘结果
  [[ -z $ETCD_DISK && -f $STATE_DIR/etcd.disk ]] && ETCD_DISK=$(<"$STATE_DIR/etcd.disk")
  # 未选盘 → 整个阶段静默跳过
  [[ -n $ETCD_DISK ]] || return 0

  # 已经是独立挂载点则视为完成(幂等)
  if findmnt -n "$ETCD_DIR" >/dev/null 2>&1; then
    log_info "$ETCD_DIR 已是独立挂载点: $(findmnt -no SOURCE "$ETCD_DIR"), 跳过"
    return 0
  fi

  # 刚划出的新分区必然是空的且已确认过一次, 不再二次确认
  if [[ ${ETCD_DISK_CARVED:-0} != 1 ]]; then
    if has_tty; then
      confirm_danger "将擦除 $ETCD_DISK 全部数据并挂载为 etcd 专用盘($ETCD_DIR)" "wipe-etcd-disk" \
        || die "用户取消, 中止 etcd 磁盘配置(可重跑本阶段)"
    else
      [[ $ETCD_DISK_WIPE_OK == true ]] || die "无终端确认且未设置 ETCD_DISK_WIPE_OK=true, 拒绝擦盘"
    fi
  fi

  local was_running=false
  if cluster_running; then
    was_running=true
    log_warn "检测到运行中的集群, 将执行在线迁移: 停 kubelet → 停 etcd → 搬数据 → 挂载 → 恢复"
    if [[ $ASSUME_YES != true ]]; then
      confirm "迁移期间 apiserver 短暂不可用(约 1-2 分钟), 继续?" N || die "用户取消迁移"
    fi
    systemctl stop kubelet
    local podid
    podid=$(crictl pods --name "etcd-$NODE_NAME" -q 2>/dev/null | head -1)
    [[ -n $podid ]] && crictl stopp "$podid" >/dev/null
    sleep 3
  fi

  wipefs -a "$ETCD_DISK"
  mkfs.xfs -f -L etcd "$ETCD_DISK" >/dev/null

  # 旧数据先挪到一旁(迁移后保留为备份, 确认集群健康后可手动删除)
  if [[ -d $ETCD_DIR ]] && [[ -n $(ls -A "$ETCD_DIR" 2>/dev/null) ]]; then
    mv "$ETCD_DIR" "${ETCD_DIR}.pre-migration"
    log_info "原 etcd 数据已暂存: ${ETCD_DIR}.pre-migration (确认集群健康后可删除)"
  fi
  mkdir -p "$ETCD_DIR"

  local uuid
  uuid=$(blkid -o value -s UUID "$ETCD_DISK") || true
  [[ -n $uuid ]] || die "无法读取 $ETCD_DISK 的 UUID"
  backup_once /etc/fstab
  # 不加 nofail: 盘缺失时宁可停在启动阶段, 也不能让 etcd 悄悄落回根盘
  ensure_block /etc/fstab "etcd-disk" "UUID=$uuid $ETCD_DIR xfs defaults,noatime 0 2"
  systemctl daemon-reload
  mount "$ETCD_DIR"
  chmod 700 "$ETCD_DIR"

  if [[ -d ${ETCD_DIR}.pre-migration ]]; then
    cp -a "${ETCD_DIR}.pre-migration/." "$ETCD_DIR/"
  fi

  if [[ $was_running == true ]]; then
    systemctl start kubelet
    wait_for "apiserver 恢复" 300 bash -c '[[ $(kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz 2>/dev/null) == ok ]]'
    log_ok "etcd 已迁移到专用磁盘并恢复服务"
  fi
}
verify_etcd_disk() {
  # 未启用/未选盘时放行; 启用后必须确实挂载在独立盘上
  [[ -n $ETCD_DISK ]] || return 0
  findmnt -n "$ETCD_DIR" >/dev/null && { ! cluster_running || [[ $(kctl get --raw /readyz 2>/dev/null) == ok ]]; }
}

main() {
  stage_begin "45-etcd-disk" "etcd 专用磁盘(可选)"
  if is_worker; then
    log_skip "NODE_ROLE=worker: etcd 只在控制面, 跳过本阶段"
    stage_end
    return 0
  fi
  add_step choose "选择 etcd 专用磁盘"          choose_disk
  add_step mount  "格式化并挂载 $ETCD_DIR"      setup_etcd_disk  verify_etcd_disk
  run_steps
  stage_end
}
main "$@"
