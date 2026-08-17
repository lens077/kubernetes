"""生成电商大盘 JSON 并 POST 进 Grafana。

数据源分工(全部实测过有数据/可查):
- Postgres  业务真相源:orders.order_main / cart.cart_item(behaviors.events 还是空的,tracker 未接线)
- VM        rpc_server_duration_milliseconds_*(6 个服务在报,带 rpc_method/error_code)、web_vitals_*、system_filesystem
- Loki      结构化日志(detected_level / web_vital / slow_frontend_api)
"""
import json

PROM = {"type": "prometheus", "uid": "cfqdfyp4nyq68f"}
PG = {"type": "grafana-postgresql-datasource", "uid": "cfqdftoswcn40a"}
LOKI = {"type": "loki", "uid": "afqdfiefq0o3kf"}

_id = [0]
def nid():
    _id[0] += 1
    return _id[0]

def gp(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}

def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "gridPos": gp(0, y, 24, 1), "collapsed": False}

def pg_stat(title, sql, x, y, w=4, h=4, unit="none", thresholds=None, desc=""):
    p = {
        "id": nid(), "type": "stat", "title": title, "description": desc,
        "datasource": PG, "gridPos": gp(x, y, w, h),
        "targets": [{"refId": "A", "datasource": PG, "rawSql": sql, "format": "table"}],
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value",
                    "graphMode": "none", "textMode": "auto"},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
    }
    if thresholds:
        p["fieldConfig"]["defaults"]["thresholds"] = thresholds
    return p

def prom_stat(title, expr, x, y, w=4, h=4, unit="ms", steps=None, desc=""):
    p = {
        "id": nid(), "type": "stat", "title": title, "description": desc,
        "datasource": PROM, "gridPos": gp(x, y, w, h),
        "targets": [{"refId": "A", "datasource": PROM, "expr": expr, "instant": True}],
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value",
                    "graphMode": "none"},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
    }
    if steps:
        p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": steps}
    return p

def ts(title, targets, x, y, w=12, h=8, unit="none", datasource=PROM, desc="", percent=False):
    p = {
        "id": nid(), "type": "timeseries", "title": title, "description": desc,
        "datasource": datasource, "gridPos": gp(x, y, w, h),
        "targets": targets,
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 8,
                        "showPoints": "never", "spanNulls": True}}, "overrides": []},
    }
    if percent:
        p["fieldConfig"]["defaults"]["max"] = 1
        p["fieldConfig"]["defaults"]["min"] = 0
    return p

def prom_t(expr, legend, refid="A"):
    return {"refId": refid, "datasource": PROM, "expr": expr, "legendFormat": legend}

def pg_t(sql, refid="A"):
    return {"refId": refid, "datasource": PG, "rawSql": sql, "format": "time_series"}

def logs(title, expr, x, y, w=12, h=8, desc=""):
    return {
        "id": nid(), "type": "logs", "title": title, "description": desc,
        "datasource": LOKI, "gridPos": gp(x, y, w, h),
        "targets": [{"refId": "A", "datasource": LOKI, "expr": expr}],
        "options": {"showTime": True, "wrapLogMessage": True, "enableLogDetails": True,
                    "sortOrder": "Descending"},
    }

def bargauge(title, targets, x, y, w=8, h=8, unit="none", datasource=PROM, desc=""):
    return {
        "id": nid(), "type": "bargauge", "title": title, "description": desc,
        "datasource": datasource, "gridPos": gp(x, y, w, h),
        "targets": targets,
        "options": {"orientation": "horizontal", "displayMode": "gradient",
                    "reduceOptions": {"calcs": ["lastNotNull"]}},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
    }

def piechart(title, sql, x, y, w=8, h=8, desc=""):
    return {
        "id": nid(), "type": "piechart", "title": title, "description": desc,
        "datasource": PG, "gridPos": gp(x, y, w, h),
        "targets": [{"refId": "A", "datasource": PG, "rawSql": sql, "format": "table"}],
        "options": {"pieType": "donut", "legend": {"displayMode": "table", "placement": "right",
                    "values": ["value"]},
                    "reduceOptions": {"values": True, "fields": "/^n$/"}},
    }

# Web Vitals 及格线(Google 标准):good / needs-improvement / poor
def vital_steps(good, poor):
    return [{"color": "green", "value": None}, {"color": "yellow", "value": good},
            {"color": "red", "value": poor}]

panels = []
y = 0

# ───── Row 1 业务北极星 ─────
panels.append(row("业务北极星(时间范围内)", y)); y += 1
panels.append(pg_stat("订单数", "SELECT count(*) FROM orders.order_main WHERE $__timeFilter(created_at)", 0, y,
                      desc="orders.order_main 落库数"))
panels.append(pg_stat("GMV(应付)", "SELECT coalesce(sum(pay_amount),0) FROM orders.order_main WHERE $__timeFilter(created_at)", 4, y,
                      unit="currencyCNY", desc="sum(pay_amount)。金额列是 numeric,汇总在库内做"))
panels.append(pg_stat("客单价", "SELECT coalesce(avg(pay_amount),0) FROM orders.order_main WHERE $__timeFilter(created_at)", 8, y,
                      unit="currencyCNY"))
panels.append(pg_stat("加购条目数", "SELECT count(*) FROM cart.cart_item WHERE $__timeFilter(created_at)", 12, y,
                      desc="cart.cart_item 新增行数(同 SKU 累加数量不产生新行,口径偏保守)"))
panels.append(pg_stat("加购→下单转化率",
    "SELECT count(DISTINCT o.user_id)::float / nullif((SELECT count(DISTINCT user_id) FROM cart.cart_item WHERE $__timeFilter(created_at)),0) FROM orders.order_main o WHERE $__timeFilter(o.created_at)",
    16, y, unit="percentunit",
    thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "yellow", "value": 0.1}, {"color": "green", "value": 0.3}]},
    desc="下单用户数 / 加购用户数(用户去重口径,不是订单/条目比)"))
panels.append(pg_stat("支付完成率",
    "SELECT count(*) FILTER (WHERE paid_at IS NOT NULL)::float / nullif(count(*),0) FROM orders.order_main WHERE $__timeFilter(created_at)",
    20, y, unit="percentunit",
    thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "yellow", "value": 0.5}, {"color": "green", "value": 0.8}]},
    desc="paid_at 非空 / 订单数。payment 服务还是桩,当前恒为 0 是预期"))
y += 4

# ───── Row 2 业务趋势 ─────
panels.append(row("业务趋势", y)); y += 1
panels.append(ts("加购 vs 下单(按天)", [
    pg_t("SELECT $__timeGroup(created_at,'1d') AS time, count(*) AS \"加购条目\" FROM cart.cart_item WHERE $__timeFilter(created_at) GROUP BY 1 ORDER BY 1", "A"),
    pg_t("SELECT $__timeGroup(created_at,'1d') AS time, count(*) AS \"订单\" FROM orders.order_main WHERE $__timeFilter(created_at) GROUP BY 1 ORDER BY 1", "B"),
], 0, y, w=10, datasource=PG))
panels.append(ts("GMV(按天)", [
    pg_t("SELECT $__timeGroup(created_at,'1d') AS time, sum(pay_amount) AS \"GMV\" FROM orders.order_main WHERE $__timeFilter(created_at) GROUP BY 1 ORDER BY 1"),
], 10, y, w=6, unit="currencyCNY", datasource=PG))
panels.append(piechart("订单状态分布",
    "SELECT order_status::text AS metric, count(*) AS n FROM orders.order_main WHERE $__timeFilter(created_at) GROUP BY 1",
    16, y, w=8, desc="order_main.order_status"))
y += 8

# ───── Row 3 行为漏斗(RPC 近似) ─────
panels.append(row("行为漏斗 —— RPC 调用近似(behaviors.events 为空:tracker 未接线,接上后换真漏斗)", y)); y += 1
panels.append(bargauge("浏览 → 加购 → 下单(调用量,时间范围内)", [
    prom_t('sum(increase(rpc_server_duration_milliseconds_count{rpc_method="GetProductDetail"}[$__range]))', "浏览商详", "A"),
    prom_t('sum(increase(rpc_server_duration_milliseconds_count{rpc_method="AddProductToCart"}[$__range]))', "加购", "B"),
    prom_t('sum(increase(rpc_server_duration_milliseconds_count{rpc_method="CreateOrder"}[$__range]))', "下单", "C"),
], 0, y, w=12, desc="以服务端 RPC 计数近似,含重试/失败调用;真实转化以上方 Postgres 口径为准"))
panels.append(ts("漏斗各环节调用率", [
    prom_t('sum(rate(rpc_server_duration_milliseconds_count{rpc_method=~"GetProductDetail|AddProductToCart|CreateOrder|GetCart"}[$__rate_interval])) by (rpc_method)', "{{rpc_method}}"),
], 12, y, w=12, unit="reqps"))
y += 8

# ───── Row 4 服务健康 ─────
panels.append(row("服务健康(RPC)", y)); y += 1
panels.append(ts("请求率 by 服务", [
    prom_t('sum(rate(rpc_server_duration_milliseconds_count{service_name=~"$service"}[$__rate_interval])) by (service_name)', "{{service_name}}"),
], 0, y, w=8, unit="reqps"))
panels.append(ts("错误率 by 服务", [
    prom_t('sum(rate(rpc_server_duration_milliseconds_count{service_name=~"$service", rpc_connect_rpc_error_code!=""}[$__rate_interval])) by (service_name) / sum(rate(rpc_server_duration_milliseconds_count{service_name=~"$service"}[$__rate_interval])) by (service_name)', "{{service_name}}"),
], 8, y, w=8, unit="percentunit", percent=True,
    desc="rpc_connect_rpc_error_code 非空即错误。分母为全部调用"))
panels.append(ts("P95 时延 by 服务", [
    prom_t('histogram_quantile(0.95, sum(rate(rpc_server_duration_milliseconds_bucket{service_name=~"$service"}[$__rate_interval])) by (le, service_name))', "{{service_name}}"),
], 16, y, w=8, unit="ms"))
y += 8
panels.append({
    "id": nid(), "type": "table", "title": "最慢方法 Top(P95,时间范围内)",
    "datasource": PROM, "gridPos": gp(0, y, 12, 7),
    "targets": [{"refId": "A", "datasource": PROM, "instant": True, "format": "table",
        "expr": 'topk(10, histogram_quantile(0.95, sum(increase(rpc_server_duration_milliseconds_bucket[$__range])) by (le, service_name, rpc_method)))'}],
    "options": {"sortBy": [{"displayName": "Value", "desc": True}]},
    "fieldConfig": {"defaults": {"unit": "ms"},
        "overrides": [{"matcher": {"id": "byRegexp", "options": "Time|le"}, "properties": [{"id": "custom.hidden", "value": True}]}]},
})
panels.append(logs("错误日志(全服务)", '{service_name=~".+"} | detected_level=~"error|warn" |~ "(?i)error|fail|panic"', 12, y, w=12, h=7))
y += 7

# ───── Row 5 前端体验(Web Vitals) ─────
panels.append(row("前端体验(Web Vitals RUM)", y)); y += 1
vitals = [
    ("LCP P75", "lcp", 2500, 4000, "ms"), ("INP P75", "inp", 200, 500, "ms"),
    ("CLS P75", "cls", 0.1, 0.25, "none"), ("FCP P75", "fcp", 1800, 3000, "ms"),
    ("TTFB P75", "ttfb", 800, 1800, "ms"),
]
x = 0
for title, m, good, poor, unit in vitals:
    panels.append(prom_stat(title,
        f'histogram_quantile(0.75, sum(increase(web_vitals_{m}_milliseconds_bucket[$__range])) by (le))',
        x, y, w=4, unit=unit, steps=vital_steps(good, poor),
        desc=f"及格线 {good}{unit if unit=='ms' else ''} / 差 {poor}"))
    x += 4
panels.append(prom_stat("长任务次数", 'sum(increase(web_vitals_long_task_milliseconds_count[$__range]))', 20, y, w=4, unit="none",
    steps=[{"color": "green", "value": None}, {"color": "yellow", "value": 10}, {"color": "red", "value": 50}]))
y += 4
panels.append(ts("LCP P75 by 页面", [
    prom_t('histogram_quantile(0.75, sum(rate(web_vitals_lcp_milliseconds_bucket[$__rate_interval])) by (le, page))', "{{page}}"),
], 0, y, w=8, unit="ms"))
panels.append(ts("前端观测的接口耗时 P95", [
    prom_t('histogram_quantile(0.95, sum(rate(frontend_api_duration_milliseconds_bucket[$__rate_interval])) by (le))', "P95"),
    prom_t('histogram_quantile(0.50, sum(rate(frontend_api_duration_milliseconds_bucket[$__rate_interval])) by (le))', "P50", "B"),
], 8, y, w=8, unit="ms", desc="Resource Timing 口径(含排队/DNS/TCP),与服务端 P95 的差值≈网络+网关"))
panels.append(logs("慢接口与性能明细(带归因)", '{service_name="behavior-service"} |~ "web_vital|slow_frontend_api"', 16, y, w=8, h=8,
    desc="attribution 字段:LCP 的元素 selector / INP 的交互目标 / 长任务的容器"))
y += 8

# ───── Row 6 基础设施 ─────
panels.append(row("基础设施", y)); y += 1
panels.append(ts("节点文件系统使用率", [
    prom_t('system_filesystem_usage_bytes{state="used", type!~"autofs|tmpfs"} / ignoring(state) (system_filesystem_usage_bytes{state="used", type!~"autofs|tmpfs"} + ignoring(state) system_filesystem_usage_bytes{state="free", type!~"autofs|tmpfs"})', "{{mountpoint}}"),
], 0, y, w=8, unit="percentunit", percent=True,
    desc="host_metrics 目前只开了 filesystem scraper;CPU/内存要在 collector 的 host_metrics 里加 scrapers 才有"))
panels.append(ts("DB 连接池(pgxpool)", [
    prom_t('pgxpool_total_conns', "{{service_name}} total"),
    prom_t('pgxpool_acquired_conns', "{{service_name}} acquired", "B"),
], 8, y, w=8, desc="otelpgx RecordStats;服务未启动时无数据"))
panels.append(ts("网关→上游 HTTP 时延 P95", [
    prom_t('histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket[$__rate_interval])) by (le, service_name))', "{{service_name}}"),
], 16, y, w=8, unit="s"))

dashboard = {
    "dashboard": {
        "uid": "ecommerce-overview",
        "title": "电商大盘 · 业务与系统",
        "tags": ["ecommerce", "generated"],
        "timezone": "browser",
        "time": {"from": "now-90d", "to": "now"},
        "refresh": "1m",
        "templating": {"list": [{
            "name": "service", "label": "服务", "type": "query", "datasource": PROM,
            "query": {"query": "label_values(rpc_server_duration_milliseconds_count, service_name)", "refId": "v"},
            "includeAll": True, "multi": True, "current": {"text": ["All"], "value": ["$__all"]},
            "refresh": 2,
        }]},
        "panels": panels,
        "schemaVersion": 39,
        "editable": True,
    },
    "folderUid": "",
    "overwrite": True,
    "message": "generated: 业务(PG) + RPC(VM) + Web Vitals(VM) + 日志(Loki)",
}

print(json.dumps(dashboard, ensure_ascii=False))
