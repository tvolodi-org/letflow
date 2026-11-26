"""Tests of the read-only stock definition report (T-2982). Fake API only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_definition_report.py   (from the repository root)
"""

import io
import sys
import unittest
from argparse import Namespace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import definition_report  # noqa: E402
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402


def row(ident, name, status, owner="stock", created="2026-11-26T10:00:00Z"):
    return {"id": ident, "name": name, "version": "1.0.0", "status": status, "owner_module": owner,
            "created_by": "system", "created_at": created, "updated_at": created, "activation_state": "ok"}


class ReportCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.state.users = {"admin": "qoimeks-qa2-admin"}

    def go(self, tenant="qoimeks-qa2", base=None):
        out = io.StringIO()
        args = Namespace(tenant=tenant, admin="qoimeks-qa2-admin", base_url=base or self.base,
                         base_url_template=None, run_dir=str(Path(self.tmp.name) / "rep"))
        return definition_report.main(args, runner, out), out.getvalue()

    def test_verdict_per_name_and_other_definitions_left_out(self):
        self.state.definitions = [
            row("a1", "stock_receipt", "ACTIVE"),
            row("b1", "stock_issue", "DEPRECATED"),
            row("b2", "stock_issue", "ARCHIVED", created="2026-11-26T11:00:00Z"),
            row("c1", "stock_transfer", "ACTIVE", owner=None),
            row("d1", "stock_return", "DRAFT"),
            row("z1", "uat-tmp-x", "ACTIVE", owner=None),
        ]
        code, text = self.go()
        self.assertEqual(code, 0, text)
        self.assertIn("stock_receipt: ok", text)
        self.assertIn("stock_issue: dead-newest", text)
        self.assertIn("stock_transfer: foreign", text)
        self.assertIn("stock_return: no-active", text)
        self.assertNotIn("uat-tmp-x", text)
        self.assertTrue((Path(self.tmp.name) / "rep" / "definition_report.json").is_file())

    def test_no_rows_and_forbidden_list(self):
        code, text = self.go()
        self.assertEqual(code, 0, text)
        self.assertIn("no stock definition row", text)
        self.state.definitions_forbidden = True
        code, text = self.go()
        self.assertEqual(code, 1)
        self.assertIn("answered 403", text)

    def test_refuses_a_host_that_is_not_qa(self):
        code, _ = self.go(base="https://example.com")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
