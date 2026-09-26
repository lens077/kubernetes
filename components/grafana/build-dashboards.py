#!/usr/bin/env python3
"""Build the existing alert workbench and its bounded infrastructure drilldowns.

No live values are embedded. Use --check to detect generated-file drift.
"""
import argparse
import copy
import json
import pathlib

ROOT = pathlib.Path(__file__).parent
PROM = {"type": "prometheus", "uid": "${datasource}"}
EVIDENCE = {"type": "yesoreyeram-infinity-datasource", "uid": "ds-alert-evidence"}
ROWS = (ROOT / "alert_rows.jq").read_text()
NAV = [
    ("问题工作台", "ntfy-alerting-overview"), ("基础设施", "infra-overview"),
    ("数据库 / 备份", "infra-cnpg"), ("Kubernetes", "infra-kubernetes"),
    ("Kafka / CDC", "infra-cdc"), ("采集 / 网络", "infra-observability"),
]


def datasource_var():
    return {"name": "datasource", "label": "指标数据源", "type": "datasource", "query": "prometheus",
            "regex": "/VictoriaMetrics/", "refresh": 1, "options": [],
            "current": {"text": "VictoriaMetrics", "value": "VictoriaMetrics"}}


def variable(name, label, query=None, default=".*", hidden=False):
    result = {"name": name, "label": label, "hide": 2 if hidden else 0,
              "type": "query" if query else "textbox", "current": {"text": "All" if query else default, "value": "$__all" if query else default},
              "options": [], "skipUrlSync": False}
    if query:
        result.update(datasource=PROM, query=query, definition=query, refresh=1, includeAll=True, allValue=".*", multi=False, sort=1)
    else:
        result["query"] = default
    return result


def dashboard(uid, title, panels, variables=(), description=""):
    return {"uid": uid, "title": title, "id": None, "version": 3, "schemaVersion": 42,
            "editable": True, "description": description, "tags": ["infrastructure", "alerting", "evidence"],
            "timezone": "browser", "refresh": "30s", "time": {"from": "now-6h", "to": "now"},
            "annotations": {"list": []}, "panels": panels,
            "templating": {"list": [datasource_var(), *variables]},
            "links": [{"title": title, "url": "/d/" + target, "type": "link", "includeVars": False, "keepTime": True, "targetBlank": False}
                      for title, target in NAV if target != uid]}


def base(panel_id, title, kind, x, y, w, h, description=""):
    return {"id": panel_id, "title": title, "type": kind, "gridPos": {"x": x, "y": y, "w": w, "h": h}, "description": description}


def target(expr, ref="A", instant=False, legend=""):
    return {"refId": ref, "expr": expr, "datasource": PROM, "editorMode": "code",
            "instant": instant, "range": not instant, "legendFormat": legend}


def mappings(values):
    return [{"type": "value", "options": {str(k): {"text": v[0], "color": v[1]} for k, v in values.items()}}]


def stat(panel_id, title, expr, x, y, w=4, unit="short", healthy_one=False, values=None, description="", neutral=False):
    p = base(panel_id, title, "stat", x, y, w, 3, description)
    p.update(datasource=PROM, targets=[target(expr, instant=True)],
             options={"colorMode": "value", "graphMode": "none", "textMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}})
    steps = [{"color": "red" if healthy_one else "green", "value": None}, {"color": "green" if healthy_one else "red", "value": 1}]
    p["fieldConfig"] = {"defaults": {"unit": unit, "noValue": "指标缺失", "decimals": 0,
        "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": steps},
        "mappings": (mappings(values) if values else []) + [{"type": "special", "options": {"match": "null", "result": {"text": "指标缺失", "color": "gray"}}}]}, "overrides": []}
    if neutral:
        p['fieldConfig']['defaults']['color'] = {'mode': 'fixed', 'fixedColor': 'blue'}
    return p


def text(panel_id, title, content, y, h=4, x=0, w=24):
    return {**base(panel_id, title, "text", x, y, w, h), "options": {"mode": "markdown", "content": content}}


def timeseries(panel_id, title, queries, x, y, w=12, h=7, unit="short", description=""):
    return {**base(panel_id, title, "timeseries", x, y, w, h, description), "datasource": PROM,
            "targets": [target(q, chr(65+i), legend=legend) for i, (q, legend) in enumerate(queries)],
            "fieldConfig": {"defaults": {"unit": unit, "noValue": "指标缺失", "color": {"mode": "palette-classic"},
                 "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 6, "showPoints": "never", "spanNulls": False}}, "overrides": []},
            "options": {"legend": {"showLegend": True, "displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi"}}}


def override(field, **properties):
    return {"matcher": {"id": "byName", "options": field}, "properties": [{"id": k, "value": v} for k, v in properties.items()]}


def table(panel_id, title, expr, x, y, w=24, h=8, fields=None, unit="short", description=""):
    p = {**base(panel_id, title, "table", x, y, w, h, description), "datasource": PROM,
         "targets": [{**target(expr, instant=True), "format": "table"}],
         "fieldConfig": {"defaults": {"unit": unit, "custom": {"filterable": True, "wrapText": True, "wrapHeaderText": True, "cellOptions": {"type": "auto"}}}, "overrides": []},
         "options": {"showHeader": True, "cellHeight": "md", "enablePagination": True}}
    if fields:
        p["transformations"] = [{"id": "merge", "options": {}}, {"id": "organize", "options": {"includeByName": {k: True for k in fields}, "renameByName": fields,
                                                                      "indexByName": {k: i for i, k in enumerate(fields)}}}]
    return p


def evidence_target(tail="", columns=None):
    return {"refId": "A", "datasource": EVIDENCE, "type": "json", "source": "url", "format": "table", "parser": "jq-backend",
            "url": "http://vmalert.observability.svc.cluster.local:8880/api/v1/alerts", "url_options": {"method": "GET"},
            "root_selector": ROWS + tail, "columns": columns or [], "filters": []}


def columns(fields):
    return [{"selector": name, "text": name, "type": kind} for name, kind in fields]


def problem_table(panel_id, title, y, h=12, selected=False):
    tail = '\n| map(select((.key | @uri) == "${instance:percentencode}"))' if selected else ''
    cols = columns([(n, "number" if n == "condition_seconds" else "string") for n in
                    ("state", "kind_label", "severity", "summary", "resource", "condition_seconds", "description", "evidence", "logs",
                     "key", "original_rule", "detail_url", "evidence_url", "logs_url")])
    p = {**base(panel_id, title, "table", 0, y, 24, h,
                  "实时读取 vmalert annotations 与对象标签。条件持续时间从 activeAt 起算，包含 pending 等待；持续提醒不是独立故障。"),
         "datasource": EVIDENCE, "targets": [evidence_target(tail, cols)],
         "options": {"showHeader": True, "cellHeight": "auto", "enablePagination": True, "pageSize": 5},
         "fieldConfig": {"defaults": {"custom": {"filterable": True, "wrapText": True, "wrapHeaderText": True, "cellOptions": {"type": "auto"}}}, "overrides": []}}
    labels = {"state": "状态", "kind_label": "类型", "severity": "级别", "summary": "问题 / 点击详情", "resource": "影响对象",
              "condition_seconds": "条件持续", "description": "规则说明 / 下一步", "evidence": "查看证据", "logs": "对象日志"}
    widths = {"state": 75, "kind_label": 85, "severity": 65, "summary": 260, "resource": 180, "condition_seconds": 95,
              "description": 320, "evidence": 125, "logs": 115}
    for name, label in labels.items():
        props = {"displayName": label, "custom.width": widths[name]}
        if name == "condition_seconds": props.update(unit="s", decimals=0)
        if name == "severity": props.update(mappings=mappings({"critical": ("严重", "red"), "warning": ("警告", "orange"), "none": ("信息", "blue")}))
        if name == "state": props.update(mappings=mappings({"firing": ("触发中", "red"), "pending": ("等待确认", "orange")}))
        if name in ("summary", "evidence", "logs"):
            field = {"summary": "detail_url", "evidence": "evidence_url", "logs": "logs_url"}[name]
            props.update(links=[{"title": "${__value.raw}", "url": '${__data.fields["'+field+'"]:raw}' + ('&${__url_time_range}' if name != "logs" else ''), "targetBlank": False}],
                         **{"custom.cellOptions": {"type": "auto" if name == "summary" else "data-links"}, "custom.wrapText": True})
        p["fieldConfig"]["overrides"].append(override(name, **props))
    for hidden in ("key", "original_rule", "detail_url", "evidence_url", "logs_url"):
        p["fieldConfig"]["overrides"].append(override(hidden, **{"custom.hidden": True}))
    p["transformations"] = [{"id": "organize", "options": {"indexByName": {c["text"]: i for i, c in enumerate(cols)}}}]
    return p


def current_alerts(panel_id, y, group, h=9):
    p = problem_table(panel_id, "该类当前告警与排查", y, h)
    p["targets"][0] = evidence_target('\n| map(select(.labels.alertgroup == '+json.dumps(group)+' or .labels.exported_alertgroup == '+json.dumps(group)+'))', p["targets"][0]["columns"])
    return p


def build_main():
    # Preserve validated metric expressions/ids while moving task content before charts.
    old = json.loads((ROOT / "dashboards/ntfy-alerting-overview.json").read_text())
    old_panels = {p["id"]: copy.deepcopy(p) for p in old["panels"]}
    panels = []
    for i, pid in enumerate([1, 2, 3, 4, 5, 6]):
        p = old_panels[pid]
        p["gridPos"] = {"x": 4*i, "y": 0, "w": 4, "h": 3}
        p["options"]["colorMode"] = "value"
        panels.append(p)
    panels[0]["title"] = "触发实例（含提醒）"
    panels.append(problem_table(9, "当前问题 · 点击摘要看详情，点击证据直达对象", 3, 12))
    panels.append(text(15, "怎样读这张表", "**原始告警**来自实际规则，**持续提醒**关联原始告警，不表示新增独立故障。中文说明取自规则原文，是排查建议，不是自动确认的根因。\n\n用列标题筛选状态、级别和对象；**问题摘要 → 实例详情**，**查看证据 → 按对象过滤的基础设施面板**。空表表示当前无非 Watchdog 实例；若左上角有错误标记则是数据请求失败。", 15, 3))
    for pid, x in [(7, 0), (8, 12)]:
        p = old_panels[pid]; p["gridPos"] = {"x": x, "y": 18, "w": 12, "h": 7}; panels.append(p)
    for pid, x, w in [(11, 0, 6), (12, 6, 6), (10, 12, 12)]:
        p=old_panels[pid];p["gridPos"]={"x":x,"y":25,"w":w,"h":5};panels.append(p)
    p=old_panels[13];p["gridPos"]={"x":0,"y":30,"w":24,"h":9};panels.append(p)
    d=dashboard('ntfy-alerting-overview','ntfy 告警链路与降噪',panels,description='实时问题工作台：直接显示规则说明、对象、条件持续时间和证据入口；历史图只表示指标，不保存历史告警正文。')
    d['time']={'from':'now-24h','to':'now'}
    return d


def build_detail():
    selection='\n| map(select((.key | @uri) == "${instance:percentencode}"))'
    p1=problem_table(1,'告警实例 · 原文、对象和操作入口',3,10,selected=True)
    p2=base(2,'规则与实际观测值','table',0,13,24,7)
    p2.update(datasource=EVIDENCE,targets=[evidence_target(selection,columns([('rule','string'),('original_rule','string'),('expression','string'),('value','string'),('active_at','timestamp'),('stabilizing','boolean')]))],
              options={'showHeader':True,'cellHeight':'auto'},fieldConfig={'defaults':{'custom':{'wrapText':True,'cellOptions':{'type':'auto'}}},'overrides':[override('expression',**{'custom.width':780}),override('active_at',displayName='条件开始（含 pending）')]})
    p3=base(3,'完整对象标签（实时）','table',0,20,24,9)
    p3.update(datasource=EVIDENCE,targets=[evidence_target(selection+' | if length == 0 then [] else .[0].labels | to_entries end',columns([('key','string'),('value','string')]))],options={'showHeader':True,'cellHeight':'md'},fieldConfig={'defaults':{'custom':{'filterable':True}},'overrides':[]})
    info='从问题工作台选择具体实例。这里展示的是**当前仍活跃的实例**，不是历史正文存档。实例消失时，可能已恢复或规则已移除；请返回问题表，并用证据面板查看时间窗内的指标。\n\n**条件持续**从 vmalert `activeAt` 起算，包含 `for` 等待时间；`value` 是表达式原始值，单位由表达式决定。'
    return dashboard('alert-instance-detail','告警实例 · 说明与证据',[text(4,'实时实例详情',info,0,3),p1,p2,p3],[variable('instance','告警实例',default='')])


def build_cnpg():
    s='{cnpg_cluster=~"$cnpg_cluster",pod=~"$pod"}'
    backup='max(cnpg_collector_last_available_backup_timestamp'+s+')'
    panels=[
        stat(1,'数据库采集可用','min(cnpg_collector_up'+s+')',0,0,healthy_one=True,values={0:('不可用','red'),1:('可用','green')}),
        stat(2,'可用备份',backup+' > bool 0',4,0,healthy_one=True,values={0:('无可用备份','red'),1:('有备份记录','green')}),
        stat(3,'最近可用备份',backup+' * 1000',8,0,unit='dateTimeAsIso',values={0:('尚无备份','red')},neutral=True),
        stat(4,'距可用备份','(time() - ('+backup+' > 0)) or (0 * ('+backup+' == 0))',12,0,unit='s',values={0:('无备份 / 不计算','orange')},neutral=True,description='有备份才计算年龄，0 明确标为无备份；缺失指标单独显示，正值仅提供时长而非故障判定。'),
        stat(5,'WAL 归档失败 / 15m','sum(increase(cnpg_pg_stat_archiver_failed_count_total'+s+'[15m]))',16,0),
        stat(6,'最早可恢复点','max(cnpg_collector_first_recoverability_point'+s+') * 1000',20,0,unit='dateTimeAsIso',values={0:('未建立','red')},neutral=True),
        text(7,'备份问题怎样核实','**零值 ≠ 采集缺失。** `last_available_backup_timestamp=0` 表示没有可用备份时间；`first_recoverability_point=0` 表示未提供恢复点。先看下表的真实告警原文与原始值，再核对 ScheduledBackup / Backup 对象和归档日志。\n\n此面板不自动配置备份，也不宣称已经验证恢复。Backup CR 状态尚未作为时序数据接入；相关采集缺口见「基础设施」。',3,3),
        current_alerts(8,6,'cnpg',9),
        timeseries(9,'数据库连接 / max_connections', [('sum by(pod) (cnpg_backends_total'+s+') / on(pod) cnpg_pg_settings_setting{cnpg_cluster=~"$cnpg_cluster",pod=~"$pod",name="max_connections"}','{{pod}}')],0,15,unit='percentunit'),
        timeseries(10,'复制延迟', [('cnpg_pg_replication_lag'+s,'{{pod}}')],12,15,unit='s'),
        timeseries(11,'复制槽保留 WAL', [('cnpg_pg_replication_slots_pg_wal_lsn_diff'+s,'{{pod}} / {{slot_name}}')],0,22,unit='bytes'),
        timeseries(12,'WAL 归档成功 / 失败速率', [('sum by(pod)(rate(cnpg_pg_stat_archiver_archived_count_total'+s+'[$__rate_interval]))','{{pod}} 已归档'),('sum by(pod)(rate(cnpg_pg_stat_archiver_failed_count_total'+s+'[$__rate_interval]))','{{pod}} 失败')],12,22,unit='ops'),
        table(13,'备份原始时间戳（秒；0 = 无记录）','max by(cnpg_cluster,pod)(cnpg_collector_last_available_backup_timestamp'+s+')',0,29,12,6,fields={'cnpg_cluster':'集群','pod':'实例','Value':'原始时间戳'}),
        table(14,'实例与采集状态','cnpg_collector_up'+s,12,29,12,6,fields={'cnpg_cluster':'集群','pod':'实例','k8s_node_name':'节点','Value':'采集可用'})]
    return dashboard('infra-cnpg','PostgreSQL · 备份与实例证据',panels,[variable('cnpg_cluster','数据库集群','label_values(cnpg_collector_up, cnpg_cluster)'),variable('pod','实例','label_values(cnpg_collector_up{cnpg_cluster=~"$cnpg_cluster"}, pod)')])


def build_kubernetes():
    s='{k8s_namespace_name=~"$namespace",k8s_pod_name=~"$pod"}'
    running='(k8s_pod_phase'+s+' == 2)'
    panels=[
        stat(1,'Ready 节点','sum(k8s_node_condition_ready{k8s_node_name=~"$node"})',0,0,6,neutral=True),
        stat(2,'Running Pod','count('+running+')',6,0,6,neutral=True),
        stat(3,'未就绪运行容器','count((k8s_container_ready'+s+' == 0) and on(k8s_namespace_name,k8s_pod_name) '+running+') or (0*count(k8s_container_ready'+s+'))',12,0,6),
        stat(4,'重启增量 / 15m','sum(increase(k8s_container_restarts'+s+'[15m]))',18,0,6),
        table(5,'Deployment 期望 / 可用差','k8s_deployment_desired{k8s_namespace_name=~"$namespace"} - on(k8s_deployment_uid) group_left k8s_deployment_available{k8s_namespace_name=~"$namespace"}',0,3,12,7,fields={'k8s_namespace_name':'命名空间','k8s_deployment_name':'Deployment','Value':'缺少副本'}),
        table(6,'StatefulSet 未就绪副本','k8s_statefulset_desired_pods{k8s_namespace_name=~"$namespace"} - on(k8s_statefulset_uid) group_left k8s_statefulset_ready_pods{k8s_namespace_name=~"$namespace"}',12,3,12,7,fields={'k8s_namespace_name':'命名空间','k8s_statefulset_name':'StatefulSet','Value':'未就绪副本'}),
        table(7,'容器状态与对象','k8s_container_ready'+s,0,10,24,9,fields={'k8s_namespace_name':'命名空间','k8s_pod_name':'Pod','k8s_container_name':'容器','Value':'Ready'}),
        timeseries(8,'容器重启增量 / 15m',[('sum by(k8s_pod_name)(increase(k8s_container_restarts'+s+'[15m]))','{{k8s_pod_name}}')],0,19),
        table(9,'节点 Ready','k8s_node_condition_ready{k8s_node_name=~"$node"}',12,19,12,7,fields={'k8s_node_name':'节点','Value':'Ready'}),
        current_alerts(10,26,'ecommerce-k8s',9),
        text(11,'证据边界','**这里是对象状态，不是实际 CPU/内存利用率。** requests/limits 只是资源声明；实际用量未接入时不画成“利用率”。\n\n运行中 Ready=0 才是容器就绪问题；Completed Job 的 Ready=0 不按故障解释。告警实例详情提供精确 Pod 日志入口。',35,4)]
    return dashboard('infra-kubernetes','Kubernetes · 对象与就绪证据',panels,[variable('namespace','命名空间','label_values(k8s_container_ready, k8s_namespace_name)'),variable('pod','Pod','label_values(k8s_container_ready{k8s_namespace_name=~"$namespace"}, k8s_pod_name)'),variable('node','节点','label_values(k8s_node_condition_ready, k8s_node_name)')])


def build_cdc():
    s='{connector=~"$connector"}'
    panels=[
        table(1,'Connect task 当前状态','kafka_connect_connector_task_status'+s,0,0,12,7,fields={'connector':'连接器','task':'任务','status':'状态','Value':'状态标志'}),
        stat(2,'Debezium 源库连接','min(debezium_metrics_connected{context="streaming"})',12,0,6,healthy_one=True,values={0:('断开','red'),1:('已连接','green')}),
        stat(3,'源库事件落后','max(debezium_metrics_millisecondsbehindsource{context="streaming"})',18,0,6,unit='ms',values={-1:('空闲 / 无事件','blue')},neutral=True),
        table(4,'PG / ES 行数差','abs(max by(cdc_table)(cnpg_cdc_rows_count) - on(cdc_table) max by(cdc_table)(cdc_es_docs_count))',12,3,12,4,fields={'cdc_table':'表','Value':'行数差'}),
        timeseries(5,'复制槽保留 WAL',[('max by(slot_name)(cnpg_pg_replication_slots_pg_wal_lsn_diff)','{{slot_name}}')],0,7,unit='bytes'),
        timeseries(6,'消费组 lag',[('max by(consumergroup,topic)(kafka_consumergroup_lag)','{{consumergroup}} / {{topic}}')],12,7),
        stat(7,'最近对账结果','max(cdc_es_reconcile_run_ok)',0,14,6,healthy_one=True,values={0:('失败','red'),1:('成功','green')}),
        stat(8,'对账样本年龄','time()-max(timestamp(cdc_es_reconcile_run_ok))',6,14,6,unit='s',neutral=True),
        text(9,'状态与进展分开看','**Task running 不证明位点推进。** 联看复制槽 WAL、消费 lag 和 PG/ES 对账。Debezium 延迟 `-1` 表示空闲无事件，不是负延迟。\n\n连接器筛选作用于 task；复制槽与对账仍显示链路级证据，避免把别的来源静默过滤掉。',14,3,12,12),
        current_alerts(10,17,'ecommerce-cdc',10)]
    return dashboard('infra-cdc','Kafka / CDC · 位点与对账证据',panels,[variable('connector','连接器','label_values(kafka_connect_connector_task_status, connector)')])


def build_observability():
    panels=[
        stat(1,'vmalert → AM 发送错误 / 10m','sum(increase(vmalert_alerts_send_errors_total[10m]))',0,0,6),
        stat(2,'AM 通知失败 / 10m','sum(increase(alertmanager_notifications_failed_total[10m]))',6,0,6),
        stat(3,'bridge 发布失败 / 10m','sum(increase(alert_bridge_notifications_total{result="failed"}[10m]))',12,0,6),
        stat(4,'Gatus 最近探测成功率','avg(gatus_results_endpoint_success)',18,0,6,unit='percentunit',healthy_one=True),
        timeseries(5,'OTel 导出队列占比',[('max by(exporter)(otelcol_exporter_queue_size / otelcol_exporter_queue_capacity)','{{exporter}}')],0,3,unit='percentunit'),
        timeseries(6,'网络丢弃速率（原因）',[('sum by(reason)(rate(hubble_drop_total[$__rate_interval]))','{{reason}}')],12,3,unit='ops',description='丢包原因来自 Hubble。不是每一种丢包都代表用户故障；结合对象、策略和业务影响。'),
        timeseries(7,'vmalert 状态写回错误',[('sum(rate(vmalert_remotewrite_errors_total[$__rate_interval]))','remoteWrite 错误')],0,10,unit='ops'),
        table(8,'Gatus 最近一次探测结果','min by(group,name,key)(gatus_results_endpoint_success)',12,10,12,7,fields={'group':'分组','name':'端点','Value':'成功（1/0）'}),
        current_alerts(9,17,'observability-pipeline',9),
        current_alerts(10,26,'ecommerce-security',8),
        text(11,'未覆盖与误判边界','本页只显示已存在的 OTel、Hubble、Gatus 与通知指标。**Vector 自身安全指标缺失、宿主资源和外部 dead-man 不能用健康探针替代。** 无指标保留缺失状态。\n\n通知发送成功仅表示服务接受；手机订阅和终端送达是另外的验收。',34,4)]
    return dashboard('infra-observability','观测链路 · 采集与网络证据',panels)


def build_overview():
    capabilities=[('Kubernetes 对象状态','k8s_container_ready','infra-kubernetes'),('CNPG / 备份时间','cnpg_collector_up','infra-cnpg'),
                  ('Kafka / Connect','kafka_connect_connector_task_status','infra-cdc'),('OTel 导出队列','otelcol_exporter_queue_size','infra-observability'),
                  ('Hubble 网络事件','hubble_flows_processed_total','infra-observability'),('Gatus 合成探测','gatus_results_endpoint_success','infra-observability'),
                  ('通知 bridge','alert_bridge_notifications_total','ntfy-alerting-overview'),('宿主 CPU exporter','node_cpu_seconds_total','infra-kubernetes')]
    expressions=['label_replace(label_replace((count('+metric+') > bool 0) or vector(0), "capability", '+json.dumps(name,ensure_ascii=False)+', "", ""), "dashboard_uid", "'+uid+'", "", "")' for name,metric,uid in capabilities]
    p=table(1,'观测覆盖 · 有指标不等于服务健康',' or '.join(expressions),0,0,24,10,fields={'capability':'观测能力','Value':'当前数据','dashboard_uid':'入口'})
    p['fieldConfig']['overrides']=[override('当前数据',mappings=mappings({0:('未接入 / 无数据','red'),1:('有指标','green')})),
        override('观测能力',links=[{'title':'打开证据面板','url':'/d/${__data.fields["入口"]}?${__url_time_range}','targetBlank':False}]),override('入口',**{'custom.hidden':True})]
    panels=[p,text(2,'基础设施定位路径','**数据库 / 备份**：可用备份时间、恢复点、WAL、连接与复制。\n\n**Kubernetes**：节点 Ready、Deployment/StatefulSet、运行容器与重启。\n\n**Kafka / CDC**：task、源库连接、复制槽、lag 和对账。\n\n**采集 / 网络**：OTel 队列、Hubble 丢弃、Gatus 与通知链。\n\n当前告警的「查看证据」会携带对象筛选；每页顶部可返回问题工作台。',10,7),
      text(3,'仍需补齐的观测，不以空白冒充健康','- node0/node1/node2 宿主资源与 watchdog 状态尚无本套 Prometheus 证据；不能把 Kubernetes 节点状态当成全部宿主。\n- 容器实际 CPU/内存、磁盘容量需要对应采集器，requests/limits 不等于实际用量。\n- CNPG Backup / ScheduledBackup 对象状态和恢复演练尚未在本面板自动取证；备份时间为 0 能证明缺少可用备份记录，不能单独区分配置缺失与任务失败。\n- Silo、Redis、Elasticsearch 等应用专属指标未逐一接入；目前只能查其 Kubernetes 对象和已配置的 Gatus 探测。\n- 外部独立 dead-man 与手机送达仍需独立验证。',17,8)]
    return dashboard('infra-overview','基础设施 · 观测覆盖与定位入口',panels)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    documents=[build_main(),build_detail(),build_cnpg(),build_kubernetes(),build_cdc(),build_observability(),build_overview()]
    dirty=[]
    for doc in documents:
        out=ROOT/'dashboards'/(doc['uid']+'.json')
        data=json.dumps(doc,ensure_ascii=False,indent=2)+'\n'
        if args.check:
            if not out.exists() or out.read_text()!=data:dirty.append(out.name)
        else:out.write_text(data)
    if dirty:raise SystemExit('Generated dashboard drift: '+', '.join(dirty))
    print(('checked' if args.check else 'generated'),len(documents),'dashboards')


if __name__=='__main__':main()
