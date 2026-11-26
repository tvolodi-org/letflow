"""G-04 canary cases C-30..C-32 for the UAT runner (plant and write only; the detector is Elixir).

The ExUnit file test/letflow/security_probe/g04_artifact_surfaces_test.exs writes cases.json (case id -> kind ->
canary value, from the one Elixir generator), runs this module with G04_CASES and G04_OUT set, then scans every file
under G04_OUT. This module never detects. Without G04_CASES (the plain UAT suite) it uses built-in canaries and only
asserts that the run directories exist.

Run: python3 -I -B -m unittest discover -s scripts/uat/tests -p test_g04_canary.py   (from the repository root)
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
from test_wait_mail import WaitMail, mail_step, process  # noqa: E402

_BUILTIN = {
    "C-30": {"email": "lfe+qbuiltin30@example.test"},
    "C-31": {"credential_url": "https://uqbuiltin31:pqbuiltin31@127.0.0.1:1/x?token=qbuiltin31#fqbuiltin31"},
    "C-32": {"name": "Lfn qbuiltin32", "email": "lfe+qbuiltin32@example.test"},
}


def _cases():
    path = os.environ.get("G04_CASES")
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    return _BUILTIN


class G04Canary(WaitMail):
    """A canary planted where the runner reads it; the run directory is kept for the Elixir scan."""

    def keep(self, case_id):
        out = os.environ.get("G04_OUT")
        dest = Path(out) / case_id if out else Path(tempfile.mkdtemp(prefix="g04-")) / case_id
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(self.run_dir, dest)
        self.assertTrue((dest / "run.jsonl").is_file())
        if not out:
            self.addCleanup(shutil.rmtree, dest.parent, True)

    def test_c30_mail_wait_with_an_unreachable_trap(self):
        """L1: the recipient, plain and percent-encoded, in a trap that cannot be reached."""
        email = _cases()["C-30"]["email"]
        for form in (email, urllib.parse.quote(email, safe=""), urllib.parse.quote(urllib.parse.quote(email, safe=""))):
            code, _ = self.run_it(process(mail_step("s1", within_s=0.3, recipient=form)),
                                  mail_trap_url="http://127.0.0.1:1")
            self.assertEqual(code, 1)
            self.assertEqual(self.step_row("s1")["verdict"], "error")
        self.keep("C-30")

    def test_c31_urls_that_carry_userinfo_and_a_query_token(self):
        """L2: a trap address with a credential, and a base URL with one, in the error paths."""
        cu = _cases()["C-31"]["credential_url"]
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)), mail_trap_url=cu)
        self.assertEqual(code, 1)
        self.assertEqual(self.step_row("s1")["verdict"], "error")
        self.keep("C-31")

    def test_c32_a_step_that_names_a_record_with_a_canary(self):
        """E-07: the evidence line of a step may name the record (name only); the email may not appear."""
        c = _cases()["C-32"]
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3, recipient=c["email"],
                                                subject=c["name"])))
        self.assertEqual(code, 1)
        self.keep("C-32")


if __name__ == "__main__":
    unittest.main()
