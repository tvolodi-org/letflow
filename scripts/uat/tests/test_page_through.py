"""Tests of the `page_through` step kind (T-2941): a cursor followed over a fake list of 3 pages, with the
age_at_least and unique_ids asserts on the collected set.

Run: python3 -B -m unittest -v scripts/uat/tests/test_page_through.py   (from the repository root)
"""

import datetime
import io
import json
import sys
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402

NOW = datetime.datetime.now(datetime.timezone.utc)


def stamp(days):
    return (NOW - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def pages_of(ids, ages):
    rows = [{"id": i, "created_at": stamp(a)} for i, a in zip(ids, ages)]
    return [rows[0:2], rows[2:4], rows[4:5]]


class Lister(BaseHTTPRequestHandler):
    pages = []
    status = {}
    count_off = False

    def do_GET(self):  # noqa: N802
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/health":
            return self.reply(200, {"status": "ok", "sha": "abc123"})
        n = int(urllib.parse.parse_qs(parts.query).get("cursor", ["0"])[0])
        if n in self.status:
            return self.reply(self.status[n], {})
        page = self.pages[n]
        doc = {"items": page, "count": len(page) + (1 if self.count_off and n == 1 else 0),
               "next_cursor": str(n + 1) if n + 1 < len(self.pages) else None}
        self.reply(200, doc)

    def reply(self, status, doc):
        data = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def step(expect=None, **spec):
    return {"id": "p1", "actor": "admin", "do": {"page_through": dict({"path": "/api/v1/things"}, **spec)},
            "expect": dict({"status": 200}, **(expect or {}))}


class PageThrough(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.handler = type("H", (Lister,), {"pages": pages_of("abcde", [0, 1, 2, 3, 4]), "status": {},
                                             "count_off": False})
        srv = ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
        threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        self.actors = {"admin": {"user": "admin-user", "tenant": "bpm-default",
                                 "base_url": f"http://127.0.0.1:{srv.server_address[1]}"}}

    def run_it(self, st):
        r = runner.Runner({"id": "PG", "steps": [st]}, base_url=self.base, tenant="qoimeks-qa2",
                          actors=self.actors, run_dir=self.run_dir, inputs={}, poll_interval=0.01,
                          out=io.StringIO(), run_id="20261126T090000Z-aaaaaa")
        r.run()
        return next(x for x in self.lines() if x["step"] == "p1")

    def test_three_pages_are_collected_and_pass(self):
        row = self.run_it(step({"json": {"$.pages": 3, "$.items[4].id": "e"},
                                "age_at_least": {"seconds": 3 * 86400}, "unique_ids": True}))
        self.assertEqual(row["verdict"], "pass", row)

    def test_no_old_rows_is_inconclusive_not_a_pass(self):
        self.handler.pages = pages_of("abcde", [0, 0, 0, 0, 0])
        row = self.run_it(step({"age_at_least": {"seconds": 86400}}))
        self.assertEqual(row["verdict"], "blocked")
        self.assertIn("inconclusive: no old rows", row["error"])

    def test_a_duplicated_id_fails(self):
        self.handler.pages = pages_of("abcad", [3, 3, 3, 3, 3])
        row = self.run_it(step({"unique_ids": True}))
        self.assertEqual(row["verdict"], "fail")
        self.assertIn("unique", row["error"])

    def test_a_duplicate_beats_inconclusive(self):
        self.handler.pages = pages_of("abcad", [0, 0, 0, 0, 0])
        row = self.run_it(step({"age_at_least": 86400, "unique_ids": True}))
        self.assertEqual(row["verdict"], "fail")

    def test_a_count_that_disagrees_with_the_items_errors(self):
        self.handler.count_off = True
        row = self.run_it(step())
        self.assertEqual(row["verdict"], "error")
        self.assertIn("page 2 count", row["error"])

    def test_a_non_200_page_errors(self):
        self.handler.status = {1: 500}
        row = self.run_it(step())
        self.assertEqual(row["verdict"], "error")
        self.assertIn("page 2 answered 500", row["error"])

    def test_max_pages_truncates(self):
        row = self.run_it(step({"json": {"$.pages": 2, "$.truncated": True}}, max_pages=2))
        self.assertEqual(row["verdict"], "pass", row)

    def test_static_validation(self):
        runner.validate_step(step(), "t")
        for bad in ({"path": "/x", "max_pages": 16}, {"path": "/x", "max_pages": 0}, {"path": ""}, {"path": "/x", "z": 1}):
            with self.assertRaises(runner.ConfigError):
                runner.validate_step({"id": "x", "actor": "admin", "do": {"page_through": bad}}, "t")


if __name__ == "__main__":
    unittest.main()
