"""Tests of T-3108: route 3 (POST /admin/v1/tenants, 202 + poll) from the runner with a named provisioner credential,
the bearer kept on upload / repeat / page_through, a body read from a file under test/uat, and the checker that
accepts /admin/v1 for a step flagged `platform_route` and nothing else.

Run: python3 -B -m unittest -v scripts/uat/tests/test_platform_route.py   (from the repository root)
"""

import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import check_processes  # noqa: E402
import runner  # noqa: E402

CRED_ENV = "UAT_QA_PROVISIONER_CREDENTIAL"
CRED = "PROVISIONER-SECRET-CANARY-5521"


class Echo(BaseHTTPRequestHandler):
    seen = []

    def handle_any(self):
        size = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(size) if size else b""
        if self.path in ("/health", "/"):
            out = b'{"status":"ok","sha":"abc123"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        type(self).seen.append((self.command, self.path, self.headers.get("Authorization"), data))
        if self.path.startswith("/admin/v1/tenants") and self.command == "POST":
            status, doc = 202, {"tenant_id": "t-1", "status": "pending", "poll": "/admin/v1/tenants/t-1"}
        elif self.path.startswith("/admin/v1/tenants/t-1"):
            status, doc = 200, {"tenant_id": "t-1", "status": "active"}
        elif self.path.startswith("/api/v1/list"):
            status, doc = 200, {"items": [{"id": "a"}], "count": 1, "next_cursor": None}
        else:
            status, doc = 200, {"ok": True}
        out = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_POST = do_PUT = handle_any  # noqa: N815

    def log_message(self, *a):
        pass


def step(sid, do, **kw):
    s = {"id": sid, "actor": "admin", "do": do, "expect": {"status": 200}}
    s.update(kw)
    return s


class Base(unittest.TestCase):
    def setUp(self):
        Echo.seen = []
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Echo)
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "uat" / "fixtures").mkdir(parents=True)
        (self.root / "uat" / "bodies").mkdir()
        (self.root / "uat" / "bodies" / "links.json").write_text(json.dumps({"links": [{"x": "${slug}"}]}))
        (self.root / "uat" / "fixtures" / "up.bin").write_bytes(b"abc")
        (self.root / "outside.json").write_text('{"leak": true}')
        scripts = self.root / "team" / "project" / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "uat_creds.sh").write_text("#!/usr/bin/env bash\nprintf 'Token: SESSION-TOKEN\\n'\n")
        env = mock.patch.dict(os.environ, {CRED_ENV: CRED, "TEAM_ROOT": str(self.root / "team")}, clear=False)
        env.start()
        self.addCleanup(env.stop)

    def play(self, steps, env_ok=True):
        proc = {"id": "BP-T", "title": "t", "steps": steps}
        out = io.StringIO()
        r = runner.Runner(proc, base_url=f"http://127.0.0.1:{self.srv.server_address[1]}", tenant="t1",
                          actors={"admin": "adm"}, run_dir=self.root / "run", poll_interval=0.01, out=out,
                          upload_dir=self.root / "uat" / "fixtures", body_dir=self.root / "uat",
                          residue_check=False)
        r.ctx["slug"] = "uat-tmp-1"
        return r.run(), r

    def lines(self):
        return [json.loads(x) for x in (self.root / "run" / "run.jsonl").read_text().splitlines()]

    def blob(self):
        return b"".join(f.read_bytes() for f in (self.root / "run").rglob("*") if f.is_file())


class Route3(Base):
    def test_create_202_then_poll_with_the_credential_never_logged(self):
        steps = [
            step("p1", {"api": "POST", "path": "/admin/v1/tenants",
                        "body": {"slug": "uat-tmp-1", "display_name": "x", "admin_email": "a@uat.letflow.internal"}},
                 platform_route=True, bearer_env=CRED_ENV,
                 expect={"status": 202, "json": {"$.tenant_id": {"exists": True}}}, save={"tid": "$.tenant_id"}),
            step("p2", {"api": "GET", "path": "/admin/v1/tenants/${tid}"}, platform_route=True, bearer_env=CRED_ENV,
                 expect={"status": 200, "json": {"$.status": "active"}}, poll={"within_s": 2, "interval_s": 0.01}),
        ]
        code, _ = self.play(steps)
        self.assertEqual(code, 0, self.lines())
        self.assertEqual([(m, p) for m, p, _, _ in Echo.seen], [("POST", "/admin/v1/tenants"),
                                                                  ("GET", "/admin/v1/tenants/t-1")])
        self.assertTrue(all(a == "Bearer " + CRED for _, _, a, _ in Echo.seen))
        self.assertNotIn(CRED.encode(), self.blob())

    def test_a_missing_variable_is_a_typed_error_naming_the_variable_only(self):
        with mock.patch.dict(os.environ):
            os.environ.pop(CRED_ENV)
            code, _ = self.play([step("p1", {"api": "POST", "path": "/admin/v1/tenants", "body": {}},
                                      platform_route=True, bearer_env=CRED_ENV)])
        self.assertNotEqual(code, 0)
        self.assertIn(CRED_ENV + ": not set in the environment", json.dumps(self.lines()))
        self.assertEqual(Echo.seen, [])

    def test_validation_refuses_a_foreign_variable_and_a_step_without_the_flag(self):
        base = {"id": "s", "actor": "admin", "do": {"api": "GET", "path": "/admin/v1/tenants/x"}}
        for bad in (dict(base, platform_route=True, bearer_env="HOME"),
                    dict(base, bearer_env=CRED_ENV),
                    dict(base, platform_route=True, bearer_env=CRED_ENV, bearer="session"),
                    dict(base, platform_route="yes")):
            with self.assertRaises(runner.ConfigError, msg=bad):
                runner.validate_step(bad, "x")
        runner.validate_step(dict(base, platform_route=True, bearer_env=CRED_ENV), "x")


class BearerKept(Base):
    def test_upload_repeat_and_page_through_keep_the_bearer(self):
        steps = [
            step("u1", {"upload": {"api": "POST", "path": "/api/v1/up", "raw": True, "file": "up.bin"}},
                 platform_route=True, bearer_env=CRED_ENV),
            step("r1", {"repeat": {"api": "POST", "path": "/api/v1/rep", "body": {"a": 1}}, "times": 2},
                 platform_route=True, bearer_env=CRED_ENV),
            step("g1", {"page_through": {"path": "/api/v1/list"}}, platform_route=True, bearer_env=CRED_ENV),
        ]
        code, _ = self.play(steps)
        self.assertEqual(code, 0, self.lines())
        self.assertEqual(len(Echo.seen), 4)
        for method, path, auth, _ in Echo.seen:
            self.assertEqual(auth, "Bearer " + CRED, (method, path))
        self.assertNotIn(CRED.encode(), self.blob())


class BodyFile(Base):
    def post(self, rel):
        return [step("b1", {"api": "POST", "path": "/api/v1/links", "body_file": rel})]

    def test_body_read_from_a_file_and_substituted(self):
        code, _ = self.play(self.post("bodies/links.json"))
        self.assertEqual(code, 0, self.lines())
        self.assertEqual(json.loads(Echo.seen[0][3]), {"links": [{"x": "uat-tmp-1"}]})

    def test_a_path_outside_the_tree_is_refused(self):
        (self.root / "uat" / "bodies" / "link").symlink_to(self.root / "outside.json")
        for rel in ("../outside.json", "/etc/passwd", "bodies/link", "bodies/none.json"):
            Echo.seen = []
            code, _ = self.play(self.post(rel))
            self.assertNotEqual(code, 0, rel)
            self.assertEqual(Echo.seen, [], rel)
            self.assertIn("body_file_", json.dumps(self.lines()), rel)

    def test_body_and_body_file_together_are_refused_at_validation(self):
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({"id": "s", "actor": "a", "do": {"api": "POST", "path": "/api/x", "body": {},
                                                                     "body_file": "a.json"}}, "x")


class Checker(unittest.TestCase):
    def problems(self, path, flagged):
        out = []
        step_ = {"id": "s", "actor": "admin", "do": {"api": "POST", "path": path}}
        for method, p in check_processes.calls_of(step_):
            check_processes.check_path(out, "step s: ", None, method, p, platform_route=flagged)
        return out

    def test_admin_v1_only_for_a_flagged_step_and_only_that_mount(self):
        self.assertEqual(self.problems("/admin/v1/tenants", True), [])
        self.assertTrue(self.problems("/admin/v1/tenants", False))
        self.assertTrue(self.problems("/internal/x", True))
        self.assertTrue(self.problems("/admin/v1/../api/x", True))
        self.assertTrue(self.problems("/admin/v1", True))
        self.assertEqual(self.problems("/api/v1/x", False), [])


if __name__ == "__main__":
    unittest.main()
