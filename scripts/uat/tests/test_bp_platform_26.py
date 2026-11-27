"""Tests of the BP-PLATFORM-26 scenario file (T-2986): the four tenant-creating routes, the played ones expect 202 and
the platform.register_tenant definition, the unplayable ones carry blocked_by with an owner, the cleanup retires every
throwaway tenant. No network, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_26.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

ROOT = HERE.parents[2]
FILE = ROOT / "test" / "uat" / "processes" / "BP-PLATFORM-26-no-bypass.json"


class Scenario(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def test_every_step_passes_the_runner_validation(self):
        for step in self.process["steps"] + self.process["cleanup"]:
            runner.validate_step(step, step["id"])

    def test_each_route_is_started_once_and_answers_202(self):
        paths = {s["do"]["path"] for s in self.process["steps"] if s["id"] in ("R1a", "R2a", "R4a")}
        self.assertEqual(
            paths,
            {"/api/v1/onboarding", "/api/v1/tenants", "/api/signup"},
        )
        self.assertIn("/admin/v1/tenants", self.steps["R3a"]["says"])
        self.assertIn("/api/signup", self.steps["R4a"]["do"]["path"])
        for rid in ("R1a", "R2a"):
            self.assertEqual(self.steps[rid]["expect"]["status"], 202)
            self.assertTrue(self.steps[rid]["do"]["body"]["slug"].startswith("uat-tmp-"))

    def test_played_routes_check_definition_history_and_timeline(self):
        for n in (1, 2):
            self.assertEqual(self.steps[f"R{n}b"]["expect"]["json"]["$.definition_id"], "${definition_id}")
            self.assertEqual(
                self.steps[f"R{n}c"]["expect"]["json"]["$.items[0].event_type"], "INSTANCE_STARTED"
            )
            self.assertEqual(self.steps[f"R{n}d"]["expect"]["json"]["$.steps[1].node_id"], "validate")
            self.assertNotIn("blocked_by", self.steps[f"R{n}a"])
        self.assertEqual(self.steps["A1"]["expect"]["json"]["$.name"], "platform.register_tenant")

    def test_unplayable_routes_are_blocked_with_an_owner(self):
        for rid in ("R3a", "R4a"):
            self.assertIn("owner", self.steps[rid]["blocked_by"])

    def test_cleanup_deactivates_every_throwaway_tenant(self):
        slugs = {s["do"]["path"] for s in self.process["cleanup"]}
        self.assertEqual(
            slugs,
            {"/api/v1/tenants/${slug1}/deactivate", "/api/v1/tenants/${slug2}/deactivate"},
        )


if __name__ == "__main__":
    unittest.main()
