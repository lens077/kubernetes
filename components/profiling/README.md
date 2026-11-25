# profiling —— 持续剖析（Go 函数级 CPU profile）

在 `observability` 命名空间落地 **Pyroscope v2 server**（`pyroscope:4040`）+ **Grafana Alloy `pyroscope.ebpf` DaemonSet**。eBPF 直接在内核采样所有容器的用户态/内核态 CPU 栈，不修改业务服务、不需要 pprof endpoint，因此能看见 Go 运行时的 `runtime.copystack` / `runtime.morestack` / `runtime.newstack` 等自适应栈开销。

## 组成

| 清单 | 内容 |
| --- | --- |
| `manifests/01-pyroscope.yaml` | SA + Service `pyroscope:4040` + StatefulSet（20Gi PVC，`openebs-lvm`）；v2 filesystem 后端；保留期 168h（7 天）；requests 250m/512Mi，limits 1/1Gi |
| `manifests/02-alloy-ebpf.yaml` | SA/ClusterRole/RBAC + Alloy 配置 ConfigMap + privileged DaemonSet（`hostPID: true`，含 control-plane 节点容忍） |

镜像按 digest 固定，避免使用 `:latest`：

- `docker.io/grafana/pyroscope@sha256:288da0b9b73193b5aee0843b6f1f5d033ee697d4afa280efb95de338d1409870`（镜像内版本 2.4.4）
- `docker.io/grafana/alloy@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189`

## 安装

```bash
bash components/profiling/install.sh
# 或单独在集群上：
KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -n observability -f components/profiling/manifests/
```

前置条件：内核支持 eBPF；`observability` 命名空间无 PodSecurity `restricted` 约束；允许 `privileged: true` + `hostPID: true`。本集群实测内核 `7.0.0-44-generic`、`kernel.perf_event_paranoid=4`，特权容器带 `CAP_SYS_ADMIN` 可绕过 paranoid 限制（集群已有 tetragon eBPF DaemonSet 运行）。

## 验证

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n observability get pods -l app=pyroscope
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n observability get pods -l app=alloy-pyroscope

# 集群内健康检查（需要一个有 curl/wget 的 Pod，或用kubectl exec到任一容器）
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n observability run curl-probe \
  --image=curlimages/curl:8.10.1 --restart=Never --rm -it -- \
  curl -fsS http://pyroscope.observability.svc.cluster.local:4040/-/healthy

# Alloy 组件健康（每个 Alloy Pod）
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n observability exec ds/alloy-pyroscope -- \
  wget -qO- http://127.0.0.1:12345/api/v1/health 2>/dev/null || true

# Pyroscope 内置自剖析会向自己写数据；查询 API 看 profile 列表
KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n observability run curl-probe2 \
  --image=curlimages/curl:8.10.1 --restart=Never --rm -it -- \
  curl -fsS 'http://pyroscope.observability.svc.cluster.local:4040/api/v1/label/service_name/values'
```

## Grafana 数据源（由另一工作流配置）

- uid：`ds-pyroscope`
- type：`grafana-pyroscope-datasource`
- url：`http://pyroscope.observability.svc.cluster.local:4040`

面板中用 Flame Graph / Profiles 面板，按 `service_name` 选择 `ebpf/<namespace>/<container>`；搜索 `runtime.copystack`、`runtime.morestack`、`runtime.newstack` 即可定位 Go 1.19+ 自适应栈开销。

## 退化方案（如 eBPF 不可用）

若内核/权限/镜像导致 eBPF 不可行，服务端仍可独立使用：在 Go 服务中引入 `github.com/grafana/pyroscope-go`，在 `main` 里 `pyroscope.Start(pyroscope.Config{ApplicationName: "<service>", ServerAddress: "http://pyroscope.observability.svc.cluster.local:4040", ProfileTypes: []pyroscope.ProfileType{pyroscope.ProfileCPU}})`，并为每个 Pod 加资源即可。**这要改 ecommerce 业务仓库，超出本组件边界**，届时只部署 `01-pyroscope.yaml`，并在服务仓库另行提交 SDK 接入。

## 已知限制

- eBPF 采样看到的函数名依赖 Go 二进制的 `.gopclntab`（Go 1.27 默认保留，strip 也可解析）；若业务使用 `-ldflags="-s -w"` 之外裁剪符号表的极端构建，函数名可能退化为地址。
- `runtime.copystack` 只在实际发生栈扩容时出现；若服务处于空闲或栈已稳定，火焰图里可能没有它 —— 这是负载特征，不是采集故障。
- 单节点 filesystem 存储不支持 HA；metastore 是单点。生产多副本应换 S3/兼容对象存储并拆分组件。
- `collect_interval=15s` / `sample_rate=19Hz` 为保守默认值，可在 ConfigMap 中调高采样频率（代价是 CPU 与存储开销上升）。
