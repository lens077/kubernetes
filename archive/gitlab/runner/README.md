# GitLab runner（K8s executor）—— 已于 2026-11-17 下线

## 结论

`sumery/ecommerce` 的 CI 不再使用集群内的 GitLab runner。原先的 Helm 部署、runner 对象和全部 Secret 数据已于 **2026-11-17** 删除干净；CI 现在统一由云主机 **node5** 上的 Docker runner 承担。

## 下线时的处置记录

| 对象 | 处置 |
|---|---|
| GitLab runner `id=56697756`（desc `k8s`） | 先 `paused=true` 停止接单，随后经 API `DELETE /runners/56697756` 删除 |
| Helm release `gitlab-runner`（chart 0.93.0，revision 6，namespace `gitlab-runner`） | `helm uninstall gitlab-runner -n gitlab-runner` |
| `secret/gitlab-runner-token`、`secret/gitlab-runner-cache-s3` | 显式 `kubectl delete secret` —— runner 认证 token 与 S3 缓存凭据均已清除 |
| Deployment / ConfigMap / ServiceAccount / RBAC / 历史 release secret | 随 namespace 删除一并清理 |
| namespace `gitlab-runner` | 删除。Pod 与 k2 节点上两个残留 crictl sandbox 清理后，namespace 自动完成回收 |
| `archive/gitlab/runner/helm/` | 官方 values 模板与 `install.sh` 已无用途，删除；以本文替代 |

## 下线原因

1. 该 runner 配置为 `concurrent = 1`，是全仓 CI 排队十几分钟的直接原因。
2. 集群三节点资源长期紧张（k3 的 CPU requests 曾达 99%、memory 95%），CI job Pod 频繁卡在 `Pending / ContainersNotReady`，甚至 `runner_system_failure`。
3. 替代方案：node5（4 核 / 3.6G / 50G 空盘）上部署的 Docker runner（`id=59316237`，desc `node5-docker`，`concurrent=1`），已验证 `gitleaks`、`backend-gate` 能正常接单并跑绿。

## 已知遗留问题

`frontend-gate` 在 node5 上会失败：`vp lint --threads=1` 触发 Rust panic（`oxc_allocator/src/pool/fixed_size.rs:112`，`Result::unwrap()` on `Err(())`），exit 134。已确认：

- 同一提交在旧 k8s runner 上 success，故与代码无关；
- 裸 `oxlint` 二进制在 node5 上正常（5/5），问题出在 vite-plus 的包装层；
- 与 CPU 架构、线程数（0/1/2/4）、插件开关、资源限制、常见环境变量均无关。

因该 runner 已下线，`frontend-gate` 需要在 node5 上解决此 panic 后才能恢复绿色；在此之前 pipeline 中该 job 会失败。不要在未验证的情况下直接把 `vp lint` 换成裸 oxlint —— 规则集会从 177 条降到 96 条，门禁强度下降。

## 参考

- 新 runner 的部署与验证过程见 WorkBuddy 项目日志 `2026-11-15.md`（ecommerce 相关章节）。
- gitlab.com 项目：`sumery/ecommerce`（project id `83474117`）。
