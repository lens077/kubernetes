"""Offline contracts for the ops portal: link hygiene and host-resource query semantics."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).parent
DASHBOARDS = ROOT / "dashboards"
# Pangolin 资源里只提供 API / 数据入口或已屏蔽的域名，放进跳转台只会打开 JSON、401 或 404。
NOT_FOR_HUMANS = ("argocd-api.", "config-api.", "scorpius-api.", "silo-api.", "es-dev.", "minio.",
                  "otlp-dev.", "gateway.", "lyrapass-tunnel-internal.")


class PortalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = json.loads((DASHBOARDS / "ops-portal.json").read_text())
        cls.panels = {p["id"]: p for p in cls.doc["panels"]}
        cls.html = cls.panels[1]["options"]["content"]
        cls.anchors = re.findall(r'<a href="([^"]+)"([^>]*)>', cls.html)

    def test_links_are_pages_not_api_endpoints(self):
        hrefs = [href for href, _ in self.anchors]
        self.assertGreater(len(hrefs), 10)
        for href in hrefs:
            self.assertFalse(any(host in href for host in NOT_FOR_HUMANS), href)
            self.assertNotIn(".dev.test", href)
        self.assertEqual(len(hrefs), len(set(hrefs)))

    def test_external_links_open_new_tab_and_internal_ones_stay(self):
        for href, attrs in self.anchors:
            with self.subTest(href=href):
                if href.startswith("/"):
                    self.assertNotIn("_blank", attrs)
                else:
                    self.assertTrue(href.startswith("https://"))
                    self.assertIn('target="_blank"', attrs)

    def test_every_generated_dashboard_is_reachable_from_portal_and_back(self):
        internal = {href for href, _ in self.anchors if href.startswith("/d/")}
        for file in DASHBOARDS.glob("*.json"):
            uid = file.stem
            if uid in ("ops-portal", "alert-instance-detail"):
                continue  # 实例详情需要从问题表带实例参数进入
            self.assertIn("/d/" + uid, internal)
        for file in DASHBOARDS.glob("*.json"):
            if file.stem == "ops-portal":
                continue
            urls = [link["url"] for link in json.loads(file.read_text())["links"]]
            self.assertIn("/d/ops-portal", urls, file.name)

    def test_resource_panels_use_shared_records_and_keep_missing_hosts(self):
        for panel_id, metric in ((2, "host:cpu_busy_ratio"), (3, "host:memory_used_ratio"),
                                 (4, "host:filesystem_used_ratio"), (5, "host:cpu_busy_ratio"),
                                 (6, "host:memory_used_ratio"), (8, "host:cpu_iowait_ratio")):
            with self.subTest(panel_id=panel_id):
                panel = self.panels[panel_id]
                expr = panel["targets"][0]["expr"]
                self.assertIn(metric, expr)
                self.assertIn("host:signal_present", expr)
                self.assertIn("host:rules_evaluation_timestamp_seconds", expr)
                self.assertNotRegex(expr, r"\bsystem_[a-z_]+")
                self.assertNotIn("vector(0)", expr)
                defaults = panel["fieldConfig"]["defaults"]
                self.assertEqual("percentunit", defaults["unit"])
                self.assertEqual("指标缺失", defaults["noValue"])
                if panel["type"] == "bargauge":
                    self.assertIn("host:expected_info", expr)
                    self.assertIn("* -1", expr, "display sentinel must not look like a healthy zero")
                    self.assertEqual("指标缺失", defaults["mappings"][0]["options"]["-1"]["text"])
        self.assertIn("host:signal_present", self.panels[9]["targets"][0]["expr"])
        self.assertIn("host:last_seen_timestamp_seconds", self.panels[10]["targets"][0]["expr"])


if __name__ == "__main__":
    unittest.main()
