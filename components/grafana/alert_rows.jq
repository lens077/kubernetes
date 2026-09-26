# Read-only presentation of vmalert /api/v1/alerts. Do not infer a root cause.
def fallback($value; $other): if $value == null or $value == "" then $other else $value end;
def row:
  . as $a | (.labels // {}) as $l |
  fallback($l.exported_alertname; $a.name) as $origin |
  fallback($l.exported_alertgroup; $l.alertgroup) as $group |
  fallback($l.k8s_namespace_name; fallback($l.namespace; "")) as $ns |
  fallback($l.k8s_pod_name; fallback($l.pod; "")) as $alert_pod |
  fallback($l.k8s_node_name; fallback($l.node; "")) as $alert_node |
  (if $group == "cnpg" then "infra-cnpg"
   elif $group == "ecommerce-cdc" then "infra-cdc"
   elif $group == "ecommerce-k8s" and $a.name != "AlertFiringTooLong" then "infra-kubernetes"
   elif $group == "ecommerce-security" or $group == "observability-pipeline" or $group == "ecommerce-observability-readiness" then "infra-observability"
   elif $ns != "" then "infra-kubernetes" else "infra-overview" end) as $target |
  (if $target == "infra-cnpg" then "数据库 / 备份"
   elif $target == "infra-cdc" then "CDC / 位点"
   elif $target == "infra-kubernetes" then "工作负载"
   elif $target == "infra-observability" then "采集 / 网络" else "基础设施" end) as $destination |
  (try ($a.activeAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $started |
  ([$l.cnpg_cluster, $ns, $alert_pod, $l.k8s_container_name, $l.k8s_deployment_name,
    $alert_node, $l.connector, $l.slot_name, $l.service_name, $l.cdc_table, $l.exporter]
    | map(select(. != null and . != "")) | unique | join(" · ")) as $objects |
  (if $ns != "" then "kubernetes.pod_namespace:=" + ($ns | tojson) +
     (if $alert_pod != "" then " AND kubernetes.pod_name:=" + ($alert_pod | tojson) else "" end)
   else "" end) as $logs |
  {
    key: ($a.group_id + ":" + $a.id),
    kind: (if $a.name == "AlertFiringTooLong" then "reminder" else "problem" end),
    kind_label: (if $a.name == "AlertFiringTooLong" then "持续提醒" else "原始告警" end),
    state: $a.state,
    severity: fallback($l.severity; "unknown"),
    summary: fallback($a.annotations.summary; $a.name),
    description: fallback($a.annotations.description; "规则未提供排查说明；查看表达式与实际标签。"),
    rule: $a.name,
    original_rule: $origin,
    resource: fallback($objects; fallback($l.cluster; "标签未提供具体对象")),
    cluster: fallback($l.cluster; ""),
    namespace: $ns, pod: $alert_pod, node: $alert_node,
    cnpg_cluster: fallback($l.cnpg_cluster; ""),
    connector: fallback($l.connector; ""),
    active_at: $a.activeAt,
    condition_seconds: (if $started == null then null else ([0, now - $started] | max) end),
    value: $a.value,
    expression: $a.expression,
    restoring: ($a.restored // false),
    stabilizing: ($a.stabilizing // false),
    labels: $l,
    detail_url: ("/d/alert-instance-detail?var-instance=" + (($a.group_id + ":" + $a.id) | @uri)),
    evidence: $destination,
    evidence_url: ("/d/" + $target +
      "?var-cnpg_cluster=" + (fallback($l.cnpg_cluster; ".*") | @uri) +
      "&var-namespace=" + (fallback($ns; ".*") | @uri) +
      "&var-pod=" + (fallback($alert_pod; ".*") | @uri) +
      "&var-node=" + (fallback($alert_node; ".*") | @uri) +
      "&var-connector=" + (fallback($l.connector; ".*") | @uri) +
      "&var-rule=" + ($origin | @uri)),
    logs: (if $logs == "" then "先在证据页选择对象" else "查看对象日志" end),
    logs_url: (if $logs == "" then null else
      "/explore?schemaVersion=1&panes=" + ({
        logs: {datasource:"ds-vlogs", queries:[{refId:"A", datasource:{type:"victoriametrics-logs-datasource",uid:"ds-vlogs"},expr:$logs,queryType:"instant"}],
          range:{from:(if $started == null then "now-6h" else (($started-300)*1000|floor|tostring) end),to:"now"}}
      } | tojson | @uri) end)
  } | .logs_url = (.logs_url // .evidence_url);
if .status != "success" or (.data.alerts | type) != "array" then
  error("vmalert alert API did not return a successful alerts array")
else
  [.data.alerts[] | select(.name != "Watchdog") | row]
  | sort_by([if .severity == "critical" then 0 else 1 end, .kind, .active_at, .key])
end
