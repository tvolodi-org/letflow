"""A fake QA for the runner tests: an HTTP server on 127.0.0.1 with the few routes BP-01 needs and a fake
token command. No network beyond it, no model. Shared by the test files of scripts/uat."""

import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import runner  # noqa: E402,F401

PROCESS_FILE = HERE.parent.parent.parent / "test" / "uat" / "processes" / "BP-01-receive-goods.json"
RUNNER_FILE = HERE.parent / "runner.py"
SECRET = "XYZ789"  # part of every fake token: it must never reach a log file
USERS = {"admin": "adm", "storekeeper": "sk"}
INPUTS = {"item": "item-1", "place": "place-1", "org_unit": "ou-1", "responsible": "resp-1"}
SHARED_VALUE = "ab" * 32  # the shared access value the fake hands out: 64 hex characters


def step_by_id(process, step_id):
    """The step with this id: a process file may grow a step, so an index is not a stable address."""
    return next(s for s in process["steps"] if s["id"] == step_id)


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
        self.shared_value = None  # the shared access value while one exists
        self.shared_calls = []  # (method, path, authorization ok)
        self.revoked = 0
        self.once = {}  # id -> stored body (an idempotent create)
        self.race_hits = 0
        self.dead_after_health = False  # /health answers 503 from the second call on (QA down)
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
                if path.startswith("/qoimeks/"):
                    good = state.shared_value is not None and auth == f"Bearer {state.shared_value}"
                    state.shared_calls.append((method, path, good))
                    if not good:
                        return self.reply(401, {"title": "unauthorized"})
                    if method == "GET" and path.endswith("/movements"):
                        return self.reply(200, [])
                    return self.reply(404, {"title": "no route"})
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
            if method == "POST" and path == "/api/v1/entities/query":
                # the item of the run: its base unit is the fallback for the receipt when the place has no stock row
                record_id = "item-1"
                if isinstance(body, dict) and body.get("filters"):
                    record_id = body["filters"][0].get("value", record_id)
                return self.reply(200, {"items": [{"record_id": record_id,
                                                    "field_values": {"base_uom_id": "uom-1"}}],
                                        "next_cursor": None})
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
            if path == "/api/v1/identity/shared-stock-access":
                if method == "POST":
                    state.shared_value = SHARED_VALUE
                    return self.reply(201, {"value": SHARED_VALUE})
                if method == "DELETE":
                    state.revoked += 1
                    state.shared_value = None
                    return self.reply(204)
            if method == "POST" and path == "/api/v1/once":  # an idempotent create: the same id answers 200
                key = (body or {}).get("id")
                if key in state.once:
                    return self.reply(200, state.once[key])
                state.once[key] = {"id": key, "n": len(state.once) + 1}
                return self.reply(201, state.once[key])
            if method == "POST" and path == "/api/v1/race":  # the first of two concurrent calls wins
                state.race_hits += 1
                return self.reply(201 if state.race_hits == 1 else 409, {"title": "conflict", "detail": "already_taken"})
            if method == "POST" and path == "/api/v1/refuse":
                return self.reply(422, {"title": "Unprocessable Entity", "detail": "output_refused", "status": 422})
            if method == "POST" and path == "/api/v1/redaction-secret-error":
                return self.reply(500, {"value": SHARED_VALUE})
            if method == "POST" and path == "/api/v1/redaction-echo":
                return self.reply(200, {"request": body, "authorization": self.headers.get("Authorization")})
            if method == "POST" and path == "/api/v1/echo":
                return self.reply(200, {"ok": True})
            if method == "GET" and path == "/api/v1/leak":
                return self.reply(200, {"note": "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl", "password": "hunter2"})
            return self.reply(404, {"title": "no route"})

        def do_GET(self):
            self.handle_any("GET")

        def do_POST(self):
            self.handle_any("POST")

        def do_DELETE(self):
            self.handle_any("DELETE")

        def do_PUT(self):
            self.handle_any("PUT")

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


