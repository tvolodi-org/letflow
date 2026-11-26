"""Tests of the BP-DESIGNER-34 scenario file (T-2844): a SUB_PROCESS proof on throwaway definitions. No network, no
model: the answers are canned. The scenario uses no platform function (a child with a platform call is refused by the
engine), creates no tenant and removes what it made.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_designer_34.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-DESIGNER-34-sub-process-proof.json"


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

    def test_no_platform_call_no_tenant_route_no_blocker(self):
        for token in ("platform_call", "/api/v1/onboarding", "/api/v1/tenants", "blocked_by"):
            self.assertNotIn(token, self.text)

    def test_every_definition_name_is_throwaway_and_removed(self):
        for step in self.process["steps"]:
            body = step["do"].get("body") or {}
            if step["do"]["path"] == "/api/v1/definitions":
                self.assertTrue(body["name"].startswith("uat-tmp-subproof-${run_id}-"), step["id"])
        deleted = {c["requires"][0] for c in self.process["cleanup"] if c["do"].get("api") == "DELETE"}
        for key in ("defP", "defC", "defP2", "defC2", "defP4", "defC1b", "defP5"):
            self.assertIn(key, deleted)
        sweeps = [c["do"]["sweep"] for c in self.process["cleanup"] if "sweep" in c["do"]]
        self.assertEqual(sweeps, [{"prefix": "uat-tmp-subproof-", "exclude_contains": "${run_id}"}])

    def test_input_filter_judges_the_extra_variable(self):
        good = {"variables": {"order_no": "SP-${uuid1}"}}
        leaked = {"variables": {"order_no": "SP-${uuid1}", "secret_note": "x"}}
        text = lambda b: json.loads(json.dumps(b).replace("${uuid1}", "u1"))
        step = json.loads(json.dumps(self.steps["A8"]["expect"]).replace("${uuid1}", "u1"))
        self.assertTrue(all(r["ok"] for r in runner.run_assertions(step, 200, text(good))))
        self.assertFalse(all(r["ok"] for r in runner.run_assertions(step, 200, text(leaked))))

    def test_failure_is_an_error_not_a_success(self):
        self.assertTrue(self.ok("F9", {"status": "ERROR"}))
        self.assertFalse(self.ok("F9", {"status": "COMPLETED"}))

    def test_missing_child_and_unknown_child_are_refused_at_start(self):
        for sid in ("G2", "N3"):
            self.assertEqual(self.steps[sid]["expect_refused"], {"status": 404})

    def test_upgrade_step_reads_the_version_b_child(self):
        self.assertIn("work_b", json.dumps(self.steps["U9"]))
        self.assertIn("defC1b", json.dumps(self.steps["U8"]))


if __name__ == "__main__":
    unittest.main()
