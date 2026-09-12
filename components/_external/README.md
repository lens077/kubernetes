# _external —— 集群外依赖的契约声明

这里的每个目录只有一份 `component.env`，**不安装任何东西**：它声明一个集群外实例（node3 的 PostgreSQL / OTLP / Elasticsearch，云箱的 Casdoor）「地址、端口、协议、凭据在哪」，让消费方（`tools/config-center-harvest.sh`）用与集群内组件完全相同的字段读取。内外实例在消费方眼里没有区别，这正是把 PG 定稿在 node3 之后仍能自动填充的原因。

字段含义见 `components/_template/component.env`「依赖契约」段；`EXTERNAL=true` 时 80 阶段的 `verify_contracts` 不查 Service，只查 `CRED_SECRET` / `CA_REF` 是否已由 ESO 物化。

凭据流向：

```text
外部系统的真相(Pigsty CA、Casdoor 后台…) → 手工放入 OpenBao 一次: k8s/<CLUSTER_NAME>/<id>
  → ESO ExternalSecret(<id>/externalsecret.yaml, P1) → Secret external/<id> → harvest 读
```

同一能力有集群内组件并存时（CNPG 与 postgres-node3、集群内 collector 与 otlp-node3），由 `config.env` 的 `CC_PROVIDERS` 指定谁是提供方；只有一个启用候选时自动选中。

开关：`EXTERNAL_PG_NODE3` / `EXTERNAL_OTLP_NODE3` / `EXTERNAL_CASDOOR` / `EXTERNAL_ES_NODE3`（`config.env`，未定义时按 `DEFAULT_ENABLED`）。
