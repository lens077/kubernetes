# Tetragon

## 1. 定位

Tetragon 在节点内核侧观察容器进程行为，为运行时取证、异常执行调查和合规审计提供证据。当前 chart `1.7.1` 在 `node101`、`node102`、`node103` 三节点运行，仅导出 `ecommerce` 命名空间的进程与 audit-only 策略事件，不执行阻断。

部署职责分为两处：

- 本目录管理 Tetragon Helm release、资源限制、三节点采集和 exporter；
- ecommerce 仓 `infrastructure/tetragon/` 管理业务专属 `TracingPolicyNamespaced`，避免基础设施仓复制业务策略。

## 2. 上游最佳实践

- ARM64 节点应使用 Linux 5.10+ 并提供 BTF；本集群三个节点均为 ARM64、Linux 7.0，BTF 已实测加载。
- agent 需要 `hostNetwork` 和 privileged 权限读取节点内核事件，因此必须固定镜像版本、限制管理权限并持续观察资源。
- 先观察、后阻断：策略先采用 `Post` 审计，完成误报、告警和回滚验证后再独立评估 enforcement。
- 用 namespace/workload 维度控制指标基数；日志只保留调查需要的事件，并对常见凭据参数做脱敏。

参考：<https://tetragon.io/docs/>、<https://github.com/cilium/tetragon/releases>。

## 3. 本集群取舍

集群是 3 个 ARM64 节点（Ubuntu 26.04、Linux 7.0），Cilium 完全替代 kube-proxy，单节点约 6.5 GiB 内存。

| 上游默认 | 本集群 | 原因 |
|---|---|---|
| 所有节点运行 DaemonSet | `node101`/`node102`/`node103` 三节点 `3/3` Ready | 消除工作负载调度后的观察盲区 |
| 导出多个 namespace | 仅导出 `ecommerce` 的 `PROCESS_EXEC`/`PROCESS_EXIT`/`PROCESS_KPROBE` | 控制日志量与敏感信息范围 |
| 默认进程缓存 65536 | 16384 | 降低小集群内存占用 |
| 指标含 pod/binary 标签 | 只保留 namespace/workload | 控制 VictoriaMetrics 基数 |
| 可创建阻断策略 | 唯一策略为 `ecommerce-service-account-token-access`，namespaced、`Post`、audit-only | 建立正常 token-access 为零的审计基线，不阻断业务 |
| credential/namespace 上下文可选 | 已启用 | 为 token-access、提权和 namespace 调查提供上下文 |
| agent 无资源限制 | request 50m/128Mi，limit 100m/250Mi | 保持每节点 CPU <100m、内存 <250Mi 的观察门槛 |

当前资源快照约为每个 agent 1–2m CPU、75–89 MiB，operator 约 1m CPU、10 MiB；这是即时快照，不替代持续基线。扩充传感器或启用阻断前，仍须验证业务 P99 劣化小于 3%、事件无持续丢失、VictoriaLogs 增长可接受。

## 4. 数据与告警链路

没有公网或 Gateway 入口。gRPC 仅监听 Pod 内 `localhost:54321`。

已验收的数据路径：

```text
Tetragon export-stdout
  → Vector（三节点）
  → VictoriaLogs（原始事件）
  → 低基数 security metrics
  → OTel Collector
  → VictoriaMetrics
  → vmalert
  → Alertmanager
  → 通知审计桥
```

当前告警覆盖 token-access、`ecommerce` 可疑工具执行和 Hubble deny burst。业务告警规则及完整调查入口见 ecommerce 仓 `infrastructure/observability/README.md`。

## 5. 验证

```bash
# 检查三节点集合、每节点 BTF、唯一 audit-only 策略、资源和事件数量。
bash components/tetragon/verify.sh

# 查看三节点 agent。
kubectl -n tetragon get pods -l app.kubernetes.io/component=agent -o wide

# 查看 token-access 审计策略；其动作应为 Post，不得包含 Sigkill 等阻断动作。
kubectl -n ecommerce get tracingpolicynamespaced \
  ecommerce-service-account-token-access -o yaml
```

## 6. 踩坑与边界

- Pod 启动时报 BTF 或内核能力错误：先确认 `/sys/kernel/btf/vmlinux` 可读；不要下载不匹配的 BTF 文件绕过。
- agent `OOMKilled`：不要直接提高 limit；先检查事件量、进程缓存和日志堆积。
- `PROCESS_EXEC` 会记录命令参数。当前仅脱敏 `--password`、`--token`、`--secret`；业务容器不得通过其他命令行参数传递凭据。
- `PROCESS_KPROBE` 只有与具体策略配合才有意义；不要新增无工作负载上下文、只增加命中计数的策略制造虚假安全感。
- `TracingPolicy` CRD 的存在不等于启用阻断。当前唯一策略采用 `Post`，enforcement 需要独立评估、误报观察和回滚方案。
- 仓库 values 必须保持 `nodeSelector: {}`。重新写成单节点会在下次 Helm 升级时制造观察盲区。
