"""Tests of the BP-PLATFORM-02 scenario file (T-2749) and of the anonymous actor it needs: the expectations judge a
good answer as good and a defective one as failed; the anonymous actor needs no token and no roster entry.
No network, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_bp_platform_02.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import check_processes  # noqa: E402
import runner  # noqa: E402

FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-02-self-service-signup.json"


class Signup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def ok(self, step_id, body, status):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_every_step_is_anonymous_and_no_secret_or_retired_tenant(self):
        for step in self.steps.values():
            self.assertEqual("anonymous", step["actor"])
        text = json.dumps(self.process["steps"] + self.process["cleanup"])
        self.assertNotIn("qoimeks", text)
        self.assertNotIn("password", text)
        self.assertTrue(self.process["later_steps"])

    def test_config_on_and_off(self):
        self.assertTrue(self.ok("S1", {"enabled": True, "languages": ["en", "ru", "kk"]}, 200))
        self.assertFalse(self.ok("S1", {"error": "not_found"}, 404))
        self.assertFalse(self.ok("S1", {"enabled": False, "languages": ["en"]}, 200))

    def test_accepted_is_202_only(self):
        self.assertTrue(self.ok("S4", {"status": "check_your_mail"}, 202))
        self.assertFalse(self.ok("S4", {"error": "rate_limited"}, 429))
        self.assertFalse(self.ok("S4", {"error": "signup_unavailable"}, 503))

    def test_static_check_passes_and_anonymous_needs_no_roster(self):
        for step in self.steps.values():
            self.assertEqual(set(), check_processes.actors_of(step))

    def test_anonymous_sends_no_authorization_and_mints_no_token(self):
        seen = {}

        def fake(method, url, headers, body):
            seen.update(url=url, headers=headers)
            return 200, {}, "{}"

        original = runner.http_call
        runner.http_call = fake
        try:
            r = runner.Runner.__new__(runner.Runner)
            r.base_url = "http://x"
            r.secrets = {}
            r.old_base_url = None
            r.request("anonymous", "GET", "/api/signup/config")
        finally:
            runner.http_call = original
        self.assertEqual("http://x/api/signup/config", seen["url"])
        self.assertNotIn("Authorization", seen["headers"])

    def test_needed_roles_skip_anonymous(self):
        r = runner.Runner.__new__(runner.Runner)
        r.processes, r.overrides, r.fixtures = [self.process], {}, []
        self.assertEqual([], r.needed_roles())


if __name__ == "__main__":
    unittest.main()
