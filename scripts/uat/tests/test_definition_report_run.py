"""T-2992: the run path takes a definition report at the start of the stock leg and on the first 409
definition_not_active. Fake API only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_definition_report_run.py   (from the repository root)
"""

import io
import json
import sys
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import definition_report  # noqa: E402
import runner  # noqa: E402
from fakes import SECRET, FakeServerCase  # noqa: E402


def row(ident, name, status, owner="stock"):
    return {"id": ident, "name": name, "version": "1.0.0", "status": status, "owner_module": owner,
            "created_by": "system", "created_at": "2026-11-26T10:00:00Z", "updated_at": "2026-11-26T10:00:00Z"}


class RunReportCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.state.definitions = [row("a1", "stock_issue", "DRAFT")]

    def summary(self):
        return (self.run_dir / "summary.md").read_text()

    def test_baseline_written_before_the_stock_leg(self):
        code, r = self.run_process()
        path = self.run_dir / "definition_report_before.json"
        self.assertTrue(path.is_file())
        data = json.loads(path.read_text())
        self.assertEqual(data["tenant"], "qoimeks-qa2")
        self.assertEqual(data["verdicts"], {"stock_issue": "no-active"})
        self.assertFalse((self.run_dir / "definition_report_after.json").exists())
        self.assertIn(str(path.resolve()), self.summary())

    @mock.patch.object(runner, "REPAIR_TENANTS", ())  # T-3125: a tenant outside the repair list fails as T-3014 says
    def test_dead_newest_fails_the_stock_leg_loudly_before_the_first_step(self):
        """T-3014: stock_receipt ARCHIVED with no ACTIVE row: the run fails at the health check, naming the report."""
        self.state.definitions = [row("a1", "stock_receipt", "ARCHIVED"), row("a2", "stock_issue", "ACTIVE")]
        code, r = self.run_process()
        self.assertEqual(code, 1)
        text = self.summary()
        path = (self.run_dir / "definition_report_before.json").resolve()
        self.assertIn("definition-health", text)
        self.assertIn("DEAD-NEWEST stock definition(s) on qoimeks-qa2: stock_receipt", text)
        self.assertIn(str(path), text)
        self.assertEqual(json.loads(path.read_text())["verdicts"]["stock_receipt"], "dead-newest")

    def test_healthy_tenant_passes_the_health_check(self):
        self.state.definitions = [row("a2", "stock_issue", "ACTIVE")]
        code, r = self.run_process()
        self.assertNotIn("definition-health", self.summary())

    def dead(self):
        self.state.definitions = [row("a1", "stock_receipt", "ARCHIVED"), row("a2", "stock_issue", "ACTIVE")]

    def test_dead_newest_repaired_by_ensure_seeds_as_the_tenant_admin(self):
        """T-3125: the run repairs the dead-newest definition, prints the loud line and goes on."""
        self.dead()
        code, r = self.run_process()
        self.assertEqual(len(self.state.ensure_seeds_calls), 1)
        self.assertEqual(self.state.ensure_seeds_calls[0][0], "admin")
        self.assertNotIn("definition-health", self.summary())
        self.assertIn("fixture repair: ensure-seeds applied: stock_receipt re-activated", self.summary())
        self.assertIn("fixture repair: ensure-seeds applied: stock_receipt re-activated", r.out.getvalue())
        after = json.loads((self.run_dir / "definition_report_repaired.json").read_text())
        self.assertEqual(after["verdicts"]["stock_receipt"], "ok")
        self.assertTrue((self.run_dir.parent / "fixture-state" / "definition-repairs-qoimeks-qa2.json").is_file())

    def test_healthy_tenant_makes_no_ensure_seeds_call(self):
        self.state.definitions = [row("a2", "stock_issue", "ACTIVE")]
        self.run_process()
        self.assertEqual(self.state.ensure_seeds_calls, [])
        self.assertNotIn("fixture repair", self.summary())

    def test_still_dead_after_the_repair_fails_loudly(self):
        self.dead()
        self.state.ensure_seeds_noop = True
        code, r = self.run_process()
        self.assertEqual(code, 1)
        self.assertIn("did not list stock_receipt", self.summary())
        self.assertIn("DEAD-NEWEST", self.summary())

    def test_ensure_seeds_refusal_fails_loudly(self):
        self.dead()
        self.state.ensure_seeds_status = 500
        code, r = self.run_process()
        self.assertEqual(code, 1)
        self.assertIn("ensure-seeds answered 500", self.summary())

    def test_dead_again_after_a_recorded_repair_is_a_product_defect(self):
        self.dead()
        state_dir = self.run_dir.parent / "fixture-state"
        state_dir.mkdir(parents=True)
        (state_dir / "definition-repairs-qoimeks-qa2.json").write_text("{}")
        code, r = self.run_process()
        self.assertEqual(code, 1)
        self.assertEqual(self.state.ensure_seeds_calls, [])
        text = self.summary()
        self.assertIn("PRODUCT DEFECT", text)
        self.assertIn(str((self.run_dir / "definition_report_before.json").resolve()), text)

    def test_tenant_outside_the_fixture_list_is_not_repaired(self):
        self.dead()
        rn = runner
        with mock.patch.object(rn, "REPAIR_TENANTS", ("other-qa",)):
            code, r = self.run_process()
        self.assertEqual(code, 1)
        self.assertEqual(self.state.ensure_seeds_calls, [])

    def test_never_tenants_are_not_repaired_even_when_listed(self):
        self.dead()
        rn = runner
        with mock.patch.object(rn, "REPAIR_TENANTS", ("qoimeks-qa2",)), \
                mock.patch.object(rn, "REPAIR_NEVER_TENANTS", ("qoimeks-qa2",)):
            code, r = self.run_process()
        self.assertEqual(code, 1)
        self.assertEqual(self.state.ensure_seeds_calls, [])

    def test_a_non_qa_host_is_refused_before_any_call(self):
        rn = runner
        r = rn.Runner(self.process(), base_url="https://qoimeks-qa2.example.com", tenant="qoimeks-qa2",
                      actors={"admin": "adm"}, run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=io.StringIO())
        ok, why = r._repair_dead_newest(["stock_receipt"], "-")
        self.assertFalse(ok)
        self.assertIn("refused", why)
        self.assertEqual(self.state.ensure_seeds_calls, [])

    def test_the_summary_says_the_module_journal_has_no_read_route(self):
        code, r = self.run_process()
        self.assertIn("not readable - the product has no read route for Boot.list_outcomes", self.summary())

    def test_409_definition_not_active_triggers_the_after_report(self):
        self.state.post_409 = "definition_not_active"
        code, r = self.run_process()
        self.assertEqual(code, 1)
        after = self.run_dir / "definition_report_after.json"
        self.assertTrue(after.is_file())
        text = self.summary()
        self.assertIn(str(after.resolve()), text)
        self.assertIn(str((self.run_dir / "definition_report_before.json").resolve()), text)
        self.assertIn("> definition reports:", text)

    def test_409_with_another_reason_does_not(self):
        self.state.post_409 = "something_else"
        self.run_process()
        self.assertTrue((self.run_dir / "definition_report_before.json").is_file())
        self.assertFalse((self.run_dir / "definition_report_after.json").exists())

    def test_files_hold_no_secret(self):
        self.state.post_409 = "definition_not_active"
        self.run_process()
        for name in ("definition_report_before.json", "definition_report_after.json"):
            self.assertNotIn(SECRET, (self.run_dir / name).read_text())

    def test_a_failing_report_is_a_note_and_not_a_verdict(self):
        ok_code, _ = self.run_process()
        self.state.definitions_forbidden = True
        self.run_dir = self.run_dir.parent / "run2"
        code, r = self.run_process()
        self.assertEqual(code, ok_code)
        self.assertFalse((self.run_dir / "definition_report_before.json").exists())
        self.assertIn("NOTE", self.summary())

    def test_timeout_is_a_note(self):
        old = definition_report.TIMEOUT_S
        definition_report.TIMEOUT_S = 0.05
        self.addCleanup(setattr, definition_report, "TIMEOUT_S", old)
        orig = definition_report.list_definitions
        import time
        definition_report.list_definitions = lambda run: time.sleep(0.5) or []
        self.addCleanup(setattr, definition_report, "list_definitions", orig)
        self.run_process()
        self.assertIn("timed out", self.summary())


if __name__ == "__main__":
    unittest.main()
