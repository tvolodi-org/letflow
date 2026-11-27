"""T-2992: the run path takes a definition report at the start of the stock leg and on the first 409
definition_not_active. Fake API only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_definition_report_run.py   (from the repository root)
"""

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import definition_report  # noqa: E402
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
