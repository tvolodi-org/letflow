"""Tests of the tenant retention step (T-3203): a fake tenant registry and a fake platform.tenant_lifecycle process.
Young tenant kept, old matching tenant purged through the process, every excluded tenant kept, dry run purges nothing,
a batch cap, a lock, a not-eligible purge is a loud FAILED line. No network, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_tenant_retention.py   (from the repository root)
"""

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402
import tenant_retention as tr  # noqa: E402

NOW = datetime(2026, 11, 28, 12, 0, tzinfo=timezone.utc)
BASE = "http://127.0.0.1:1"


def ago(days):
    return (NOW - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakePlatform:
    """The registry and the lifecycle process. `not_eligible` slugs end their purge in ERROR (retention rule)."""

    def __init__(self, tenants, not_eligible=()):
        self.tenants = {t["slug"]: dict(t) for t in tenants}
        self.not_eligible = set(not_eligible)
        self.instances = {}
        self.started = []  # (slug, action)

    def __call__(self, method, path, body=None):
        if method == "GET" and path.startswith("/api/v1/tenants"):
            return 200, {"items": list(self.tenants.values()), "next_cursor": None}, ""
        if method == "POST" and path == "/api/v1/instances":
            v = body["initial_variables"]
            self.started.append((v["slug"], v["action"]))
            assert body["definition_name"] == "platform.tenant_lifecycle" and v["confirm"] == v["slug"]
            iid = f"i{len(self.started)}"
            tenant, state = self.tenants[v["slug"]], "COMPLETED"
            if v["action"] == "suspend":
                tenant["status"] = "inactive"
            elif v["slug"] in self.not_eligible or tenant["status"] != "inactive":
                state = "ERROR"
            else:
                del self.tenants[v["slug"]]
            self.instances[iid] = state
            return 201, {"instance_id": iid}, ""
        if method == "GET" and path.startswith("/api/v1/instances/"):
            return 200, {"status": self.instances[path.rsplit("/", 1)[1]]}, ""
        raise AssertionError((method, path))


def row(slug, age, status="active", **extra):
    return dict({"slug": slug, "status": status, "tenant_type": "test", "inserted_at": ago(age)}, **extra)


class Retention(unittest.TestCase):
    def setUp(self):
        self.locks = tempfile.mkdtemp()
        self.out = []

    def go(self, fake, spec=None, retired=None, own="bpm-default", extra=()):
        return tr.execute(fake, spec if spec is not None else {}, own, BASE, retired or {"qoimeks-qa": ""}, now=NOW,
                          lock_root=self.locks, extra=list(extra), sleep=lambda s: None, out=self.out.append)

    def test_young_tenant_is_kept(self):
        fake = FakePlatform([row("uat-tmp-young", 0.5)])
        result = self.go(fake)
        self.assertEqual((result["purged"], fake.started), (0, []))
        self.assertIn("uat-tmp-young", fake.tenants)

    def test_old_matching_tenant_is_purged_through_the_process(self):
        fake = FakePlatform([row("uat-tmp-old", 5), row("uat-20261101-ab12", 20, status="inactive")])
        result = self.go(fake)
        self.assertEqual(result["purged"], 2)
        self.assertEqual(fake.tenants, {})
        # the active one is suspended first, the inactive one is purged directly
        self.assertEqual(fake.started, [("uat-20261101-ab12", "purge"), ("uat-tmp-old", "suspend"), ("uat-tmp-old", "purge")])
        self.assertIn("2 purged", self.out[-1])

    def test_every_exclusion_is_kept(self):
        kept = [row("uat-tmp-fixture", 90), row("uat-tmp-admin", 90), row("owner-demo", 90), row("owner-uat-tmp-x", 90),
                row("qoimeks-qa2", 90), row("sss-rehearsal2", 90), row("bpm-default", 90), row("qoimeks-qa", 90),
                row("qoimeks-client1-qa", 90), row("acme", 90), row("uat-tmp-real", 90, tenant_type="production"),
                row("uat-tmp-nodate", 90, inserted_at="garbage")]
        for t in kept:
            with self.subTest(slug=t["slug"]):
                fake = FakePlatform([t])
                self.go(fake, retired={"qoimeks-qa": "", "qoimeks-client1-qa": ""})
                self.assertEqual(fake.started, [])
                self.assertIn(t["slug"], fake.tenants)

    def test_acting_tenant_is_kept(self):
        fake = FakePlatform([row("uat-tmp-me", 90)])
        self.go(fake, own="uat-tmp-me")
        self.assertEqual(fake.started, [])

    def test_dry_run_lists_and_purges_nothing(self):
        fake = FakePlatform([row("uat-tmp-old", 5)])
        result = self.go(fake, {"dry_run": True})
        self.assertEqual((result["purged"], result["candidates"], fake.started), (0, 1, []))
        self.assertTrue(any(line.startswith("uat-tmp-old: candidate") for line in self.out))

    def test_batch_is_bounded_oldest_first(self):
        fake = FakePlatform([row(f"uat-tmp-t{i}", 10 + i, status="inactive") for i in range(5)])
        result = self.go(fake, {"max_per_run": 2})
        self.assertEqual(result["purged"], 2)
        self.assertEqual([s for s, _ in fake.started], ["uat-tmp-t4", "uat-tmp-t3"])
        self.assertEqual(len(fake.tenants), 3)

    def test_a_held_lock_skips_the_tenant(self):
        fake = FakePlatform([row("uat-tmp-a", 9, status="inactive"), row("uat-tmp-b", 8, status="inactive")])
        lock = tr.Lock("uat-tmp-a", self.locks)
        self.assertTrue(lock.acquire())
        self.go(fake)
        self.assertEqual(fake.started, [("uat-tmp-b", "purge")])
        self.assertIn("uat-tmp-a", fake.tenants)
        lock.release()
        self.assertTrue(tr.Lock("uat-tmp-a", self.locks).acquire())  # released locks are free; unrelated locks are freed after a run

    def test_not_eligible_purge_is_kept(self):
        fake = FakePlatform([row("uat-tmp-wait", 9, status="inactive")], not_eligible=["uat-tmp-wait"])
        result = self.go(fake)
        self.assertEqual((result["purged"], result["failed"]), (0, 1))
        self.assertIn("uat-tmp-wait", fake.tenants)

    def test_deactivated_non_runner_tenant_is_excluded_by_name_even_at_retention_0(self):
        fake = FakePlatform([row("acme-test", 90, status="inactive"), row("req384-x", 90, status="inactive")])
        self.go(fake)
        self.assertEqual(fake.started, [])
        self.assertEqual(set(fake.tenants), {"acme-test", "req384-x"})

    def test_active_old_runner_tenant_is_deactivated_then_purged_in_order(self):
        fake = FakePlatform([row("uat-tmp-act", 3)])
        result = self.go(fake)
        self.assertEqual(fake.started, [("uat-tmp-act", "suspend"), ("uat-tmp-act", "purge")])
        self.assertEqual((result["purged"], result["failed"], fake.tenants), (1, 0, {}))

    def test_active_runner_tenant_younger_than_a_day_is_untouched(self):
        fake = FakePlatform([row("uat-tmp-new", 0.9)])
        self.go(fake)
        self.assertEqual(fake.started, [])
        self.assertEqual(fake.tenants["uat-tmp-new"]["status"], "active")

    def test_purge_is_never_started_when_deactivate_fails(self):
        fake = FakePlatform([row("uat-tmp-stuck", 3)])
        real_post = fake.__call__

        def failing(method, path, body=None):
            r = real_post(method, path, body)
            if method == "POST" and body["initial_variables"]["action"] == "suspend":
                fake.instances[r[1]["instance_id"]] = "ERROR"
            return r
        result = self.go(failing)
        self.assertEqual(fake.started, [("uat-tmp-stuck", "suspend")])
        self.assertEqual(result["left"], 1)

    def test_not_eligible_is_a_loud_named_failure_and_not_retried(self):
        fake = FakePlatform([row("uat-tmp-a", 9, status="inactive"), row("uat-tmp-b", 8, status="inactive")],
                            not_eligible=["uat-tmp-a", "uat-tmp-b"])
        result = self.go(fake)
        self.assertEqual((result["failed"], result["purged"]), (1, 0))
        self.assertEqual(fake.started, [("uat-tmp-a", "purge")])
        failed = [l for l in self.out if l.startswith("FAILED")]
        self.assertEqual(len(failed), 1)
        self.assertIn("uat-tmp-a", failed[0])
        self.assertIn("LETFLOW_PROVISIONER_RETENTION_DAYS", failed[0])

    def test_extra_allow_entry_is_taken_but_only_when_listed(self):
        fake = FakePlatform([row("leftover-one", 9, status="inactive"), row("leftover-two", 9, status="inactive")])
        self.go(fake, extra=["leftover-one"])
        self.assertEqual(fake.started, [("leftover-one", "purge")])

    def test_shipped_extra_list_is_empty(self):
        self.assertEqual(tr.load_extra(), [])

    def test_host_guard_and_spec_are_refused_before_any_request(self):
        fake = FakePlatform([row("uat-tmp-old", 9)])
        with self.assertRaises(ValueError):
            tr.execute(fake, {}, "bpm-default", "https://letflow.example.com", {}, now=NOW, extra=[])
        with self.assertRaises(ValueError):
            tr.execute(fake, {"days": 0}, "bpm-default", BASE, {}, now=NOW, extra=[])
        with self.assertRaises(ValueError):
            tr.execute(fake, {"max_per_run": 99}, "bpm-default", BASE, {}, now=NOW, extra=[])
        self.assertEqual(fake.started, [])

    def test_shipped_scenario_step_is_valid(self):
        doc = json.loads((HERE.parents[2] / "test" / "uat" / "processes" / "BP-PLATFORM-25-designer.json").read_text())
        step = next(s for s in doc["cleanup"] if s["id"] == "c11")
        self.assertIsNone(tr.spec_problem(step["do"]["tenant_retention"]))
        self.assertIn("tenant_retention", runner.DO_KINDS)
        self.assertEqual(step["do"]["tenant_retention"]["days"], 1)
        self.assertEqual(step["do"]["tenant_retention"]["max_per_run"], 20)
        self.assertEqual((tr.DEFAULT_DAYS, tr.DEFAULT_MAX_PER_RUN), (1, 20))

    def test_a_batch_of_20_is_allowed_and_26_is_not(self):
        self.assertIsNone(tr.spec_problem({"max_per_run": 25}))
        self.assertIsNotNone(tr.spec_problem({"max_per_run": 26}))


if __name__ == "__main__":
    unittest.main()
