"""Tests of the BP-PLATFORM-01 scenario file, step A (T-2744): the expectations of the file judge a good answer as
good and a defective one (definition missing, not active, a service step without its function, a notify step
without recipient, a registry without the entry) as failed. No network, no model: the answers are canned.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_01.py   (from the repository root)
"""

import copy
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-01-register-tenant.json"
CALLS = [
    ("validate", "tenant.validate"),
    ("create", "tenant.create"),
    ("provision", "tenant.provision"),
    ("record_lifecycle", "tenant.record_lifecycle"),
    ("record_onboarding", "tenant.record_onboarding"),
    ("bind_realm", "tenant.bind_realm"),
    ("grant_first_admins", "tenant.grant_first_admins"),
    ("install_default_modules", "tenant.install_default_modules"),
]
FUNCTIONS = [
    "platform.validate_registration",
    "tenant.bind_realm",
    "tenant.create",
    "tenant.grant_first_admins",
    "tenant.install_default_modules",
    "tenant.provision",
    "tenant.record_lifecycle",
    "tenant.record_onboarding",
    "tenant.validate",
]


def definition():
    nodes = [{"id": "start", "node_type": "START"}]
    for node_id, fn in CALLS:
        nodes.append({"id": node_id, "node_type": "SERVICE_TASK", "attributes": {"platform_call": {"function": fn}}})
    nodes.append({"id": "notify_gate", "node_type": "EXCLUSIVE_GATEWAY"})
    nodes.append({"id": "notify", "node_type": "SERVICE_TASK", "attributes": {
        "notify": {"template_key": "tenant_registered", "recipient": {"var": "admin_email"}}}})
    nodes.append({"id": "end", "node_type": "END"})
    return {"id": "d1", "name": "platform.register_tenant", "version": "2", "status": "ACTIVE", "graph": {"nodes": nodes}}


def registry():
    return {"items": [{"name": n, "inputs": [{"name": "x"}], "outputs": [{"name": "y"}]} for n in FUNCTIONS]}


def templates():
    keys = ["asset_expiry_reminder", "exam_assigned", "exam_reminder", "exam_result", "password_reset_hint",
            "problem_report_status", "task_assigned", "tenant_registered"]
    return {"items": [{"template_key": k, "placeholders": ["tenant_name", "tenant_slug", "registered_by"]} for k in keys]}


class StepA(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def verdict(self, step_id, body, status=200):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_step_a_is_read_only_and_throwaway_free(self):
        self.assertEqual(["A1", "A2", "A3a", "A3b"], list(self.steps))
        for step in self.steps.values():
            self.assertEqual("GET", step["do"]["api"])
        self.assertEqual([], self.process["cleanup"])
        self.assertNotIn("qoimeks", FILE.read_text())
        self.assertEqual("bpm-default", self.process["dry_run"]["actors"]["admin"]["tenant"])
        self.assertTrue(self.process["later_steps"])
        self.assertIn("web/tests/e2e/pilot-register-tenant-qa.e2e.spec.ts", self.process["description"])
        self.assertNotIn("pilot-register-tenant-designer.e2e.spec.ts", self.process["description"])

    def test_a1_active_definition(self):
        self.assertTrue(self.verdict("A1", definition()))

    def test_a1_missing_or_not_active_fails(self):
        self.assertFalse(self.verdict("A1", {"error": "not_found"}, status=404))
        draft = definition()
        draft["status"] = "DRAFT"
        self.assertFalse(self.verdict("A1", draft))
        draft = definition()
        draft["version"] = "0"
        self.assertFalse(self.verdict("A1", draft))

    def test_a2_complete_graph(self):
        self.assertTrue(self.verdict("A2", definition()))

    def test_a2_service_step_without_function_fails(self):
        d = definition()
        d["graph"]["nodes"][3]["attributes"] = {}
        self.assertFalse(self.verdict("A2", d))

    def test_a2_notify_without_recipient_or_template_fails(self):
        d = definition()
        del d["graph"]["nodes"][10]["attributes"]["notify"]["recipient"]
        self.assertFalse(self.verdict("A2", d))
        d = copy.deepcopy(definition())
        d["graph"]["nodes"][10]["attributes"]["notify"]["template_key"] = None
        self.assertFalse(self.verdict("A2", d))

    def test_a2_node_count_is_twelve(self):
        d = definition()
        d["graph"]["nodes"].append({"id": "extra", "node_type": "END"})
        self.assertFalse(self.verdict("A2", d))
        d = definition()
        del d["graph"]["nodes"][1]
        self.assertFalse(self.verdict("A2", d))

    def test_a3_registry_and_template_options(self):
        self.assertTrue(self.verdict("A3a", registry()))
        self.assertTrue(self.verdict("A3b", templates()))
        self.assertFalse(self.verdict("A3a", {"items": []}))
        self.assertFalse(self.verdict("A3b", {"items": []}))
        t = templates()
        t["items"][7]["placeholders"] = []
        self.assertFalse(self.verdict("A3b", t))


if __name__ == "__main__":
    unittest.main()
