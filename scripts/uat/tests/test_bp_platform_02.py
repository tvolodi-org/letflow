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

    def test_actors_are_anonymous_or_the_platform_admin_and_no_secret_or_retired_tenant(self):
        for step in self.steps.values():
            self.assertIn(step["actor"], ("anonymous", "admin"))
        text = json.dumps(self.process["steps"] + self.process["cleanup"])
        self.assertNotIn("qoimeks", text)
        # the password is an input of the run, never a literal in the file
        self.assertEqual(["signup_password"], self.process["inputs"])
        for step in self.process["steps"]:
            body = step["do"].get("body") or {}
            if "password" in body:
                self.assertEqual("${signup_password}", body["password"])
        self.assertTrue(self.process["later_steps"])

    def test_signup_sends_the_owner_fields_and_expects_the_tenant_url(self):
        body = self.steps["S6"]["do"]["body"]
        for key in ("company_name", "user_name", "password", "slug"):
            self.assertIn(key, body)
        self.assertEqual("${signup_password}", body["password"])
        self.assertTrue(body["slug"].startswith("uat-tmp-"))
        self.assertTrue(self.ok("S6", {"status": "check_your_mail", "tenant_url": "https://uat-tmp-1.x"}, 202))
        # no tenant URL (the build lacks the fields) or a refusal is RED
        self.assertFalse(self.ok("S6", {"status": "check_your_mail"}, 202))
        self.assertFalse(self.ok("S6", {"error": "signup_unavailable"}, 503))

    def test_new_tenant_must_be_active_without_a_human_step(self):
        self.assertTrue(self.ok("S7", {"status": "ACTIVE"}, 200))
        self.assertFalse(self.ok("S7", {"status": "PENDING"}, 200))
        self.assertFalse(self.ok("S7", {}, 404))
        self.assertEqual(["signup_made"], self.steps["S7"]["requires"])

    def test_refusals_slug_taken_and_reserved(self):
        self.assertEqual("slug_taken", self.steps["S8"]["expect_refused"])
        self.assertEqual("admin", self.steps["S9"]["do"]["body"]["slug"])
        self.assertEqual(422, self.steps["S9"]["expect_refused"]["status"])

    def test_cleanup_touches_only_the_throwaway_tenant_and_needs_the_mark(self):
        self.assertEqual(1, len(self.process["cleanup"]))
        c = self.process["cleanup"][0]
        self.assertEqual("/api/v1/tenants/uat-tmp-${run_id}/deactivate", c["do"]["path"])
        self.assertEqual(["signup_made"], c["requires"])
        self.assertEqual("admin", c["actor"])
        self.assertEqual("bpm-default", self.process["dry_run"]["actors"]["admin"]["tenant"])

    def test_residue_group_exists_for_the_platform_actor(self):
        r = runner.Runner.__new__(runner.Runner)
        r.processes, r.overrides, r.fixtures = [self.process], {}, []
        self.assertEqual(["admin"], r.needed_roles())

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
            want = set() if step["actor"] == "anonymous" else {"admin"}
            self.assertEqual(want, check_processes.actors_of(step))

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
        self.assertEqual(["admin"], r.needed_roles())


if __name__ == "__main__":
    unittest.main()
