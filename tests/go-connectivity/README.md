# Go 客户端连通性测试

用每个组件的官方 Go SDK 在集群内做一次**真实读写往返**，证明组件不只是端口通，而是应用视角可用。
2026-09-06 在机房两节点集群（node4 + node5）首次全绿。

## 运行

在控制面节点（或任何有 `KUBECONFIG` 的机器）执行：

```bash
bash tests/go-connectivity/run-in-cluster.sh              # Pod 网络: 13 个用例
bash tests/go-connectivity/run-in-cluster.sh --host       # hostNetwork: Tetragon gRPC(只监听节点 localhost:54321)
bash tests/go-connectivity/run-in-cluster.sh --run TestNATS
SKIP_OPENFGA=1 bash tests/go-connectivity/run-in-cluster.sh   # 组件未装时跳过
```

脚本把源码打成 ConfigMap，用 `golang:1.26` 镜像起一个 Job 跑 `go test -v`，模块经 `goproxy.cn` 下载并缓存在节点
`/var/cache/conntest-gopath`（首跑约 1 分钟，之后十几秒）。退出码就是 `go test` 的退出码；日志末尾有 `=== SUMMARY ===`。

凭据只从集群 Secret 复制到 `conntest` 命名空间再以环境变量注入：`postgresql/pg-main-app`（`uri`）、
`consul/consul-bootstrap-acl-token`（`token`）、`dragonfly/dragonfly-password-secret`（`password`）。
Secret 不存在时对应用例 `Skip`，不会假装通过。TLS 校验用 trust-manager 分发的 `global-root-ca`。

## 用例与判据

| 用例 | SDK | 往返内容 |
|---|---|---|
| `TestNATSJetStream` | `nats-io/nats.go` + `jetstream` | 建流 → 发布 → durable 消费者拉取 → 比对 → 删流 |
| `TestDragonfly` | `redis/go-redis/v9` | TLS + 密码 PING → SET/GET/DEL |
| `TestPostgres` | `jackc/pgx/v5` | app 用户连 `pg-main-rw` → 临时表写读 |
| `TestConsul` | `hashicorp/consul/api` | ACL token → `agent/self` → KV put/get/delete |
| `TestOpenFGA` | `openfga/go-sdk` | 建 store → 写授权模型 → 写 tuple → check=allowed → 删 store |
| `TestOpenBao` | `openbao/openbao/api/v2` | `sys/health` initialized 且未 sealed |
| `TestVictoriaMetrics` | net/http | Prometheus 文本导入 → `/api/v1/export` 精确查回 → PromQL（评估点放到 `-search.latencyOffset` 之外）查回 |
| `TestVictoriaLogs` | net/http | jsonline 写入 → LogsQL 查回 |
| `TestOTLPTraceToVictoriaTraces` | `go.opentelemetry.io/otel` OTLP/gRPC | 发一个 span 到 collector → VictoriaTraces Jaeger 接口出现该服务名（证明 traces pipeline 真落库） |
| `TestAlertmanager` | net/http | `/-/ready` + `/api/v2/status` 配置已加载 |
| `TestHTTPEndpoints` | net/http | argocd `/api/version`、spegel/tetragon `/metrics` 含自有指标、gatus/healthchecks/bugsink 健康接口 |
| `TestGatewayVIP` | net/http | 从 Pod 到固定 VIP：匹配 Host 200/envoy、未匹配 404/envoy、80→443 301（与 `CILIUM.md` §8.1 第三层验收一致） |
| `TestKubernetesAPI` | `k8s.io/client-go` | 节点全 Ready；算子命名空间的 Deployment 全部可用 |
| `TestTetragonGRPC`（`--host`） | `cilium/tetragon/api` | `GetVersion` + `GetHealth`=RUNNING |

## 踩坑

- VictoriaMetrics 即时查询默认忽略最近 30 秒（`-search.latencyOffset`）：刚写入的点用 `/api/v1/query` 查不到不是故障；
  用 `export` 或把 `time=` 放到 30 秒之后。
- `/metrics` 正文里组件自有指标排在 Go 运行时指标之后，只读前几 KB 会误判"缺少指标"。
- Job 内 `go test | tee` 必须 `set -o pipefail`，否则有 FAIL 的 Job 也会 Complete。
- Tetragon gRPC 只监听节点 `localhost`，必须 hostNetwork + `ClusterFirstWithHostNet` 才能在 Job 里测。
