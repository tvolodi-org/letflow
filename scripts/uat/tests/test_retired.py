"""Tests of the retired-tenant guard (T-2538): the runner, check_processes.py and dry-run refuse a file, tenant or user
of a retired tenant with exit 2 before any request; blocked_by files are skipped with a visible reason.

Run: python3 -B -m unittest -v scripts/uat/tests/test_retired.py   (from the repository root)
"""

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import check_processes  # noqa: E402
import retired  # noqa: E402
import runner  # noqa: E402
from test_check_processes import CheckCase, GOOD  # noqa: E402
from fakes import INPUTS  # noqa: E402
from test_dryrun import DryRunCase  # noqa: E402

REPO = HERE.parent.parent.parent
RETIRED = retired.load_retired(REPO)


class Denylist(unittest.TestCase):
    def test_the_two_retired_tenants_are_listed(self):
        self.assertEqual(set(RETIRED), {"qoimeks-qa", "qoimeks-client1-qa"})

    def test_user_and_url_matching_does_not_catch_the_active_tenant(self):
        self.assertEqual(retired.retired_tenant_of_user("qoimeks-qa-admin", RETIRED), "qoimeks-qa")
        self.assertIsNone(retired.retired_tenant_of_user("qoimeks-qa2-admin", RETIRED))
        self.assertEqual(retired.retired_tenant_of_url("https://qoimeks-qa.letflow.qa.bizdala.com", RETIRED), "qoimeks-qa")
        self.assertIsNone(retired.retired_tenant_of_url("https://qoimeks-qa2.letflow.qa.bizdala.com", RETIRED))

    def test_no_shipped_process_chain_or_fixture_names_a_retired_tenant(self):
        files = sorted((REPO / "test/uat").glob("*/*.json"))
        self.assertTrue(files)
        for f in files:
            self.assertEqual(retired.violations_in_file(f, RETIRED), [], f.name)

    def test_the_four_sec_assets_files_are_blocked_and_on_an_active_tenant(self):
        files = sorted((REPO / "test/uat/processes").glob("SEC-ASSETS-0[1-4]-*.json"))
        self.assertEqual(len(files), 4)
        for f in files:
            doc = json.loads(f.read_text())
            self.assertEqual(doc["dry_run"]["blocked_by"], "assets-module-on-active-tenant", f.name)


class Static(CheckCase):
    def doc(self, **block):
        d = dict(GOOD, bp_entry="X")
        d["dry_run"] = {"tenant": "demo", "actors": {"admin": "demo-admin", "storekeeper": "demo-sk"}, "inputs": {"item": "1"}, **block}
        return d

    def test_active_tenant_passes(self):
        self.assertEqual(self.check(self.doc(), strict=True), [])

    def test_retired_tenant_and_its_users_are_reported(self):
        problems = self.check(self.doc(tenant="qoimeks-qa", actors={"admin": "qoimeks-qa-admin", "storekeeper": "x"}), strict=True)
        text = "\n".join(problems)
        self.assertIn("BP-T.json", text)
        self.assertIn("qoimeks-qa", text)
        self.assertIn("qoimeks-qa-admin", text)

    def test_cli_exits_2(self):
        path = self.write(self.doc(tenant="qoimeks-client1-qa"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_processes.main(["--root", str(self.root), str(path)])
        self.assertEqual(code, 2, out.getvalue())

    def test_a_fixture_naming_a_retired_tenant_is_reported(self):
        (self.root / "test/uat/fixtures").mkdir(parents=True, exist_ok=True)
        fx = {"id": "fx", "tenant": "qoimeks-qa", "steps": []}
        problems = check_processes.check_files([self.write(fx, rel="test/uat/fixtures/fx.json")], root=self.root)
        self.assertTrue(any("retired" in p for p in problems), problems)


class DryRun(DryRunCase):
    def test_a_file_naming_a_retired_tenant_exits_2_before_any_request(self):
        path = self.write("BP-01-receive-goods.json", self.bp01(tenant="qoimeks-qa"))
        code, out, _ = self.main(files=[path])
        self.assertEqual(code, 2, out)
        self.assertIn("BP-01-receive-goods.json", out)
        self.assertIn("qoimeks-qa", out)
        self.assertEqual(self.state.log, [])

    def test_a_retired_actor_user_alone_is_refused(self):
        doc = self.bp01()
        first = next(iter(doc["dry_run"]["actors"]))
        doc["dry_run"]["actors"][first] = "qoimeks-qa-admin"
        path = self.write("BP-01-receive-goods.json", doc)
        code, out, _ = self.main(files=[path])
        self.assertEqual(code, 2, out)
        self.assertEqual(self.state.log, [])

    def test_a_chain_naming_a_retired_tenant_is_refused(self):
        chain = {"id": "C", "processes": ["BP-01-receive-goods"], "tenant": "qoimeks-qa", "bp_entry": "C",
                 "dry_run": {"tenant": "qoimeks-qa", "actors": {}, "inputs": {}}}
        self.write("BP-01-receive-goods.json", self.bp01())
        path = self.write("c.json", chain, folder="chains")
        code, out, _ = self.main(files=[path])
        self.assertEqual(code, 2, out)
        self.assertEqual(self.state.log, [])

    def test_one_retired_file_refuses_the_whole_batch(self):
        good = self.write("BP-01-receive-goods.json", self.bp01())
        bad = self.write("BP-02-bad.json", self.dry_doc(self.bp01(), tenant="qoimeks-qa"))
        code, out, _ = self.main(files=[good, bad])
        self.assertEqual(code, 2, out)
        self.assertEqual(self.state.log, [])

    def test_the_batch_lists_each_distinct_tenant_before_running(self):
        self.write("BP-01-receive-goods.json", self.bp01())
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertEqual(out.count("batch tenant qoimeks-qa2:"), 1, out)

    def test_a_blocked_file_is_skipped_with_its_reason_and_never_run(self):
        self.write("BP-01-receive-goods.json", self.bp01(blocked_by="assets-module-on-active-tenant"))
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertIn("SKIPPED BP-01-receive-goods.json: blocked_by assets-module-on-active-tenant", out)
        self.assertEqual(self.state.log, [])


class RunAndCleanup(DryRunCase):
    def run_cli(self, argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = runner.main(argv)
        return code, err.getvalue()

    def test_run_with_a_retired_tenant_or_user_exits_2(self):
        path = self.write("BP-01-receive-goods.json", self.bp01())
        base = ["run", str(path), "--base-url", self.base, "--no-stable-check", "--run-dir", str(Path(self.tmp.name) / "r1"), "--input"] + [f"{k}={v}" for k, v in INPUTS.items()]
        code, err = self.run_cli(base + ["--tenant", "qoimeks-qa", "--actors", "admin=a,storekeeper=b"])
        self.assertEqual(code, 2, err)
        self.assertIn("retired", err)
        code, err = self.run_cli(base + ["--tenant", "ok", "--actors", "admin=qoimeks-client1-qa-admin,storekeeper=b"])
        self.assertEqual(code, 2, err)
        self.assertEqual(self.state.log, [])

    def test_run_of_a_blocked_process_exits_2(self):
        path = self.write("BP-01-receive-goods.json", self.bp01(blocked_by="why"))
        code, err = self.run_cli(["run", str(path), "--tenant", "ok", "--base-url", self.base, "--no-stable-check",
                                  "--actors", "admin=a,storekeeper=b", "--run-dir", str(Path(self.tmp.name) / "r2"), "--input"] + [f"{k}={v}" for k, v in INPUTS.items()])
        self.assertEqual(code, 2, err)
        self.assertIn("blocked_by", err)
        self.assertEqual(self.state.log, [])


if __name__ == "__main__":
    unittest.main()
