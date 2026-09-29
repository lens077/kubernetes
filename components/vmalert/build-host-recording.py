#!/usr/bin/env python3
"""Generate the single host-metric contract and cloud inventory (JSON is valid YAML).

vmalert remoteWrite is asynchronous: every record below reads raw samples, never
another record from this group. See README-host-metrics.md for units and rollout.
"""
import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOSTS = ROOT / "hosts/observability/hosts.json"
FRESH_SECONDS = 180
KEY = "host, host_kind"


def validate_hosts(hosts):
    seen = set()
    for h in hosts:
        name = h.get("host", "")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}", name) or name in seen:
            raise ValueError(f"Invalid or duplicate host identity: {name!r}")
        seen.add(name)
        if h.get("host_kind") not in ("cloud", "kubernetes") or h.get("disk_alert_owner") not in ("watchdog", "vmalert"):
            raise ValueError(f"Invalid kind or disk alert owner for {name}")
        if h["host_kind"] == "cloud" and (h.get("ssh_alias") != name or not h.get("cloud_provider")):
            raise ValueError(f"Cloud host {name} needs its exact SSH alias and provider")
    if not seen:
        raise ValueError("Expected host list cannot be empty")
    return hosts


def load_hosts():
    data = json.loads(HOSTS.read_text())
    if data.get("schema_version") != 1:
        raise ValueError("Unsupported hosts schema")
    return validate_hosts(data["hosts"])


def expected(hosts):
    parts = []
    for h in hosts:
        expr = "vector(1)"
        for key in ("host", "host_kind", "disk_alert_owner"):
            expr = f'label_replace({expr}, "{key}", "{h[key]}", "", "")'
        parts.append(expr)
    return " or ".join(parts)


def normalized(metric, filters="", *, fresh=True, rate=False, last_seen=False):
    """K8s identity takes precedence. Never concatenate host_name and node name."""
    parts = []
    for kind, selector, label in (
        ("kubernetes", 'k8s_node_name!=""', "k8s_node_name"),
        ("cloud", 'k8s_node_name="",host_name!="",host_group="cloud"', "host_name"),
    ):
        sel = f'{metric}{{{selector}{"," + filters if filters else ""}}}'
        value = f"tlast_over_time({sel}[1d])" if last_seen else (f"rate({sel}[5m])" if rate else sel)
        if fresh:
            value = f"({value}) and (time() - timestamp({sel}) < {FRESH_SECONDS})"
        value = f'label_replace(({value}), "host", "$1", "{label}", "(.+)")'
        parts.append(f'label_replace({value}, "host_kind", "{kind}", "", "")')
    return "(" + " or ".join(parts) + ")"


def document(hosts):
    rules = []
    def record(name, expr):
        rules.append({"record": "host:" + name, "expr": expr})

    cpu_all = normalized("system_cpu_utilization_ratio")
    cpu = normalized("system_cpu_utilization_ratio", 'state=~"idle|wait"')
    # Pair mutually exclusive states WITHIN each source first. Taking max(idle)
    # and max(wait) across different replicas can fabricate a lower busy ratio.
    complete_sources = f"(count without (state) ({cpu}) == 2)"
    source_pairs = f"sum without (state) ({cpu}) and {complete_sources}"
    pairs = f"max by ({KEY}, cpu) ({source_pairs})"
    # Incomplete idle/wait on one core must not silently average only the healthy cores.
    all_cores = f"count by ({KEY}) (group by ({KEY}, cpu) ({cpu_all}))"
    pair_count = f"count by ({KEY}) ({pairs})"
    logical_count = f'max by ({KEY}) ({normalized("system_cpu_logical_count")})'
    per_core = f'count by ({KEY}) (group by ({KEY}, cpu) ({normalized("system_cpu_utilization_ratio", "cpu!=\"\"")}))'
    aggregate = f'group by ({KEY}) ({normalized("system_cpu_utilization_ratio", "cpu=\"\"")})'
    # Aggregate mode has no cpu label. Per-core mode must include every logical
    # core; also reject mixtures of per-core and already aggregated series.
    mode_ok = f'(({aggregate}) unless on ({KEY}) ({per_core})) or (({per_core}) == on ({KEY}) ({logical_count}))'
    mixed = f'({aggregate}) and on ({KEY}) ({per_core})'
    complete_hosts = f'(({pair_count} == on ({KEY}) {all_cores}) and on ({KEY}) ({mode_ok})) unless on ({KEY}) ({mixed})'
    busy = f"avg by ({KEY}) (max by ({KEY}, cpu) (1 - ({source_pairs}))) and on ({KEY}) ({complete_hosts})"
    busy = f"(({busy}) >= 0) <= 1"
    raw_wait = normalized("system_cpu_utilization_ratio", 'state="wait"')
    wait = f"max by ({KEY}, cpu) ((sum without(state) ({raw_wait})) and {complete_sources})"
    iowait = f"avg by ({KEY}) ({wait}) and on ({KEY}) ({complete_hosts})"
    raw_memory = normalized("system_memory_utilization_ratio", 'state="used"')
    memory = f"((max by ({KEY}) ({raw_memory})) >= 0) <= 1"

    dims = KEY + ", mountpoint, device"
    raw_fs_used = normalized("system_filesystem_usage_bytes", 'state="used"')
    raw_fs_free = normalized("system_filesystem_usage_bytes", 'state="free"')
    source_used = f"sum without(state) ({raw_fs_used})"
    source_free = f"sum without(state) ({raw_fs_free})"
    denominator = f"({source_used}) + ({source_free})"
    fs = f"(({source_used}) / ({denominator})) and (({denominator}) > 0)"
    fs = f"max by ({KEY}, mountpoint) ({fs})"
    devices = f"count by ({KEY}, mountpoint) (group by ({dims}) ({raw_fs_used})) == 1"
    fs = f"({fs}) and on ({KEY}, mountpoint) ({devices})"
    network_filter = 'device!~"lo|veth.*|br-.*|docker[0-9]*|cali.*|cilium.*|lxc.*|safeline-.*",direction=~"receive|transmit"'
    network = f'sum by ({KEY}, direction) (max by ({KEY}, device, direction) ({normalized("system_network_io_bytes_total", network_filter, rate=True)}))'
    record("expected_info", expected(hosts))
    record("cpu_busy_ratio", busy)
    record("cpu_iowait_ratio", iowait)
    record("memory_used_ratio", memory)
    record("filesystem_used_ratio", fs)
    record("network_io_bytes_per_second", network)
    record("cpu_count", f'max by ({KEY}) ({normalized("system_cpu_logical_count")})')
    record("load1", f'max by ({KEY}) ({normalized("system_cpu_load_average_1m")})')
    # A single failed scraper must not classify a still-reporting host as offline.
    # Each signal has independent coverage; host liveness is the latest raw sample
    # across all four families, never the timestamp of a rewritten recording result.
    heartbeat_sources = [normalized(metric, fresh=False, last_seen=True) for metric in (
        "system_cpu_utilization_ratio", "system_memory_utilization_ratio",
        "system_filesystem_usage_bytes", "system_network_io_bytes_total")]
    record("last_seen_timestamp_seconds", f"max by ({KEY}) (" + " or ".join(heartbeat_sources) + ")")
    for signal, expr in (("cpu", busy), ("memory", memory), ("filesystem", fs), ("network", network)):
        if signal == "filesystem":
            # Root mount is required by every consumer; /boot alone is not coverage.
            expr = expr.replace('state="used"', 'mountpoint="/",state="used"').replace('state="free"', 'mountpoint="/",state="free"')
        present = f'group by ({KEY}) ({expr}) or on ({KEY}) (0 * group by ({KEY}) ({expected(hosts)}))'
        # Four disjoint signal label sets keep each query below VM's 16KiB limit,
        # without introducing a dependency on asynchronous recording-rule writes.
        rules.append({"record": "host:signal_present", "expr": present, "labels": {"signal": signal}})
    record("rules_evaluation_timestamp_seconds", "vector(time())")
    signatures = [(r['record'], tuple(sorted(r.get('labels', {}).items()))) for r in rules]
    if len(set(signatures)) != len(signatures) or any(len(r['expr'].encode()) > 16384 for r in rules):
        raise ValueError('Duplicate recording label set or expression exceeds VM default query limit')
    return {"groups": [{"name": "host-recording", "interval": "30s", "rules": rules}]}


def cloud_inventory(hosts):
    entries = {}
    for h in hosts:
        if h["host_kind"] == "cloud":
            entries[h["ssh_alias"]] = {"host_label": h["host"], "cloud_provider": h["cloud_provider"],
                                       "host_watchdog": h["disk_alert_owner"] == "watchdog"}
    return {"all": {"children": {"host_otel": {"hosts": entries, "vars": {"host_group": "cloud"}}}}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    hosts = load_hosts()
    outputs = {
        ROOT / "components/vmalert/rules/host-recording.yml": document(hosts),
        ROOT / "hosts/observability/inventory.generated.json": cloud_inventory(hosts),
    }
    for path, data in outputs.items():
        text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        if args.check:
            if not path.exists() or path.read_text() != text:
                raise SystemExit(f"Generated contract drift: {path.relative_to(ROOT)}")
        else:
            path.write_text(text)
    print(("checked" if args.check else "generated"), len(outputs), "host contract artifacts")


if __name__ == "__main__":
    main()
