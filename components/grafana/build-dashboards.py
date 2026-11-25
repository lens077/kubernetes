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
    ("运维控制台", "ops-portal"),
    ("问题工作台", "ntfy-alerting-overview"), ("基础设施", "infra-overview"),
    ("数据库 / 备份", "infra-cnpg"), ("Kubernetes", "infra-kubernetes"),
    ("Kafka / CDC", "infra-cdc"), ("采集 / 网络", "infra-observability"),
    ("控制面进程", "control-plane-overview"), ("中间件", "middleware-overview"),
    ("电商 APM", "ecommerce-apm"),
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


def stat(panel_id, title, expr, x, y, w=4, unit="short", healthy_one=False, values=None, description="", neutral=False, decimals=0):
    p = base(panel_id, title, "stat", x, y, w, 3, description)
    p.update(datasource=PROM, targets=[target(expr, instant=True)],
             options={"colorMode": "value", "graphMode": "none", "textMode": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}})
    steps = [{"color": "red" if healthy_one else "green", "value": None}, {"color": "green" if healthy_one else "red", "value": 1}]
    p["fieldConfig"] = {"defaults": {"unit": unit, "noValue": "指标缺失", "decimals": decimals,
        "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": steps},
        "mappings": (mappings(values) if values else []) + [{"type": "special", "options": {"match": "null", "result": {"text": "指标缺失", "color": "gray"}}}]}, "overrides": []}
    if neutral:
        p['fieldConfig']['defaults']['color'] = {'mode': 'fixed', 'fixedColor': 'blue'}
    return p


def text(panel_id, title, content, y, h=4, x=0, w=24):
    return {**base(panel_id, title, "text", x, y, w, h), "options": {"mode": "markdown", "content": content}}


def row(panel_id, title, y):
    """可折叠分组标题；后续面板是它的兄弟节点，不是嵌套子面板。"""
    return {**base(panel_id, title, "row", 0, y, 24, 1), "collapsed": False, "panels": []}


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
                  ('通知 bridge','alert_bridge_notifications_total','ntfy-alerting-overview'),('K8s 节点资源（共享指标）','host:cpu_busy_ratio{host_kind="kubernetes"}','ops-portal'),('云主机资源（共享指标）','host:cpu_busy_ratio{host_kind="cloud"}','ops-portal')]
    expressions=['label_replace(label_replace((count('+metric+') > bool 0) or vector(0), "capability", '+json.dumps(name,ensure_ascii=False)+', "", ""), "dashboard_uid", "'+uid+'", "", "")' for name,metric,uid in capabilities]
    p=table(1,'观测覆盖 · 有指标不等于服务健康',' or '.join(expressions),0,0,24,10,fields={'capability':'观测能力','Value':'当前数据','dashboard_uid':'入口'})
    p['fieldConfig']['overrides']=[override('当前数据',mappings=mappings({0:('未接入 / 无数据','red'),1:('有指标','green')})),
        override('观测能力',links=[{'title':'打开证据面板','url':'/d/${__data.fields["入口"]}?${__url_time_range}','targetBlank':False}]),override('入口',**{'custom.hidden':True})]
    panels=[p,text(2,'基础设施定位路径','**数据库 / 备份**：可用备份时间、恢复点、WAL、连接与复制。\n\n**Kubernetes**：节点 Ready、Deployment/StatefulSet、运行容器与重启。\n\n**Kafka / CDC**：task、源库连接、复制槽、lag 和对账。\n\n**采集 / 网络**：OTel 队列、Hubble 丢弃、Gatus 与通知链。\n\n当前告警的「查看证据」会携带对象筛选；每页顶部可返回问题工作台。',10,7),
      text(3,'仍需补齐的观测，不以空白冒充健康','- 云主机 node1–node4 已有 CPU/内存/磁盘/网络指标（host_otel），但容器、systemd 单元与 host-watchdog 巡检结果仍只在 host-watchdog 本机，不进本套指标。\n- 容器实际 CPU/内存、磁盘容量需要对应采集器，requests/limits 不等于实际用量。\n- CNPG Backup / ScheduledBackup 对象状态和恢复演练尚未在本面板自动取证；备份时间为 0 能证明缺少可用备份记录，不能单独区分配置缺失与任务失败。\n- Silo、Redis、Elasticsearch 等应用专属指标未逐一接入；目前只能查其 Kubernetes 对象和已配置的 Gatus 探测。\n- 外部独立 dead-man 与手机送达仍需独立验证。',17,8)]
    return dashboard('infra-overview','基础设施 · 观测覆盖与定位入口',panels)


# 跳转控制台只收「给人打开的页面」。以下 Pangolin 资源刻意不收：纯 API / 数据入口
# (argocd-api、config-api、scorpius-api、silo-api、es-dev、minio 的 S3 端口、otlp-dev、gateway)
# 打开只会得到 JSON、401 或 404；lyrapass-tunnel-internal 已 blockAccess；
# cat / getcat / dsh 在个人 mac 上，常离线，不属于运维入口。
PORTAL_LINKS = [
    ("观测 / 告警", [
        ("VMUI 指标查询", "https://metrics.apikv.com/vmui/", "只读 · 用户 ops"),
        ("vmalert 规则", "https://vmalert.apikv.com/", "规则与评估状态"),
        ("Alertmanager", "https://alerts.apikv.com/", "静默 / 分组"),
        ("链路追踪", "https://traces.apikv.com/select/vmui/", "VictoriaTraces"),
        ("Healthchecks", "https://hc.apikv.com/", "定时任务心跳"),
        ("ntfy", "https://ntfy.apikv.com/", "通知主题"),
    ]),
    ("平台管理", [
        ("Pangolin", "https://pangolin.apikv.com/", "公网入口 / 隧道"),
        ("Argo CD", "https://argocd.apikv.com/", "K8s 发布"),
        ("配置中心", "https://config.apikv.com/", ""),
        ("Casdoor", "https://casdoor.apikv.com/", "统一登录"),
        ("密码管理", "https://ps.apikv.com/", "Vaultwarden"),
        ("Umami", "https://umami.apikv.com/", "站点访问统计"),
        ("Gorse", "https://gorse.apikv.com/", "推荐引擎"),
    ]),
    ("业务站点", [
        ("主页", "https://apikv.com/", ""),
        ("商城", "https://shop.apikv.com/", "灯市 · ecommerce"),
        ("博客", "https://blog.apikv.com/", ""),
        ("剪贴板", "https://scorpius.apikv.com/", "Scorpius"),
        ("Silo", "https://silo.apikv.com/", ""),
        ("CS", "https://cs.apikv.com/", ""),
        ("MCM", "https://mcm.apikv.com/", ""),
        ("Stream", "https://stream.apikv.com/", "MediaMTX"),
    ]),
]


def portal_html():
    """Link cards for the text panel. Only inline styles Grafana's sanitizer keeps (flex, not grid)."""
    card = ('display:block;min-width:150px;padding:8px 12px;border-radius:6px;text-decoration:none;'
            'border:1px solid rgba(127,127,127,0.35);background:rgba(127,127,127,0.08)')
    def link(name, url, note):
        # 站内面板同页打开（保留登录态与时间范围），外部服务新标签页打开。
        blank = '' if url.startswith('/') else ' target="_blank"'
        caption = note or url.split('//')[-1].rstrip('/')
        return (f'<a href="{url}"{blank} style="{card}"><b>{name}</b><br>'
                f'<small style="opacity:0.7">{caption}</small></a>')
    def group(title, items):
        cards = ''.join(link(*item) for item in items)
        return (f'<div style="margin-bottom:10px"><div style="font-weight:600;opacity:0.8;margin-bottom:6px">{title}</div>'
                f'<div style="display:flex;flex-wrap:wrap;gap:8px">{cards}</div></div>')
    notes = {'ntfy-alerting-overview': '当前告警与详情', 'infra-overview': '观测覆盖', 'infra-cnpg': '备份 / 复制',
             'infra-kubernetes': '对象 / 就绪', 'infra-cdc': '位点 / 对账', 'infra-observability': 'OTel / Gatus / 通知',
             'control-plane-overview': 'apiserver / etcd / scheduler', 'middleware-overview': 'Dragonfly / MinIO / ES',
             'ecommerce-apm': 'RED / Go runtime / Pyroscope'}
    internal = [(name, '/d/' + uid, notes.get(uid, '')) for name, uid in NAV if uid != 'ops-portal']
    internal.append(('日志 Explore', '/explore', 'VictoriaLogs'))
    return ''.join(group(t, items) for t, items in [('Grafana 面板', internal), *PORTAL_LINKS])


def bargauge(panel_id, title, expr, x, y, w=8, h=8, description=""):
    return {**base(panel_id, title, "bargauge", x, y, w, h, description), "datasource": PROM,
            "targets": [target(expr, instant=True, legend="{{host}}")],
            "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0, "max": 1, "decimals": 1, "noValue": "指标缺失",
                 "color": {"mode": "thresholds"},
                 "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}]}},
                 "overrides": []},
            "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True, "valueMode": "color",
                        "namePlacement": "left", "sizing": "auto",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}}


HOST_FRESH = '(time() - host:rules_evaluation_timestamp_seconds < 180)'


def host_query(metric, signal):
    """Consume the shared contract; do not reimplement resource formulas here."""
    return (f'(({metric}) and (time() - timestamp({metric}) < 180) '
            f'and on(host,host_kind) (host:signal_present{{signal="{signal}"}} == 1) '
            f'and on(host,host_kind) (time() - timestamp(host:signal_present{{signal="{signal}"}}) < 180) '
            'and on(host,host_kind) host:expected_info '
            'and on(host,host_kind) (time() - host:last_seen_timestamp_seconds < 180)) '
            f'and on() {HOST_FRESH}')


def expected_or_missing(expr):
    # VM drops NaN results. A display-only -1 sentinel is explicitly mapped to gray
    # missing text; canonical ratio records remain 0..1 or absent, never synthetic zero.
    return f'({expr}) or on(host,host_kind) (group by(host,host_kind) (host:expected_info) * -1)'


def build_portal():
    cpu = host_query('host:cpu_busy_ratio', 'cpu')
    wait = host_query('host:cpu_iowait_ratio', 'cpu')
    mem = host_query('host:memory_used_ratio', 'memory')
    disk = host_query('host:filesystem_used_ratio{mountpoint="/"}', 'filesystem')
    links = text(1, '', portal_html(), 0, 11)
    links['options']['mode'] = 'html'
    current_coverage = '(host:signal_present and (time() - timestamp(host:signal_present) < 180))'
    coverage_expr = (f'(min by(host,host_kind) {current_coverage} '
                     f'and on(host,host_kind) (count by(host,host_kind) {current_coverage} == 4) '
                     f'and on() {HOST_FRESH}) or on(host,host_kind) (host:expected_info * -1)')
    coverage = table(9, '预期主机覆盖 · 缺一项也不算齐全', coverage_expr, 0, 19, 12, 9,
                     fields={'host':'主机','host_kind':'类型','Value':'指标覆盖'})
    coverage['fieldConfig']['overrides'] = [override('指标覆盖', mappings=mappings({1:('四类指标齐全','green'),0:('部分指标缺失','orange'),-1:('规则数据缺失 / 延迟','gray')}))]
    age = table(10, '原始上报距今 · 非规则重写时间', expected_or_missing('time() - host:last_seen_timestamp_seconds'), 12, 19, 12, 9,
                fields={'host':'主机','host_kind':'类型','Value':'距今'})
    age['fieldConfig']['overrides'] = [override('距今', unit='s', decimals=0, noValue='从未上报 / 无数据', mappings=mappings({-1:('从未上报 / 无数据','gray')}))]
    for p in (coverage, age):
        p['options'].update(enablePagination=False, cellHeight='sm')
    osinfo = table(13, '系统信息 · OS / 架构（不登录机器）', 'host:os_info', 0, 53, 24, 8,
                   fields={'host':'主机','host_kind':'类型','os_type':'OS','os_version':'版本','host_arch':'架构'})
    osinfo['options'].update(enablePagination=False, cellHeight='sm')
    panels = [
        links,
        bargauge(2, 'CPU 忙碌率', expected_or_missing(cpu), 0, 11, w=6, description='共享 host:cpu_busy_ratio；跨核平均，不包含 idle 与 iowait。'),
        bargauge(8, 'I/O 等待', expected_or_missing(wait), 6, 11, w=6, description='共享 host:cpu_iowait_ratio；等待不是 CPU 执行时间，不与忙碌率重复相加。'),
        bargauge(3, '内存使用率', expected_or_missing(mem), 12, 11, w=6, description='OTel used 状态，不是 MemAvailable 口径；所有消费方使用同一记录规则。'),
        bargauge(4, '根分区使用率', expected_or_missing(disk), 18, 11, w=6, description='共享 used/(used+free)，不含 root 保留块。'),
        coverage, age,
        timeseries(5, 'CPU 忙碌率趋势', [(cpu, '{{host}}')], 0, 28, h=11, unit='percentunit'),
        timeseries(6, '内存使用率趋势', [(mem, '{{host}}')], 12, 28, h=11, unit='percentunit'),
        timeseries(11, 'I/O 等待趋势', [(wait, '{{host}}')], 0, 39, h=10, unit='percentunit'),
        timeseries(12, '主机网络速率', [(host_query('host:network_io_bytes_per_second','network'), '{{host}} / {{direction}}')], 12, 39, h=10, unit='Bps'),
        text(7, '覆盖范围与数据口径', '主机清单来自 Kubernetes 仓 `hosts/observability/hosts.json`，采集部署用 `make host-otel CONFIRM=yes`。'
             '**CPU、iowait、内存、磁盘与网络统一读取共享记录指标**；缺失不补零，主机不会因从未上报而从清单消失。'
             '\n\n180 秒是展示新鲜度，不是失联通知的触发时间。历史曲线从共享规则上线时开始，不回填或改写原始数据。'
             '容器与进程数据属于其它指标，不与宿主资源混用。', 49, 4),
    ]
    for p in panels:
        if p['type'] == 'timeseries' and p['id'] != 12:
            p['fieldConfig']['defaults'].update(min=0, max=1)
        if p['type'] == 'bargauge':
            p['fieldConfig']['defaults']['mappings'] = mappings({-1:('指标缺失','gray')})
    d = dashboard('ops-portal', '运维控制台 · 跳转与资源', panels, description='共享 host:* 指标：全部主机资源、I/O 等待、预期覆盖与采集新鲜度。')
    d['time'] = {'from': 'now-3h', 'to': 'now'}
    return d


def build_control_plane():
    """控制面进程证据。

    components/control-plane-metrics 直抓四个 127.0.0.1 端点并 remote write 到 VM，指标名保持
    组件原始导出：apiserver_* / etcd_* / scheduler_*，controller-manager 的队列指标是
    workqueue_*（用 component="controller-manager" 区分）。表达式按上游标准名写，端点恢复后
    自动出图；现在没 series 的位置显示「指标缺失」，不补零、不画假健康。
    """
    live = [stat(i, t, e, x, 0, 6, healthy_one=True,
                 values={0: ('抓取失败 / 未接入', 'red'), 1: ('存活', 'green')})
            for i, t, e, x in [
                (1, 'apiserver 抓取', 'up{job="control-plane-apiserver"}', 0),
                (2, 'etcd 抓取', 'up{job="control-plane-etcd"}', 6),
                (3, 'scheduler 抓取', 'up{job="control-plane-scheduler"}', 12),
                (4, 'controller-manager 抓取', 'up{job="control-plane-controller-manager"}', 18)]]
    panels = live + [
        text(5, '读数口径',
             '**抓取存活 ≠ 进程健康**：`up` 只表示采集器拿到了 `/metrics`；静态 Pod 的 Phase / Ready 请看「Kubernetes · 对象与就绪证据」。\n\n'
             '采集器保留组件原始指标名：`apiserver_*`、`etcd_*`、`scheduler_*`，controller-manager 的队列指标叫 `workqueue_*`'
             '（用 `component="controller-manager"` 区分）。apiserver 请求指标目前没有 series（127.0.0.1:6443 的抓取尚未产生数据），'
             '面板按上游标准名保留，端点恢复后自动出图；缺失显示「指标缺失」，不补零。', 3, 3),
        row(6, 'etcd · Leader 与 Raft', 6),
        stat(7, '当前 Leader', 'etcd_server_is_leader', 0, 7, 6, healthy_one=True,
             values={0: ('非 Leader', 'orange'), 1: ('是 Leader', 'green')}, description='1 表示该实例是 Raft leader。'),
        stat(8, '存在 Leader', 'etcd_server_has_leader', 6, 7, 6, healthy_one=True,
             values={0: ('无 Leader', 'red'), 1: ('有 Leader', 'green')}),
        stat(9, 'Leader 变更 / 1h', 'increase(etcd_server_leader_changes_seen_total[1h])', 12, 7, 6,
             description='频繁变更意味着选举或网络抖动；0 表示这一小时没有切换。'),
        stat(10, '后端 DB 大小', 'etcd_mvcc_db_total_size_in_bytes', 18, 7, 6, unit='bytes', neutral=True),
        timeseries(11, 'Raft 提议提交 / 应用 / 失败', [
            ('sum(rate(etcd_server_proposals_committed_total[$__rate_interval]))', '已提交'),
            ('sum(rate(etcd_server_proposals_applied_total[$__rate_interval]))', '已应用'),
            ('sum(rate(etcd_server_proposals_failed_total[$__rate_interval]))', '失败')], 0, 10, w=12, unit='ops'),
        timeseries(12, 'etcd 服务端请求速率', [
            ('sum by(code)(rate(etcd_server_client_requests_total[$__rate_interval]))', '{{code}}')], 12, 10, w=12, unit='ops',
            description='这是 etcd 自身按响应码统计的服务端请求，不是 apiserver 转发量。'),
        row(13, 'apiserver · 请求比例与延迟', 17),
        stat(14, '请求速率', 'sum(rate(apiserver_request_total[$__rate_interval]))', 0, 18, 6, unit='ops'),
        stat(15, '5xx 错误率',
             'sum(rate(apiserver_request_total{code=~"5.."}[$__rate_interval])) / '
             'sum(rate(apiserver_request_total[$__rate_interval]))', 6, 18, 6, unit='percentunit', decimals=1,
             healthy_one=False, description='低为健康；分母为全部请求，缺失时不计算。'),
        stat(16, 'P99 请求延迟',
             'histogram_quantile(0.99, sum by(le)(rate(apiserver_request_duration_seconds_bucket[$__rate_interval])))',
             12, 18, 6, unit='s', decimals=3),
        stat(17, '在处理请求', 'sum(apiserver_current_inflight_requests)', 18, 18, 6, neutral=True),
        timeseries(18, '请求速率 · 按响应码', [
            ('sum by(code)(rate(apiserver_request_total[$__rate_interval]))', '{{code}}')], 0, 21, w=12, unit='ops'),
        timeseries(19, '请求延迟分位', [
            ('histogram_quantile(0.50, sum by(le)(rate(apiserver_request_duration_seconds_bucket[$__rate_interval])))', 'P50'),
            ('histogram_quantile(0.90, sum by(le)(rate(apiserver_request_duration_seconds_bucket[$__rate_interval])))', 'P90'),
            ('histogram_quantile(0.99, sum by(le)(rate(apiserver_request_duration_seconds_bucket[$__rate_interval])))', 'P99')],
            12, 21, w=12, unit='s'),
        row(20, 'scheduler / controller-manager · 排队与重试', 28),
        timeseries(21, '调度尝试 · 按结果', [
            ('sum by(result)(rate(scheduler_schedule_attempts_total[$__rate_interval]))', '{{result}}')], 0, 29, w=12, unit='ops',
            description='"unschedulable" 升高说明有 Pod 找不到合适节点，不等于调度器故障。'),
        timeseries(22, '待调度 Pod · 按队列', [
            ('sum by(queue)(scheduler_pending_pods)', '{{queue}}')], 12, 29, w=12),
        timeseries(23, 'workqueue 深度 · controller-manager', [
            ('topk(10, sum by(name)(workqueue_depth{component="controller-manager"}))', '{{name}}')], 0, 36, w=12,
            description='按队列名聚合，避免几十条同名序列把图例刷爆。'),
        timeseries(24, 'workqueue 重试速率 · controller-manager', [
            ('topk(10, sum by(name)(rate(workqueue_retries_total{component="controller-manager"}[$__rate_interval])))', '{{name}}')],
            12, 36, w=12, unit='ops'),
        text(25, '证据边界',
             '这些是**进程级指标**，回答「组件自己报告了什么」。Pod 是否 Running/Ready、是否被调度，仍以 Kubernetes 对象面板为准；'
             'apiserver 的 5xx 与 P99 只反映收到并完成的请求，请求根本没到时不会在此显红。'
             '\n\n本页不含任何合成探测结果：外部可达性由 Gatus 负责。', 43, 4)]
    return dashboard('control-plane-overview', 'Kubernetes 控制面 · 进程级证据', panels,
                     description='apiserver / etcd / scheduler / controller-manager 抓取存活、etcd Leader、apiserver 延迟与错误率、调度与队列。')


def build_middleware():
    """Dragonfly / MinIO / Elasticsearch 三组证据，指标名均已在 VM 验证。"""
    hit = 'dragonfly_keyspace_hits_total'
    miss = 'dragonfly_keyspace_misses_total'
    panels = [
        row(1, 'Dragonfly · 缓存', 0),
        stat(2, '连接客户端', 'sum(dragonfly_connected_clients)', 0, 1, 6),
        stat(3, 'Keyspace 命中率',
             'sum(rate(' + hit + '[$__rate_interval])) / '
             'clamp_min(sum(rate(' + hit + '[$__rate_interval])) + sum(rate(' + miss + '[$__rate_interval])), 1)',
             6, 1, 6, unit='percentunit', decimals=1, description='命中 /（命中 + 未命中）；没有流量时显示 0，不冒充命中。'),
        stat(4, '内存使用', 'sum(dragonfly_memory_used_bytes)', 12, 1, 6, unit='bytes', neutral=True),
        stat(5, '阻塞客户端', 'sum(dragonfly_blocked_clients)', 18, 1, 6,
             description='非零表示有客户端因内存或慢命令被阻塞，结合延迟与内存再看。'),
        timeseries(6, 'Keyspace 命中 / 未命中速率', [
            ('sum(rate(' + hit + '[$__rate_interval]))', '命中'),
            ('sum(rate(' + miss + '[$__rate_interval]))', '未命中')], 0, 4, w=12, unit='ops'),
        timeseries(7, '连接与阻塞客户端', [
            ('sum(dragonfly_connected_clients)', '已连接'),
            ('sum(dragonfly_blocked_clients)', '阻塞')], 12, 4, w=12),
        timeseries(8, '内存使用趋势', [('sum(dragonfly_memory_used_bytes)', '已用内存')], 0, 11, w=12, unit='bytes'),
        table(9, 'Dragonfly 实例连接数', 'sum by(k8s_pod_name)(dragonfly_connected_clients)',
              12, 11, 12, 7, fields={'k8s_pod_name': 'Pod', 'Value': '连接客户端'},
              description='空表表示采集器未接入；命中率与内存见左侧面板。'),
        row(10, 'MinIO · 对象存储', 18),
        stat(11, '可用容量', 'sum(minio_cluster_capacity_usable_free_bytes)', 0, 19, 6, unit='bytes', neutral=True),
        stat(12, '容量使用率',
             '1 - sum(minio_cluster_capacity_usable_free_bytes) / clamp_min(sum(minio_cluster_capacity_usable_total_bytes), 1)',
             6, 19, 6, unit='percentunit', decimals=1, description='基于 usable 口径，不等于裸盘容量。'),
        stat(13, '离线磁盘', 'sum(minio_cluster_drive_offline_total)', 12, 19, 6,
             values={0: ('全部在线', 'green')}, description='大于 0 需核对纠删组读/写仲裁。'),
        stat(14, '离线节点', 'sum(minio_cluster_nodes_offline_total)', 18, 19, 6,
             values={0: ('全部在线', 'green')}),
        timeseries(15, '可用 / 总容量', [
            ('sum(minio_cluster_capacity_usable_free_bytes)', '可用'),
            ('sum(minio_cluster_capacity_usable_total_bytes)', '总计')], 0, 22, w=12, unit='bytes'),
        timeseries(16, '健康状态与在线资源', [
            ('minio_cluster_health_status', '健康状态（1=健康）'),
            ('sum(minio_cluster_drive_online_total)', '在线磁盘'),
            ('sum(minio_cluster_nodes_online_total)', '在线节点')], 12, 22, w=12),
        table(17, 'MinIO 健康原始值', 'minio_cluster_health_status',
              0, 29, 24, 6, fields={'server_address': '服务地址', 'Value': '健康状态（1=健康）'},
              description='离线磁盘/节点数见上方两个 stat；空表表示采集器未接入。'),
        row(18, 'Elasticsearch · 搜索', 35),
        stat(19, '绿色健康', 'max(elasticsearch_cluster_health_status{color="green"})', 0, 36, 6, healthy_one=True,
             values={0: ('非绿色', 'red'), 1: ('green', 'green')}, description='elasticsearch_cluster_health_status 的值 1 表示当前是该颜色。'),
        stat(20, '未分配分片', 'sum(elasticsearch_cluster_health_unassigned_shards)', 6, 36, 6,
             description='持续大于 0 表示有分片无法分配，先看节点磁盘水位。'),
        stat(21, '节点数', 'max(elasticsearch_cluster_health_number_of_nodes)', 12, 36, 6, neutral=True),
        stat(22, 'JVM 已用内存', 'sum(elasticsearch_jvm_memory_used_bytes)', 18, 36, 6, unit='bytes', neutral=True),
        timeseries(23, '集群健康颜色（1 = 当前颜色）', [
            ('sum by(color)(elasticsearch_cluster_health_status)', '{{color}}')], 0, 39, w=12,
            description='green/yellow/red 三个序列，读「哪一条是 1」而不是把三条相加。'),
        timeseries(24, '未分配分片 / 节点数', [
            ('sum(elasticsearch_cluster_health_unassigned_shards)', '未分配分片'),
            ('max(elasticsearch_cluster_health_number_of_nodes)', '节点数')], 12, 39, w=12),
        timeseries(25, 'JVM 内存使用', [
            ('sum(elasticsearch_jvm_memory_used_bytes)', '已用'),
            ('sum(elasticsearch_jvm_memory_committed_bytes)', '已提交'),
            ('sum(elasticsearch_jvm_memory_max_bytes)', '上限')], 0, 46, w=12, unit='bytes'),
        table(26, '集群健康原始状态', 'elasticsearch_cluster_health_status', 12, 46, 12, 7,
              fields={'cluster': '集群', 'color': '颜色', 'Value': '状态（1=当前）'}),
        text(27, '口径与边界',
             '命中率按 `hit / (hit + miss)` 计算，采样窗口内无请求时显示 0 而不是绿色；Dragonfly 阻塞客户端与 MinIO 离线磁盘是「数量」不是比率。'
             '\n\nElasticsearch 健康颜色来自 `elasticsearch_cluster_health_status{color=...}`，**值 1 才表示该颜色**，不要把三条颜色相加；'
             'JVM 指标来自 `elasticsearch-exporter`（`elasticsearch_jvm_*`），与 Kafka 的 `jvm_*` 不是同一来源。'
             '\n\n本页只覆盖这三个组件的 scrape 指标；容器日志请走 VictoriaLogs，可用性探测由 Gatus 负责。', 53, 4)]
    return dashboard('middleware-overview', '中间件 · Dragonfly/MinIO/Elasticsearch', panels,
                     description='三个组件各一组：容量、健康、命中率与队列；所有指标已在 VM 验证存在。')


def build_ecommerce_apm():
    """电商 APM：RED（HTTP 实测埋点 + Connect RPC）、Go runtime、copystack/Pyroscope 指引。

    侦察结论：service.namespace=ecommerce 的服务只上报 http_server_* / http_client_* / db_client_* /
    go_* 等 OTel 语义指标；rpc_server_call_duration_seconds_* 与 rpc_response_status_code 目前只在
    config-center 命名空间的 config-service 上出现。因此两组 RED 分开呈现并各自带服务下拉，避免
    把「没有 RPC 埋点」画成「RPC 错误率为 0」。go_gc_pauses_seconds_bucket / go_memstats_* 同样
    只来自控制面组件，这里保留面板并明确标为指标缺失，不伪造数据。
    """
    s = '{service_namespace="ecommerce",service_name=~"$service"}'
    rs = '{service_namespace="config-center",service_name=~"$rpc_service"}'
    http_count = 'http_server_request_duration_seconds_count' + s
    http_bucket = 'http_server_request_duration_seconds_bucket' + s
    http_5xx = 'http_server_request_duration_seconds_count{service_namespace="ecommerce",service_name=~"$service",http_response_status_code=~"5.."}'
    rpc_count = 'rpc_server_call_duration_seconds_count' + rs
    rpc_err = 'rpc_server_call_duration_seconds_count{service_namespace="config-center",service_name=~"$rpc_service",rpc_response_status_code!="OK"}'
    panels = [
        text(1, '怎么读这张 APM 面板',
             '**服务下拉只选 ecommerce 服务**（10 个 Go 服务）。RED 第一组用 `http_server_request_duration_seconds_*`——这是 ecommerce 目前真正上报的服务端埋点。'
             '\n\n`rpc_server_call_duration_seconds_*` 与 `rpc_response_status_code`（OK / UNAVAILABLE 等大写值）当前只在 **config-center** 的 config-service 上出现，'
             '所以第二组 RED 单独提供 RPC 服务下拉；两个下拉互不替代，某组没有埋点就显示「指标缺失」，**不画成 0 错误率**。'
             '\n\nlabels 在 VM 里是下划线形式（`service_name` / `service_namespace`），OTel 语义名中的点号已被 `usePrometheusNaming` 改掉。', 0, 4),
        stat(2, 'HTTP 请求速率', 'sum(rate(' + http_count + '[$__rate_interval]))', 0, 4, 6, unit='ops'),
        stat(3, 'HTTP 5xx 错误率',
             'sum(rate(' + http_5xx + '[$__rate_interval])) / '
             'sum(rate(' + http_count + '[$__rate_interval]))', 6, 4, 6, unit='percentunit', decimals=1,
             description='状态码来自 http_response_status_code（如 200 / 503）。'),
        stat(4, 'HTTP P99 延迟',
             'histogram_quantile(0.99, sum by(le)(rate(' + http_bucket + '[$__rate_interval])))',
             12, 4, 6, unit='s', decimals=3),
        stat(5, 'Goroutine 数', 'sum(go_goroutine_count' + s + ')', 18, 4, 6, neutral=True),
        row(6, 'RED · HTTP server（ecommerce 实际埋点）', 7),
        timeseries(7, '请求速率 · 按服务与状态码', [
            ('sum by(service_name, http_response_status_code)(rate(' + http_count + '[$__rate_interval]))',
             '{{service_name}} / {{http_response_status_code}}')], 0, 8, w=12, unit='ops'),
        timeseries(8, '错误率 · 按服务', [
            ('sum by(service_name)(rate(' + http_5xx + '[$__rate_interval])) / '
             'sum by(service_name)(rate(' + http_count + '[$__rate_interval]))', '{{service_name}}')],
            12, 8, w=12, unit='percentunit'),
        timeseries(9, '延迟分位 · P50 / P90 / P99', [
            ('histogram_quantile(0.50, sum by(le)(rate(' + http_bucket + '[$__rate_interval])))', 'P50'),
            ('histogram_quantile(0.90, sum by(le)(rate(' + http_bucket + '[$__rate_interval])))', 'P90'),
            ('histogram_quantile(0.99, sum by(le)(rate(' + http_bucket + '[$__rate_interval])))', 'P99')],
            0, 15, w=12, unit='s'),
        timeseries(10, '请求速率 · 按路由', [
            ('topk(10, sum by(http_route)(rate(' + http_count + '[$__rate_interval])))', '{{http_route}}')],
            12, 15, w=12, unit='ops'),
        row(11, 'RED · Connect RPC（config-center，当前唯一 RPC 埋点）', 22),
        timeseries(12, 'RPC 请求速率 · 按响应码', [
            ('sum by(rpc_response_status_code)(rate(' + rpc_count + '[$__rate_interval]))',
             '{{rpc_response_status_code}}')], 0, 23, w=12, unit='ops',
            description='rpc_response_status_code 是大写枚举（OK / UNAVAILABLE ...），不是 HTTP 数字码。'),
        timeseries(13, 'RPC 错误率 · 按服务', [
            ('sum by(service_name)(rate(' + rpc_err + '[$__rate_interval])) / '
             'sum by(service_name)(rate(' + rpc_count + '[$__rate_interval]))', '{{service_name}}')],
            12, 23, w=12, unit='percentunit'),
        row(14, 'Go runtime · OTel 语义指标', 30),
        timeseries(15, 'Goroutine 数 · 按服务', [
            ('sum by(service_name)(go_goroutine_count' + s + ')', '{{service_name}}')], 0, 31, w=12),
        timeseries(16, '调度延迟分位 · P50 / P90 / P99', [
            ('histogram_quantile(0.50, sum by(le)(rate(go_schedule_duration_seconds_bucket' + s + '[$__rate_interval])))', 'P50'),
            ('histogram_quantile(0.90, sum by(le)(rate(go_schedule_duration_seconds_bucket' + s + '[$__rate_interval])))', 'P90'),
            ('histogram_quantile(0.99, sum by(le)(rate(go_schedule_duration_seconds_bucket' + s + '[$__rate_interval])))', 'P99')],
            12, 31, w=12, unit='s'),
        timeseries(17, 'GC pause 分位 · 待自定义采集', [
            ('histogram_quantile(0.90, sum by(le)(rate(go_gc_pauses_seconds_bucket' + s + '[$__rate_interval])))', 'P90')],
            0, 38, w=12, unit='s',
            description='OTel 官方 Go runtime 仪表当前不导出 gc pause；该序列在 ecommerce 服务上为空，显示「指标缺失」。'
                        'go_gc_pauses_seconds_bucket / go_memstats_* 目前只见于控制面组件，不能当成 ecommerce 的 GC 证据。'),
        timeseries(18, '内存使用 · 按类型', [
            ('sum by(go_memory_type)(go_memory_used_bytes' + s + ')', '{{go_memory_type}}')], 12, 38, w=12, unit='bytes'),
        table(19, 'Go runtime 原始值 · 按服务', 'go_goroutine_count' + s, 0, 45, 24, 6,
              fields={'service_name': '服务', 'service_version': '版本', 'Value': 'Goroutine 数'}),
        text(20, 'copystack · 为什么还需要 Pyroscope',
             '微信文章对 Uber Go 集群的分析显示 `runtime.copystack` 占 CPU **3.9%**（GC 为 7.3%），600 个服务中 334 个超过 3%。'
             '这类**函数级 CPU 归因**无法从 `go_goroutine_count` 或调度延迟分位推断：总量增长不等于栈拷贝开销，'
             'GC 快照也看不到短生命周期 goroutine 的峰值栈需求。\n\n'
             '**下一步**：用持续剖析（Pyroscope 数据源 `ds-pyroscope`）看 `runtime.copystack` / `morestack` / `newstack` 的 CPU 占比与趋势，'
             '与本页的 goroutine、调度延迟曲线对照；栈缓存优化前后要保留同一口径的 profile 基线。'
             '\n\n[打开 Pyroscope Explore](/explore?left=%7B%22datasource%22%3A%22ds-pyroscope%22%7D)（进入后选择 `ds-pyroscope`，'
             'label 过滤 `service_namespace="ecommerce"`）。本页只提供指标侧证据，不宣称已定位到函数级热点。', 51, 5)]
    return dashboard('ecommerce-apm', '电商 APM · RED 与 Go Runtime', panels,
                     [variable('service', 'ecommerce 服务', 'label_values(go_goroutine_count{service_namespace="ecommerce"}, service_name)'),
                      variable('rpc_service', 'RPC 服务（config-center）',
                               'label_values(rpc_server_call_duration_seconds_count{service_namespace="config-center"}, service_name)')],
                     description='ecommerce 服务的 RED 与 Go runtime；RPC 与 GC pause 的真实埋点边界在面板内明示。')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    documents=[build_portal(),build_main(),build_detail(),build_cnpg(),build_kubernetes(),build_cdc(),build_observability(),build_overview(),build_control_plane(),build_middleware(),build_ecommerce_apm()]
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
