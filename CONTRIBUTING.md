# 贡献指南

感谢你为 Cloud Native Deploy 改进部署清单、文档和运维经验。本仓库包含会影响 Kubernetes 集群、存储卷、Gateway、证书和数据服务的内容；请把可审阅、可回滚和不泄露凭据放在首位。

## 贡献范围

欢迎以下贡献：

- 修正 Kubernetes、Helm、Docker Compose 或 Shell 配置中的错误。
- 补充可复现的安装、升级、回滚、验证和故障排查说明。
- 更新已失效的资源引用，例如 Gateway、StorageClass、命名空间、服务名或版本。
- 补充与上游开源项目许可证相容的示例与文档链接。

不应提交：

- 密码、API Token、私钥、证书私钥、kubeconfig、真实会话 Cookie 或包含凭据的日志。
- 未经验证就宣称适用于生产环境的“一键部署”脚本。
- 与现有部署无关的大规模格式化或自动生成文件。

## 开始前

1. 阅读根目录 [README.md](README.md) 与目标组件目录中的 README。
2. 确认目标资源的命名空间、Gateway、StorageClass、依赖服务和现有运维方式。
3. 对影响集群的改动，先在隔离环境中审阅和验证；不要默认脚本可安全地用于任意集群。
4. 为新配置提供最小必要的说明：用途、前提条件、如何应用、如何验证，以及已知限制。

## 文档与配置约定

- 主要说明使用简体中文；产品名、资源字段、命令、API 名称和上游专有名词保留英文。
- 示例中的密码、Token、域名和 IP 必须使用环境变量或明确的脱敏占位符。
- Gateway API 资源应写清 parent Gateway 的名称、命名空间、listener 和 hostnames；不要假设默认命名空间或默认 listener。
- 涉及 PVC、StorageClass、节点亲和性或访问模式时，必须说明数据持久性和故障迁移影响。
- 修改运行方式后，同步更新根目录 `TODO.md` 中对应的进度、风险或验证记录。

## 提交变更

1. 将一个清晰的目的拆分为易于审阅的提交。
2. 在提交前检查敏感信息和无意加入的文件。
3. 提交信息遵循 Conventional Commits，例如：

   ```text
   docs(jaeger): 补充 badger 部署说明
   fix(gateway): 修正 HTTPRoute 的 parentRef
   chore(deploy): 清理失效的 TLS 示例
   ```

4. 在变更说明中写明影响范围、前提条件和没有执行的验证项。

## 提交问题与建议

请提供组件目录、Kubernetes/Helm 版本、期望行为、实际行为和必要的脱敏日志。涉及安全问题或意外泄露的凭据时，请遵循 [SECURITY.md](SECURITY.md)，不要在公开 Issue 中粘贴敏感信息。
