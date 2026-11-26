"""The scenario BP-QOIMEKS-REHEARSAL-03 (T-2857) is well formed: every step passes the runner's own validation, the
live steps are the registration and the cleanup, and every step that needs a tenant login is blocked_by with its reason.

Run: python3 -B -m unittest -v scripts/uat/tests/test_rehearsal3_scenario.py   (from the repository root)
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "uat"))
import runner  # noqa: E402

DOC = json.loads((ROOT / "test/uat/processes/BP-QOIMEKS-REHEARSAL-03.json").read_text())


class Rehearsal3(unittest.TestCase):
    def test_r1_every_step_validates(self):
        for step in DOC["steps"] + DOC["cleanup"]:
            runner.validate_step(step, DOC["id"])

    def test_r2_live_steps_are_registration_and_cleanup(self):
        live = [s["id"] for s in DOC["steps"] if "blocked_by" not in s]
        self.assertEqual(live, ["r1", "r2", "r3"])
        self.assertEqual([s["id"] for s in DOC["cleanup"]], ["c1"])

    def test_r3_blocked_steps_name_the_realm_and_send_no_realm(self):
        for s in DOC["steps"]:
            if "blocked_by" in s:
                self.assertIn("decision 0072", s["blocked_by"])
        body = DOC["steps"][0]["do"]["body"]
        self.assertNotIn("idp_realm_id", body)

    def test_r4_runbook_tools_are_in_the_scenario(self):
        tools = [s["do"]["client1_tool"]["tool"] for s in DOC["steps"] if "client1_tool" in s["do"]]
        self.assertEqual(tools, ["headers", "balances_compare", "masters_compare"])


if __name__ == "__main__":
    unittest.main()
