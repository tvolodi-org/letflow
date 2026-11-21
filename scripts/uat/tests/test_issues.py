"""Tests of `--file-issues` of scripts/uat/runner.py: one GitHub issue per failed process through a FAKE gh
script (it records its arguments and its stdin). No network, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_issues.py   (from the repository root)
"""

import contextlib
import io
import json
import stat
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import INPUTS, PROCESS_FILE, SECRET, SHARED_VALUE, USERS, FakeServerCase  # noqa: E402
from test_chain import call, proc, tagged  # noqa: E402,F401  (helpers only)


class IssueCase(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.gh_dir = Path(self.tmp.name) / "gh"
        self.gh_dir.mkdir()
        self.gh = self.fake_gh("exit 0")

    def fake_gh(self, tail):
        """A gh that stores `args-N.txt` (one argument per line) and `body-N.txt` (stdin), prints an issue url."""
        script = Path(self.tmp.name) / "fake-gh.sh"
        script.write_text(
            "#!/usr/bin/env bash\n"
            f"d={self.gh_dir}\n"
            'n=$(ls "$d" | grep -c "^args-")\n'
            'printf "%s\\n" "$@" > "$d/args-$n.txt"\n'
            'cat > "$d/body-$n.txt"\n'
            f"{tail}\n"
        )
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        return str(script)

    def ok_gh(self):
        return self.fake_gh('echo "https://github.com/o/r/issues/$((n+100))"')

    def filed(self):
        names = sorted(p.name for p in self.gh_dir.iterdir() if p.name.startswith("args-"))
        return [(self.read_args(n), (self.gh_dir / n.replace("args-", "body-")).read_text()) for n in names]

    def read_args(self, name):
        return (self.gh_dir / name).read_text().splitlines()

    def failing_409(self, pid="BP-77"):
        """s1 posts (201), s2 posts again and expects 200 but gets 409."""
        return proc(pid, [call("s1", "POST", "/api/v1/race", {"a": 1}, {"status": 201}),
                          call("s2", "POST", "/api/v1/race", {"a": 2}, {"status": 200})])

    def run_with_issues(self, processes, **kwargs):
        return self.run_process(processes, inputs=kwargs.pop("inputs", {}), file_issues=True, gh_cmd=self.gh,
                                repo="o/r", **kwargs)


class FileIssues(IssueCase):
    def test_one_issue_for_the_failed_process_with_title_label_and_log_path(self):
        self.gh = self.ok_gh()
        code, r = self.run_with_issues([self.failing_409()])
        self.assertEqual(code, 1)
        ((args, body),) = self.filed()
        self.assertEqual(args[:2], ["issue", "create"])
        self.assertEqual(args[args.index("--title") + 1], "UAT BP-77 s2: expected 200 got 409")
        self.assertEqual(args[args.index("--label") + 1], "uat-regression")
        self.assertEqual(args[args.index("--repo") + 1], "o/r")
        self.assertIn(str((self.run_dir / "run.jsonl").resolve()), body)
        self.assertIn("process **BP-77**", body)
        self.assertIn("| step | s2 | admin | POST /api/v1/race | 409 | fail |", body)  # the step table
        self.assertIn("POST /api/v1/race", body)
        self.assertIn("already_taken", body)  # the failing response
        self.assertEqual(json.loads((self.run_dir / "issues.json").read_text()), {"BP-77": "https://github.com/o/r/issues/100"})
        self.assertIn("https://github.com/o/r/issues/100", (self.run_dir / "summary.md").read_text())

    def test_a_passing_run_files_nothing(self):
        code, _ = self.run_with_issues([tagged("PA", "A")])
        self.assertEqual(code, 0)
        self.assertEqual(self.filed(), [])

    def test_one_issue_per_failed_process_not_per_failed_step(self):
        two_bad = proc("BP-78", [call("s1", "POST", "/api/v1/echo", {}, {"status": 404}),
                                 call("s2", "POST", "/api/v1/echo", {}, {"status": 404})])
        self.gh = self.ok_gh()
        code, _ = self.run_with_issues([two_bad, tagged("PA", "A"), self.failing_409()], keep_going=True)
        self.assertEqual(code, 1)
        titles = [a[a.index("--title") + 1] for a, _ in self.filed()]
        self.assertEqual(len(titles), 2)
        self.assertTrue(titles[0].startswith("UAT BP-78 s1: expected 404 got 200"), titles)
        self.assertTrue(titles[1].startswith("UAT BP-77 s2"), titles)

    def test_the_same_run_files_a_process_only_once(self):
        self.gh = self.ok_gh()
        code, r = self.run_with_issues([self.failing_409()])
        self.assertEqual(len(self.filed()), 1)
        r._file_issues()  # asked again for the same run: the ledger remembers
        self.assertEqual(len(self.filed()), 1)

    def test_a_failing_cleanup_is_an_issue_too(self):
        bad = tagged("PA", "A")
        bad["cleanup"][0]["expect"] = {"status": 404}
        self.gh = self.ok_gh()
        code, _ = self.run_with_issues([bad])
        self.assertEqual(code, 1)
        ((args, _),) = self.filed()
        self.assertEqual(args[args.index("--title") + 1], "UAT PA c1: expected 404 got 200")

    def test_a_preflight_failure_files_no_issue(self):
        code, _ = self.run_with_issues([self.failing_409()], build_sha="zzz")
        self.assertEqual(code, 1)
        self.assertEqual(self.filed(), [])

    def test_gh_failing_does_not_hide_the_failed_run(self):
        self.gh = self.fake_gh("echo 'gh: not logged in' >&2; exit 4")
        code, r = self.run_with_issues([self.failing_409()])
        self.assertEqual(code, 1)
        self.assertIn("NOT FILED", json.loads((self.run_dir / "issues.json").read_text())["BP-77"])

    def test_without_the_flag_gh_is_never_called(self):
        self.gh = self.ok_gh()
        code, _ = self.run_process([self.failing_409()], inputs={}, gh_cmd=self.gh)
        self.assertEqual(code, 1)
        self.assertEqual(self.filed(), [])

    def test_the_command_line_flag_reaches_gh(self):
        self.gh = self.ok_gh()
        path = Path(self.tmp.name) / "p.json"
        path.write_text(json.dumps(self.failing_409()))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(["run", str(path), "--tenant", "t", "--base-url", self.base, "--actors", "admin=adm",
                                "--run-dir", str(self.run_dir), "--file-issues", "--gh", self.gh, "--repo", "o/r"])
        self.assertEqual(code, 1, out.getvalue() + err.getvalue())
        self.assertEqual(len(self.filed()), 1)
        self.assertIn("issues/100", out.getvalue())


class NoSecretInAnIssue(IssueCase):
    def everything_sent(self):
        return "\n".join("\n".join(args) + "\n" + body for args, body in self.filed())

    def test_tokens_passwords_and_jwts_of_the_failing_exchange_are_not_in_the_issue(self):
        leak = proc("BP-79", [{"id": "s1", "actor": "admin", "do": {"api": "GET", "path": "/api/v1/leak"},
                               "expect": {"status": 404}}])
        self.gh = self.ok_gh()
        code, _ = self.run_with_issues([leak])
        self.assertEqual(code, 1)
        sent = self.everything_sent()
        self.assertTrue(sent)
        for forbidden in (SECRET, "TOKEN_", "Bearer", "hunter2", "eyJhbGci"):
            self.assertNotIn(forbidden, sent)

    def test_a_request_body_with_a_secret_key_is_masked(self):
        step = call("s1", "POST", "/api/v1/echo", {"password": "hunter2", "api_key": "k-123", "ok": "visible"}, {"status": 404})
        self.gh = self.ok_gh()
        self.run_with_issues([proc("BP-80", [step])])
        sent = self.everything_sent()
        self.assertNotIn("hunter2", sent)
        self.assertNotIn("k-123", sent)
        self.assertIn("visible", sent)

    def test_the_shared_access_value_is_not_in_the_issue(self):
        create = call("s1", "POST", "/api/v1/identity/shared-stock-access", {}, {"status": 201},
                      save={"shared_created": "yes", "shared_access": {"secret": "$.value"}})
        read = {"id": "s2", "http_as": "shared_access", "do": {"api": "GET", "path": "/movements"}, "expect": {"status": 404}}
        cleanup = [{"id": "c1", "actor": "admin", "requires": ["shared_created"],
                    "do": {"api": "DELETE", "path": "/api/v1/identity/shared-stock-access"}, "expect": {"status": 204}}]
        self.gh = self.ok_gh()
        r = runner.Runner([proc("BP-81", [create, read], cleanup)], base_url=self.base, tenant="t", actors=USERS,
                          run_dir=self.run_dir, old_base_url=self.base + "/qoimeks/t", file_issues=True, gh_cmd=self.gh,
                          out=io.StringIO())
        self.assertEqual(r.run(), 1)
        self.assertEqual(len(self.filed()), 1)
        self.assertNotIn(SHARED_VALUE, self.everything_sent())


if __name__ == "__main__":
    unittest.main()
