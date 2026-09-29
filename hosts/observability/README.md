# 云主机采集与预期主机清单

本目录是现役采集部署的唯一版本化来源。由旧 `observability/roles/host_otel` 迁入，不包含退役 Pigsty 剧本、历史审计备份或凭据。K8s 节点仍由 `components/opentelemetry-node` DaemonSet 采集，不在本 playbook 上安装第二份代理。

## 主机清单

`hosts.json` 同时维护云主机和 K8s 节点的预期身份：

- `host`：全局唯一名称，不含地址或凭据。
- `host_kind`：`cloud` 或 `kubernetes`。
- `disk_alert_owner`：`watchdog` 或 `vmalert`。一台机器的磁盘只交给一套规则。
- 云主机额外声明 `ssh_alias` 与 `cloud_provider`；SSH 地址与私钥仍由本机 SSH 配置管理。

运行 `make host-metrics-generate` 会生成两份产物：`inventory.generated.json`（仅云主机）与 `components/vmalert/rules/host-recording.yml`（全部预期主机）。从未上报的主机也保留在预期清单；移除主机必须主动改清单，不能靠指标消失自动忘记。

## 安装

前提：Python 3.12+、Ansible、Docker（提取固定 digest 的 Linux amd64 二进制）、kubectl 可读取既有 OTLP Secret，SSH alias/known_hosts 已准备好。凭据不传入 make 参数。

```bash
make -C hosts/observability bootstrap
make host-metrics-check
make host-otel CONFIRM=yes H=node3
# 单台通过后按清单串行扩展
make host-otel CONFIRM=yes
```

已有 Ansible 环境可显式设置 `ANSIBLE_PLAYBOOK=/path/to/ansible-playbook`；默认使用本目录 `.venv`，不依赖旧 observability 目录。生成物、版本号、镜像 digest、二进制 sha256 均受检查。

采集器保留原有 host_metrics、docker_stats、journald、容器日志、file_storage 落盘队列和自监控。迁移不改变 `/etc/otelcol`、`/var/lib/otelcol`、服务名或日志游标，不改 Docker 日志驱动、不关闭 host-watchdog。

## 验收与回退

部署逐台串行。检查服务、实际主机指标、自监控、日志和运行容器覆盖；敏感 token 任务使用 no_log。本机模板验证不能替代后端有数据。

```bash
make -C hosts/observability check
python3 components/vmalert/verify-host-metrics.py
```

共享指标语义与页面/告警迁移见 `components/vmalert/README-host-metrics.md`。仅修改清单或源码不会自动改远程机器，必须运行相应部署和验收。回退使用上一提交的同一入口，不运行旧 `observability/infra.yml` 或 `node.yml`。

旧 `observability/Makefile` 的 `host-otel` 已改为转发入口，`host-otel.yml` 转入本 playbook，`inventory.host-otel.yml` 是指向生成 inventory 的兼容链接；旧 Pigsty inventory 不再是现役真相源。
