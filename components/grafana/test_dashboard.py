"""Offline guards for the dashboard's operational metric semantics."""
import json
import pathlib
import unittest


DASHBOARD = pathlib.Path(__file__).parent / "dashboards/ntfy-alerting-overview.json"


class DashboardQueryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = json.loads(DASHBOARD.read_text())
        cls.panels = {panel["id"]: panel for panel in cls.dashboard["panels"]}

    def test_current_gatus_panels_use_last_probe_not_lifetime_counters(self):
        for panel_id in (5, 10):
            with self.subTest(panel_id=panel_id):
                expr = self.panels[panel_id]["targets"][0]["expr"]
                self.assertIn("gatus_results_endpoint_success", expr)
                self.assertNotIn("gatus_results_total", expr)

    def test_watchdog_requires_alertmanager_probe_not_only_remote_write(self):
        expr = self.panels[3]["targets"][0]["expr"]
        self.assertIn('alertname="Watchdog"', expr)
        self.assertIn("gatus_results_endpoint_success", expr)
        self.assertIn('key="observability-pipeline_alert-pipeline-watchdog"', expr)

    def test_missing_bridge_or_rule_telemetry_is_not_an_unconditional_zero(self):
        for panel_id in (1, 2, 4, 6):
            with self.subTest(panel_id=panel_id):
                expr = self.panels[panel_id]["targets"][0]["expr"]
                self.assertNotIn("or vector(0)", expr)
        for panel_id in (4, 6):
            expr = self.panels[panel_id]["targets"][0]["expr"]
            self.assertIn("alert_bridge_state_entries", expr)
            self.assertIn("and on()", expr)


if __name__ == "__main__":
    unittest.main()
