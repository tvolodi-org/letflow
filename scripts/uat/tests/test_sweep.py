"""Tests of the `sweep` step kind (T-2898): the cleanup of a scenario retires the throwaway definitions an EARLIER
failed run left, found by the name prefix, through the product's own list and DELETE calls. A small fake definitions
server (paged list, per-id DELETE answers), no network beyond it.

Run: python3 -B -m unittest -v scripts/uat/tests/test_sweep.py   (from the repository root)
"""

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

RUN = "20261126T090000Z-aaaaaa"
OLD = "20261126T073256Z-ad82b7"
DEFS = [
    ("d1", f"uat-tmp-designer-{OLD}-1", "DRAFT"),
    ("d2", f"uat-tmp-designer-{OLD}-2", "ACTIVE"),
    ("d3", f"uat-tmp-designer-{RUN}-1", "DRAFT"),  # this run's own: never swept
    ("d4", "invoice-approval", "ACTIVE"),  # a real definition: never swept
    ("d5", f"uat-tmp-defproof-{OLD}-1", "DRAFT"),  # another scenario's prefix: not this sweep's
    ("d6", f"uat-tmp-designer-{OLD}-3", "ARCHIVED"),
    ("d7", f"uat-tmp-designer-{OLD}-4", "DEPRECATED"),
]


VERSIONS = [  # T-2917: platform.register_tenant versions
    ("v1", "platform.register_tenant", "2", "ACTIVE"),  # the seeded version: never
    ("v2", "platform.register_tenant", f"uat-{OLD}", "DRAFT"),  # the leftover draft: retired
    ("v3", "platform.register_tenant", "3-draft", "DRAFT"),  # a non-uat draft: never
    ("v4", "platform.register_tenant", f"uat-{RUN}", "DRAFT"),  # this run's own: never
    ("v5", "platform.register_tenant", f"uat-{OLD}-b", "ACTIVE"),  # uat but not a draft: never
    ("v6", "platform.other", f"uat-{OLD}", "DRAFT"),  # another definition: never
]


class Defs(BaseHTTPRequestHandler):
    deleted = []
    answers = {}
    page = 2

    def do_GET(self):  # noqa: N802
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/health":
            return self.reply(200, {"status": "ok", "sha": "abc123"})
        query = urllib.parse.parse_qs(parts.query)
        name = query.get("name", [""])[0].lower()
        rows = [{"id": i, "name": n, "status": s} for i, n, s in DEFS if name in n.lower()]
        rows += [{"id": i, "name": n, "version": v, "status": s} for i, n, v, s in VERSIONS if name in n.lower()]
        start = int(query.get("cursor", ["0"])[0])
        page = rows[start:start + self.page]
        end = start + len(page)
        self.reply(200, {"items": page, "next_cursor": str(end) if end < len(rows) else None})

    def do_DELETE(self):  # noqa: N802
        def_id = self.path.rsplit("/", 1)[1]
        type(self).deleted.append(def_id)
        self.reply(self.answers.get(def_id, 204), {})

    def reply(self, status, doc):
        data = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def sweep_step(prefix="uat-tmp-designer-", marker="${run_id}", **extra):
    spec = dict({"prefix": prefix, "exclude_contains": marker}, **extra)
    if prefix is None:
        del spec["prefix"]
    return {"id": "c9", "actor": "admin",
            "do": {"sweep": spec},
            "expect": {"status": 200}}


class Sweep(FakeServerCase):
    def setUp(self):
        super().setUp()
        self.handler = type("H", (Defs,), {"deleted": [], "answers": {}, "page": 2})
        self.other = ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
        threading.Thread(target=self.other.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.other.server_close)
        self.addCleanup(self.other.shutdown)
        self.actors = {"admin": {"user": "admin-user", "tenant": "bpm-default",
                                 "base_url": f"http://127.0.0.1:{self.other.server_address[1]}"}}

    def run_it(self, step):
        self.out = io.StringIO()
        r = runner.Runner({"id": "SWP", "steps": [], "cleanup": [step]}, base_url=self.base, tenant="qoimeks-qa2",
                          actors=self.actors, run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=self.out,
                          run_id=RUN)
        return r.run()

    def row(self):
        return next(x for x in self.lines() if x["step"] == "c9")

    def test_only_old_prefixed_names_are_deleted_across_pages(self):
        self.run_it(sweep_step())
        self.assertEqual(sorted(self.handler.deleted), ["d1", "d2", "d6", "d7"])
        row = self.row()
        self.assertEqual(row["verdict"], "pass")
        self.assertEqual(len([x for x in row["sweep"] if x.startswith("sweep d")]), 4)
        self.assertIn("4 swept", self.out.getvalue())
        self.assertIn(f"sweep d1 uat-tmp-designer-{OLD}-1 was DRAFT: swept (204)", self.out.getvalue())

    def test_only_the_uat_draft_version_of_the_named_definition_is_retired(self):
        self.run_it(sweep_step(prefix=None, draft_versions_of="platform.register_tenant"))
        self.assertEqual(self.handler.deleted, ["v2"])
        self.assertEqual(self.row()["verdict"], "pass")
        self.assertIn(f"sweep v2 platform.register_tenant@uat-{OLD} was DRAFT: swept (204)", self.out.getvalue())
        self.assertIn("1 swept", self.out.getvalue())

    def test_404_and_409_are_already_gone_and_pass(self):
        self.handler.answers = {"d6": 409, "d1": 404}
        self.run_it(sweep_step())
        self.assertEqual(self.row()["verdict"], "pass")
        self.assertIn("2 swept, 2 already gone", self.out.getvalue())

    def test_a_500_fails_the_step(self):
        self.handler.answers = {"d2": 500}
        self.run_it(sweep_step())
        row = self.row()
        self.assertEqual(row["verdict"], "error")
        self.assertIn("d2", row["error"])

    def test_nothing_to_sweep_passes_with_zero(self):
        self.run_it(sweep_step(prefix="uat-tmp-nothing-"))
        self.assertEqual(self.handler.deleted, [])
        self.assertEqual(self.row()["verdict"], "pass")
        self.assertIn("0 swept", self.out.getvalue())

    def test_a_too_broad_prefix_or_a_missing_marker_is_refused_before_any_request(self):
        for prefix in ("", "uat-", "uat-tmp-", "invoice", "uat-tmp-designer"):
            self.handler.deleted.clear()
            self.run_it(sweep_step(prefix=prefix))
            self.assertEqual(self.handler.deleted, [], prefix)
            self.assertNotEqual(self.row()["verdict"], "pass", prefix)

    def test_static_validation(self):
        good = {"id": "x", "actor": "admin", "expect": {"status": 200}, "do": {"sweep": {"prefix": "uat-tmp-walk-", "exclude_contains": "${run_id}"}}}
        runner.validate_step(good, "t")
        for bad in ({"prefix": "uat-", "exclude_contains": "${run_id}"},
                    {"prefix": "uat-tmp-walk-", "exclude_contains": ""},
                    {"prefix": "uat-tmp-walk-", "exclude_contains": "${run_id}", "path": "/x"}):
            with self.assertRaises(runner.ConfigError):
                runner.validate_step({"id": "x", "actor": "admin", "expect": {"status": 200}, "do": {"sweep": bad}}, "t")


if __name__ == "__main__":
    unittest.main()
