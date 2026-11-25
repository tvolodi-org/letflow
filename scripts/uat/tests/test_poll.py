"""Tests of the `poll` option of a GET step (T-2608): the runner repeats the read until the step's `expect` holds or
`within_s` ran out, so a read right after the start of an instance (the engine runs its steps afterwards) is judged
on the final answer. A small fake server whose answer changes, no network beyond it.

Run: python3 -B -m unittest -v scripts/uat/tests/test_poll.py   (from the repository root)
"""

import io
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import runner  # noqa: E402
from fakes import FakeServerCase  # noqa: E402


class Changing(BaseHTTPRequestHandler):
    """GET /api/v1/instances/i1: ACTIVE for the first `flip` reads, then COMPLETED."""

    calls = 0
    flip = 3

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            return self.reply({"status": "ok", "sha": "abc123"})
        if self.path != "/api/v1/instances/i1":
            return self.reply({})
        type(self).calls += 1
        status = "COMPLETED" if type(self).calls > type(self).flip else "ACTIVE"
        self.reply({"status": status})

    def reply(self, doc):
        data = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def step(poll=None, want="COMPLETED"):
    doc = {"id": "P1", "actor": "admin", "do": {"api": "GET", "path": "/api/v1/instances/i1"},
           "expect": {"status": 200, "json": {"$.status": want}}}
    if poll is not None:
        doc["poll"] = poll
    return doc


class Poll(FakeServerCase):
    def setUp(self):
        super().setUp()
        handler = type("H", (Changing,), {"calls": 0, "flip": 3})
        self.handler = handler
        self.other = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.other.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(self.other.server_close)
        self.addCleanup(self.other.shutdown)
        self.actors = {"admin": {"user": "admin-user", "tenant": "bpm-default",
                                 "base_url": f"http://127.0.0.1:{self.other.server_address[1]}"}}

    def run_it(self, *steps):
        out = io.StringIO()
        r = runner.Runner({"id": "POLL", "steps": list(steps)}, base_url=self.base, tenant="qoimeks-qa2",
                          actors=self.actors, run_dir=self.run_dir, inputs={}, poll_interval=0.01, out=out)
        return r.run()

    def row(self):
        return next(x for x in self.lines() if x["phase"] == "step" and x["step"] == "P1")

    def test_a_read_that_becomes_true_passes_and_counts_its_polls(self):
        code = self.run_it(step({"within_s": 5, "interval_s": 0.01}))
        self.assertEqual(0, code)
        self.assertEqual("pass", self.row()["verdict"])
        self.assertEqual(4, self.row()["polls"])

    def test_without_poll_the_first_answer_is_judged(self):
        code = self.run_it(step())
        self.assertEqual(1, code)
        self.assertEqual("fail", self.row()["verdict"])

    def test_a_read_that_never_becomes_true_fails_when_the_time_is_up(self):
        self.handler.flip = 10_000
        code = self.run_it(step({"within_s": 0.3, "interval_s": 0.01}))
        self.assertEqual(1, code)
        self.assertEqual("fail", self.row()["verdict"])
        self.assertGreater(self.row()["polls"], 1)

    def test_a_context_name_is_read_as_the_wait_time(self):
        proc = {"id": "POLL", "steps": [step({"within_s": "${wait}", "interval_s": 0.01})]}
        out = io.StringIO()
        r = runner.Runner(proc, base_url=self.base, tenant="qoimeks-qa2", actors=self.actors,
                          run_dir=self.run_dir, inputs={"wait": "5"}, poll_interval=0.01, out=out)
        self.assertEqual(0, r.run())

    def test_poll_is_refused_on_a_write_or_without_an_expect(self):
        post = {"id": "P2", "actor": "admin", "do": {"api": "POST", "path": "/x", "body": {}},
                "expect": {"status": 200}, "poll": {"within_s": 1}}
        with self.assertRaises(runner.ConfigError):
            runner.validate_step(post, "P2")
        bare = {"id": "P3", "actor": "admin", "do": {"api": "GET", "path": "/x"}, "poll": {"within_s": 1}}
        with self.assertRaises(runner.ConfigError):
            runner.validate_step(bare, "P3")
        bad = step({"within_s": "soon"})
        with self.assertRaises(runner.ConfigError):
            runner.validate_step(bad, "P1")
        runner.validate_step(step({"within_s": 5}), "P1")


if __name__ == "__main__":
    unittest.main()
