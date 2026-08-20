# Argo Rollouts

**定位**：金丝雀/蓝绿控制器（TECH-RADAR §9 定稿）。AnalysisTemplate 用 Prometheus provider 直连 VictoriaMetrics。
**上游**：argo/argo-rollouts chart 2.41.1 / app v1.9.1（实测 2026-08-20）。
**本集群取舍**：单副本、不装 dashboard；**硬前置**——业务流量仍经 Consul 直连 pod IP，基于 Service 的权重切分在服务发现迁移（TODO ⑤）完成前不生效，此前只有「副本分批」语义；与 ArgoCD 共存（CRD 独立）。
**验证**：`kubectl apply -f examples/rollout-demo.yaml && kubectl rollout status rollout/rollouts-demo -n default`。
