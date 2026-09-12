#!/usr/bin/python3
# =============================================================================
# alert-bridge —— Alertmanager / Bugsink webhook → ntfy 推送 + 结构化日志
#
# 来源: node3 Pigsty 时代的 /usr/local/libexec/pigsty-alert-ntfy.py(2026-09-03 收割),
# 容器化改动只有三处:
#   1. 监听地址从 127.0.0.1 改为可配(默认 0.0.0.0), Pod 里必须对外监听;
#   2. ntfy 未配置时不再启动即崩(KeyError), 改为"只记日志不推送"并在 /healthz 里如实报告,
#      这样 Alertmanager → 桥 这一段链路在没拿到 ntfy 凭据前也是通的;
#   3. 每条进来的告警都以 JSON 行写 stdout —— Vector 采到 VictoriaLogs 后, 告警历史可查
#      (job=alert-bridge)。这是 ntfy 之外的第二条"告警去了哪"的证据链。
# 只用标准库, 镜像用官方 python:alpine 即可。
# =============================================================================
import datetime
import json
import os
import threading
from email.header import Header
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote
from urllib.request import Request, urlopen

MAX_BODY = 1024 * 1024
NTFY_URL = os.environ.get("NTFY_URL", "").rstrip("/")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")
NTFY_READY = bool(NTFY_URL and NTFY_TOPIC)
BUGSINK_BRIDGE_TOKEN = os.environ.get("BUGSINK_BRIDGE_TOKEN", "")
ALERTMANAGER_LISTEN = os.environ.get("ALERTMANAGER_LISTEN", "0.0.0.0:9099")
BUGSINK_BRIDGE_LISTEN = os.environ.get("BUGSINK_BRIDGE_LISTEN", "0.0.0.0:9199")


def log(record):
    record.setdefault("time", datetime.datetime.now(datetime.timezone.utc).isoformat())
    print(json.dumps(record, ensure_ascii=False), flush=True)   # UTF-8 直出, VictoriaLogs 里中文可读


def compact(value, limit):
    text = " ".join(str(value or "").split())
    return text[:limit]


def send_raw(title, message, priority, tags):
    if not NTFY_READY:
        log({"source": "ntfy", "skipped": "ntfy not configured", "title": compact(title, 160)})
        return
    headers = {
        "Content-Type": "text/plain; charset=utf-8",
        "Priority": str(priority),
        "Tags": tags,
        "Title": Header(compact(title, 160), "utf-8").encode(),
    }
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"
    request = Request(
        f"{NTFY_URL}/{quote(NTFY_TOPIC, safe='')}",
        data=message.encode("utf-8"),
        method="POST",
        headers=headers,
    )
    with urlopen(request, timeout=10) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError(f"ntfy returned HTTP {response.status}")


def send_alertmanager(payload):
    labels = payload.get("commonLabels", {})
    annotations = payload.get("commonAnnotations", {})
    alerts = payload.get("alerts", [])
    status = payload.get("status", "unknown")
    name = labels.get("alertname") or "multiple alerts"
    severity = labels.get("severity", "unknown")
    summary = annotations.get("summary") or annotations.get("description") or ""

    resolved = status == "resolved"
    title = f"[{status.upper()}] {compact(name, 120)}"
    message = (
        f"severity={severity}\n"
        f"alerts={len(alerts)}\n"
        f"summary={compact(summary, 1200)}"
    )
    priority = 3 if resolved else (5 if severity.lower() in ("crit", "critical") else 4)
    tags = "white_check_mark" if resolved else "rotating_light"
    send_raw(title, message, priority, tags)


def slack_text(payload):
    title = "Bugsink issue"
    parts = []
    if payload.get("text"):
        parts.append(compact(payload["text"], 500))
    for block in payload.get("blocks", []):
        if block.get("type") == "header":
            title = compact(block.get("text", {}).get("text"), 150) or title
            continue
        text = block.get("text", {}).get("text")
        if text:
            parts.append(compact(text, 800))
        for field in block.get("fields", []):
            if field.get("text"):
                parts.append(compact(field["text"], 400))
    return title, "\n".join(dict.fromkeys(parts))[:2500]


def healthz(handler):
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.end_headers()
    handler.wfile.write(json.dumps({"ok": True, "ntfy": NTFY_READY}).encode())


class AlertmanagerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_error(404)
            return
        healthz(self)

    def do_POST(self):
        if self.path != "/alerts":
            self.send_error(404)
            return
        length = min(int(self.headers.get("Content-Length", "0")), MAX_BODY)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            # 每条告警单独落一行: 便于 VictoriaLogs 按 alertname/severity 过滤, 而不是只看分组摘要
            for alert in payload.get("alerts", []):
                log({
                    "source": "alertmanager",
                    "status": alert.get("status"),
                    "alertname": alert.get("labels", {}).get("alertname"),
                    "severity": alert.get("labels", {}).get("severity"),
                    "category": alert.get("labels", {}).get("category"),
                    "summary": compact(alert.get("annotations", {}).get("summary"), 300),
                    "startsAt": alert.get("startsAt"),
                })
            send_alertmanager(payload)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        except Exception as exc:  # noqa: BLE001 - 必须回 502 让 Alertmanager 重试
            log({"source": "alertmanager", "error": str(exc)})
            self.send_response(502)
            self.end_headers()

    def log_message(self, fmt, *args):
        return


class BugsinkHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_error(404)
            return
        healthz(self)

    def do_POST(self):
        expected = f"/bugsink/{BUGSINK_BRIDGE_TOKEN}"
        if not BUGSINK_BRIDGE_TOKEN or self.path != expected:
            self.send_error(404)
            return
        length = min(int(self.headers.get("Content-Length", "0")), MAX_BODY)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            title, message = slack_text(payload)
            send_raw(title, message or "Bugsink alert", 5, "bug")
            log({"source": "bugsink", "title": title})
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        except Exception as exc:  # noqa: BLE001
            log({"source": "bugsink", "error": str(exc)})
            self.send_response(502)
            self.end_headers()

    def log_message(self, fmt, *args):
        return


def listen(addr, handler):
    host, port = addr.rsplit(":", 1)
    return ThreadingHTTPServer((host, int(port)), handler)


log({"source": "bridge", "event": "start", "ntfy": NTFY_READY,
     "bugsink_bridge": bool(BUGSINK_BRIDGE_TOKEN),
     "alertmanager_listen": ALERTMANAGER_LISTEN, "bugsink_listen": BUGSINK_BRIDGE_LISTEN})
if BUGSINK_BRIDGE_TOKEN:
    threading.Thread(target=listen(BUGSINK_BRIDGE_LISTEN, BugsinkHandler).serve_forever, daemon=True).start()
listen(ALERTMANAGER_LISTEN, AlertmanagerHandler).serve_forever()
