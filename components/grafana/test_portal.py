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

    def test_resource_panels_use_hostmetrics_and_show_missing_data(self):
        for panel_id, metric in ((2, "system_cpu_utilization_ratio"), (3, "system_memory_utilization_ratio"),
                                 (4, "system_filesystem_usage_bytes"), (5, "system_cpu_utilization_ratio"),
                                 (6, "system_memory_utilization_ratio")):
            with self.subTest(panel_id=panel_id):
                panel = self.panels[panel_id]
                expr = panel["targets"][0]["expr"]
                self.assertIn(metric, expr)
                # K8s 节点与云主机合并为同一 host 维度，缺任何一边都会让一类主机从面板消失
                self.assertIn('"k8s_node_name", "host_name"', expr)
                self.assertIn("by (host)", expr)
                self.assertNotIn("vector(0)", expr)
                defaults = panel["fieldConfig"]["defaults"]
                self.assertEqual("percentunit", defaults["unit"])
                self.assertEqual("指标缺失", defaults["noValue"])
        # iowait 必须算作空闲：k3 上 Dragonfly 的 io_uring 等待会把 iowait 常驻抬到 24%
        self.assertIn('state=~"idle|wait"', self.panels[2]["targets"][0]["expr"])
        self.assertIn('state=~"used|free"', self.panels[4]["targets"][0]["expr"])


if __name__ == "__main__":
    unittest.main()
