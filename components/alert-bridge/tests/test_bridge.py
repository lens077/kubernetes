"""Offline bridge regressions: no server import side effects or notification network."""
import copy
import importlib.util
import http.client
import threading
import pathlib
import tempfile
import unittest
from unittest.mock import patch

PATH = pathlib.Path(__file__).resolve().parents[1] / 'bridge.py'
# Older bridge starts server at import: explicit safe failure before importing it.
if '__name__' not in PATH.read_text():
    raise AssertionError('bridge import starts its server; add an explicit main guard')
spec = importlib.util.spec_from_file_location('alert_bridge', PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def alert(name='pod-a', status='firing', severity='critical', start='2026-09-26T00:00:00Z'):
    return {'status': status, 'fingerprint': name, 'startsAt': start,
            'endsAt': '2026-09-26T02:00:00Z',
            'labels': {'alertname': 'RestartStorm', 'severity': severity, 'cluster': 'dev.test',
                       'k8s_namespace_name': 'infra', 'k8s_pod_name': name},
            'annotations': {'summary': '该 Pod 正在崩溃循环', 'description': '故障说明',
                            'dashboard': 'https://grafana.example/inspect'}}


def payload(*alerts, status='firing'):
    return {'receiver': 'bridge', 'groupKey': '{}:{alertname="RestartStorm"}',
            'status': status, 'alerts': list(alerts), 'commonLabels': {},
            'commonAnnotations': {}, 'truncatedAlerts': 0}


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(pathlib.Path(self.tmp.name) / 'state.json')
        self.now = 100000.
        self.sent = []
        self.env = patch.dict(bridge.os.environ, {
            'NTFY_URL': 'https://ntfy.example', 'NTFY_TOPIC': 'core',
            'NTFY_TICKET_TOPIC': 'ticket', 'NTFY_TEST_TOPIC': 'test', 'NTFY_TOKEN': ''})
        self.env.start(); self.addCleanup(self.env.stop)
        self.engine = self.make_engine()

    def make_engine(self, sender=None):
        return bridge.NotificationEngine(self.path, sender=sender or self.sent.append,
                                         clock=lambda: self.now, metrics=bridge.Metrics())

    def test_metrics_declare_types_and_start_with_zero_counters(self):
        lines = self.engine.metrics.render(self.engine).splitlines()
        self.assertIn('# TYPE alert_bridge_notifications_total counter', lines)
        self.assertIn('# TYPE alert_bridge_state_entries gauge', lines)
        for kind in ('page', 'ticket', 'test'):
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",reason="state_change_or_reminder",result="sent"}} 0', lines)
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",reason="publish",result="failed"}} 0', lines)
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",reason="backoff",result="suppressed"}} 0', lines)
        self.assertIn('alert_bridge_state_entries{active="true"} 0', lines)
        self.assertIn('alert_bridge_state_entries{active="false"} 0', lines)

    def test_metrics_distinguish_failed_publish_retry_and_suppression(self):
        p = payload(alert())
        with patch.object(self.engine, 'sender', side_effect=OSError('offline failure')):
            with self.assertRaises(OSError):
                self.engine.process(p)
        self.engine.process(p)
        self.engine.process(p)
        lines = self.engine.metrics.render(self.engine).splitlines()
        for result, reason in [('failed', 'publish'), ('sent', 'state_change_or_reminder'),
                               ('suppressed', 'backoff')]:
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="page",reason="{reason}",result="{result}"}} 1', lines)
        self.assertEqual(1, len(self.sent))

    def test_page_backoff_persists_and_caps(self):
        p = payload(alert())
        self.engine.process(p)
        self.assertEqual(1, len(self.sent))
        for hours in [1, 2, 4, 8, 24, 24]:
            self.now += hours * 3600 - 1
            self.engine = self.make_engine()
            self.engine.process(p)
            count = len(self.sent)
            self.now += 1
            self.engine.process(p)
            self.assertEqual(count + 1, len(self.sent))
        self.assertEqual(7, len(self.sent))

    def test_ticket_intervals_and_unknown_are_visible(self):
        p = payload(alert(severity='unexpected'))
        self.engine.process(p)
        self.assertEqual('ticket', self.sent[-1]['topic'])
        self.assertIn('unexpected', self.sent[-1]['body'])
        for hours in [4, 8, 16, 24, 24]:
            count = len(self.sent)
            self.now += hours * 3600 - 1; self.engine.process(p)
            self.assertEqual(count, len(self.sent))
            self.now += 1; self.engine.process(p)
            self.assertEqual(count + 1, len(self.sent))

    def test_failure_does_not_commit_and_retry_sends(self):
        def fail(_): raise OSError('unavailable')
        self.engine = self.make_engine(fail)
        with self.assertRaises(OSError): self.engine.process(payload(alert()))
        self.engine = self.make_engine()
        self.engine.process(payload(alert()))
        self.assertEqual(1, len(self.sent))

    def test_complete_resolved_once_and_without_fault_text(self):
        p = payload(alert(status='resolved'), status='resolved')
        self.engine.process(p)
        self.assertEqual([], self.sent)
        self.engine.process(payload(alert()))
        self.engine.process(p)
        self.engine = self.make_engine(); self.engine.process(p)
        self.assertEqual(2, len(self.sent))
        self.assertIn('[恢复]', self.sent[-1]['title'])
        self.assertNotIn('崩溃', self.sent[-1]['body'])
        self.assertNotIn('故障说明', self.sent[-1]['body'])

    def test_members_change_mixed_counts_and_refire(self):
        self.engine.process(payload(alert(), alert('pod-b')))
        self.engine.process(payload(alert(status='resolved'), alert('pod-b')))
        self.assertEqual(2, len(self.sent))
        self.assertIn('故障 1', self.sent[-1]['body'])
        self.assertIn('恢复 1', self.sent[-1]['body'])
        # Same labels and fingerprint but a new episode must never be suppressed.
        self.engine.process(payload(alert(start='2026-09-26T02:00:00Z'), alert('pod-b')))
        self.assertEqual(3, len(self.sent))

    def test_equivalent_timestamp_and_annotation_change_do_not_reset(self):
        self.engine.process(payload(alert()))
        a = alert(start='2026-09-26T00:00:00.000+00:00')
        a['annotations']['summary'] = 'value changes each evaluation'
        self.engine.process(payload(a))
        self.assertEqual(1, len(self.sent))

    def test_stale_firing_then_resolved_cannot_replace_current_episode(self):
        self.engine.process(payload(alert()))
        self.engine.process(payload(alert(start='2026-09-26T02:00:00Z')))
        self.engine = self.make_engine()
        self.engine.process(payload(alert()))
        self.engine.process(payload(alert(status='resolved'), status='resolved'))
        self.assertEqual(2, len(self.sent))
        self.engine.process(payload(alert(status='resolved', start='2026-09-26T02:00:00Z'), status='resolved'))
        self.assertEqual(3, len(self.sent))

    def test_topics_must_be_distinct_for_readiness_and_delivery(self):
        for key in ['NTFY_TEST_TOPIC', 'NTFY_TICKET_TOPIC']:
            with self.subTest(key=key), patch.dict(bridge.os.environ, {key: 'core'}):
                self.assertFalse(bridge.configured())
                with self.assertRaises(bridge.ConfigurationError): self.engine.process(payload(alert()))
        self.assertEqual([], self.sent)

    def test_late_firing_for_closed_episode_is_not_a_new_failure(self):
        self.engine.process(payload(alert()))
        self.engine.process(payload(alert(status='resolved'), status='resolved'))
        self.engine.process(payload(alert()))
        self.assertEqual(2, len(self.sent))
        self.engine.process(payload(alert(start='2026-09-26T02:00:00Z')))
        self.assertEqual(3, len(self.sent))

    def test_class_partial_failure_retry_does_not_duplicate_success(self):
        attempts = []
        def sender(m):
            if m['topic'] == 'ticket': raise OSError('fail ticket')
            attempts.append(m)
        self.engine = self.make_engine(sender)
        p = payload(alert(), alert('warning', severity='warning'))
        with self.assertRaises(OSError): self.engine.process(p)
        self.engine = self.make_engine(); self.engine.process(p)
        self.assertEqual(['core'], [m['topic'] for m in attempts])
        self.assertEqual(['ticket'], [m['topic'] for m in self.sent])

    def test_delayed_old_resolved_cannot_close_new_episode(self):
        self.engine.process(payload(alert()))
        self.engine.process(payload(alert(start='2026-09-26T02:00:00Z')))
        self.engine.process(payload(alert(status='resolved'), status='resolved'))
        self.assertEqual(2, len(self.sent))
        self.engine.process(payload(alert(status='resolved', start='2026-09-26T02:00:00Z'), status='resolved'))
        self.assertEqual(3, len(self.sent))

    def test_utf8_budget_three_objects_truncation_and_safe_click(self):
        alerts = [alert('对象' * 500 + str(i)) for i in range(6)]
        for a in alerts:
            a['annotations']['summary'] = '告警' * 4000
            a['annotations']['dashboard'] = 'https://user:password@grafana.example/'
        p = payload(*alerts); p['truncatedAlerts'] = 17
        self.engine.process(p)
        m = self.sent[0]
        self.assertLessEqual(len(m['body'].encode()), 3000)
        self.assertLessEqual(len(m['body'].splitlines()), 6)
        self.assertEqual(3, m['body'].count('对象：'))
        self.assertIn('截断 17', m['body'])
        self.assertEqual('', m['click'])

    def test_classes_split_and_test_topic_is_explicit(self):
        a = alert('test'); a['labels']['notification_class'] = 'test'
        self.engine.process(payload(alert(), alert('ticket', severity='warning'), a))
        self.assertEqual({'core', 'ticket', 'test'}, {m['topic'] for m in self.sent})

    def test_missing_topic_and_send_raw_config_fail_closed(self):
        with patch.dict(bridge.os.environ, {'NTFY_TICKET_TOPIC': ''}):
            with self.assertRaises(bridge.ConfigurationError):
                self.engine.process(payload(alert(severity='warning')))
        self.assertEqual([], self.sent)
        with patch.dict(bridge.os.environ, {'NTFY_URL': ''}):
            with self.assertRaises(bridge.ConfigurationError):
                bridge.send_raw('x', 'y', 3, 'tag')

    def test_truncated_resolution_cannot_close_notified_episode(self):
        self.engine.process(payload(alert(), alert('b')))
        p = payload(alert(status='resolved'), status='resolved'); p['truncatedAlerts'] = 1
        self.engine.process(p)
        self.assertEqual(1, len(self.sent))
        self.engine.process(payload(alert(status='resolved'), alert('b', status='resolved'), status='resolved'))
        self.assertEqual(2, len(self.sent))

    def test_concurrent_identical_delivery_publishes_once(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(self.engine.process, [payload(alert()) for _ in range(8)]))
        self.assertEqual(1, sum(results))
        self.assertEqual(1, len(self.sent))

    def test_corrupt_state_fails_closed_on_start(self):
        pathlib.Path(self.path).write_text('{"x": {"active": "maybe"}}')
        with self.assertRaises(bridge.ConfigurationError): self.make_engine()

    def test_send_raw_uses_utf8_json_and_no_external_network(self):
        from unittest.mock import MagicMock
        response = MagicMock(); response.__enter__.return_value.status = 200
        response.__enter__.return_value.read.return_value = b'{"event":"message","id":"test"}'
        with patch.object(bridge, 'urlopen', return_value=response) as sender:
            bridge.send_raw('[故障][关注] 中文', '故障 1\n摘要：中文', 5, 'rotating_light', topic='test')
        request = sender.call_args.args[0]
        self.assertEqual('application/json; charset=utf-8', request.get_header('Content-type'))
        body = bridge.json.loads(request.data)
        self.assertEqual('test', body['topic'])
        self.assertEqual('故障 1\n摘要：中文', body['message'])
        self.assertIn('中文'.encode(), request.data)

    def test_non_realtime_priorities(self):
        a = alert('test'); a['labels']['notification_class'] = 'test'
        self.engine.process(payload(alert(), alert('ticket', severity='warning'), a))
        self.assertEqual({'core': 4, 'ticket': 2, 'test': 1}, {m['topic']: m['priority'] for m in self.sent})
        self.engine.process(payload(alert(status='resolved'), status='resolved'))
        self.assertEqual(2, self.sent[-1]['priority'])

    def test_200_without_ntfy_confirmation_is_failure(self):
        from unittest.mock import MagicMock
        for body in [b'<html>login</html>', b'{}', b'{"event":"keepalive"}']:
            response = MagicMock(); response.__enter__.return_value.status = 200
            response.__enter__.return_value.read.return_value = body
            with patch.object(bridge, 'urlopen', return_value=response):
                with self.assertRaises(RuntimeError): bridge.send_raw('test', 'test', 1, 'test')

    def test_redirect_does_not_forward_authorization(self):
        import urllib.error
        handler = bridge.NoRedirect()
        request = bridge.Request('https://ntfy.example', headers={'Authorization': 'Bearer test'})
        self.assertIsNone(handler.redirect_request(request, None, 302, 'redirect', {}, 'https://other.example'))

    def test_invalid_schema_and_size_rejected(self):
        for p in [{}, payload(), payload(alert(start='not-a-time')),
                  payload(alert(status='unknown')), payload(alert(), status='resolved')]:
            with self.subTest(p=p):
                with self.assertRaises(bridge.InvalidPayload): self.engine.process(p)
        with self.assertRaises(bridge.InvalidPayload):
            bridge.decode_payload(b'x' * (bridge.MAX_BODY + 1))
        with self.assertRaises(bridge.InvalidPayload): bridge.decode_payload(b'[]')

    def test_http_schema_failure_retry_and_health(self):
        server = bridge.ThreadingHTTPServer(('127.0.0.1', 0), bridge.AlertmanagerHandler)
        server.engine = self.engine
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(lambda: (server.shutdown(), thread.join()))
        def request(path='/alerts', body=b'{}', length=None, method='POST'):
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
            headers = {'Content-Type': 'application/json', 'Content-Length': str(len(body)) if length is None else length}
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse(); status = response.status; response.read(); conn.close()
            return status
        self.assertEqual(400, request(length='NaN'))
        self.assertEqual(400, request(length='-1'))
        self.assertEqual(413, request(length=str(bridge.MAX_BODY+1)))
        self.assertEqual(400, request())
        raw = bridge.json.dumps(payload(alert())).encode()
        self.assertEqual(200, request(body=raw))
        self.assertEqual(200, request(body=raw))
        self.assertEqual(1, len(self.sent))
        self.assertEqual(200, request('/healthz', method='GET'))
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
        conn.request('GET', '/metrics')
        response = conn.getresponse(); metrics = response.read().decode(); conn.close()
        self.assertEqual(200, response.status)
        self.assertIn('alert_bridge_notifications_total{notification_class="page",reason="state_change_or_reminder",result="sent"} 1', metrics)
        self.assertIn('alert_bridge_notifications_total{notification_class="page",reason="backoff",result="suppressed"} 1', metrics)
        self.assertIn('alert_bridge_state_entries{active="true"} 1', metrics)
        with patch.dict(bridge.os.environ, {'NTFY_TICKET_TOPIC': ''}):
            self.assertEqual(503, request('/healthz', method='GET'))
            self.assertEqual(200, request('/livez', method='GET'))
        self.now += 3600
        with patch.object(self.engine, 'sender', side_effect=OSError('failure')):
            self.assertEqual(502, request(body=raw))
        self.assertEqual(200, request(body=raw))
        self.assertEqual(2, len(self.sent))


if __name__ == '__main__':
    unittest.main()
