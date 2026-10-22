#!/usr/bin/env python3
"""把 CNPG 备份的真实状态推进 VictoriaMetrics。

为什么需要它：CNPG 实例导出器的 cnpg_collector_last_available_backup_timestamp
只反映**已废弃的 in-tree barmanObjectStore** 备份。改用 Barman Cloud Plugin 之后，
即便备份真实成功，该指标也恒为 0 —— 原来的两条备份告警因此彻底失效：
一条恒真永久告警，另一条永远不响、变成盲区。

这里绕过导出器，直接问 Kubernetes API 里 Backup 对象的真相，写成两个 series：

  cnpg_backup_last_success_timestamp_seconds  最近一次 completed 备份的 Unix 秒
                                             （没有任何成功备份时为 0）
  cnpg_probe_run_timestamp_seconds            探针本次成功运行的时间（死人开关）

探针自己挂了会让这两个 series 变 stale 并消失，由 vmalert 的 CNPGBackupProbeMissing
兜住 —— 不会假绿。
"""
import json
import os
import ssl
import time
import urllib.request

NAMESPACE = os.environ.get("PROBE_NAMESPACE", "postgresql")
CLUSTER = os.environ.get("PROBE_CLUSTER", "pg-main")
VM_URL = os.environ.get("VM_URL", "").rstrip("/")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

K8S_HOST = os.environ.get("KUBERNETES_SERVICE_HOST")
K8S_PORT = os.environ.get("KUBERNETES_SERVICE_PORT")


def kube_get(path):
    token = open(os.path.join(SA_DIR, "token")).read().strip()
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    url = f"https://{K8S_HOST}:{K8S_PORT}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.load(resp)


def to_epoch(text):
    from datetime import datetime, timezone
    if not text:
        return 0.0
    # CNPG 的时间形如 2026-10-20T18:27:21Z 或带小数秒
    t = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return t.timestamp()


def main():
    if not VM_URL:
        raise SystemExit("VM_URL not set")

    backups = kube_get(
        f"/apis/postgresql.cnpg.io/v1/namespaces/{NAMESPACE}/backups"
    ).get("items", [])

    latest = 0.0
    total = 0
    for b in backups:
        status = b.get("status") or {}
        # Backups 没有固定的 cnpg.io/cluster 标签，按 spec.cluster.name 归属更可靠
        if ((b.get("spec") or {}).get("cluster") or {}).get("name") != CLUSTER:
            continue
        total += 1
        if status.get("phase") != "completed":
            continue
        latest = max(latest, to_epoch(status.get("stoppedAt") or status.get("startedAt")))

    now = time.time()
    now_ms = int(now * 1000)
    lines = [
        f'cnpg_backup_last_success_timestamp_seconds{{cluster="{CLUSTER}",source="k8s-api"}} '
        f'{int(latest)} {now_ms}',
        f'cnpg_probe_run_timestamp_seconds{{cluster="{CLUSTER}",source="backup-probe"}} '
        f'{int(now)} {now_ms}',
    ]
    body = ("\n".join(lines) + "\n").encode()

    req = urllib.request.Request(
        VM_URL + "/api/v1/import/prometheus",
        data=body,
        headers={"Content-Type": "text/plain"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()

    if latest:
        age_h = (now - latest) / 3600
        print(f"OK: scanned {total} backups; latest success {age_h:.1f}h ago")
    else:
        print(f"OK: scanned {total} backups; NO successful backup found -> emitted 0")


if __name__ == "__main__":
    main()
