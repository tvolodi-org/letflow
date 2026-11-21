"""Tests of the wait_mail step (G18): the runner reads the mail trap by recipient and subject, bounded by a
timeout, and the body of the mail never reaches the log. A fake Mailpit and the fake QA, no network beyond them.

Run: python3 -B -m unittest -v scripts/uat/tests/test_wait_mail.py   (from the repository root)
"""

import io
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase, FakeTrapCase  # noqa: E402

RECIPIENT = "admin@uat.letflow.internal"
OTHER = "someone-else@uat.letflow.internal"
SUBJECT = "Tenant registered"
BODY = "BODY-SECRET-42 the invitation link https://qa.example/reset?token=abc"


def mail_step(sid, recipient=RECIPIENT, subject=SUBJECT, expect=None, save=None, **extra):
    spec = {"recipient": recipient, "subject": subject, "within_s": 1, "interval_s": 0.05}
    spec.update(extra)
    step = {"id": sid, "actor": "admin", "do": {"wait_mail": spec},
            "expect": expect if expect is not None else {"status": 200}}
    if save:
        step["save"] = save
    return step


def process(*steps):
    return {"id": "MAIL", "steps": list(steps)}


class WaitMail(FakeServerCase, FakeTrapCase):
    """A step that waits for a mail in the trap."""

    def setUp(self):
        super().setUp()
        self.trap_url = self.start_trap()

    def run_it(self, doc, **kwargs):
        out = io.StringIO()
        options = {"mail_trap_url": self.trap_url}
        options.update(kwargs)
        r = runner.Runner(doc, base_url=self.base, tenant="qoimeks-qa2", actors={"admin": "adm"},
                          run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=out, **options)
        code = r.run()
        return code, r

    def step_row(self, step_id):
        return next(x for x in self.lines() if x["phase"] == "step" and x["step"] == step_id)

    def all_files(self):
        return "\n".join(p.read_text(encoding="utf-8") for p in sorted(self.run_dir.rglob("*")) if p.is_file())


class TheMailIsFound(WaitMail):
    def test_a_mail_to_the_recipient_with_the_subject_passes_the_step(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        row = self.step_row("s1")
        self.assertEqual(row["verdict"], "pass")
        self.assertEqual(row["mail_subject"], SUBJECT)
        self.assertEqual(row["mail_id"], "m1")
        self.assertEqual(row["polls"], 1)

    def test_the_step_saves_what_the_mail_answer_carries(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY)
        code, r = self.run_it(process(mail_step("s1", save={"mail_id": "$.message_id"})))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(r.ctx["mail_id"], "m1")

    def test_the_body_of_the_mail_never_reaches_the_log(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0)
        text = self.all_files()
        self.assertNotIn(BODY, text)
        self.assertNotIn("BODY-SECRET-42", text)
        self.assertNotIn("https://qa.example/reset", text)

    def test_the_subject_is_in_the_log_and_the_address_is_masked(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0)
        text = self.all_files()
        self.assertIn(SUBJECT, text)
        # every address in a log is masked (the shape stays visible, the address does not)
        self.assertNotIn(RECIPIENT, text)
        self.assertNotIn("uat.letflow.internal", text)
        self.assertIn("@***", text)

    def test_the_step_waits_for_a_mail_that_arrives_late(self):
        self.trap.empty_searches = 2
        self.trap.add(SUBJECT, RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        row = self.step_row("s1")
        self.assertEqual(row["verdict"], "pass")
        self.assertEqual(row["polls"], 3)

    def test_a_summary_without_a_subject_is_read_from_the_message_itself(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY, summary_subject=False)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.step_row("s1")["verdict"], "pass")

    def test_a_summary_without_a_recipient_is_read_from_the_message_itself(self):
        self.trap.add(SUBJECT, RECIPIENT, body=BODY, summary_recipient=False)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.step_row("s1")["verdict"], "pass")

    def test_a_mail_to_another_recipient_in_a_summary_without_a_recipient_is_not_the_mail(self):
        self.trap.add(SUBJECT, OTHER, body=BODY, summary_recipient=False)
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)))
        self.assertEqual(code, 1)
        self.assertIn("timeout", self.step_row("s1")["error"])

    def test_subject_contains_finds_a_mail_with_a_prefix(self):
        self.trap.add(f"[Letflow] {SUBJECT}", RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1", subject_contains=True)))
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        self.assertEqual(self.step_row("s1")["verdict"], "pass")

    def test_the_exact_subject_does_not_match_a_prefixed_one(self):
        self.trap.add(f"[Letflow] {SUBJECT}", RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1")))
        self.assertEqual(code, 1)
        self.assertEqual(self.step_row("s1")["verdict"], "error")


class TheMailIsNotFound(WaitMail):
    def test_a_mail_to_another_recipient_is_not_the_mail(self):
        self.trap.add(SUBJECT, OTHER, body=BODY)
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)))
        self.assertEqual(code, 1)
        row = self.step_row("s1")
        self.assertEqual(row["verdict"], "error")
        self.assertIn("timeout", row["error"])
        self.assertIn("no mail to", row["error"])

    def test_a_mail_with_another_subject_is_not_the_mail(self):
        self.trap.add("Something else entirely", RECIPIENT, body=BODY)
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)))
        self.assertEqual(code, 1)
        self.assertIn("timeout", self.step_row("s1")["error"])

    def test_an_empty_trap_times_out(self):
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)))
        self.assertEqual(code, 1)
        self.assertIn("timeout", self.step_row("s1")["error"])

    def test_an_unreachable_trap_fails_the_step(self):
        code, _ = self.run_it(process(mail_step("s1", within_s=0.3)),
                              mail_trap_url="http://127.0.0.1:1")
        self.assertEqual(code, 1)
        row = self.step_row("s1")
        self.assertEqual(row["verdict"], "error")
        self.assertIn("mail trap", row["error"])

    def test_a_trap_address_that_is_not_http_is_refused(self):
        code, _ = self.run_it(process(mail_step("s1", trap_url="ftp://trap")))
        self.assertEqual(code, 1)
        self.assertIn("http", self.step_row("s1")["error"])


class TheStepMustBeReadable(WaitMail):
    """A bad wait_mail step is a usage error (exit 2), never a request."""

    def load(self, step):
        path = Path(self.tmp.name) / "process.json"
        path.write_text(json.dumps({"id": "MAIL", "steps": [step]}), encoding="utf-8")
        return runner.load_process(str(path))

    def test_a_step_without_a_recipient_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"id": "s1", "actor": "admin",
                       "do": {"wait_mail": {"subject": SUBJECT}}, "expect": {"status": 200}})

    def test_a_step_without_a_subject_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"id": "s1", "actor": "admin",
                       "do": {"wait_mail": {"recipient": RECIPIENT}}, "expect": {"status": 200}})

    def test_a_step_with_a_number_of_seconds_that_is_not_a_number_is_refused(self):
        with self.assertRaises(runner.ConfigError):
            self.load({"id": "s1", "actor": "admin",
                       "do": {"wait_mail": {"recipient": RECIPIENT, "subject": SUBJECT, "within_s": "soon"}},
                       "expect": {"status": 200}})

    def test_a_good_step_is_accepted(self):
        doc = self.load(mail_step("s1"))
        self.assertEqual(doc["steps"][0]["do"]["wait_mail"]["subject"], SUBJECT)


if __name__ == "__main__":
    unittest.main()
