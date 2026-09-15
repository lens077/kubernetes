# Config Center Token 生命周期

## 当前可用能力

- operator token 由 `tools/config-center-operator-token.sh` 签发。
- `tools/config-center-harvest.sh` 可以使用 operator token 填充配置、签发 service token，并更新 selector Secret。
- `tools/config-center-environment-ensure.sh` 根据 `environments/<env>.yaml` 幂等合成缺失的 bootstrap 键，再运行 harvest 和 config 服务自举收敛。
- 新环境声明示例：`environments/staging.yaml`。

```bash
make environment-plan ENV=staging
make environment-ensure ENV=staging CONFIRM=yes
```

新环境必须先有对应 environment 的 operator token；operator 不能自行签发 operator token。首次授权需要管理员 JWT 或人工管理员流程。

## service token 轮换设计

完整安全轮换必须遵循：

```text
读取旧 token 元数据
  → 签发新 service token
  → 写入 OpenBao/ESO 目标 Secret
  → 让消费者重新加载
  → 用新 token 读回并验证
  → 吊销旧 token
```

失败规则：新 token 验证失败不动旧 token；Secret 更新失败不吊销旧 token；吊销失败保留状态并报警，之后重试。轮换状态必须落在可审计的 K8s Job/ConfigMap/数据库记录中，不能只放进进程变量。

`tools/config-center-rotate-service-tokens.sh` 实现了这个状态机（A 签发+新 token 读回+写 Secret → B 滚动消费者等就绪 → C 吊销旧 token；旧 id 落 `service-token-ids-previous` 注解，失败后重跑进续跑模式）。2026-09-15 起 pre 的 CronJob 已启用，见 `components/config-center-token-rotation/README.md` 的两次演练记录。

## Job/CronJob 安全边界

`components/config-center-token-rotation/` 提供了受限 RBAC 与 CronJob 骨架：

- CronJob 每周日 03:17 跑 pre（2026-09-15 起 `suspend: false`）；镜像在 TCR 按 digest 固定；
- `concurrencyPolicy: Forbid`；
- 不包含管理员密码、Casdoor 登录文件或管理员 JWT；
- 只引用预先签发的 operator Secret；
- operator token 只能操作自身 environment，不能签发 operator；
- RBAC 只允许读取/更新指定 operator Secret；
- `--apply-infra`、OpenBao root token 和 Casdoor 登录都不应放入 Job。

operator token 自身轮换仍需要管理员授权（`tools/config-center-operator-token.sh` + 管理员 JWT），不能由当前 operator 自我升级；这条边界是 CronJob 权限模型的基础，不要为了"全自动"去掉。
