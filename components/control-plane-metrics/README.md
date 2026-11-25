# control-plane-metrics：Kubernetes 控制面进程级指标

## 1. 定位

把 k1 上四个控制面静态 Pod 自己暴露的 `/metrics` 写进集群内 VictoriaMetrics，供 `vmalert` 的 `control-plane-process` 规则组做进程级告警。

此前 VM 中 `apiserver_` / `etcd_` / `scheduler_` / 控制器相关序列为零条。`components/vmalert/rules/control-plane.yml` 只能看静态 Pod 的 phase/container ready——它能说「Pod 还活着」，但说不出 etcd 有没有 leader、apiserver 延迟多高、leader lease 有没有丢。本组件补的就是这一层。

| 组件 | 端点（k1 本机） | 认证 | 实际指标前缀（k8s v1.37.2 实测） |
|---|---|---|---|
| etcd | `http://127.0.0.1:2381/metrics` | 无（`--listen-metrics-urls` 是明文） | `etcd_*` |
| kube-apiserver | `https://127.0.0.1:6443/metrics` | SA token + RBAC `nonResourceURLs=/metrics:get` | `apiserver_*` |
| kube-scheduler | `https://127.0.0.1:10259/metrics` | 同上 | `scheduler_*`（**不是** `kube_scheduler_*`） |
| kube-controller-manager | `https://127.0.0.1:10257/metrics` | 同上 | `workqueue_*` / `leader_election_master_status` / `*_controller_*`（**没有** `kube_controller_manager_*`） |

## 2. 上游最佳实践

Prometheus 官方对控制面组件的抓取建议是用 bearer token + RBAC（`system:kube-scheduler` / `system:kube-controller-manager` 自带 `/metrics` 权限），并为 TLS 端点配置 CA 校验；etcd 的 metrics 端口与客户端端口分离，默认是无认证的明文端口，应当只绑定回环。

本集群实际路径：

- 四个静态 Pod 的启动参数已确认（只读检查 `/etc/kubernetes/manifests/*.yaml`）：etcd `--listen-metrics-urls=http://127.0.0.1:2381`；scheduler / KCM `--bind-address=127.0.0.1`；apiserver 未设 `--bind-address`，回环可达。
- 证书 SAN 已包含 `127.0.0.1` 与 `10.10.21.161`，**无需重签任何证书**。

## 3. 本集群取舍

| 上游默认 | 本集群 | 原因 |
|---|---|---|
| 每台控制面节点一个采集器 | 只在 k1 一个 Deployment，`hostNetwork: true` + `nodeSelector kubernetes.io/hostname=k1` | 只有 k1 是 control-plane；四个端点只监听本机回环，worker 上的采集器够不到 |
| 用 `system:monitoring` 之类的内置角色 | 自建最小 ClusterRole，只给 `nonResourceURLs: ["/metrics"] get` | 采集器跑在 hostNetwork 上，权限越小越好；不挂 cluster-admin |
| 客户端证书认证 | projected SA token（`bearer_token_file`） | 6443 / 10257 / 10259 实测未认证返回 403，带 SA token 全部 200；不需要 hostPath 挂 `/etc/kubernetes/pki` |
| 校验服务端证书 | `insecure_skip_verify: true` | SAN 已含回环 IP；这里只走本机回环，不跨网络。若坚持严格校验，需要把 `ca.crt` 投影进 Pod 并配 `ca_file`（见「遗留限制」） |
| 高内存节点上随意给 limit | 容器 limit `1Gi`（最初 256Mi 实测 OOMKilled） | apiserver `/metrics` 单次约 **16.8 MB**，转成 ~4.4 万条序列；实际常驻约 411 Mi |
| 原样写全部指标 | 原样写，不重命名 | 保持上游指标语义；v1.37 的命名与旧文档不同，规则按实测名写 |

**未改任何静态 Pod manifest、未改 grafana/opentelemetry 组件**。唯一对既有组件的改动是在 `components/vmalert/rules/` 下**新增**一个规则文件（不修改已有规则）。

## 4. 暴露方式

- 无对外暴露（`EXPOSE=none`）：不接收 OTLP、不开抓取端点、不经网关。
- 出口：`http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/write`（prometheusremotewrite exporter）。
- `dnsPolicy: ClusterFirstWithHostNet`：hostNetwork 下必须显式设置，否则解析不到 VM 的 Service 名。
- 采集周期 30s，`scrape_timeout` 默认 10s。

## 5. 验证

```bash
bash components/control-plane-metrics/install.sh

# 四个 job 全部 up=1
kubectl -n observability exec deploy/grafana -c grafana -- curl -sG \
  'http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=up{job=~"control-plane-.*"}'

# 指标前缀（v1.37 下这条只返回 apiserver_/etcd_ 两类，原因见下）
kubectl -n observability exec deploy/grafana -c grafana -- curl -sG \
  'http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=count by (__name__) ({__name__=~"(apiserver|etcd|kube_scheduler|kube_controller_manager)_.*"})'

# 实际四类组件都有数据：scheduler 用 scheduler_*，KCM 用 workqueue_*/leader_election_master_status
kubectl -n observability exec deploy/grafana -c grafana -- curl -sG \
  'http://vm-single-victoria-metrics-single-server.victoriametrics.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=count by (component) ({job=~"control-plane-.*"})'

# vmalert 规则健康（health=ok, lastError 为空）
bash components/vmalert/install.sh
kubectl -n observability exec deploy/vmalert -- wget -qO- http://127.0.0.1:8880/api/v1/rules
```

只 `kubectl get pods` 不够：Pod Running 但配置解析失败或 OOM 时，VM 里一条序列都不会多。

## 6. 踩坑

**① `prometheusremotewrite` exporter 在 0.158.0 不接受 `sending_queue`。** 现象：Pod Running 但容器立即退出，日志 `has invalid keys: sending_queue`。根因：该版本 exporter 尚未支持这个配置项。修法：只保留 `retry_on_failure`。

**② apiserver 抓取让采集器 OOMKilled。** 现象：其余三个 job 有 `up`，唯独 apiserver 没有；`kubectl get pods` 显示 `OOMKilled`。根因：单次抓 16.8 MB、转换出 ~4.4 万条序列，256Mi limit 不够。修法：limit 提到 1Gi（实测常驻 411 Mi）。

**③ 用错指标前缀写规则会「查询成功但没有序列」。** 现象：`kube_scheduler_*` / `kube_controller_manager_*` 恒为空。根因：k8s v1.37 已把 scheduler 自身指标改名为 `scheduler_*`，KCM 则只暴露通用 `workqueue_*` 与 `leader_election_master_status`。修法：先在 VM 用 `count by (__name__)` 查真实名字再写告警，不照抄旧文档。

**④ 抓取间隔初期看到的 `instance="127.0.0.1:10259", component="apiserver"` 是测试残留。** VM 的即时查询会给陈旧序列盖上查询时刻的时间戳，看起来像还在写。用 `query_range` 看最后样本时间即可确认它早已停更。告警表达式用 `job` + `component` 联合限定，不受它影响。

## 7. 遗留限制

- **单点**：只在 k1 跑一份；采集器或 k1 挂掉，控制面进程指标会断流。`ControlPlaneProcessMetricsMissing`  rule 会在 15 分钟后提示，但不会自动恢复采集。
- **TLS 校验**：为省去证书投影用了 `insecure_skip_verify`。流量只走本机回环，风险有限；若要求严格校验，可把 `ca.crt` 以 ConfigMap/Secret 投影并改 `tls_config.ca_file`。
- **apiserver 基数**：`apiserver_request_duration_seconds_bucket` 单指标约 2.2 万条序列（verb/resource/scope/code/le 组合）。当前 VM 可承受，但该组件贡献了大部分写入量；后续若 VM 压力上升，可用 `metric_relabel_configs` 归档不需要的 label。
- **KCM 覆盖不完整**：KCM 没有独立前缀，本组件只看 `workqueue_*` / leader lease / 各 controller 自身指标；单个 controller 的具体错误仍需看日志。
- **未覆盖证书过期**：`apiserver_client_certificate_expiration_seconds` 已在 VM 中，但本规则组没有为它加告警（避免与现有证书告警重复）。
