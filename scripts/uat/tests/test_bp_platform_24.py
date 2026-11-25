"""Tests of the BP-PLATFORM-24 scenario file (T-2808): the expectations judge a step log that follows the order of the
definition as good and a log in a fixed or foreign order as failed; the scenario uses no provisioner function, creates no
tenant and removes what it made. No network, no model: the answers are canned.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_24.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-24-definition-drives-execution.json"


def log(order):
    """A canned step log: start, the steps in `order`, end."""
    steps = [{"node_id": "start", "result": "completed"}]
    for node in order:
        steps.append({"node_id": node, "result": "completed",
                      "step": "platform.validate_registration" if node.startswith("validate") else None})
    steps.append({"node_id": "end", "result": "completed"})
    return {"steps": steps}


class Scenario(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = FILE.read_text()
        cls.process = json.loads(cls.text)
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def ok(self, step_id, body, status=200):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_every_step_passes_the_runner_validation(self):
        for step in self.process["steps"] + self.process["cleanup"]:
            runner.validate_step(step, step["id"])

    def test_no_provisioner_function_no_tenant_route(self):
        for fn in ("tenant.create", "tenant.provision", "tenant.bind_realm", "tenant.grant_first_admins",
                   "platform.register_tenant", "/api/v1/onboarding", "/api/v1/tenants"):
            self.assertNotIn(fn, self.text.replace("tenant.not_in_the_catalogue", ""))
        self.assertNotIn("blocked_by", self.text)

    def test_throwaway_names_and_cleanup_of_every_definition(self):
        self.assertIn("uat-tmp-defproof-${run_id}-1", self.text)
        deleted = {c["requires"][0] for c in self.process["cleanup"] if c["do"]["api"] == "DELETE"}
        for key in ("defA", "defB", "defC", "defD", "defE", "defF"):
            self.assertIn(key, deleted)
        for c in self.process["cleanup"]:
            self.assertTrue(c.get("requires"))

    def test_a_and_b_share_one_name_and_differ_in_order(self):
        a, b = self.steps["A1"]["do"]["body"], self.steps["B1"]["do"]["body"]
        self.assertEqual(a["name"], b["name"])
        order = lambda body: [n["id"] for n in body["graph"]["nodes"] if n["node_type"] == "SERVICE_TASK"]
        self.assertEqual(["validate", "mail", "file"], order(a))
        self.assertEqual(["file", "validate", "mail"], order(b))

    def test_the_log_must_follow_the_definition_order(self):
        self.assertTrue(self.ok("A6", log(["validate", "mail", "file"])))
        self.assertFalse(self.ok("A6", log(["file", "validate", "mail"])))
        self.assertTrue(self.ok("B6", log(["file", "validate", "mail"])))
        self.assertFalse(self.ok("B6", log(["validate", "mail", "file"])))
        self.assertTrue(self.ok("B10", log(["validate", "mail", "file"])))

    def test_removed_step_leaves_no_mail_entry_and_added_step_runs_once(self):
        self.assertTrue(self.ok("C5", log(["validate", "file"])))
        self.assertFalse(self.ok("C5", log(["validate", "mail", "file"])))
        self.assertTrue(self.ok("D5", log(["validate", "validate_again", "mail", "file"])))
        self.assertFalse(self.ok("D5", log(["validate", "mail", "file"])))
        self.assertFalse(self.ok("D5", log(["validate", "validate_again", "validate_again", "mail", "file"])))

    def test_a_failed_step_fails_the_log_check(self):
        body = log(["validate", "mail", "file"])
        body["steps"][2]["result"] = "failed"
        self.assertFalse(self.ok("A6", body))

    def test_another_template_and_recipient(self):
        g = self.steps["E1"]["do"]["body"]["graph"]
        notify = [n for n in g["nodes"] if n["id"] == "mail"][0]["attributes"]["notify"]
        self.assertEqual("password_reset_hint", notify["template_key"])
        self.assertEqual({"var": "admin_email"}, notify["recipient"])
        wait = self.steps["E6"]["do"]["wait_mail"]
        self.assertEqual("Set a new password", wait["subject"])
        self.assertTrue(wait["recipient"].startswith("dpadm-"))

    def test_pinning_reads_the_definition_id_of_the_first_instance(self):
        self.assertTrue(self.ok("B8", {"definition_id": "x"}) is False)
        self.assertEqual("${defA}", self.steps["B8"]["expect"]["json"]["$.definition_id"])
        self.assertEqual("${defB}", self.steps["B9"]["expect"]["json"]["$.definition_id"])

    def test_negatives_name_status_and_code(self):
        self.assertEqual({"status": 422, "code": "platform_call_function_unknown"}, self.steps["N2"]["expect_refused"])
        self.assertEqual({"status": 422, "code": "dangling_edge"}, self.steps["N4"]["expect_refused"])
        g = self.steps["N4"]["do"]["body"]["graph"]
        ids = {n["id"] for n in g["nodes"]}
        self.assertTrue(any(e["target"] not in ids for e in g["edges"]))
        fn = [n for n in self.steps["N1"]["do"]["body"]["graph"]["nodes"] if n["id"] == "validate"][0]
        self.assertEqual("tenant.not_in_the_catalogue", fn["attributes"]["platform_call"]["function"])


if __name__ == "__main__":
    unittest.main()
