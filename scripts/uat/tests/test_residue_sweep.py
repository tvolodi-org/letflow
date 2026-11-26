"""Tests of the residue sweep (T-2869, D-208): reversal, already gone, refused tenant, refused host. Fake API only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_residue_sweep.py   (from the repository root)
"""

import io
import json
import sys
import unittest
from argparse import Namespace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import residue_sweep  # noqa: E402
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402

REPO = HERE.parent.parent.parent
SHIPPED = REPO / "test/uat/sweeps/residue-sweep-qoimeks-qa2.json"


class SweepCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.state.users = {"admin": "qoimeks-qa2-admin"}
        self.state.docs = {"d17": {"state": "posted", "qty": 1}, "d18": {"state": "reversed", "qty": 1}}
        self.state.tasks = [{"id": "t1", "instance_id": "i1", "node_id": "approve", "status": "PENDING", "doc": "d17"}]

    def write(self, **over):
        doc = {"tenant": "qoimeks-qa2", "admin": "qoimeks-qa2-admin",
               "documents": [{"id": "d17", "number": "R-d17"}, {"number": "R-d18"}, {"number": "R-zzz"}],
               "tasks": [{"id": "t1"}, {"id": "t-gone"}]}
        doc.update(over)
        path = Path(self.tmp.name) / "list.json"
        path.write_text(json.dumps(doc))
        return path

    def go(self, path, tenant="qoimeks-qa2", base=None):
        out = io.StringIO()
        args = Namespace(list_file=str(path), tenant=tenant, base_url=base or self.base, base_url_template=None,
                         run_dir=str(Path(self.tmp.name) / "sweep"))
        code = residue_sweep.main(args, runner, out)
        return code, out.getvalue()

    def test_reverses_completes_and_prints_the_baseline(self):
        code, text = self.go(self.write())
        self.assertEqual(code, 0, text)
        self.assertIn("document R-d17: done (reversed)", text)
        self.assertIn("document R-d18: already gone", text)
        self.assertIn("document R-zzz: already gone", text)
        self.assertIn("task t1: done (completed)", text)
        self.assertIn("task t-gone: already gone", text)
        self.assertEqual(self.state.docs["d17"]["state"], "reversed")  # the Reverse task it opened was completed too
        self.assertRegex(text, r"residue baseline of qoimeks-qa2: sha256 [0-9a-f]{64}")

    def test_second_run_is_all_already_gone(self):
        self.go(self.write())
        code, text = self.go(self.write())
        self.assertEqual(code, 0, text)
        self.assertNotIn("done", text.split("residue baseline")[0])

    def test_refused_reversal_is_reported_and_fails(self):
        path = self.write(documents=[{"id": "d17"}])
        orig = self.state.docs["d17"]
        orig["state"] = "posted"
        # a bad reason code is the fake's 422: patch the reason to prove a refusal is not "already gone"
        old = dict(residue_sweep.REASON)
        residue_sweep.REASON["reason_code"] = "bogus"
        self.addCleanup(lambda: residue_sweep.REASON.update(old))
        code, text = self.go(path)
        self.assertEqual(code, 1)
        self.assertIn("document d17: refused (422)", text)

    def test_refuses_a_tenant_not_in_the_list_file(self):
        code, text = self.go(self.write(), tenant="qoimeks-qa3")
        self.assertEqual(code, 2)
        self.assertEqual(self.state.log, [])

    def test_refuses_retired_tenants(self):
        for slug in ("qoimeks-qa", "qoimeks-client1-qa"):
            code, _ = self.go(self.write(tenant=slug, admin=slug + "-admin"), tenant=slug)
            self.assertEqual(code, 2, slug)
        self.assertEqual(self.state.log, [])

    def test_refuses_a_production_host(self):
        for host in ("https://qoimeks-qa2.letflow.bizdala.com", "https://qoimeks-qa2.example.com", "http://10.0.0.5:4000"):
            code, _ = self.go(self.write(), base=host)
            self.assertEqual(code, 2, host)
        self.assertEqual(self.state.log, [])

    def test_refuses_the_qa_host_of_another_tenant(self):
        code, _ = self.go(self.write(), base="https://qoimeks-qa.letflow.qa.bizdala.com")
        self.assertEqual(code, 2)

    def test_shipped_list_file_is_for_qa2_only(self):
        doc = residue_sweep.load_list(SHIPPED, runner)
        self.assertEqual(doc["tenant"], "qoimeks-qa2")
        self.assertEqual([d["number"] for d in doc["documents"]], ["TRF-2026-000017", "TRF-2026-000018"])
        self.assertEqual(len(doc["tasks"]), 1)
        guard_ok = residue_sweep.guard(doc, "qoimeks-qa2", "https://qoimeks-qa2.letflow.qa.bizdala.com", runner)
        self.assertIsNone(guard_ok)


if __name__ == "__main__":
    unittest.main()
