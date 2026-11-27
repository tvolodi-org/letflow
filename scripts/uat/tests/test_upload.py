"""Tests of the `upload` step (T-2864): a multipart body from a fixture file, the SHA-256 in the log and never the
content, typed refusals, a refused upload as an expected negative, the generated Client 1 workbook set.

Run: python3 -B -m unittest -v scripts/uat/tests/test_upload.py   (from the repository root)
"""

import hashlib
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import client1_workbook  # noqa: E402
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402

CONTENT = b"PK\x03\x04CANARY-FILE-CONTENT-7731" + bytes(range(256))
CANARY = b"CANARY-FILE-CONTENT-7731"


class Receiver(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):  # noqa: N802
        size = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(size)
        type(self).seen.append((self.path, self.headers.get("Content-Type"), data))
        too_big = b"BIGFILE" in data
        status = 413 if too_big else (415 if b"text/plain" in data else 200)
        out = json.dumps({"checked": True, "rows": 3} if status == 200 else {"error": "refused"}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):  # noqa: N802
        out = b'{"status":"ok","sha":"abc"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def process(file="up.xlsx", ctype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", expect=None,
            extra=None):
    up = {"api": "POST", "path": "/api/v1/import?dry_run=true", "field": "file", "file": file,
          "content_type": ctype, "fields": {"mode": "check"}}
    up.update(extra or {})
    step = {"id": "U1", "actor": "admin", "do": {"upload": up},
            "expect": expect or {"status": 200, "json": {"$.checked": True}}}
    return {"id": "BP-UP", "title": "t", "steps": [step]}


class Upload(FakeServerCase):
    def setUp(self):
        super().setUp()
        Receiver.seen = []
        self.rx = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
        threading.Thread(target=self.rx.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.rx.server_close)
        self.addCleanup(self.rx.shutdown)
        self.fx = Path(self.tmp.name) / "fx"
        self.fx.mkdir()
        (self.fx / "up.xlsx").write_bytes(CONTENT)

    def play(self, proc):
        out = __import__("io").StringIO()
        r = runner.Runner(proc, base_url=f"http://127.0.0.1:{self.rx.server_address[1]}", tenant="t1",
                          actors={"admin": "adm"}, run_dir=self.run_dir, poll_interval=0.01, out=out,
                          upload_dir=self.fx, residue_check=False)
        return r.run(), r

    def lines(self):
        return [json.loads(x) for x in (self.run_dir / "run.jsonl").read_text().splitlines()]

    def step_line(self):
        return [x for x in self.lines() if x.get("step") == "U1"][-1]

    def test_u1_multipart_body(self):
        code, _ = self.play(process())
        self.assertEqual(code, 0)
        path, ctype, data = Receiver.seen[0]
        self.assertEqual(path, "/api/v1/import?dry_run=true")
        self.assertTrue(ctype.startswith("multipart/form-data; boundary="))
        boundary = ctype.split("boundary=")[1].encode()
        self.assertIn(b'name="mode"\r\n\r\ncheck', data)
        self.assertIn(b'name="file"; filename="up.xlsx"', data)
        self.assertIn(b"Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n" + CONTENT
                      + b"\r\n--" + boundary + b"--\r\n", data)

    def test_u1b_raw_body_is_the_file(self):
        code, _ = self.play(process(extra={"raw": True, "field": None, "fields": None}))
        self.assertEqual(code, 0)
        path, ctype, data = Receiver.seen[0]
        self.assertEqual(ctype, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        self.assertEqual(data, CONTENT)
        line = self.step_line()
        self.assertTrue(line["request"]["upload"]["raw"])
        self.assertEqual(line["request"]["upload"]["sha256"], hashlib.sha256(CONTENT).hexdigest())
        self.assertNotIn(CANARY, (self.run_dir / "run.jsonl").read_bytes())

    def test_u1c_raw_needs_no_field_but_refuses_fields(self):
        p = process(extra={"raw": True})
        del p["steps"][0]["do"]["upload"]["field"]
        code, _ = self.play(p)
        self.assertNotEqual(code, 0)
        self.assertIn("no fields", self.step_line()["error"])
        self.assertEqual(Receiver.seen, [])

    def test_u2_sha_logged_content_never(self):
        self.play(process())
        line = self.step_line()
        self.assertEqual(line["request"]["upload"]["sha256"], hashlib.sha256(CONTENT).hexdigest())
        self.assertEqual(line["request"]["upload"]["bytes"], len(CONTENT))
        for f in self.run_dir.rglob("*"):
            if f.is_file():
                blob = f.read_bytes()
                self.assertNotIn(CANARY, blob, f.name)
                self.assertNotIn(b"CANARY-FILE", blob, f.name)

    def test_u3_missing_fixture_typed(self):
        code, _ = self.play(process(file="nope.xlsx"))
        self.assertNotEqual(code, 0)
        line = self.step_line()
        self.assertEqual(line["verdict"], "error")
        self.assertTrue(line["error"].startswith("upload_fixture_missing:"), line["error"])
        self.assertEqual(Receiver.seen, [])

    def test_u4_path_escape_and_absolute_refused(self):
        for bad in ("../x.xlsx", "/etc/passwd"):
            Receiver.seen = []
            self.play(process(file=bad))
            self.assertTrue(self.step_line()["error"].startswith("upload_fixture_path_invalid:"), bad)
            self.assertEqual(Receiver.seen, [])

    def test_u5_too_big_refused_before_send(self):
        old = runner.UPLOAD_MAX_BYTES
        runner.UPLOAD_MAX_BYTES = 10
        self.addCleanup(setattr, runner, "UPLOAD_MAX_BYTES", old)
        self.play(process())
        self.assertTrue(self.step_line()["error"].startswith("upload_fixture_too_big:"))
        self.assertEqual(Receiver.seen, [])

    def test_u6_server_refusals_are_expected_negatives(self):
        (self.fx / "big.xlsx").write_bytes(b"BIGFILE")
        code, _ = self.play(process(file="big.xlsx", expect={"status": 413}))
        self.assertEqual(code, 0)
        code, _ = self.play(process(ctype="text/plain", expect={"status": 415}))
        self.assertEqual(code, 0)
        code, _ = self.play(process(ctype="text/plain"))  # the same refusal when 200 was expected: a failure
        self.assertNotEqual(code, 0)

    def test_u7_validation(self):
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({"id": "x", "actor": "a", "do": {"upload": {"path": "/p", "field": "f"}}}, "w")
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({"id": "x", "actor": "a", "do": {"upload": {
                "path": "/p", "field": "f", "file": "a", "body": {}}}}, "w")
        with self.assertRaises(runner.ConfigError):
            runner.validate_step({"id": "x", "actor": "a", "do": {"api": "GET", "path": "/p", "upload": {}}}, "w")

    def test_u8_bad_content_type_and_field_refused(self):
        self.play(process(ctype="x/y\r\nX: 1"))
        self.assertIn("content_type", self.step_line()["error"])
        self.play(process(extra={"field": 'f"; x="'}))
        self.assertIn("field", self.step_line()["error"])
        self.assertEqual(Receiver.seen, [])

    def test_u9_generated_client1_set_is_uploaded(self):
        proc = process(file="generated/client1/03-items-01.xlsx")
        code, _ = self.play(proc)
        self.assertEqual(code, 0)
        _, _, data = Receiver.seen[0]
        self.assertIn(b"PK\x03\x04", data)
        self.assertTrue((self.run_dir / "generated-fixtures" / "client1" / "03-items-01.xlsx").is_file())


class Client1Set(unittest.TestCase):
    def test_g1_shape_and_determinism(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            names = client1_workbook.build(a)
            client1_workbook.build(b)
            self.assertIn("03-items-01.xlsx", names)
            for n in names:
                self.assertEqual((Path(a) / n).read_bytes(), (Path(b) / n).read_bytes(), n)
            counts = (Path(a) / "expected_counts.txt").read_text()
            self.assertIn("records.catalog_item 666", counts)
            self.assertIn("records.stock_opening_line 603", counts)
            self.assertIn("records.location_node 142", counts)  # 134 places + 8 hierarchy nodes

    def test_g2_no_real_data_markers(self):
        with tempfile.TemporaryDirectory() as a:
            client1_workbook.build(a)
            self.assertLess(sum(p.stat().st_size for p in Path(a).iterdir()), 1_000_000)


if __name__ == "__main__":
    unittest.main()
