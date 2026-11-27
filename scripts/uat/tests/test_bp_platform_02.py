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
LIFECYCLE_FILE = HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-02-tenant-lifecycle-process.json"


class Signup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def ok(self, step_id, body, status):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_actors_and_no_secret_literal_or_retired_tenant(self):
        for step in self.steps.values():
            self.assertIn(step["actor"], ("anonymous", "admin"))
        text = json.dumps(self.process["steps"] + self.process["cleanup"])
        self.assertNotIn("qoimeks", text)
        # the form takes no password (config password_required=false): no step sends one, no secret is an input
        for step in self.process["steps"]:
            self.assertNotIn("password", step["do"].get("body") or {})
        self.assertEqual(["verify_token"], self.process["inputs"])

    def test_every_runner_address_is_on_the_mail_trap_domain(self):
        for sid in ("S2", "S4", "S11"):
            self.assertTrue(self.steps[sid]["do"]["body"]["email"].endswith("@uat.letflow.internal"), sid)
        self.assertTrue(self.steps["S5"]["do"]["wait_mail"]["recipient"].endswith("@uat.letflow.internal"))
        self.assertEqual(self.steps["S4"]["do"]["body"]["email"], self.steps["S5"]["do"]["wait_mail"]["recipient"])

    def test_first_credential_chain_order_and_inputs(self):
        ids = [s["id"] for s in self.process["steps"]]
        self.assertEqual(["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11"], ids)
        s8 = self.steps["S8"]["do"]["first_signin"]
        self.assertEqual("${tenant_realm}", s8["realm"])  # the realm of the registry, never derived from the slug
        self.assertEqual("Your workspace account", s8["subject"])  # Signup.Messages.first_credential, en
        self.assertEqual("new_admin", s8["as"])
        for sid in ("S9", "S10"):
            self.assertEqual("new_admin", self.steps[sid]["bearer"])
        self.assertEqual("/api/v1/modules/stock/documents", self.steps["S10"]["do"]["path"])
        self.assertTrue(self.ok("S9", {"roles": ["TENANT_ADMIN"]}, 200))
        self.assertFalse(self.ok("S9", {"roles": ["TENANT_AUDITOR"]}, 200))
        self.assertFalse(self.ok("S10", {}, 404))
        self.assertTrue(self.ok("S10", {"items": []}, 200))

    def test_the_steps_the_runner_cannot_do_are_blocked_with_an_owner_and_the_rest_run(self):
        for sid in ("S6", "S7", "S8", "S9", "S10"):
            self.assertIn("owner: operator", self.steps[sid]["blocked_by"])
        for sid in ("S1", "S2", "S3", "S4", "S5", "S11"):
            self.assertNotIn("blocked_by", self.steps[sid])
        self.assertNotIn("blocked_by", self.process["dry_run"])  # the file itself is not blocked
        self.assertIsNone(runner.blocked_reason(self.process))

    def test_verify_and_registry_expectations(self):
        self.assertTrue(self.ok("S6", {"status": "verified"}, 200))
        self.assertFalse(self.ok("S6", {"error": "invalid_or_expired_link"}, 400))
        self.assertFalse(self.ok("S6", {"error": "slug_taken"}, 409))
        # the registry serialises the enum with Atom.to_string: lower case (lib/letflow/routers/tenants.ex tenant_map/1)
        self.assertTrue(self.ok("S7", {"status": "active"}, 200))
        self.assertFalse(self.ok("S7", {"status": "ACTIVE"}, 200))
        self.assertFalse(self.ok("S7", {}, 404))
        self.assertEqual({"tenant_realm": "$.idp_realm_id"}, self.steps["S7"]["save"])
        self.assertIn("poll", self.steps["S7"])

    def test_reserved_slug_is_refused(self):
        self.assertEqual("admin", self.steps["S11"]["do"]["body"]["slug"])
        self.assertEqual(422, self.steps["S11"]["expect_refused"]["status"])

    def test_cleanup_touches_only_the_throwaway_tenant_and_always_runs(self):
        paths = [c["do"]["path"] for c in self.process["cleanup"]]
        self.assertEqual(["/api/v1/tenants/uat-tmp-${run_id}/deactivate", "/api/v1/tenants/uat-tmp-${run_id}/purge"], paths)
        for c in self.process["cleanup"]:
            self.assertNotIn("requires", c)  # a sign-up that made the tenant and then failed is reconciled
            self.assertIn(404, c["expect"]["status"])  # nothing was made
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


class TenantLifecycle(unittest.TestCase):
    """T-3105: the lifecycle scenario names the three lifecycle functions of the compiled
    catalogue; an assertion by position went red when the catalogue grew."""

    @classmethod
    def setUpClass(cls):
        cls.process = json.loads(LIFECYCLE_FILE.read_text())
        cls.steps = {s["id"]: s for s in cls.process["steps"]}

    def ok(self, step_id, body, status=200):
        rows = runner.run_assertions(self.steps[step_id]["expect"], status, body)
        return all(r["ok"] for r in rows)

    def test_the_lifecycle_functions_are_named_and_not_counted(self):
        catalogue = {"items": [{"name": "tenant.purge"}, {"name": "tenant.reactivate"}, {"name": "tenant.suspend"},
                                {"name": "tenant.set_script_policy"}]}
        self.assertTrue(self.ok("A2", catalogue))
        self.assertTrue(self.ok("A2", {"items": list(reversed(catalogue["items"]))}))
        self.assertFalse(self.ok("A2", {"items": [{"name": "tenant.purge"}]}))


if __name__ == "__main__":
    unittest.main()
