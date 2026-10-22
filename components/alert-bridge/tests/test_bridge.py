"""Offline bridge regressions: no server import side effects or notification network."""
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
        # 续期上限与心跳也要有零值基线, 否则 increase() 看不到首次事件。
        for kind in ('page', 'ticket', 'test'):
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",reason="renewal_cap",result="suppressed"}} 0', lines)
            self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",reason="recap",result="sent"}} 0', lines)

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

    def assert_metric(self, kind, reason, result, value):
        lines = self.engine.metrics.render(self.engine).splitlines()
        self.assertIn(f'alert_bridge_notifications_total{{notification_class="{kind}",'
                      f'reason="{reason}",result="{result}"}} {value}', lines)

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

    def test_page_renewal_cap_persists_then_heartbeat_only(self):
        p = payload(alert())
        self.engine.process(p)
        for hours in [1, 2, 4, 8, 24, 24, 24]:
            self.now += hours * 3600
            self.engine.process(p)
        self.assertEqual(8, len(self.sent))                  # 首发 + 7 次续期 = MAX_SENDS
        # 上限后重建进程: 状态在 PVC 上, 上限必须仍然生效, 24h 阶梯到点也不再推。
        self.engine = self.make_engine()
        self.now += 24 * 3600
        self.engine.process(p)
        self.assertEqual(8, len(self.sent))
        self.assert_metric('page', 'renewal_cap', 'suppressed', 1)
        # RECAP_INTERVAL 之后只放行一条心跳, 且不重启退避阶梯。
        self.now += self.engine.RECAP_INTERVAL['page']
        self.engine.process(p)
        self.assertEqual(9, len(self.sent))
        self.assert_metric('page', 'recap', 'sent', 1)
        self.now += 24 * 3600
        self.engine.process(p)
        self.assertEqual(9, len(self.sent))
        self.assert_metric('page', 'renewal_cap', 'suppressed', 2)

    def test_ticket_renewal_cap_and_heartbeat(self):
        p = payload(alert(severity='warning'))
        self.engine.process(p)
        for hours in [4, 8, 16, 24, 24]:
            self.now += hours * 3600
            self.engine.process(p)
        self.assertEqual(6, len(self.sent))
        self.now += 24 * 3600
        self.engine.process(p)
        self.assertEqual(6, len(self.sent))
        self.assert_metric('ticket', 'renewal_cap', 'suppressed', 1)
        self.now += self.engine.RECAP_INTERVAL['ticket']
        self.engine.process(p)
        self.assertEqual(7, len(self.sent))
        self.assert_metric('ticket', 'recap', 'sent', 1)

    def test_member_change_and_new_episode_beat_renewal_cap(self):
        p = payload(alert())
        self.engine.process(p)
        for hours in [1, 2, 4, 8, 24, 24, 24]:
            self.now += hours * 3600
            self.engine.process(p)
        self.assertEqual(8, len(self.sent))
        # 新成员进组是新的故障面, 必须穿透上限。
        self.engine.process(payload(alert(), alert('pod-b')))
        self.assertEqual(9, len(self.sent))
        # 同标签新 episode(startsAt 不同)同样必须穿透, 上限不能吞掉复发。
        self.engine.process(payload(alert(start='2026-09-27T00:00:00Z')))
        self.assertEqual(10, len(self.sent))

    def test_recovery_after_renewal_cap_still_notifies(self):
        p = payload(alert())
        self.engine.process(p)
        for hours in [1, 2, 4, 8, 24, 24, 24]:
            self.now += hours * 3600
            self.engine.process(p)
        self.now += 24 * 3600
        self.engine.process(p)                      # 被上限吞掉, 不再打扰
        self.engine.process(payload(alert(status='resolved'), status='resolved'))
        self.assertEqual(9, len(self.sent))
        self.assertIn('[恢复]', self.sent[-1]['title'])

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


class AckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state_path = str(pathlib.Path(self.tmp.name) / 'state.json')
        self.ack_path = str(pathlib.Path(self.tmp.name) / 'acks.json')
        self.now = 100000.
        self.sent = []
        self.env = patch.dict(bridge.os.environ, {
            'NTFY_URL': 'https://ntfy.example', 'NTFY_TOPIC': 'core',
            'NTFY_TICKET_TOPIC': 'ticket', 'NTFY_TEST_TOPIC': 'test', 'NTFY_TOKEN': '',
            'ACK_TOKEN': 'test-ack-token', 'ACK_ENDPOINT': 'https://ack.example'})
        self.env.start(); self.addCleanup(self.env.stop)

    def make_engine(self):
        ack = bridge.AckStore(self.ack_path, clock=lambda: self.now)
        return bridge.NotificationEngine(self.state_path, sender=self.sent.append,
                                         clock=lambda: self.now, metrics=bridge.Metrics(),
                                         ack_store=ack)

    def group_key(self, kind='page', topic='core'):
        return bridge.digest(['bridge', '{}:{alertname="RestartStorm"}', kind, topic])

    def test_ack_suppresses_renewal_but_not_recovery(self):
        e = self.make_engine()
        e.process(payload(alert()))
        self.assertEqual(1, len(self.sent))
        e.ack_store.set('group', self.group_key(), 86400)
        self.now += 7200  # 跨过 page 首次退避(1h)但仍在 24h 静音窗内
        e.process(payload(alert()))
        self.assertEqual(1, len(self.sent))
        lines = e.metrics.render(e).splitlines()
        self.assertIn('alert_bridge_notifications_total{notification_class="page",'
                      'reason="acked",result="suppressed"} 1', lines)
        e.process(payload(alert(status='resolved'), status='resolved'))
        self.assertEqual(2, len(self.sent))
        self.assertIn('[恢复]', self.sent[-1]['title'])
        self.assertIsNone(e.ack_store.active(self.group_key(), set()))

    def test_ack_persists_across_engine_rebuild(self):
        e = self.make_engine()
        e.process(payload(alert()))
        e.ack_store.set('group', self.group_key(), 86400)
        e2 = self.make_engine()
        self.now += 7200  # still inside the 24h mute window on disk
        e2.process(payload(alert()))
        self.assertEqual(1, len(self.sent))  # still suppressed via persisted ack file

    def test_ack_expiry_resumes_reminder(self):
        e = self.make_engine()
        e.process(payload(alert()))
        e.ack_store.set('group', self.group_key(), 3600)
        self.now += 3600 + 1
        e.process(payload(alert()))
        self.assertEqual(2, len(self.sent))  # ack expired -> reminder resumes

    def test_new_episode_beats_ack(self):
        e = self.make_engine()
        e.process(payload(alert()))
        e.ack_store.set('group', self.group_key(), 86400)
        self.now += 3600
        e.process(payload(alert(start='2026-09-27T00:00:00Z')))
        self.assertEqual(2, len(self.sent))  # new startsAt -> changed -> bypass ack

    def test_alert_scope_ack_from_meta_silences_source(self):
        e = self.make_engine()
        meta = alert(); meta['labels']['alertname'] = 'AlertFiringTooLong'
        meta['labels']['source_alertname'] = 'CNPGBackupStale'
        meta['labels']['severity'] = 'warning'
        src = alert(); src['labels']['alertname'] = 'CNPGBackupStale'
        e.process(payload(src))          # 1: source first sight
        e.process(payload(meta))         # 2: meta first sight (new group always notifies)
        self.assertEqual(2, len(self.sent))
        e.ack_store.set('alert', 'CNPGBackupStale', 86400)
        self.now += 7200  # inside the 24h mute window; past first backoff
        e.process(payload(src))          # source renewal suppressed via alert-scope ack
        self.assertEqual(2, len(self.sent))
        e.process(payload(meta))         # meta renewal suppressed (match set includes source)
        self.assertEqual(2, len(self.sent))

    def test_format_includes_ack_actions_when_configured(self):
        msg = bridge.format_notification([alert()], 'page', 'core', 0,
                                         key=self.group_key(), ack_scope='group',
                                         ack_target=self.group_key())
        self.assertEqual(3, len(msg['actions']))
        self.assertTrue(all(a['action'] == 'http' and a.get('clear') for a in msg['actions']))
        self.assertTrue(all('sig=' in a['url'] for a in msg['actions']))

    def test_format_no_actions_when_unconfigured(self):
        with patch.dict(bridge.os.environ, {'ACK_TOKEN': '', 'ACK_ENDPOINT': ''}):
            msg = bridge.format_notification([alert()], 'page', 'core', 0,
                                             key='k', ack_scope='group', ack_target='k')
            self.assertEqual([], msg['actions'])

    def test_build_ack_url_unconfigured_empty(self):
        with patch.dict(bridge.os.environ, {'ACK_TOKEN': '', 'ACK_ENDPOINT': ''}):
            self.assertEqual('', bridge.build_ack_url('group', 'x', 86400))

    def test_corrupt_ack_file_fails_closed(self):
        pathlib.Path(self.ack_path).write_text('{"x": {"until": "soon"}}')
        with self.assertRaises(bridge.ConfigurationError):
            bridge.AckStore(self.ack_path)


class AckEndpointTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state_path = str(pathlib.Path(self.tmp.name) / 'state.json')
        self.ack_path = str(pathlib.Path(self.tmp.name) / 'acks.json')
        self.sent = []
        self.env = patch.dict(bridge.os.environ, {
            'NTFY_URL': 'https://ntfy.example', 'NTFY_TOPIC': 'core',
            'NTFY_TICKET_TOPIC': 'ticket', 'NTFY_TEST_TOPIC': 'test', 'NTFY_TOKEN': '',
            'ACK_TOKEN': 'test-ack-token', 'ACK_ENDPOINT': 'https://ack.example'})
        self.env.start(); self.addCleanup(self.env.stop)
        ack = bridge.AckStore(self.ack_path)
        self.engine = bridge.NotificationEngine(self.state_path, sender=self.sent.append, ack_store=ack)
        self.server = bridge.ThreadingHTTPServer(('127.0.0.1', 0), bridge.AlertmanagerHandler)
        self.server.engine = self.engine
        self.server.ack_store = self.engine.ack_store
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(lambda: (self.server.shutdown(), self.thread.join()))

    def get(self, url, method='GET', headers=None):
        if url.startswith('http'):  # build_ack_url returns a full URL; strip to path+query
            from urllib.parse import urlsplit as _us
            parts = _us(url)
            url = parts.path + (('?' + parts.query) if parts.query else '')
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        conn.request(method, url, headers=headers or {})
        r = conn.getresponse(); body = r.read().decode(); conn.close()
        return r.status, body

    def test_ack_endpoint_valid_sets_silence(self):
        url = bridge.build_ack_url('group', 'abc', 86400)
        self.assertTrue(url)
        status, body = self.get(url)
        self.assertEqual(200, status)
        self.assertIn('"ok": true', body)
        self.assertIsNotNone(self.engine.ack_store.active('abc', set()))

    def test_ack_endpoint_bad_signature_rejected(self):
        url = bridge.build_ack_url('group', 'abc', 86400)
        tampered = url.rsplit('sig=', 1)[0] + 'sig=' + '0' * 64
        status, _ = self.get(tampered)
        self.assertEqual(403, status)

    def test_ack_endpoint_bad_duration_rejected(self):
        import time as _t
        exp = int(_t.time()) + 3600
        msg = f"group|abc|999999|{exp}"
        sig = bridge.hmac.new(b'test-ack-token', msg.encode(), bridge.hashlib.sha256).hexdigest()
        status, _ = self.get(f'/ack?scope=group&target=abc&dur=999999&exp={exp}&sig={sig}')
        self.assertEqual(400, status)

    def test_acks_requires_bearer_and_lists(self):
        self.engine.ack_store.set('group', 'abc', 86400)
        status, _ = self.get('/acks')
        self.assertEqual(401, status)
        status, body = self.get('/acks', headers={'Authorization': 'Bearer test-ack-token'})
        self.assertEqual(200, status)
        self.assertIn('abc', body)

    def test_unack_clears(self):
        self.engine.ack_store.set('group', 'abc', 86400)
        status, _ = self.get('/unack?scope=group&target=abc', method='POST',
                             headers={'Authorization': 'Bearer test-ack-token'})
        self.assertEqual(200, status)
        self.assertIsNone(self.engine.ack_store.active('abc', set()))

    def test_ack_disabled_without_token(self):
        with patch.dict(bridge.os.environ, {'ACK_TOKEN': '', 'ACK_ENDPOINT': 'https://ack.example'}):
            conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
            conn.request('GET', '/ack?scope=group&target=abc&dur=86400&exp=9999999999&sig=x')
            r = conn.getresponse(); conn.close()
            self.assertEqual(503, r.status)


if __name__ == '__main__':
    unittest.main()
