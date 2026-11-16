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

## 已知遗留问题：`frontend-gate` 在 node5 上 lint 崩溃（截至 2026-11-17 未解决）

### 现象

`vp lint --threads=1` 稳定 panic：

```
thread 'tokio-rt-worker' panicked at crates/oxc_allocator/src/pool/fixed_size.rs:112:67
called `Result::unwrap()` on an `Err` value: ()
→ exit code 134 (SIGABRT)
```

同一提交 `eeb37dfd` 在旧 k8s runner 上 success，故与代码无关。

### 根因（已用上游源码实证）

vite-plus 1.6.0 的 `bin.js` 会在 lint 前设置 `OXLINT_TSGOLINT_PATH`，让 oxlint 拉起 `oxlint-tsgolint` 独立子进程做类型感知检查。panic 来自 oxc 分配器，源码在 `oxc-project/oxc` 的 `crates/oxc_allocator/src/pool/fixed_size.rs`：

```rust
const BLOCK_SIZE: usize = 2147483632;   // ≈ 2 GiB

pub fn new(thread_count: usize) -> Self {
    for i in 0..thread_count {
        let allocator = FixedSizeAllocator::try_new(i as u32).unwrap();  // 第 112 行，panic 点
    }
}
fn try_new(id: u32) -> Result<Self, ()> {
    let allocator = Allocator::new_fixed_size().ok_or(())?;  // mmap 失败 → Err(())
}
```

链条：tsgolint 建 tokio worker 池 → oxc 为**每个 worker 线程预留一块约 2 GiB 的虚拟内存**（`mmap`，非物理内存）→ node5（AMD EPYC / 内核 7.0 / Docker 29）的虚拟地址空间/overcommit 环境拒绝这块预留 → `try_new` 返回 `Err(())` → 第 112 行 `.unwrap()` 把它变成 panic → `panic=abort` → SIGABRT / exit 134。

这是上游 **oxc 的错误处理缺陷**：`try_new` 返回 `Result` 本可被优雅处理，却在生产路径上被 `unwrap()`；源码注释甚至写着 "This should be impossible if thread_count is accurate"。裸 `oxlint` 不设 `OXLINT_TSGOLINT_PATH`、不走到这个分配路径，在 node5 上连跑 5 次全部正常。

这也解释了为何"减少线程数"无效——只要任一 2 GiB 块申请失败就崩；为何"设无效路径"能消 panic 却仍 exit 1——那是压根不启动 tsgolint，但 vp 把 `Failed to find tsgolint executable` 当成 fatal。

### 已验证无效的方案（不要重复试）

| 方案 | 结果 |
|---|---|
| `--threads` = 0 / 1 / 2 / 4 | 全 PANIC |
| 禁用 unicorn / oxc / typescript 三个默认插件（含全禁） | 全 PANIC |
| tsconfig 加 `baseUrl`（该代码路径只在 `vp lint --init` 时用） | 无效 |
| `.oxlintrc.json` 写 `options.typeAware: false`（被 vp 运行时合并覆盖） | 无效 |
| pnpm override oxlint → 1.94.0（vite-plus 精确锁 1.93.0，未生效） | 无效 |
| 资源限制模拟 K8s（2 CPU / 1Gi）、`RAYON_NUM_THREADS` / `CI_LOW_MEMORY` / `MALLOC_ARENA_MAX` / `NODE_OPTIONS` | 全 PANIC |
| **`OXLINT_TSGOLINT_PATH=/dev/null`** | **panic 消失但 vp 报 `Failed to find tsgolint executable` 并 exit 1**（曾误判为有效，已 revert：`bf2746d0` → `b01e703d`） |
| 同变量指向 `/bin/true`（文件存在） | vp 真去启动 → 仍 PANIC |

### 可行的方向（未执行）

- **换回归属**：恢复一台 Intel 节点的 runner，让 `frontend-gate` 用 tag 固定跑在上面；node5 承担其余 job。
- **替换 lint 实现**：在 CI 里用 pnpm 内部的 `node_modules/.pnpm/node_modules/.bin/oxlint` 直接跑，规则数可在 96（默认）～398（启用所有类别）间选，但会丢掉 vite-plus 的 `prefer-vite-plus-imports` 插件规则，需评估门禁覆盖。
- **等上游修复**：oxc/vite-plus 在该环境下缺少错误处理，待新版本修复后再恢复。

在解决之前，`frontend-gate` 会持续失败；其余三个 job（`gitleaks`、`backend-gate`、`context-gate`）已在 node5 上验证通过。

## 参考

- 新 runner 的部署与验证过程见 WorkBuddy 项目日志 `2026-11-15.md`（ecommerce 相关章节）。
- gitlab.com 项目：`sumery/ecommerce`（project id `83474117`）。
