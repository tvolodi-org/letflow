"""Tests of the first_signin step: the first administrator of a tenant made during the run signs in for the first
time (temporary password from the mail trap, forced password change at the identity provider, token of the new
realm). A fake trap and a fake realm, no network beyond them.

Class table (path, trigger, effect, replay, logged/stored):
  path                      trigger                      effect                                replay                     logged / stored
  mail trap search          step first_signin            picks the mail by recipient+subject   polls until within_s       recipient masked, mail id only
  mail body                 the picked mail              temporary password cut out of it      never stored               registered secret, never written
  idp auth page + form      temporary password           sign-in form, then password-change    cookies in memory          nothing but the typed reason
  idp password change       password made in memory      code in a redirect (PKCE)             a replay mints a new one   registered secret
  idp token endpoint        code + verifier              access token of the new realm         kept in self.secrets       registered secret, "bearer" only
  failure in the middle     missing mail / policy / ...  RunnerError "first_signin refused: x" step fails, run goes on   typed reason, no secret

Run: python3 -B -m unittest -v scripts/uat/tests/test_first_signin.py   (from the repository root)
"""

import io
import json
import os
import re
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase, FakeTrapCase  # noqa: E402

RECIPIENT = "first.admin@new-tenant.example"
SUBJECT = "Your account"
TEMP = "TempCanary-7Q2xZ"
NEW = "NewCanary-9K4wV!"
TOKEN = "eyJhbGciOiJub25lIn0.TOKENCANARY.sig"
CODE = "CODECANARY123"
REALM = "new-tenant"


class FakeRealm:
    """A realm whose first administrator must change the temporary password. Faults: policy, reject_temp."""

    def __init__(self):
        self.policy_min = 8
        self.reject_temp = False
        self.password = None
        self.seen = []


def realm_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, body="", location=None, ctype="text/html"):
            data = body.encode()
            self.send_response(status)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            base = f"/realms/{REALM}/protocol/openid-connect"
            parts = urllib.parse.urlsplit(self.path)
            if parts.path == base + "/auth":
                state.seen.append(urllib.parse.parse_qs(parts.query))
                return self.send(200, f'<form action="{base}/login?s=1&amp;t=2" method="post"></form>')
            self.send(404)

        def do_POST(self):
            base = f"/realms/{REALM}/protocol/openid-connect"
            length = int(self.headers.get("Content-Length") or 0)
            form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
            path = urllib.parse.urlsplit(self.path).path
            if path == base + "/login":
                if state.reject_temp or form.get("password") != TEMP:
                    return self.send(200, '<form action="%s/login"><p>Invalid password</p></form>' % base)
                return self.send(200, f'<form action="{base}/change"><input name="password-new"></form>')
            if path == base + "/change":
                new = form.get("password-new")
                if new != form.get("password-confirm") or len(new or "") < state.policy_min:
                    return self.send(200, f'<form action="{base}/change"><input name="password-new">too short</form>')
                state.password = new
                return self.send(302, location=f"https://app.example/?code={CODE}&state=x")
            if path == base + "/token":
                if form.get("code") == CODE and form.get("code_verifier"):
                    return self.send(200, json.dumps({"access_token": TOKEN}), ctype="application/json")
                return self.send(400, "{}", ctype="application/json")
            self.send(404)

    return Handler


class FirstSignin(FakeServerCase, FakeTrapCase):
    def setUp(self):
        super().setUp()
        self.trap_url = self.start_trap()
        self.realm = FakeRealm()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), realm_handler(self.realm))
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(lambda: (self.server.shutdown(), self.server.server_close()))
        env = mock.patch.dict(os.environ, {"BPM_IDP_BASE_URL": f"http://127.0.0.1:{self.server.server_address[1]}"})
        env.start()
        self.addCleanup(env.stop)
        self.trap.add(SUBJECT, RECIPIENT, body=f"Welcome.\nTemporary password: {TEMP}\nPlease sign in.")

    def doc(self, **spec):
        body = {"realm": REALM, "recipient": RECIPIENT, "subject": SUBJECT, "within_s": 1, "interval_s": 0.05,
                "redirect_uri": "https://app.example/"}
        body.update(spec)
        return {"id": "FS", "steps": [{"id": "s1", "actor": runner.ANONYMOUS_ACTOR, "do": {"first_signin": body},
                                       "expect": {"status": 200}}]}

    def run_it(self, doc, factory=lambda: NEW):
        r = runner.Runner(doc, base_url=self.base, tenant="qoimeks-qa2", actors={}, run_dir=self.run_dir,
                          poll_interval=0.01, out=io.StringIO(), mail_trap_url=self.trap_url,
                          password_factory=factory)
        return r.run(), r

    def written(self):
        return "\n".join(p.read_text(encoding="utf-8", errors="replace")
                         for p in sorted(self.run_dir.rglob("*")) if p.is_file())

    def assert_no_secret(self, r):
        text = self.written() + r.out.getvalue()
        for canary in (TEMP, NEW, TOKEN, "TOKENCANARY", CODE, RECIPIENT):
            self.assertNotIn(canary, text)

    def test_whole_flow_gives_a_token_and_writes_no_secret(self):
        code, r = self.run_it(self.doc())
        self.assertEqual(0, code)
        self.assertEqual(TOKEN, r.secrets["new_admin"])
        self.assertEqual(NEW, self.realm.password)  # the realm got the password the runner made
        self.assertEqual(["S256"], self.realm.seen[0]["code_challenge_method"])
        self.assert_no_secret(r)
        # the canary sweep covers every file of the run dir, the summary and the jsonl
        names = {p.name for p in self.run_dir.rglob("*") if p.is_file()}
        self.assertIn("run.jsonl", names)

    def test_default_password_is_made_in_memory_and_differs_per_run(self):
        _, r1 = self.run_it(self.doc(), factory=None)
        first = self.realm.password
        self.assertGreaterEqual(len(first), 16)
        self.assertNotIn(first, self.written())
        self.realm.password = None
        self.trap.add(SUBJECT, RECIPIENT, body=f"Temporary password: {TEMP}")
        _, r2 = self.run_it(self.doc(), factory=None)
        self.assertNotEqual(first, self.realm.password)

    def test_mail_missing_is_a_typed_refusal_without_secret(self):
        self.trap.messages.clear()
        code, r = self.run_it(self.doc(within_s=0.1))
        self.assertEqual(1, code)
        self.assertIn("timeout: no mail", self.written())
        self.assert_no_secret(r)
        self.assertNotIn("new_admin", r.secrets)

    def test_mail_without_a_password_is_refused(self):
        self.trap.messages[0]["Text"] = "Welcome, nothing else"
        code, r = self.run_it(self.doc())
        self.assertEqual(1, code)
        self.assertIn("first_signin refused: mail_without_temporary_password", self.written())
        self.assert_no_secret(r)

    def test_password_policy_refusal_is_typed_and_leaves_no_secret(self):
        self.realm.policy_min = 64
        code, r = self.run_it(self.doc())
        self.assertEqual(1, code)
        self.assertIn("first_signin refused: password_policy_refused", self.written())
        self.assert_no_secret(r)
        self.assertNotIn("new_admin", r.secrets)

    def test_temporary_password_rejected_is_typed(self):
        self.realm.reject_temp = True
        code, r = self.run_it(self.doc())
        self.assertEqual(1, code)
        self.assertIn("first_signin refused: temporary_password_rejected", self.written())
        self.assert_no_secret(r)

    def test_idp_unreachable_is_typed(self):
        with mock.patch.dict(os.environ, {"BPM_IDP_BASE_URL": "http://127.0.0.1:9"}):
            code, r = self.run_it(self.doc())
        self.assertEqual(1, code)
        self.assertIn("first_signin refused: idp_unreachable", self.written())
        self.assert_no_secret(r)

    def test_plain_http_idp_is_refused_off_loopback(self):
        with mock.patch.dict(os.environ, {"BPM_IDP_BASE_URL": "http://idp.example"}):
            code, r = self.run_it(self.doc())
        self.assertEqual(1, code)
        self.assertIn("first_signin refused: idp_not_https", self.written())

    def test_validation_refuses_a_literal_password_and_a_missing_realm(self):
        for bad in ({"password": "x"}, {"new_password": "x"}):
            with self.assertRaises(runner.ConfigError):
                runner.validate_step(self.doc(**bad)["steps"][0], "s1")
        step = self.doc()["steps"][0]
        del step["do"]["first_signin"]["realm"]
        with self.assertRaises(runner.ConfigError):
            runner.validate_step(step, "s1")

    def test_a_later_step_uses_the_token_as_bearer(self):
        seen = []
        real = runner.http_call

        def fake_call(method, url, headers, body, timeout=30):
            if not url.endswith("/api/v1/me"):
                return real(method, url, headers, body, timeout)
            seen.append(headers.get("Authorization"))
            return 200, {"ok": True}, "{}"

        doc = self.doc()
        doc["steps"].append({"id": "s2", "actor": runner.ANONYMOUS_ACTOR, "bearer": "new_admin",
                             "do": {"api": "GET", "path": "/api/v1/me"}, "expect": {"status": 200}})
        with mock.patch.object(runner, "http_call", fake_call):
            code, r = self.run_it(doc)
        self.assertEqual(0, code)
        self.assertEqual(["Bearer " + TOKEN], seen)
        self.assert_no_secret(r)


if __name__ == "__main__":
    unittest.main()
