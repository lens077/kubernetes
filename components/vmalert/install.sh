#!/usr/bin/env bash
# =============================================================================
# vmalert —— 规则评估(VictoriaMetrics 数据源 → Alertmanager); 幂等; 可单独执行:
#   bash components/vmalert/install.sh
#
# 规则就是 rules/*.yml, 改完重跑本脚本即可, 不需要滚动 Pod。但 vmalert 没开 -configCheckInterval,
# 它**不会**自己重读文件: ConfigMap 卷投影进 Pod 后本脚本末尾 POST /-/reload(= SIGHUP)才生效
# (2026-09-23 实测: 改完等 95s 内存里还是旧表达式)。写规则的三条规矩见 rules/ecommerce-k8s.yml 头部与 README。
# =============================================================================
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" &>/dev/null && pwd)/env.sh"
DIR=$(comp_dir "${BASH_SOURCE[0]}")
comp_load_meta "$DIR"
comp_require_cluster

comp_installed victoriametrics vm-single-victoria-metrics-single-server \
  || die "victoriametrics 未安装: vmalert 没有数据源(先 bash components/victoriametrics/install.sh)"
comp_installed observability alertmanager \
  || log_warn "alertmanager 尚未安装: 规则会评估但告警发不出去, 装上后自动恢复"

# Generated host rules and cloud inventory must match their shared source before deploying.
python3 "$DIR/build-host-recording.py" --check

# 规则文件语法先在本地过一遍 YAML, 错了别等 vmalert 起不来才发现
rules=()
while read -r f; do [[ -n $f ]] && rules+=("$f"); done < <(manifest_files "$DIR/rules")
(( ${#rules[@]} > 0 )) || die "$DIR/rules 下没有规则文件"
if has_cmd python3; then
  python3 - "${rules[@]}" <<'PY' || die "规则文件 YAML 解析失败(见上)"
import sys, yaml
bad = 0
for f in sys.argv[1:]:
    try:
        d = yaml.safe_load(open(f))
        groups = d.get("groups") or []
        for g in groups:
            for r in g.get("rules", []):
                if "alert" in r and "for" not in r and r["alert"] != "Watchdog":
                    print(f"{f}: 告警 {r['alert']} 缺少 for:(团队规矩: 每条规则必须有 for)")
                    bad = 1
    except Exception as e:  # noqa: BLE001
        print(f"{f}: {e}"); bad = 1
sys.exit(bad)
PY
fi

log_step "安装 $ID → 命名空间 $NAMESPACE (${#rules[@]} 个规则文件)"
ns_ensure "$NAMESPACE"

# 一个 ConfigMap 装全部规则文件(key=文件名); vmalert 用 -rule=/config/*.yml 读
args=()
for f in "${rules[@]}"; do args+=(--from-file="$(basename "$f")=$f"); done
kctl -n "$NAMESPACE" create configmap vmalert-rules "${args[@]}" \
  --dry-run=client -o yaml | kctl apply -f -

helm_install_component "$DIR" --version "$CHART_VERSION"
routes_apply "$DIR"

# 2026-11-25: 不再 POST /-/reload。当前节点内核(7.0.0-38)上 vmalert 进程给自己发
# SIGHUP 会 EPERM panic(与 PG18 latch 唤醒丢失同源, 见 11-07 处置报告), 热加载会
# 造成重启风暴且规则未必生效。改为更新 ConfigMap 后滚动重启, 新 Pod 直接读到新规则。
# 滚动重启期间告警评估有几十秒空窗, 但比「看着 reload 成功实则 panic」可靠。
if kctl -n "$NAMESPACE" rollout status deploy/vmalert --timeout=120s >/dev/null 2>&1; then
  kctl -n "$NAMESPACE" rollout restart deploy/vmalert >/dev/null \
    && kctl -n "$NAMESPACE" rollout status deploy/vmalert --timeout=180s >/dev/null 2>&1 \
    && log_ok "vmalert 已滚动重启以加载新规则" \
    || log_warn "vmalert 滚动重启未完成, 检查 kubectl -n $NAMESPACE get pods"
fi
log_ok "$ID 安装完成"
log_info "  规则/告警页面: https://$HOSTNAME  (API: /api/v1/rules, /api/v1/alerts)"
log_info "  验证心跳到达 Alertmanager: kubectl -n $NAMESPACE exec deploy/vmalert -- wget -qO- http://alertmanager:9093/api/v2/alerts?filter=alertname=Watchdog"
