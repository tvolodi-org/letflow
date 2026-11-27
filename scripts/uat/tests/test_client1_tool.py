"""Tests of the client1_tool step and the saves it reads (T-2857): upload save_response, page_through save_as, the fixed
tool allowlist, arguments from the run dir only, exit 1/2 fails the step, the log keeps RESULT/DIFF lines only.

Run: python3 -B -m unittest -v scripts/uat/tests/test_client1_tool.py   (from the repository root)
"""

import io
import json
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import client1_workbook  # noqa: E402
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402

UUID = "11111111-2222-3333-4444-555555555555"


class Srv(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/health":
            return self.reply({"status": "ok", "sha": "abc"})
        n = int(urllib.parse.parse_qs(parts.query).get("cursor", ["0"])[0])
        self.reply({"rows": [{"k": n}], "next_cursor": str(n + 1) if n < 2 else None})

    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.reply({"results": [{"line": 2, "record_id": UUID}]})

    def reply(self, doc):
        data = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def fake_tool(dirpath, name, code, lines):
    body = "import sys\nprint(%r)\nprint('CELL-TEXT-CANARY')\nsys.exit(%d)\n" % ("\n".join(lines), code)
    (Path(dirpath) / name).write_text(body)


class Client1Tool(FakeServerCase):
    def setUp(self):
        super().setUp()
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Srv)
        threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        self.port = srv.server_address[1]
        self.fx = Path(self.tmp.name) / "fx"
        self.fx.mkdir()
        (self.fx / "a.xlsx").write_bytes(b"PK\x03\x04x")
        self.tools = Path(self.tmp.name) / "tools"
        self.tools.mkdir()
        old = runner.CLIENT1_TOOLS_DIR
        runner.CLIENT1_TOOLS_DIR = self.tools
        self.addCleanup(setattr, runner, "CLIENT1_TOOLS_DIR", old)

    def play(self, steps):
        r = runner.Runner({"id": "BP-T", "title": "t", "steps": steps}, base_url=f"http://127.0.0.1:{self.port}",
                          tenant="t1", actors={"admin": "adm"}, run_dir=self.run_dir, poll_interval=0.01,
                          out=io.StringIO(), upload_dir=self.fx, residue_check=False)
        return r.run()

    def line(self, step):
        rows = [json.loads(x) for x in (self.run_dir / "run.jsonl").read_text().splitlines()]
        return [x for x in rows if x.get("step") == step][-1]

    def test_t1_upload_response_and_pages_are_saved(self):
        code = self.play([
            {"id": "u", "actor": "admin", "do": {"upload": {"path": "/x", "field": "file", "file": "a.xlsx",
                                                            "save_response": True}}, "expect": {"status": 200}},
            {"id": "p", "actor": "admin", "do": {"page_through": {"path": "/b", "items": "rows", "save_as": "balances",
                                                                   "page_size": 1}}, "expect": {"status": 200}}])
        self.assertEqual(code, 0)
        saved = json.loads((self.run_dir / "responses" / "a.json").read_text())
        self.assertEqual(saved["results"][0]["record_id"], UUID)
        names = sorted(p.name for p in (self.run_dir / "pages" / "balances").iterdir())
        self.assertEqual(names, ["page-001.json", "page-002.json", "page-003.json"])

    def test_t2_tool_result_lines_only_and_exit_0_passes(self):
        fake_tool(self.tools, "qoimeks_balances_compare.py", 0, ["RESULT balances equal", "DIFF none"])
        code = self.play([{"id": "c", "actor": "admin", "do": {"client1_tool": {"tool": "balances_compare"}},
                           "expect": {"status": 200}}])
        self.assertEqual(code, 0)
        row = self.line("c")
        self.assertEqual(row["tool_lines"], ["RESULT balances equal", "DIFF none"])
        self.assertNotIn("CELL-TEXT-CANARY", (self.run_dir / "run.jsonl").read_text())

    def test_t3_exit_1_and_2_fail_the_step(self):
        for rc in (1, 2):
            fake_tool(self.tools, "qoimeks_masters_compare.py", rc, ["DIFF places 1"])
            code = self.play([{"id": "c", "actor": "admin", "do": {"client1_tool": {"tool": "masters_compare"}},
                               "expect": {"status": 200}}])
            self.assertNotEqual(code, 0)
            self.assertIn("exit %d" % rc, self.line("c")["error"])

    def test_t4_unknown_tool_and_free_text_args_refused(self):
        for spec in ({"tool": "rm"}, {"tool": "headers", "args": ["--x"]}, {"tool": "balances_compare", "csv": "/etc"}):
            code = self.play([{"id": "c", "actor": "admin", "do": {"client1_tool": spec}, "expect": {"status": 200}}])
            self.assertNotEqual(code, 0, spec)

    def test_t5_headers_need_record_ids(self):
        fake_tool(self.tools, "qoimeks_convert.py", 0, ["wrote 7 header bodies to out"])
        bad = self.play([{"id": "c", "actor": "admin",
                          "do": {"client1_tool": {"tool": "headers", "org_unit_id": "x; rm", "responsible_id": UUID}},
                          "expect": {"status": 200}}])
        self.assertNotEqual(bad, 0)
        ok = self.play([{"id": "c", "actor": "admin",
                         "do": {"client1_tool": {"tool": "headers", "org_unit_id": UUID, "responsible_id": UUID}},
                         "expect": {"status": 200}}])
        self.assertEqual(ok, 0)

    def test_t6_workbook_build_keeps_csv(self):
        with tempfile.TemporaryDirectory() as out:
            names = client1_workbook.build(out)
            for f in ("balances.csv", "items.csv", "locations.csv"):
                self.assertTrue((Path(out) / "csv" / f).is_file(), f)
            self.assertNotIn("csv", names)


if __name__ == "__main__":
    unittest.main()
