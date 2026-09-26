#!/usr/bin/python3
# Alertmanager / Bugsink → ntfy. Standard library only; importing never starts a server.
# AM owns initial for/group_wait; this bridge owns persistent repeat backoff.
# 2026-09-26: recovery previously repeated fault prose; grouped commonAnnotations
# hid objects, and unconfigured publishing returned false success. Regression tests
# cover all three. Never advance durable suppression until publishing succeeds.
import datetime
import json
import os
import hashlib
import pathlib
import tempfile
import time
import threading
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, HTTPRedirectHandler, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward a publisher credential to another destination.


urlopen = build_opener(NoRedirect()).open

MAX_BODY = 1024 * 1024
BUGSINK_BRIDGE_TOKEN = os.environ.get("BUGSINK_BRIDGE_TOKEN", "")


class Metrics:
    """Bounded-label Prometheus counters for delivery and suppression decisions."""
    def __init__(self):
        self.lock = threading.Lock()
        # Export zeros before the first event so increase() can observe its delta.
        # Fixed classes/reasons bound this family to 18 series per process.
        outcomes = [("sent", "state_change_or_reminder"), ("failed", "publish")]
        outcomes += [("suppressed", reason) for reason in
                     ("stale", "unmatched_recovery", "closed_episode", "backoff")]
        self.values = {
            ("alert_bridge_notifications_total", tuple(sorted({
                "notification_class": kind, "result": result, "reason": reason
            }.items()))): 0
            for kind in ("page", "ticket", "test") for result, reason in outcomes
        }

    def inc(self, name, **labels):
        key = (name, tuple(sorted(labels.items())))
        with self.lock:
            self.values[key] = self.values.get(key, 0) + 1

    def render(self, engine=None):
        lines = [
            "# HELP alert_bridge_notifications_total Alertmanager delivery and suppression decisions since process start.",
            "# TYPE alert_bridge_notifications_total counter",
        ]
        with self.lock:
            values = dict(self.values)
        for (name, labels), value in sorted(values.items()):
            suffix = "{" + ",".join(f'{k}="{v}"' for k, v in labels) + "}" if labels else ""
            lines.append(f"{name}{suffix} {value}")
        if engine is not None:
            # commit() replaces the dict; keep one coherent snapshot without
            # holding the publisher lock across a scrape or network publish.
            state = engine.state
            active = sum(1 for entry in state.values() if entry.get("active"))
            lines.extend([
                "# HELP alert_bridge_state_entries Persisted notification groups by active state.",
                "# TYPE alert_bridge_state_entries gauge",
                f"alert_bridge_state_entries{{active=\"true\"}} {active}",
                f"alert_bridge_state_entries{{active=\"false\"}} {len(state)-active}",
            ])
        return "\n".join(lines) + "\n"


METRICS = Metrics()
ALERTMANAGER_LISTEN = os.environ.get("ALERTMANAGER_LISTEN", "0.0.0.0:9099")
BUGSINK_BRIDGE_LISTEN = os.environ.get("BUGSINK_BRIDGE_LISTEN", "0.0.0.0:9199")


def log(record):
    record.setdefault("time", datetime.datetime.now(datetime.timezone.utc).isoformat())
    print(json.dumps(record, ensure_ascii=False), flush=True)   # UTF-8 直出, VictoriaLogs 里中文可读


def compact(value, limit):
    text = " ".join(str(value or "").split())
    return text[:limit]


class InvalidPayload(ValueError):
    pass


class ConfigurationError(RuntimeError):
    pass


def safe_https(value):
    try:
        u = urlsplit(value)
        return value if (u.scheme == "https" and u.hostname and not u.username
                         and not u.password and len(value) <= 2048
                         and not any(ord(c) < 33 for c in value)) else ""
    except (ValueError, TypeError):
        return ""


def utf8_limit(value, limit):
    text = compact(value, limit)
    return text if len(text.encode()) <= limit else text.encode()[:limit-3].decode("utf-8", "ignore") + "…"


def send_raw(title, message, priority, tags, click="", topic=None):
    url = os.environ.get("NTFY_URL", "").rstrip("/")
    topic = os.environ.get("NTFY_TOPIC", "") if topic is None else topic
    if not safe_https(url) or not topic:
        raise ConfigurationError("ntfy destination missing or invalid")
    body = {"topic": topic, "title": utf8_limit(title, 240),
            "message": "\n".join(utf8_limit(line, 490) for line in message.splitlines()[:6]),
            "priority": priority, "tags": tags.split(",")}
    if safe_https(click):
        body["click"] = click
    headers = {"Content-Type": "application/json; charset=utf-8"}
    token = os.environ.get("NTFY_TOKEN", "")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, data=json.dumps(body, ensure_ascii=False).encode(), method="POST", headers=headers)
    with urlopen(request, timeout=10) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError("ntfy publish failed")
        try:
            confirmation = json.loads(response.read(65537))
        except (ValueError, UnicodeError) as exc:
            raise RuntimeError("ntfy acknowledgement invalid") from exc
        if not isinstance(confirmation, dict) or confirmation.get("event") != "message":
            raise RuntimeError("ntfy message not acknowledged")


def decode_payload(raw):
    if not raw or len(raw) > MAX_BODY:
        raise InvalidPayload("invalid body size")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise InvalidPayload("invalid JSON") from exc
    if not isinstance(value, dict):
        raise InvalidPayload("object required")
    return value


def timestamp(value):
    if not isinstance(value, str) or len(value) > 64:
        raise InvalidPayload("invalid timestamp")
    try:
        t = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if not t.tzinfo:
            raise ValueError()
        return t.astimezone(datetime.timezone.utc).isoformat(timespec="microseconds")
    except ValueError as exc:
        raise InvalidPayload("invalid timestamp") from exc


def validate_payload(payload):
    if not isinstance(payload, dict) or payload.get("status") not in ("firing", "resolved"):
        raise InvalidPayload("invalid status")
    for key in ("receiver", "groupKey"):
        if not isinstance(payload.get(key), str) or not 0 < len(payload[key]) <= 8192:
            raise InvalidPayload("missing group identity")
    alerts = payload.get("alerts")
    if not isinstance(alerts, list) or not 1 <= len(alerts) <= 1000:
        raise InvalidPayload("invalid alerts")
    truncated = payload.get("truncatedAlerts", 0)
    if type(truncated) is not int or truncated < 0:
        raise InvalidPayload("invalid truncated count")
    for a in alerts:
        if not isinstance(a, dict) or a.get("status") not in ("firing", "resolved"):
            raise InvalidPayload("invalid member")
        for field in ("labels", "annotations"):
            values = a.get(field, {})
            if not isinstance(values, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in values.items()):
                raise InvalidPayload("invalid labels or annotations")
        if not a.get("labels", {}).get("alertname"):
            raise InvalidPayload("missing alertname")
        timestamp(a.get("startsAt"))
        if a["status"] == "resolved":
            timestamp(a.get("endsAt"))
        if "fingerprint" in a and not isinstance(a["fingerprint"], str):
            raise InvalidPayload("invalid fingerprint")
    if (payload["status"] == "resolved") != all(a["status"] == "resolved" for a in alerts):
        raise InvalidPayload("inconsistent group status")


def alert_class(alert):
    labels = alert["labels"]
    if labels.get("notification_class") == "test" or labels.get("notification_route") == "test":
        return "test"
    return "page" if labels.get("severity", "").lower() in ("critical", "crit") else "ticket"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def fingerprint_id(alert):
    return digest(alert.get("fingerprint") or digest(alert["labels"]))


def member_id(alert):
    # Fingerprint is stable within an episode, startsAt distinguishes same-label re-fires.
    return digest([fingerprint_id(alert), timestamp(alert["startsAt"])])


def format_notification(alerts, kind, topic, truncated):
    firing = [a for a in alerts if a["status"] == "firing"]
    resolved = not firing
    focus = (firing or alerts)[0]
    labels = focus["labels"]
    name = labels.get("service_name") or labels.get("service") or labels["alertname"]
    cluster = labels.get("cluster") or "unknown-cluster"
    level = "关注" if kind == "page" else ("测试" if kind == "test" else "待办")
    title = utf8_limit(f"[{'恢复' if resolved else '故障'}][{level}] {name} · {cluster}", 240)
    severity = ",".join(sorted({a["labels"].get("severity", "unknown") for a in alerts}))
    lines = [f"故障 {len(firing)} · 恢复 {len(alerts)-len(firing)} · severity={severity}"]
    if resolved:
        lines.append("已恢复：本组已通知的故障现已解除。")
    else:
        summary = focus.get("annotations", {}).get("summary") or focus.get("annotations", {}).get("description") or "无摘要，请查看对象状态。"
        lines.append("摘要：" + summary)
    for a in (firing + [a for a in alerts if a["status"] == "resolved"])[:3]:
        lab = a["labels"]
        obj = lab.get("k8s_pod_name") or lab.get("k8s_deployment_name") or lab.get("instance") or lab.get("service_name") or lab["alertname"]
        ns = lab.get("k8s_namespace_name") or lab.get("namespace")
        lines.append(f"{'恢复' if a['status'] == 'resolved' else '故障'}对象：{ns + '/' if ns else ''}{obj}")
    extra = max(0, len(alerts)-3)
    lines.append(f"来源：Alertmanager · 集群 {cluster} · 另有 {extra} 对象 · 上游截断 {truncated}")
    click = next((safe_https(a.get("annotations", {}).get("dashboard", "")) for a in alerts if safe_https(a.get("annotations", {}).get("dashboard", ""))), "")
    return {"title": title, "body": "\n".join(utf8_limit(line, 490) for line in lines),
            "priority": 2 if resolved else {"page": 4, "ticket": 2, "test": 1}[kind],
            "tags": "white_check_mark" if resolved else ("rotating_light" if kind == "page" else "memo"),
            "topic": topic, "click": click}


class NotificationEngine:
    """Single-process serial publisher with atomic, fsynced persistent state.

    No queue: AM retries failed requests and polls successful groups every 5m.
    A crash after publish but before state commit can duplicate once (at-least-once).
    """
    INTERVALS = {"page": [1, 2, 4, 8, 24], "ticket": [4, 8, 16, 24], "test": [4, 8, 16, 24]}

    def __init__(self, path, sender=None, clock=time.time, metrics=None):
        self.path = pathlib.Path(path)
        self.clock = clock
        self.sender = sender or self.publish
        self.metrics = metrics or METRICS
        self.lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.state = json.loads(self.path.read_text()) if self.path.exists() else {}
            if not isinstance(self.state, dict):
                raise ValueError()
            for key, entry in self.state.items():
                if (not isinstance(key, str) or not isinstance(entry, dict)
                        or type(entry.get("active")) is not bool
                        or not isinstance(entry.get("members"), list)
                        or not isinstance(entry.get("closed_members"), list)
                        or not isinstance(entry.get("latest_starts"), dict)
                        or not all(isinstance(k, str) and isinstance(v, str) for k, v in entry["latest_starts"].items())
                        or not all(isinstance(x, str) for x in entry["members"] + entry["closed_members"])
                        or type(entry.get("count")) is not int or entry["count"] < 1
                        or type(entry.get("last_sent")) not in (int, float)):
                    raise ValueError()
            # Readiness must not succeed with an unwritable state volume.
            with tempfile.TemporaryFile(dir=self.path.parent) as probe:
                probe.write(b"state-check"); probe.flush(); os.fsync(probe.fileno())
        except (ValueError, OSError, TypeError) as exc:
            raise ConfigurationError("invalid or unwritable state file") from exc

    @staticmethod
    def publish(message):
        send_raw(message["title"], message["body"], message["priority"], message["tags"],
                 message["click"], topic=message["topic"])

    def commit(self, key, entry):
        state = {k: v for k, v in self.state.items()
                 if v.get("active") or self.clock() - v["last_sent"] < 30*86400}
        state[key] = entry
        fd, tmp = tempfile.mkstemp(prefix=".state-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(state, f, ensure_ascii=False)
                f.flush(); os.fsync(f.fileno())
            os.replace(tmp, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            self.state = state
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def process(self, payload):
        validate_payload(payload)
        if not configured():
            raise ConfigurationError("distinct core/ticket/test destinations required")
        groups = {}
        for alert in payload["alerts"]:
            groups.setdefault(alert_class(alert), []).append(alert)
        sent = 0
        with self.lock:
            for kind, alerts in sorted(groups.items()):
                topic = os.environ.get({"page": "NTFY_TOPIC", "ticket": "NTFY_TICKET_TOPIC", "test": "NTFY_TEST_TOPIC"}[kind], "")
                if not topic or not safe_https(os.environ.get("NTFY_URL", "")):
                    raise ConfigurationError("notification destination missing")
                key = digest([payload["receiver"], payload["groupKey"], kind, topic])
                previous = self.state.get(key, {})
                latest = dict(previous.get("latest_starts", {}))
                # A group is one snapshot. Ignore the entire stale class snapshot so
                # filtering old members cannot accidentally resolve/remove a new one.
                if any(timestamp(a["startsAt"]) < latest.get(fingerprint_id(a), "") for a in alerts):
                    self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                     result="suppressed", reason="stale")
                    continue
                for a in alerts:
                    fp = fingerprint_id(a)
                    latest[fp] = max(latest.get(fp, ""), timestamp(a["startsAt"]))
                active = sorted(member_id(a) for a in alerts if a["status"] == "firing")
                all_ids = {member_id(a) for a in alerts}
                now = self.clock()
                if not active:
                    if (not previous.get("active") or payload.get("truncatedAlerts", 0)
                            or not set(previous["members"]).issubset(all_ids)):
                        self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                         result="suppressed", reason="unmatched_recovery")
                        continue
                    count = 0
                else:
                    if not previous.get("active") and set(active).issubset(previous.get("closed_members", [])):
                        self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                         result="suppressed", reason="closed_episode")
                        continue  # Old firing webhook delivered after this episode resolved.
                    changed = not previous.get("active") or active != previous.get("members")
                    intervals = self.INTERVALS[kind]
                    count = 0 if changed else previous["count"]
                    delay = intervals[min(max(count-1, 0), len(intervals)-1)] * 3600
                    if not changed and now - previous["last_sent"] < delay:
                        self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                         result="suppressed", reason="backoff")
                        continue
                try:
                    self.sender(format_notification(alerts, kind, topic, payload.get("truncatedAlerts", 0)))
                except Exception:
                    self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                     result="failed", reason="publish")
                    raise
                self.metrics.inc("alert_bridge_notifications_total", notification_class=kind,
                                 result="sent", reason="state_change_or_reminder")
                # Never advance suppression before a successful publish.
                self.commit(key, {"active": bool(active), "members": active,
                                  "closed_members": sorted(all_ids) if not active else [],
                                  "latest_starts": latest,
                                  "count": count+1, "last_sent": now})
                sent += 1
        return sent


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


def configured():
    topics = [os.environ.get(key, "") for key in ("NTFY_TOPIC", "NTFY_TICKET_TOPIC", "NTFY_TEST_TOPIC")]
    return bool(safe_https(os.environ.get("NTFY_URL", "")) and all(topics) and len(set(topics)) == 3)


def healthz(handler):
    ready = configured() and getattr(handler.server, "engine", None) is not None
    handler.reply(200 if ready else 503, {"ok": ready, "ntfy": configured()})


class WebhookHandler(BaseHTTPRequestHandler):
    def reply(self, code, body=None, content_type="application/json; charset=utf-8"):
        raw = (json.dumps(body or {"ok": code == 200}).encode()
               if content_type.startswith("application/json") else body)
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()
        self.close_connection = True

    def read_payload(self):
        if self.headers.get("Transfer-Encoding"):
            raise InvalidPayload("chunked requests unsupported")
        lengths = self.headers.get_all("Content-Length", [])
        if (len(lengths) != 1 or len(lengths[0]) > 20
                or not lengths[0].isascii() or not lengths[0].isdigit()):
            raise InvalidPayload("invalid content length")
        length = int(lengths[0])
        if length > MAX_BODY:
            raise OverflowError("body too large")
        if length < 1:
            raise InvalidPayload("empty body")
        if self.headers.get_content_type() != "application/json":
            raise InvalidPayload("JSON content type required")
        self.connection.settimeout(10)
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise InvalidPayload("incomplete body")
        return decode_payload(raw)

    def do_GET(self):
        if self.path == "/healthz":
            healthz(self)
        elif self.path == "/livez":
            self.reply(200)
        elif self.path == "/metrics":
            self.reply(200, self.server.engine.metrics.render(self.server.engine).encode(),
                       "text/plain; version=0.0.4; charset=utf-8")
        else:
            self.reply(404)

    def log_message(self, fmt, *args):
        return  # Never log URL paths: Bugsink route includes its token.

    def error(self, exc):
        if isinstance(exc, OverflowError):
            self.reply(413)
        elif isinstance(exc, (InvalidPayload, TimeoutError)):
            self.reply(400)
        else:
            # URL exceptions may contain credentials/paths: only record type.
            log({"source": "bridge", "event": "publish_failed", "error_type": type(exc).__name__})
            self.reply(502)


class AlertmanagerHandler(WebhookHandler):
    def do_POST(self):
        if self.path != "/alerts":
            self.reply(404)
            return
        try:
            payload = self.read_payload()
            sent = self.server.engine.process(payload)
            log({"source": "alertmanager", "event": "processed", "status": payload["status"],
                 "members": len(payload["alerts"]), "notifications": sent})
            self.reply(200)
        except Exception as exc:  # Fail closed: AM retries 502 without advancing state.
            self.error(exc)


class BugsinkHandler(WebhookHandler):
    def do_POST(self):
        expected = f"/bugsink/{BUGSINK_BRIDGE_TOKEN}"
        if not BUGSINK_BRIDGE_TOKEN or self.path != expected:
            self.reply(404)
            return
        try:
            payload = self.read_payload()
            if (not isinstance(payload.get("text", ""), str)
                    or not isinstance(payload.get("blocks", []), list)):
                raise InvalidPayload("invalid Slack payload")
            try:
                title, message = slack_text(payload)
            except (AttributeError, TypeError) as exc:
                raise InvalidPayload("invalid Slack blocks") from exc
            send_raw(title, message or "Bugsink alert", 5, "bug")
            log({"source": "bugsink", "event": "published"})
            self.reply(200)
        except Exception as exc:
            self.error(exc)


def listen(addr, handler):
    host, port = addr.rsplit(":", 1)
    return ThreadingHTTPServer((host, int(port)), handler)


def main():
    engine = NotificationEngine(os.environ.get("BRIDGE_STATE_FILE", "/state/notifications.json"))
    log({"source": "bridge", "event": "start", "ntfy": configured(),
         "bugsink_bridge": bool(BUGSINK_BRIDGE_TOKEN)})
    if BUGSINK_BRIDGE_TOKEN:
        bugsink = listen(BUGSINK_BRIDGE_LISTEN, BugsinkHandler)
        bugsink.engine = engine
        threading.Thread(target=bugsink.serve_forever, daemon=True).start()
    server = listen(ALERTMANAGER_LISTEN, AlertmanagerHandler)
    server.engine = engine
    server.serve_forever()


if __name__ == "__main__":
    main()
