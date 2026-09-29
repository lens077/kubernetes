#!/usr/bin/env python3
"""Read-only acceptance: expected hosts, signal coverage, freshness and raw/record parity."""
import argparse
import json
import math
import pathlib
import subprocess
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = "/api/v1/namespaces/victoriametrics/services/vm-single-victoria-metrics-single-server:8428/proxy/api/v1/query?"


def query(expr, at=None):
    params = {"query": expr}
    if at is not None:
        params["time"] = str(at)
    result = json.loads(subprocess.check_output(["kubectl", "get", "--raw", BASE + urllib.parse.urlencode(params)], text=True))
    if result.get("status") != "success":
        raise ValueError("Metric query failed")
    return result["data"]["result"]


def samples(rows):
    result = {}
    for row in rows:
        labels = {k: v for k, v in row["metric"].items() if k not in ("__name__", "cluster")}
        key = tuple(sorted(labels.items()))
        value = float(row["value"][1])
        if not math.isfinite(value) or key in result:
            raise ValueError(f"Non-finite or duplicate series: {labels}")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-age", type=int, default=180)
    args = parser.parse_args()
    inventory = json.loads((ROOT / "hosts/observability/hosts.json").read_text())["hosts"]
    expected = {h["host"]: h["host_kind"] for h in inventory}
    actual = query("host:expected_info")
    if {r["metric"]["host"]: r["metric"]["host_kind"] for r in actual} != expected:
        raise SystemExit("Expected-host inventory mismatch")
    evaluation = query("host:rules_evaluation_timestamp_seconds")
    if len(evaluation) != 1:
        raise SystemExit("Missing or duplicate recording evaluator")
    at = float(evaluation[0]["value"][1])
    if not 0 <= time.time() - at <= args.max_age:
        raise SystemExit("Recording evaluator is stale")
    coverage = query("host:signal_present", at)
    expected_signals = {(h, kind, s) for h, kind in expected.items() for s in ("cpu", "memory", "filesystem", "network")}
    got = {(r["metric"]["host"], r["metric"]["host_kind"], r["metric"]["signal"]) for r in coverage if float(r["value"][1]) == 1}
    if got != expected_signals:
        raise SystemExit(f"Incomplete coverage: missing={sorted(expected_signals - got)} unexpected={sorted(got - expected_signals)}")
    times = query("host:last_seen_timestamp_seconds", at)
    if {r["metric"]["host"] for r in times} != set(expected):
        raise SystemExit("Missing source timestamps")
    ages = {r["metric"]["host"]: time.time() - float(r["value"][1]) for r in times}
    if any(not 0 <= a <= args.max_age for a in ages.values()):
        raise SystemExit(f"Stale host source timestamps: {ages}")
    rules = json.loads((ROOT / "components/vmalert/rules/host-recording.yml").read_text())["groups"][0]["rules"]
    for rule in rules:
        name = rule["record"]
        fixed = rule.get("labels", {})
        selector = name + ('{' + ','.join(f'{k}="{v}"' for k,v in fixed.items()) + '}' if fixed else '')
        raw_rows = query(rule["expr"], at)
        for row in raw_rows:
            row['metric'].update(fixed)
        recorded, raw = samples(query(selector, at)), samples(raw_rows)
        if recorded.keys() != raw.keys() or any(not math.isclose(recorded[k], raw[k], rel_tol=1e-8, abs_tol=1e-8) for k in raw):
            raise SystemExit(f"Raw/record mismatch at {at}: {name}")
        if name.endswith("_ratio") and any(not 0 <= v <= 1 for v in recorded.values()):
            raise SystemExit(f"Ratio out of bounds: {name}")
        print(f"PASS {name}: {len(recorded)} series, same-time raw parity")
    print("PASS expected hosts:", ", ".join(sorted(expected)))
    print("PASS source age seconds:", json.dumps({h: round(a) for h, a in sorted(ages.items())}))


if __name__ == "__main__":
    main()
