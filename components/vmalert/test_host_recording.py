"""Host metric contract guards; numeric semantics are tested by vmalert-tool fixtures."""
import importlib.util
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).parent


def builder():
    spec = importlib.util.spec_from_file_location("host_recording", ROOT / "build-host-recording.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HostRecordingContractTest(unittest.TestCase):
    def test_expected_hosts_are_independent_of_received_metrics(self):
        module = builder()
        hosts = module.load_hosts()
        self.assertEqual({"k1", "k2", "k3", "node0", "node1", "node2", "node3", "node4"}, {h["host"] for h in hosts})
        rules = {r["record"]: r for r in module.document(hosts)["groups"][0]["rules"]}
        self.assertNotIn("system_", rules["host:expected_info"]["expr"])
        for h in hosts:
            self.assertIn('"' + h["host"] + '"', rules["host:expected_info"]["expr"])
        for name in ("host:cpu_busy_ratio", "host:cpu_iowait_ratio", "host:memory_used_ratio", "host:filesystem_used_ratio", "host:network_io_bytes_per_second"):
            self.assertIn(name, rules)
            self.assertNotIn("vector(0)", rules[name]["expr"])
            self.assertNotIn("host:", rules[name]["expr"], "recording rules must not chain asynchronous writes")
        self.assertIn("tlast_over_time", rules["host:last_seen_timestamp_seconds"]["expr"])
        self.assertNotIn("timestamp(host:", rules["host:last_seen_timestamp_seconds"]["expr"])

    def test_inventory_rejects_duplicate_or_unsafe_identity(self):
        module = builder()
        hosts = module.load_hosts()
        for bad in ([*hosts, hosts[0]], [{**hosts[0], "host": 'k1" or 1'}], [{**hosts[0], "host_kind": "unknown"}]):
            with self.assertRaises(ValueError):
                module.validate_hosts(bad)

    def test_deployment_entry_uses_only_versioned_inventory(self):
        deployment = ROOT.parents[1] / "hosts/observability"
        makefile = (deployment / "Makefile").read_text()
        defaults = (deployment / "roles/host_otel/defaults/main.yml").read_text()
        image = re.search(r"^OTELCOL_IMAGE := (.+)$", makefile, re.M).group(1)
        self.assertIn("otelcol_image: " + image, defaults)
        self.assertIn("inventory.generated.json", makefile)
        self.assertNotIn("/observability/build/venv", makefile)
        self.assertIn("host_key_checking = True", (deployment / "ansible.cfg").read_text())

    def test_generated_cloud_inventory_has_no_kubernetes_targets(self):
        module = builder()
        data = module.cloud_inventory(module.load_hosts())
        targets = data["all"]["children"]["host_otel"]["hosts"]
        self.assertEqual({"node0", "node1", "node2", "node3", "node4"}, set(targets))
        self.assertTrue(targets["node0"]["host_watchdog"])
        self.assertFalse(targets["node3"]["host_watchdog"])


if __name__ == "__main__":
    unittest.main()
