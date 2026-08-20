# VictoriaLogs（单机版）

**定位**：日志存储，拍板替 Loki（TECH-RADAR §8 定稿；用户 2026-08-20 拍板）。与已有 VictoriaMetrics 同族运维。
**上游**：vm/victoria-logs-single chart 0.13.9 / app v1.52.0（实测 2026-08-20）。
**本集群取舍**：先单机版（cluster 版随 v1.46 已 GA，量级到了再切）；retention 7d 仅验证期；与 Loki **≤72h 有界双写**后切主（验收=PII 反例/3 面板改写/查询等价/丢重检查），Loki 冻结只读至保留期满退役。
**暴露**：仅集群内 `:9428`（/insert/jsonline、/select/logsql、OTLP logs）。公网暴露必须加鉴权代理。
**验证**：port-forward 9428 后 `curl /insert/jsonline` 塞一条 + `/select/logsql/query` 查回（见 vector/README 联合验证）。
**Grafana**：victoriametrics-logs-datasource 插件 0.31.0（Grafana>=10.4，现 12.3.1 满足）——在 components/grafana values 追加 plugins+datasource 后 helm upgrade，勿只用增量段覆盖。
