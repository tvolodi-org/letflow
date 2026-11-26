"""Tests of `runner.py dry-run --changed` (D-169): the process files that differ from origin/main run on a fake
QA with their own dry_run block. A temp git repository with an origin/main ref, a fake server, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_dryrun.py   (from the repository root)
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import INPUTS, PROCESS_FILE, RUNNER_FILE, USERS, FakeServerCase  # noqa: E402
from test_chain import call, proc  # noqa: E402


def git(repo, *args):
    done = subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                          capture_output=True, text=True, timeout=60)
    assert done.returncode == 0, done.stderr
    return done.stdout


class DryRunCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / "test/uat/processes").mkdir(parents=True)
        (self.repo / "test/uat/chains").mkdir(parents=True)
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "README").write_text("x")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")

    def dry_doc(self, doc, **block):
        doc = dict(doc, bp_entry=doc["id"])
        doc["dry_run"] = {"tenant": "qoimeks-qa2", "actors": dict(USERS), "inputs": dict(INPUTS), **block}
        return doc

    def write(self, name, doc, folder="processes"):
        path = self.repo / "test/uat" / folder / name
        path.write_text(json.dumps(doc))
        return path

    def bp01(self, **block):
        return self.dry_doc(json.loads(PROCESS_FILE.read_text()), **block)

    def main(self, *extra, files=None):
        argv = ["dry-run", "--repo", str(self.repo), "--base-url", self.base, "--poll-interval", "0.01",
                "--run-dir-root", str(Path(self.tmp.name) / "dry"), "--no-stable-check"]
        argv += (["--files", *map(str, files)] if files else ["--changed"])
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(argv + list(extra))
        return code, out.getvalue(), err.getvalue()


class Changed(DryRunCase):
    def test_nothing_changed_is_a_pass_that_says_so(self):
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn("nothing to run", out)
        self.assertEqual(self.state.log, [])

    def test_a_new_process_file_runs_on_qa_and_cleans_up_after_itself(self):
        self.write("BP-01-receive-goods.json", self.bp01())
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertIn("dry-run: PASS (1 file(s)", out)
        self.assertEqual(self.state.qty, Decimal("7"))  # reversed again
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)
        self.assertTrue((Path(self.tmp.name) / "dry" / "BP-01-receive-goods" / "run.jsonl").is_file())

    def test_only_the_files_that_differ_from_origin_main_run(self):
        self.write("BP-01-receive-goods.json", self.bp01())
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "bp01 on main")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        quiet = proc("BP-02", [call("s1", "POST", "/api/v1/echo", {"who": "bp02"})])
        self.write("BP-02-quiet.json", self.dry_doc(quiet, inputs={}))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "bp02 on a branch")
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertIn("BP-02-quiet.json", out)
        self.assertNotIn("BP-01-receive-goods.json", out)
        self.assertEqual(self.state.calls("POST", "/documents"), [])  # BP-01 did not run
        self.assertEqual(len(self.state.calls("POST", "/echo")), 1)

    def test_an_edited_but_uncommitted_file_counts_as_changed(self):
        self.write("BP-01-receive-goods.json", self.bp01())
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "x")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        changed = self.bp01()
        changed["title"] = "edited"
        self.write("BP-01-receive-goods.json", changed)
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn("BP-01-receive-goods.json", out)

    def test_the_default_run_root_is_outside_the_repo_and_the_tail_names_it(self):
        doc = proc("BP-DIR", [call("s1", "POST", "/api/v1/echo", {"who": "directory"})])
        path = self.write("BP-DIR-directory.json", self.dry_doc(doc, inputs={}))
        task_dir = Path(self.tmp.name) / "task"
        argv = ["dry-run", "--repo", str(self.repo), "--base-url", self.base, "--poll-interval", "0.01",
                "--no-stable-check", "--files", str(path)]
        out = io.StringIO()
        env = {"TEAM_ROOT": self.team_root, "TEAM_TASKDIR": str(task_dir)}
        with contextlib.chdir(self.repo), mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(out):
            code = runner.main(argv)
        self.assertEqual(code, 0, out.getvalue())
        roots = list((task_dir / "uat-runs").glob("dry-run-*"))
        self.assertEqual(len(roots), 1)
        self.assertFalse(roots[0].resolve().is_relative_to(self.repo.resolve()))
        self.assertTrue((roots[0] / path.stem / "run.jsonl").is_file())
        self.assertIn(f"runs in {roots[0]}", out.getvalue().splitlines()[-1])

    def test_a_failing_process_fails_the_dry_run_but_the_others_still_run_and_clean_up(self):
        self.state.post_adds_nothing = True  # BP-01 s4 fails
        self.write("BP-01-receive-goods.json", self.bp01())
        ok = proc("BP-02", [call("s1", "POST", "/api/v1/echo", {"who": "bp02"})])
        self.write("BP-02-quiet.json", self.dry_doc(ok, inputs={}))
        code, out, _ = self.main()
        self.assertEqual(code, 1)
        self.assertIn("dry-run: FAIL", out)
        self.assertEqual(len(self.state.calls("POST", "/echo")), 1)  # BP-02 ran after BP-01 failed
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)  # BP-01 cleaned up what it posted

    def test_a_changed_chain_runs_with_its_own_dry_run_block(self):
        self.write("BP-A-a.json", self.dry_doc(proc("BP-A", [call("s1", "POST", "/api/v1/echo", {"a": 1})],
                                                  outputs={"made": "yes"}), inputs={}))
        self.write("BP-B-b.json", self.dry_doc(proc("BP-B", [call("s1", "POST", "/api/v1/echo", {"made": "${made}"})],
                                                  inputs=["made"]), inputs={"made": "seed"}))  # alone it needs its own value
        chain = {"id": "chain-d", "processes": ["BP-A", "BP-B"], "pass": {"BP-A": ["made"]},
                 "dry_run": {"tenant": "qoimeks-qa2", "actors": dict(USERS), "inputs": {}}}
        self.write("c.json", chain, folder="chains")
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertIn("c.json", out)
        bodies = [c[3] for c in self.state.calls("POST", "/echo")]
        self.assertIn({"made": "yes"}, bodies)  # the output of A reached B inside the chain run

    def test_a_changed_chain_may_clean_up_after_every_process(self):
        """The dry run of a chain with "cleanup": "per_process" is a rehearsal of the real run: the
        second process meets the tenant without the value the first one created."""
        self.write("BP-A-a.json", self.dry_doc(proc("BP-A", [call("s1", "POST", "/api/v1/fx/make",
                                                                  {"name": "singleton"}, {"status": 201},
                                                                  save={"created": "yes"})],
                                                  cleanup=[{"id": "c1", "actor": "admin", "requires": ["created"],
                                                            "do": {"api": "POST", "path": "/api/v1/fx/drop",
                                                                   "body": {"name": "singleton"}},
                                                            "expect": {"status": 200}}]), inputs={}))
        self.write("BP-B-b.json", self.dry_doc(proc("BP-B", [call("s1", "POST", "/api/v1/fx/find",
                                                                   {"name": "singleton"},
                                                                   {"status": 200, "json": {"$.items": []}})]),
                                                  inputs={}))
        chain = {"id": "chain-d", "processes": ["BP-A", "BP-B"], "cleanup": "per_process",
                 "dry_run": {"tenant": "qoimeks-qa2", "actors": dict(USERS), "inputs": {}}}
        self.write("c.json", chain, folder="chains")
        code, out, err = self.main()
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.state.fx, {})  # the value was revoked before the second process ran


class Refusals(DryRunCase):
    def test_a_file_without_a_dry_run_block_fails_the_static_check_and_nothing_runs(self):
        doc = json.loads(PROCESS_FILE.read_text())
        doc.pop("dry_run", None)  # the process file on disk carries a dry_run block; this case is about one without it
        self.write("BP-01-receive-goods.json", doc)
        code, out, _ = self.main()
        self.assertEqual(code, 1)
        self.assertIn("static check fails", out)
        self.assertIn("dry_run is missing", out)
        self.assertEqual(self.state.log, [])

    def test_an_undefined_variable_stops_the_dry_run_before_any_request(self):
        doc = self.bp01()
        next(s for s in doc["steps"] if s["id"] == "s1")["do"]["body"]["note"] = "${nobody_saves_this}"
        self.write("BP-01-receive-goods.json", doc)
        code, out, _ = self.main()
        self.assertEqual(code, 1)
        self.assertIn("nobody_saves_this", out)
        self.assertEqual(self.state.log, [])

    def test_a_dry_run_input_missing_for_the_process_is_a_failure_not_a_crash(self):
        self.write("BP-01-receive-goods.json", self.bp01(inputs={"item": "item-1"}))
        code, out, _ = self.main()
        self.assertEqual(code, 1)
        self.assertIn("no value for the input", out)

    def test_not_a_git_checkout_is_a_failure_with_a_message(self):
        code, out, err = self.main("--repo", str(Path(self.tmp.name)))
        self.assertEqual(code, 1)
        self.assertIn("dry-run:", out)

    def test_an_unreachable_qa_fails_the_run_of_the_file(self):
        self.write("BP-01-receive-goods.json", self.bp01())
        code, out, _ = self.main("--health-url", "http://127.0.0.1:1/health")
        self.assertEqual(code, 1)
        self.assertEqual(self.state.calls("POST", "/documents"), [])


class UnknownCommand(unittest.TestCase):
    def test_an_unknown_command_exits_2_with_invalid_choice_so_bp_dryrun_can_say_not_yet(self):
        done = subprocess.run([sys.executable, "-B", str(RUNNER_FILE), "not-a-command"], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 2)
        self.assertIn("invalid choice", done.stderr)

    def test_dry_run_help_lists_changed(self):
        done = subprocess.run([sys.executable, "-B", str(RUNNER_FILE), "dry-run", "--help"], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0)
        self.assertIn("--changed", done.stdout)


if __name__ == "__main__":
    unittest.main()
