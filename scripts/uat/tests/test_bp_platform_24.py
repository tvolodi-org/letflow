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
import check_catalog  # noqa: E402

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
        deleted = {c["requires"][0] for c in self.process["cleanup"] if c["do"].get("api") == "DELETE"}
        for key in ("defA", "defB", "defC", "defD", "defE", "defF"):
            self.assertIn(key, deleted)
        sweeps = [c for c in self.process["cleanup"] if "sweep" in c["do"]]
        self.assertEqual([c["do"]["sweep"] for c in sweeps],
                         [{"prefix": "uat-tmp-defproof-", "exclude_contains": "${run_id}"}])  # T-2898
        for c in self.process["cleanup"]:
            self.assertTrue(c.get("requires") or c in sweeps)

    def test_a_and_b_share_one_name_and_differ_in_order(self):
        a, b = self.steps["A1"]["do"]["body"], self.steps["B1"]["do"]["body"]
        self.assertEqual(a["name"], b["name"])
        order = lambda body: [n["id"] for n in body["graph"]["nodes"] if n["node_type"] == "SERVICE_TASK"]
        self.assertEqual(["validate", "mail", "file"], order(a))
        self.assertEqual(["file", "validate", "mail"], order(b))

    def test_the_function_picker_is_read_by_name_and_not_by_position(self):
        """T-3105: the compiled catalogue grows; the step names the function it uses."""
        catalogue = {"items": [{"name": "platform.validate_registration"},
                                {"name": "tenant.create"},
                                {"name": "tenant.set_script_policy"}]}
        self.assertTrue(self.ok("A0", catalogue))
        self.assertTrue(self.ok("A0", {"items": list(reversed(catalogue["items"]))}))
        self.assertFalse(self.ok("A0", {"items": [{"name": "tenant.create"}]}))

    def test_the_log_must_follow_the_definition_order(self):
        self.assertTrue(self.ok("A6", log(["validate"])))
        self.assertFalse(self.ok("A6", log(["file"])))
        self.assertTrue(self.ok("B6", log(["file", "validate", "mail"])))
        self.assertFalse(self.ok("B6", log(["validate", "mail", "file"])))
        self.assertTrue(self.ok("B10", log(["validate", "hold", "mail", "file"])))
        self.assertFalse(self.ok("B10", log(["validate", "mail", "file"])))
        self.assertFalse(self.ok("B10", log(["file", "validate", "hold", "mail"])))

    def test_removed_step_leaves_no_mail_entry_and_added_step_runs_once(self):
        self.assertTrue(self.ok("C5", log(["validate", "file"])))
        self.assertFalse(self.ok("C5", log(["validate", "mail", "file"])))
        self.assertTrue(self.ok("D5", log(["validate", "validate_again", "mail", "file"])))
        self.assertFalse(self.ok("D5", log(["validate", "mail", "file"])))
        self.assertFalse(self.ok("D5", log(["validate", "validate_again", "validate_again", "mail", "file"])))

    def test_a_failed_step_fails_the_log_check(self):
        body = log(["validate", "hold", "mail", "file"])
        body["steps"][3]["result"] = "failed"
        self.assertFalse(self.ok("B10", body))

    def test_another_template_and_recipient(self):
        g = self.steps["E1"]["do"]["body"]["graph"]
        notify = [n for n in g["nodes"] if n["id"] == "mail"][0]["attributes"]["notify"]
        self.assertEqual("password_reset_hint", notify["template_key"])
        self.assertEqual({"var": "admin_email"}, notify["recipient"])
        wait = self.steps["E6"]["do"]["wait_mail"]
        self.assertEqual("Set a new password", wait["subject"])
        self.assertTrue(wait["recipient"].startswith("dpadm-"))

    def test_pinning_holds_a_running_instance_across_the_activation_of_b(self):
        ids = [s["id"] for s in self.process["steps"]]
        # A stops at a HUMAN_TASK; B is activated while A waits; only then A's task is completed.
        hold = [n for n in self.steps["A1"]["do"]["body"]["graph"]["nodes"] if n["id"] == "hold"][0]
        self.assertEqual("HUMAN_TASK", hold["node_type"])
        self.assertLess(ids.index("A5"), ids.index("B3"))
        self.assertLess(ids.index("B3"), ids.index("B8"))
        self.assertLess(ids.index("B8"), ids.index("B8b"))
        self.assertLess(ids.index("B8b"), ids.index("B8c"))
        self.assertEqual("ACTIVE", self.steps["B8"]["expect"]["json"]["$.status"])
        self.assertEqual("${defA}", self.steps["B8c"]["expect"]["json"]["$.definition_id"])
        self.assertEqual("COMPLETED", self.steps["B8c"]["expect"]["json"]["$.status"])
        self.assertNotEqual("COMPLETED", self.steps["A5"]["expect"]["json"].get("$.status"))

    def test_the_added_call_has_its_own_idempotency_key(self):
        # The catalogue key of platform.validate_registration is the slug alone: two calls on one slug collide.
        nodes = {n["id"]: n for n in self.steps["D1"]["do"]["body"]["graph"]["nodes"]}
        first = nodes["validate"]["attributes"]["platform_call"]
        again = nodes["validate_again"]["attributes"]["platform_call"]
        self.assertNotEqual(first["args"]["slug"], again["args"]["slug"])
        self.assertIn("slug2", again["reads"])
        start = self.steps["D3"]["do"]["body"]["initial_variables"]
        self.assertNotEqual(start["slug"], start["slug2"])

    def test_executed_by_n_a_is_a_third_kind_of_the_catalog(self):
        self.assertEqual(("n/a", "n/a", None), check_catalog.parse_executed_by({"executed_by": "n/a"}))
        counts = check_catalog.executed_by_counts([{"executed_by": "n/a"}, {}, {"executed_by": "definition:x"}])
        self.assertEqual({"direct": 1, "definition": 1, "n/a": 1}, counts)
        _v, kind, problem = check_catalog.parse_executed_by({"executed_by": "nothing"})
        self.assertIsNone(kind)
        self.assertIn("n/a", problem)
        bp = json.loads((HERE.parents[2] / "docs" / "bp" / "platform.json").read_text())
        row = [e for e in bp if e["id"] == "BP-PLATFORM-24"][0]
        self.assertEqual("n/a", row["executed_by"])

    def test_pinning_reads_the_definition_id_of_the_first_instance(self):
        self.assertTrue(self.ok("B8", {"definition_id": "x", "status": "ACTIVE"}) is False)
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
