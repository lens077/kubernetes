"""Read-only alert presentation and drilldown contracts; jq matches the backend parser."""
import copy
import json
import pathlib
import re
import subprocess
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(__file__).parent


def rows(alerts, status="success"):
    result = subprocess.run(["jq", "-c", "-f", str(ROOT / "alert_rows.jq")],
                            input=json.dumps({"status": status, "data": {"alerts": alerts}}),
                            text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr)
    return json.loads(result.stdout)


def alert():
    return {"name": "CNPGNoBackupEver", "state": "firing", "value": "0",
            "activeAt": "2026-09-25T17:51:45Z", "id": "172003230902524322", "group_id": "3992272352278794129",
            "expression": "cnpg_collector_last_available_backup_timestamp <= 0",
            "labels": {"alertname": "CNPGNoBackupEver", "alertgroup": "cnpg", "cnpg_cluster": "pg-main",
                       "k8s_namespace_name": "postgresql", "k8s_pod_name": "pg-main-1", "severity": "warning"},
            "annotations": {"summary": "pg-main 没有可用备份", "description": "检查 Backup 对象状态"}}


class TriageTest(unittest.TestCase):
    def test_workbench_shows_real_annotations_before_traffic_charts(self):
        document = json.loads((ROOT / 'dashboards/ntfy-alerting-overview.json').read_text())
        panels = {p['id']: p for p in document['panels']}
        details = panels[9]
        self.assertEqual('ds-alert-evidence', details['datasource']['uid'])
        query = details['targets'][0]
        self.assertEqual('jq-backend', query['parser'])
        self.assertIn('annotations.summary', query['root_selector'])
        self.assertIn('annotations.description', query['root_selector'])
        self.assertLess(details['gridPos']['y'], panels[7]['gridPos']['y'])
        self.assertIn('detail_url', json.dumps(details))
        self.assertIn('evidence_url', json.dumps(details))

    def test_preencoded_links_and_multiline_copy_survive_grafana_interpolation(self):
        document = json.loads((ROOT / 'dashboards/ntfy-alerting-overview.json').read_text())
        panel = next(p for p in document['panels'] if p['id'] == 9)
        self.assertTrue(panel['fieldConfig']['defaults']['custom'].get('wrapText'))
        self.assertEqual('auto', panel['options']['cellHeight'])
        urls = [prop['value'][0]['url'] for item in panel['fieldConfig']['overrides']
                for prop in item['properties'] if prop['id'] == 'links']
        self.assertTrue(urls)
        self.assertTrue(all(':raw}' in url for url in urls))

    def test_jq_locals_cannot_collide_with_dashboard_template_variables(self):
        locals_used = set(re.findall(r'\$([A-Za-z_][A-Za-z0-9_]*)', (ROOT / 'alert_rows.jq').read_text()))
        for file in (ROOT / 'dashboards').glob('*.json'):
            variables = {v['name'] for v in json.loads(file.read_text())['templating']['list']}
            self.assertFalse(locals_used & variables, (file.name, locals_used & variables))

    def test_workload_differences_keep_identity_and_backup_dates_are_not_counts(self):
        kube = json.loads((ROOT / 'dashboards/infra-kubernetes.json').read_text())
        panels = {p['id']: p for p in kube['panels']}
        for panel_id in (5, 6):
            self.assertIn('group_left', panels[panel_id]['targets'][0]['expr'])
        cnpg = json.loads((ROOT / 'dashboards/infra-cnpg.json').read_text())
        panels = {p['id']: p for p in cnpg['panels']}
        for panel_id in (3, 6):
            self.assertEqual('fixed', panels[panel_id]['fieldConfig']['defaults']['color']['mode'])
        self.assertIn('== 0', panels[4]['targets'][0]['expr'])
        mappings = panels[4]['fieldConfig']['defaults']['mappings']
        self.assertTrue(any('0' in m.get('options', {}) for m in mappings))
        for panel_id in (1, 2, 3, 4, 5, 6):
            self.assertTrue(any(m.get('type') == 'special' for m in panels[panel_id]['fieldConfig']['defaults']['mappings']))

    def test_real_annotations_value_and_instance_identity_are_preserved(self):
        source = alert()
        item = rows([source])[0]
        self.assertEqual(source["annotations"]["summary"], item["summary"])
        self.assertEqual(source["annotations"]["description"], item["description"])
        self.assertEqual("0", item["value"])
        self.assertEqual("3992272352278794129:172003230902524322", item["key"])
        self.assertGreaterEqual(item["condition_seconds"], 0)
        self.assertEqual("pg-main", parse_qs(urlsplit(item["evidence_url"]).query)["var-cnpg_cluster"][0])
        self.assertEqual(item["key"], parse_qs(urlsplit(item["detail_url"]).query)["var-instance"][0])

    def test_reminder_drills_into_original_rule_not_its_own_category(self):
        item = alert()
        item["name"] = "AlertFiringTooLong"
        item["labels"].update(alertgroup="ecommerce-k8s", exported_alertgroup="cnpg", exported_alertname="CNPGNoBackupEver")
        result = rows([item])[0]
        self.assertEqual("reminder", result["kind"])
        self.assertEqual("CNPGNoBackupEver", result["original_rule"])
        self.assertEqual("/d/infra-cnpg", urlsplit(result["evidence_url"]).path)

    def test_empty_singleton_and_watchdog_do_not_fabricate_problems(self):
        self.assertEqual([], rows([]))
        watchdog = copy.deepcopy(alert())
        watchdog["name"] = "Watchdog"
        self.assertEqual([], rows([watchdog]))
        self.assertEqual(1, len(rows([watchdog, alert()])))
        with self.assertRaises(ValueError):
            rows([], status="error")

    def test_label_values_cannot_inject_url_parameters_or_log_filters(self):
        item = alert()
        item["labels"]["k8s_namespace_name"] = 'team&var-node=other'
        item["labels"]["k8s_pod_name"] = 'pod" OR *'
        result = rows([item])[0]
        params = parse_qs(urlsplit(result["evidence_url"]).query)
        self.assertEqual(['team&var-node=other'], params['var-namespace'])
        self.assertEqual(['.*'], params['var-node'])
        log_panes = json.loads(parse_qs(urlsplit(result["logs_url"]).query)['panes'][0])
        expr = log_panes['logs']['queries'][0]['expr']
        self.assertIn(json.dumps(item['labels']['k8s_pod_name']), expr)
        self.assertNotIn('.dev.test', result['detail_url'])


if __name__ == "__main__":
    unittest.main()
