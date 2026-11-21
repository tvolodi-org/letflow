"""Tests of scripts/uat/runner.py: no network beyond a fake server on 127.0.0.1, no model.

Run: python3 -B -m unittest -v scripts/uat/tests/test_runner.py   (from the repository root)
"""

import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402

PROCESS_FILE = HERE.parent.parent.parent / "test" / "uat" / "processes" / "BP-01-receive-goods.json"
RUNNER_FILE = HERE.parent / "runner.py"
SECRET = "XYZ789"  # part of every fake token: it must never reach a log file
USERS = {"admin": "adm", "storekeeper": "sk"}
INPUTS = {"item": "item-1", "place": "place-1", "org_unit": "ou-1", "responsible": "resp-1"}


class FakeStock:
    """The few routes BP-01 needs, with a switchable fault for each test."""

    def __init__(self):
        self.qty = Decimal("7")
        self.docs = {}
        self.tasks = []
        self.log = []  # (method, path, who, body)
        self.health_calls = 0
        self.sha_at_end = None  # a sha served from the second /health call on
        self.no_sha = False
        self.inbox_calls = 0
        self.task_visible_after = 1  # inbox calls before the post task shows up
        self.post_adds_nothing = False
        self.lock = threading.Lock()

    def sha(self):
        self.health_calls += 1
        if self.no_sha:
            return None
        return self.sha_at_end if (self.sha_at_end and self.health_calls >= 2) else "abc123"

    def calls(self, method, suffix):
        return [c for c in self.log if c[0] == method and c[1].split("?")[0].endswith(suffix)]


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body=None):
            data = json.dumps(body).encode() if body is not None else b""
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def handle_any(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw) if raw else None
            path = self.path.split("?")[0]
            with state.lock:
                if path == "/health":
                    sha = state.sha()
                    return self.reply(200, {"status": "ok", **({"sha": sha} if sha else {})})
                auth = self.headers.get("Authorization", "")
                who = next((r for r, u in USERS.items() if auth == f"Bearer TOKEN_{u}_{SECRET}"), None)
                state.log.append((method, self.path, who, body))
                if who is None:
                    return self.reply(401, {"title": "unauthorized"})
                return self.route(method, path, body, who)

        def route(self, method, path, body, who):
            base = "/api/v1/modules/stock"
            if method == "GET" and path == base + "/balances":
                rows = [] if state.qty == 0 else [{"sku": "item-1", "quantity": f"{state.qty}.000000000", "unit_ref": "uom-1"}]
                return self.reply(200, {"rows": rows})
            if method == "POST" and path == base + "/documents":
                if not body or "catalog_uom_id" not in body["lines"][0] or not body.get("org_unit_id"):
                    return self.reply(422, {"title": "field_required"})
                doc_id = f"doc-{len(state.docs) + 1}"
                state.docs[doc_id] = {"state": "draft", "qty": Decimal(body["lines"][0]["quantity"])}
                return self.reply(201, {"id": doc_id, "state": "draft"})
            if path.startswith(base + "/documents/"):
                parts = path[len(base + "/documents/"):].split("/")
                doc = state.docs.get(parts[0])
                if doc is None:
                    return self.reply(404, {"title": "not found"})
                if method == "GET" and len(parts) == 1:
                    out = {"id": parts[0], "state": doc["state"]}
                    if doc["state"] == "posted":
                        out["entry_id"] = "entry-1"
                    return self.reply(200, out)
                if method == "POST" and parts[1] == "issue":
                    doc["state"] = "issued"
                    state.tasks.append({"id": f"task-{len(state.tasks) + 1}", "instance_id": f"inst-{len(state.tasks) + 1}",
                                        "node_id": "post", "status": "PENDING", "doc": parts[0]})
                    return self.reply(200, {"id": parts[0], "state": "issued"})
                if method == "POST" and parts[1] == "reverse":
                    if body.get("reason_code") not in ("wrong_document", "wrong_quantity", "wrong_master_data", "other"):
                        return self.reply(422, {"title": "reason_invalid"})
                    state.tasks.append({"id": f"task-{len(state.tasks) + 1}", "instance_id": f"inst-{len(state.tasks) + 1}",
                                        "node_id": "reverse", "status": "PENDING", "doc": parts[0]})
                    return self.reply(200, {"id": parts[0], "state": "posted"})
            if method == "GET" and path == "/api/v1/tasks/inbox":
                state.inbox_calls += 1
                items = []
                # a decoy for another document must never be picked
                items.append({"id": "task-decoy", "instance_id": "inst-decoy", "node_id": "post", "status": "PENDING"})
                if state.inbox_calls >= state.task_visible_after:
                    items += [{k: t[k] for k in ("id", "instance_id", "node_id", "status")} for t in state.tasks]
                return self.reply(200, {"items": items, "next_cursor": None})
            if method == "GET" and path.startswith("/api/v1/instances/"):
                inst = path.rsplit("/", 1)[1]
                if inst == "inst-decoy":
                    return self.reply(200, {"variables": {"document_id": "doc-other"}})
                task = next((t for t in state.tasks if t["instance_id"] == inst), None)
                return self.reply(200, {"variables": {"document_id": task["doc"]}}) if task else self.reply(404, {})
            if method == "POST" and path.startswith("/api/v1/tasks/"):
                task_id, action = path.rsplit("/", 2)[1:]
                task = next((t for t in state.tasks if t["id"] == task_id), None)
                if task is None:
                    return self.reply(404, {})
                if action == "complete":
                    if body != {}:
                        return self.reply(422, {"title": "body must be empty"})
                    task["status"] = "COMPLETED"
                    doc = state.docs[task["doc"]]
                    if task["node_id"] == "post":
                        doc["state"] = "posted"
                        if not state.post_adds_nothing:
                            state.qty += doc["qty"]
                    else:
                        doc["state"] = "reversed"
                        state.qty -= doc["qty"]
                return self.reply(200, {"status": "ok"})
            if method == "POST" and path == "/api/v1/echo":
                return self.reply(200, {"ok": True})
            if method == "GET" and path == "/api/v1/leak":
                return self.reply(200, {"note": "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl", "password": "hunter2"})
            return self.reply(404, {"title": "no route"})

        def do_GET(self):
            self.handle_any("GET")

        def do_POST(self):
            self.handle_any("POST")

    return Handler


class FakeServerCase(unittest.TestCase):
    def setUp(self):
        self.state = FakeStock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.state))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.stop_server)
        # the fake token command: TEAM_ROOT/project/scripts/uat_creds.sh token <user>
        scripts = Path(self.tmp.name) / "team" / "project" / "scripts"
        scripts.mkdir(parents=True)
        script = scripts / "uat_creds.sh"
        script.write_text(f'#!/usr/bin/env bash\n[ "$1" = token ] || exit 2\nprintf \'Token: TOKEN_%s_{SECRET}\\n\' "$2"\n')
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        self.team_root = str(Path(self.tmp.name) / "team")
        env = mock_env(TEAM_ROOT=self.team_root)
        env.start()
        self.addCleanup(env.stop)
        self.run_dir = Path(self.tmp.name) / "run"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()

    def process(self):
        return runner.load_process(PROCESS_FILE)

    def run_process(self, process=None, inputs=None, **kwargs):
        out = io.StringIO()
        r = runner.Runner(process or self.process(), base_url=self.base, tenant="qoimeks-qa2", actors=USERS,
                          run_dir=self.run_dir, inputs=dict(INPUTS if inputs is None else inputs),
                          poll_interval=0.01, out=out, **kwargs)
        code = r.run()
        return code, r

    def lines(self):
        return [json.loads(x) for x in (self.run_dir / "run.jsonl").read_text().splitlines()]

    def verdicts(self):
        return {(x["phase"], x["step"]): x["verdict"] for x in self.lines()}


def mock_env(**values):
    from unittest import mock

    return mock.patch.dict(os.environ, values)


class ExpressionAndSubstitution(unittest.TestCase):
    def test_arithmetic_and_precedence(self):
        ctx = {"a": "5.000000000", "b": 3}
        self.assertEqual(runner.eval_expression("a + 5", ctx), "10")
        self.assertEqual(runner.eval_expression("a + b * 2", ctx), "11")
        self.assertEqual(runner.eval_expression("(a + b) * 2", ctx), "16")
        self.assertEqual(runner.eval_expression("-b + 10 / 4", ctx), "-0.5")

    def test_expression_errors(self):
        with self.assertRaises(runner.Undefined):
            runner.eval_expression("missing + 1", {})
        with self.assertRaises(runner.RunnerError):
            runner.eval_expression("1 / 0", {})
        with self.assertRaises(runner.RunnerError):
            runner.eval_expression("1 + ", {})
        with self.assertRaises(runner.RunnerError):
            runner.eval_expression("x + 1", {"x": "abc"})

    def test_substitute(self):
        ctx = {"id": "d-1", "n": "4", "obj": {"k": 1}}
        self.assertEqual(runner.substitute("/docs/${id}/x", ctx), "/docs/d-1/x")
        self.assertEqual(runner.substitute("${obj}", ctx), {"k": 1})  # a lone name keeps its type
        self.assertEqual(runner.substitute("${n + 1}", ctx), "5")
        self.assertEqual(runner.substitute({"a": ["${id}", 3]}, ctx), {"a": ["d-1", 3]})
        with self.assertRaises(runner.Undefined):
            runner.substitute("${nope}", ctx)

    def test_json_path(self):
        doc = {"a": {"b": [{"c": 1}, {"c": 2}]}, "k-1": True}
        self.assertEqual(runner.json_path(doc, "$.a.b[1].c"), (True, 2))
        self.assertEqual(runner.json_path(doc, "$.a.b[5].c"), (False, None))
        self.assertEqual(runner.json_path(doc, "$.nope"), (False, None))
        self.assertEqual(runner.json_path(doc, '$["k-1"]'), (True, True))
        self.assertEqual(runner.json_path(doc, "$"), (True, doc))


class Assertions(unittest.TestCase):
    def check(self, expect, status=200, body=None):
        results = runner.run_assertions(expect, status, body)
        # a json-only expectation also gets the default 2xx status row: keep the rows the test is about
        return [r["ok"] for r in results if r["what"] != "status" or "json" not in expect]

    def test_status(self):
        self.assertEqual(self.check({"status": 201}, 201), [True])
        self.assertEqual(self.check({"status": 201}, 200), [False])
        self.assertEqual(self.check({"status": [200, 201]}, 201), [True])
        self.assertEqual(self.check({}, 204), [True])  # no status given: any 2xx
        self.assertEqual(self.check({}, 500), [False])

    def test_equals_numeric_and_text(self):
        body = {"q": "10.000000000", "s": "abc", "n": 10}
        self.assertEqual(self.check({"json": {"$.q": {"equals": "10"}, "$.n": "10.0", "s": "abc"}}, 200, body), [True] * 3)
        self.assertEqual(self.check({"json": {"$.q": {"equals": "11"}}}, 200, body), [False])
        self.assertEqual(self.check({"json": {"$.s": "ABC"}}, 200, body), [False])

    def test_contains_regex_absent_exists(self):
        body = {"s": "hello world", "l": [1, 2], "m": {"x": 1}, "z": None}
        ok = {"json": {"$.s": {"contains": "lo w"}, "$.l": {"contains": 2}, "$.m": {"contains": "x"}}}
        self.assertEqual(self.check(ok, 200, body), [True] * 3)
        self.assertEqual(self.check({"json": {"$.s": {"regex": "wor.d$"}}}, 200, body), [True])
        self.assertEqual(self.check({"json": {"$.s": {"regex": "^xyz"}}}, 200, body), [False])
        self.assertEqual(self.check({"json": {"$.gone": {"absent": True}, "$.z": {"absent": True}}}, 200, body), [True, True])
        self.assertEqual(self.check({"json": {"$.s": {"absent": True}}}, 200, body), [False])
        self.assertEqual(self.check({"json": {"$.s": {"exists": True}, "$.gone": {"exists": False}}}, 200, body), [True, True])
        self.assertEqual(self.check({"json": {"$.gone": {"exists": True}}}, 200, body), [False])

    def test_default_for_a_missing_path(self):
        self.assertEqual(self.check({"json": {"$.rows[0].quantity": {"equals": "0", "default": "0"}}}, 200, {"rows": []}), [True])
        self.assertEqual(self.check({"json": {"$.rows[0].quantity": {"equals": "0"}}}, 200, {"rows": []}), [False])


class Loader(unittest.TestCase):
    def write(self, data):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        self.addCleanup(os.unlink, tmp.name)
        json.dump(data, tmp)
        tmp.close()
        return tmp.name

    def test_bp01_loads(self):
        process = runner.load_process(PROCESS_FILE)
        self.assertEqual(process["id"], "BP-01")
        self.assertEqual([s["id"] for s in process["steps"]], ["s0", "s1", "s2", "s3", "s4", "s5"])
        self.assertEqual([s["id"] for s in process["cleanup"]], ["c1", "c2", "c3"])

    def test_bad_files_are_refused(self):
        step = {"id": "a", "actor": "x", "do": {"api": "GET", "path": "/p"}}
        for bad in ({}, {"id": "P", "steps": []}, {"id": "P", "steps": [{"id": "a"}]},
                    {"id": "P", "steps": [step, dict(step)]},
                    {"id": "P", "steps": [{"id": "a", "actor": "x", "do": {"api": "GET"}}]},
                    {"id": "P", "steps": [{"id": "a", "actor": "x", "do": {"wait_task": {"step": "post"}}}]}):
            with self.assertRaises(runner.ConfigError, msg=str(bad)):
                runner.load_process(self.write(bad))
        with self.assertRaises(runner.ConfigError):
            runner.load_process("/nonexistent/process.json")


class RunBP01(FakeServerCase):
    def test_happy_path_and_cleanup(self):
        code, r = self.run_process()
        self.assertEqual(code, 0, (self.run_dir / "summary.md").read_text())
        verdicts = self.verdicts()
        for key in [("step", s) for s in ("s0", "s1", "s2", "s3", "s4", "s5")] + [("cleanup", c) for c in ("c1", "c2", "c3")]:
            self.assertEqual(verdicts[key], "pass", key)
        self.assertEqual(self.state.qty, Decimal("7"))  # reversed: back to the start
        ctx = json.loads((self.run_dir / "context.json").read_text())
        self.assertEqual(ctx["balance_before"], "7.000000000")
        self.assertEqual(ctx["balance_after"], "12.000000000")
        self.assertEqual(ctx["balance_end"], "7.000000000")
        self.assertEqual(ctx["receipt_doc_id"], "doc-1")
        self.assertEqual(ctx["receipt_entry_id"], "entry-1")
        self.assertEqual(ctx["uom"], "uom-1")  # read from the first balance row
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("build sha at start: abc123   at end: abc123", summary)
        self.assertIn("verdict: **PASS**", summary)

    def test_each_actor_uses_its_own_token_and_bodies_are_empty_for_tasks(self):
        self.run_process()
        by_step = {(c[0], c[1].split("?")[0]): c[2] for c in self.state.log}
        self.assertEqual(by_step[("POST", "/api/v1/modules/stock/documents")], "storekeeper")
        self.assertEqual(by_step[("POST", "/api/v1/modules/stock/documents/doc-1/issue")], "storekeeper")
        self.assertEqual(by_step[("POST", "/api/v1/tasks/task-1/complete")], "admin")
        claims = self.state.calls("POST", "/claim")
        completes = self.state.calls("POST", "/complete")
        self.assertEqual(len(claims), 2)  # post and reverse task
        self.assertEqual([c[3] for c in completes], [{}, {}])
        create = self.state.calls("POST", "/documents")[0][3]
        self.assertEqual(create["kind"], "receipt")
        self.assertEqual(create["lines"], [{"catalog_item_id": "item-1", "catalog_uom_id": "uom-1", "quantity": "5"}])
        self.assertRegex(create["event_time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        reverse = self.state.calls("POST", "/reverse")[0][3]
        self.assertEqual(reverse["reason_code"], "other")

    def test_the_wait_task_picks_the_task_of_the_document_not_a_decoy(self):
        self.run_process()
        completes = [c[1] for c in self.state.calls("POST", "/complete")]
        self.assertNotIn("/api/v1/tasks/task-decoy/complete", completes)

    def test_input_uom_wins_over_the_balance_row(self):
        code, _ = self.run_process(inputs=dict(INPUTS, uom="uom-given"))
        self.assertEqual(code, 0)
        self.assertEqual(self.state.calls("POST", "/documents")[0][3]["lines"][0]["catalog_uom_id"], "uom-given")

    def test_zero_balance_start_uses_default_and_needs_uom(self):
        self.state.qty = Decimal("0")
        code, _ = self.run_process(inputs=dict(INPUTS, uom="uom-given"))
        self.assertEqual(code, 0)
        self.assertEqual(self.state.qty, Decimal("0"))  # the empty balance (no row) read as 0 at start and end

    def test_zero_balance_without_uom_fails_clearly(self):
        self.state.qty = Decimal("0")
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        line = next(x for x in self.lines() if x["step"] == "s0")
        self.assertEqual(line["verdict"], "error")
        self.assertIn("uom", line["error"])


class Failures(FakeServerCase):
    def test_assertion_failure_stops_the_steps_but_cleanup_still_runs(self):
        self.state.post_adds_nothing = True  # s4: the balance does not grow
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        v = self.verdicts()
        self.assertEqual(v[("step", "s3")], "pass")
        self.assertEqual(v[("step", "s4")], "fail")
        self.assertEqual(v[("step", "s5")], "skipped")
        self.assertEqual(len(self.state.calls("POST", "/reverse")), 1)  # the cleanup ran
        self.assertEqual(v[("cleanup", "c1")], "pass")
        self.assertEqual(v[("cleanup", "c2")], "pass")
        failing = next(x for x in self.lines() if x["step"] == "s4")
        self.assertIn("expected", failing["error"])
        self.assertTrue(any(not a["ok"] for a in failing["asserted"]))
        self.assertIn("verdict: **FAIL**", (self.run_dir / "summary.md").read_text())

    def test_an_exception_in_a_step_does_not_skip_the_cleanup(self):
        process = self.process()
        # s5 reads a variable that does not exist: a RunnerError after the post task was completed
        process["steps"][5]["do"]["path"] = "/api/v1/modules/stock/documents/${nope}"
        code, _ = self.run_process(process)
        self.assertEqual(code, 1)
        v = self.verdicts()
        self.assertEqual(v[("step", "s5")], "error")
        self.assertEqual(v[("cleanup", "c1")], "pass")
        self.assertEqual(self.state.qty, Decimal("7"))

    def test_cleanup_failure_fails_the_run(self):
        process = self.process()
        process["cleanup"][0]["do"]["body"]["reason_code"] = "not-a-reason"
        process["cleanup"][1]["do"]["wait_task"]["within_s"] = 0.1  # no Reverse task will ever exist
        code, _ = self.run_process(process)
        self.assertEqual(code, 1)
        self.assertEqual(self.verdicts()[("cleanup", "c1")], "fail")
        self.assertEqual(self.verdicts()[("cleanup", "c2")], "error")  # best effort: the next cleanup step still ran
        self.assertEqual(self.verdicts()[("step", "s5")], "pass")

    def test_cleanup_is_skipped_when_nothing_was_posted(self):
        process = self.process()
        process["steps"][1]["do"]["body"]["org_unit_id"] = ""  # the fake refuses: 422
        code, _ = self.run_process(process)
        self.assertEqual(code, 1)
        v = self.verdicts()
        self.assertEqual(v[("step", "s1")], "fail")
        self.assertEqual(v[("cleanup", "c1")], "skipped")
        self.assertEqual(self.state.calls("POST", "/reverse"), [])

    def test_wait_task_polls_until_the_task_appears(self):
        self.state.task_visible_after = 4
        code, _ = self.run_process()
        self.assertEqual(code, 0)
        s3 = next(x for x in self.lines() if x["step"] == "s3")
        self.assertGreaterEqual(s3["polls"], 4)

    def test_wait_task_times_out(self):
        self.state.task_visible_after = 10**6
        process = self.process()
        process["steps"][3]["do"]["wait_task"]["within_s"] = 0.2
        code, _ = self.run_process(process)
        self.assertEqual(code, 1)
        s3 = next(x for x in self.lines() if x["step"] == "s3")
        self.assertEqual(s3["verdict"], "error")
        self.assertIn("timeout", s3["error"])
        self.assertEqual(self.state.calls("POST", "/claim"), [])
        self.assertEqual(self.verdicts()[("cleanup", "c1")], "skipped")

    def test_build_moved_fails_the_run(self):
        self.state.sha_at_end = "def456"
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        self.assertEqual(self.verdicts()[("step", "s5")], "pass")  # every step passed, the build did not stay
        summary = (self.run_dir / "summary.md").read_text()
        self.assertIn("build moved", summary)
        self.assertIn("abc123", summary)
        self.assertIn("def456", summary)
        build = next(x for x in self.lines() if x["step"] == "build")
        self.assertEqual(build["verdict"], "fail")

    def test_no_build_sha_means_the_run_does_not_start(self):
        self.state.no_sha = True
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        self.assertEqual(self.state.log, [])
        self.assertEqual([x["step"] for x in self.lines()], ["health"])

    def test_missing_team_root_is_a_step_error(self):
        with mock_env():
            os.environ.pop("TEAM_ROOT", None)
            code, _ = self.run_process()
        self.assertEqual(code, 1)
        s0 = next(x for x in self.lines() if x["step"] == "s0")
        self.assertIn("TEAM_ROOT", s0["error"])

    def test_wrong_token_answer_is_a_401_failure(self):
        # an actor whose token the fake does not know: the answer is 401, the step fails
        script = Path(self.team_root) / "project" / "scripts" / "uat_creds.sh"
        script.write_text("#!/usr/bin/env bash\nprintf 'Token: not-a-valid-one\\n'\n")
        code, _ = self.run_process()
        self.assertEqual(code, 1)
        s0 = next(x for x in self.lines() if x["step"] == "s0")
        self.assertEqual(s0["status"], 401)


class NoSecrets(FakeServerCase):
    def all_text(self):
        return "".join((self.run_dir / n).read_text() for n in ("run.jsonl", "summary.md", "context.json"))

    def test_no_token_in_any_output_file(self):
        code, _ = self.run_process()
        self.assertEqual(code, 0)
        text = self.all_text()
        self.assertNotIn(SECRET, text)
        self.assertNotIn("TOKEN_", text)
        self.assertNotIn("Bearer", text)

    def test_secret_keys_and_jwts_are_masked(self):
        process = {
            "id": "SEC",
            "steps": [
                {"id": "a", "actor": "admin",
                 "do": {"api": "POST", "path": "/api/v1/echo", "body": {"password": "hunter2", "nested": {"api_key": "k-123"}, "ok": "visible"}},
                 "expect": {"status": 200}},
                {"id": "b", "actor": "admin", "do": {"api": "GET", "path": "/api/v1/leak"},
                 "expect": {"status": 200, "json": {"$.note": {"regex": "eyJ"}, "$.password": {"exists": True}}}},
            ],
        }
        code, _ = self.run_process(process, inputs={})
        self.assertEqual(code, 0)
        text = self.all_text()
        self.assertNotIn("hunter2", text)
        self.assertNotIn("k-123", text)
        self.assertNotIn("eyJhbGci", text)
        self.assertIn("visible", text)
        line = self.lines()[1]
        self.assertEqual(line["request"]["password"], "***")

    def test_a_token_that_slips_into_an_error_is_scrubbed(self):
        r = runner.Runner(self.process(), base_url=self.base, tenant="t", actors=USERS, run_dir=self.run_dir, inputs=INPUTS,
                          out=io.StringIO())
        r.secret_values.add("my-secret-token")
        self.run_dir.mkdir(parents=True)
        r.write_line({"phase": "step", "step": "x", "verdict": "error", "error": "boom my-secret-token boom", "ms": 1})
        self.assertNotIn("my-secret-token", (self.run_dir / "run.jsonl").read_text())


class Cli(FakeServerCase):
    def main(self, *extra):
        args = ["run", str(PROCESS_FILE), "--tenant", "qoimeks-qa2", "--base-url", self.base,
                "--actors", "admin=adm,storekeeper=sk", "--run-dir", str(self.run_dir), "--poll-interval", "0.01", *extra]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = runner.main(args)
        return code, out.getvalue(), err.getvalue()

    def test_help_works(self):
        done = subprocess.run([sys.executable, "-B", str(RUNNER_FILE), "--help"], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0)
        self.assertIn("run", done.stdout)
        done = subprocess.run([sys.executable, "-B", str(RUNNER_FILE), "run", "--help"], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0)
        self.assertIn("--actors", done.stdout)
        self.assertIn("--input", done.stdout)

    def test_run_with_inputs_from_the_command_line(self):
        code, out, err = self.main("--input", "item=item-1", "place=place-1", "org_unit=ou-1", "responsible=resp-1")
        self.assertEqual(code, 0, out + err)
        self.assertIn("BP-01: PASS", out)
        self.assertNotIn(SECRET, out + err)

    def test_inputs_from_a_context_file_and_command_line_override(self):
        path = Path(self.tmp.name) / "in.json"
        path.write_text(json.dumps(dict(INPUTS, item="wrong")))
        code, out, err = self.main("--input-file", str(path), "--input", "item=item-1")
        self.assertEqual(code, 0, out + err)

    def test_missing_input_is_a_usage_error_and_runs_nothing(self):
        code, out, err = self.main("--input", "item=item-1")
        self.assertEqual(code, 2)
        self.assertIn("inputs missing", err)
        self.assertEqual(self.state.log, [])

    def test_missing_actor_is_a_usage_error(self):
        args = ["run", str(PROCESS_FILE), "--tenant", "t", "--base-url", self.base, "--actors", "admin=adm",
                "--input", "item=1", "place=2", "org_unit=3", "responsible=4"]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = runner.main(args)
        self.assertEqual(code, 2)
        self.assertIn("storekeeper", err.getvalue())

    def test_an_existing_run_log_is_not_overwritten(self):
        self.run_dir.mkdir(parents=True)
        (self.run_dir / "run.jsonl").write_text("x\n")
        code, out, err = self.main("--input", "item=item-1", "place=place-1", "org_unit=ou-1", "responsible=resp-1")
        self.assertEqual(code, 2)
        self.assertEqual((self.run_dir / "run.jsonl").read_text(), "x\n")


if __name__ == "__main__":
    unittest.main()
