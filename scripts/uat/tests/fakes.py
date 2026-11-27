"""A fake QA for the runner tests: an HTTP server on 127.0.0.1 with the routes BP-01 and second_place need and a fake
token command. No network beyond it, no model. Shared by the test files of scripts/uat."""

import io
import json
import os
import re
import stat
import sys
import tempfile
import threading
import unittest
import urllib.parse
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
        self.users = dict(USERS)  # role -> keycloak user name: the fake knows the token of these users
        self.platform_roles = set()  # the roles that may read the tenant registry (the platform administrator)
        self.tenants = []  # the tenant registry: [{"slug": ..., "status": ...}]
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
        self.fx = {}  # fixture records by reference: the fx/find, fx/make, fx/drop routes
        self.fx_log = []  # (verb, name)
        self.fx_make_status = 201
        self.modules = {}  # installed module_id -> version (the /me/modules and /tenant/modules routes)
        self.module_catalog = {"org": "0.3.0", "assets": "0.31.0", "stock": "0.24.0"}  # what the product knows
        self.module_hidden_reads = 0  # the first N /me/modules reads show nothing (an install that raced ours)
        self.module_needs = {"assets": ["org"]}  # unmet dependency -> 422
        self.legal_entities = []  # the org_legal_entity rows a query finds
        self.app_name = None  # tenant_settings.app_name of the config-bundle
        self.access = {"admin": {"roles": ["TENANT_ADMIN"], "permissions": ["TenantSettingsManage"]},
                       "storekeeper": {"roles": ["STOREKEEPER"], "permissions": ["StockQuickCount", "CodesRead"]}}
        self.location_nodes = {}  # record id -> field values, for the real second_place fixture
        self.location_links = {}
        self.dead_after_health = False  # /health answers 503 from the second call on (QA down)
        # T-3034: the admission counters the node publishes on its public /health route
        self.admission = {"available": True, "tracked_tenants": 2, "in_use": 1, "cap": 28,
                          "reserved_headroom": 2, "pool_size": 30,
                          "rejections": {"global": 0, "tenant": 0}}
        self.admission_missing = False  # the node publishes no admission section
        self.capacity_503 = False  # the stock document post answers 503 "server at capacity"
        self.token_ttl = None  # authenticated requests a freshly minted token answers before expiring
        self.token_uses = {}
        self.token_serials = {}
        self.document_list_calls = 0
        self.document_list_faults = {}  # list call number -> non-2xx answer
        self.inbox_faults = {}  # inbox call number -> non-2xx answer
        self.task_items = None  # override both task listings; cursors are row offsets in this fake
        self.open_task_calls = 0
        self.open_task_faults = {}  # GET /tasks call number -> non-2xx answer
        # the platform tenant: the definitions of the tenant and the instances a run starts (G18)
        self.definitions = []  # [{"id", "name", "version", "status"}]
        self.definitions_forbidden = False  # the definitions list answers 403
        self.ensure_seeds_calls = []  # T-3125: (who, body) of POST .../stock/ensure-seeds
        self.ensure_seeds_status = 200  # the answer of ensure-seeds
        self.ensure_seeds_noop = False  # 200, but nothing is repaired and nothing listed
        self.instances = {}  # instance id -> {"status", "variables"}
        self.instance_starts = False  # POST /api/v1/instances may start an instance
        self.instance_status = "ACTIVE"  # the status a started instance gets
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
                    body = {"status": "ok", **({"sha": sha} if sha else {})}
                    if not state.admission_missing:
                        body["admission"] = state.admission
                    return self.reply(200, body)
                auth = self.headers.get("Authorization", "")
                if path.startswith("/qoimeks/"):
                    good = state.shared_value is not None and auth == f"Bearer {state.shared_value}"
                    state.shared_calls.append((method, path, good))
                    if not good:
                        return self.reply(401, {"title": "unauthorized"})
                    if method == "GET" and path.endswith("/movements"):
                        return self.reply(200, [])
                    return self.reply(404, {"title": "no route"})
                who = next((r for r, u in state.users.items() if auth == f"Bearer TOKEN_{u}_{SECRET}"), None)
                match = re.fullmatch(r"Bearer TOKEN_([^_]+)_(\d+)_" + SECRET, auth)
                if match:
                    role = next((r for r, u in state.users.items() if u == match.group(1)), None)
                    serial = int(match.group(2))
                    if role is not None:
                        if state.token_serials.get(role) != serial:
                            state.token_serials[role] = serial
                            state.token_uses[role] = 0
                        state.token_uses[role] += 1
                        if state.token_ttl is None or state.token_uses[role] <= state.token_ttl:
                            who = role
                state.log.append((method, self.path, who, body))
                if who is None:
                    return self.reply(401, {"title": "unauthorized"})
                return self.route(method, path, body, who)

        def task_page(self, items):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            page_size = int(query.get("page_size", ["200"])[0])
            start = int(query.get("cursor", ["0"])[0])
            page = items[start:start + page_size]
            end = start + len(page)
            return {"items": page, "next_cursor": str(end) if end < len(items) else None}

        def default_task_items(self, inbox=False):
            # a decoy for another document must never be picked
            items = [{"id": "task-decoy", "instance_id": "inst-decoy", "node_id": "post", "status": "PENDING"}]
            if not inbox or state.inbox_calls >= state.task_visible_after:
                items += [{k: t[k] for k in ("id", "instance_id", "node_id", "status")} for t in state.tasks]
            return items

        def route(self, method, path, body, who):
            base = "/api/v1/modules/stock"
            if getattr(state, "post_409", None) and method == "POST" and path.startswith(base + "/documents"):
                return self.reply(409, {"error": "conflict", "reason": state.post_409})
            if getattr(state, "capacity_503", False) and method == "POST" and path.startswith(base + "/documents"):
                return self.reply(503, {"status": 503, "title": "Service Unavailable",
                                        "detail": "server at capacity, retry shortly"})
            if path == "/api/v1/tenants":
                if who not in state.platform_roles:
                    return self.reply(403, {"title": "Forbidden", "detail": "insufficient permissions"})
                if method == "GET":
                    return self.reply(200, {"items": list(state.tenants), "next_cursor": None})
                if method == "POST":
                    slug = (body or {}).get("slug")
                    state.tenants.append({"slug": slug, "status": "active"})
                    return self.reply(201, {"slug": slug, "status": "active"})
            if method == "POST" and path.startswith("/api/v1/tenants/") and path.endswith("/deactivate"):
                if who not in state.platform_roles:
                    return self.reply(403, {"title": "Forbidden", "detail": "insufficient permissions"})
                slug = path.split("/")[4]
                for row in state.tenants:
                    if row["slug"] == slug:
                        row["status"] = "inactive"
                return self.reply(200, {"slug": slug, "status": "inactive"})
            if method == "GET" and path == base + "/balances":
                rows = [] if state.qty == 0 else [{"sku": "item-1", "quantity": f"{state.qty}.000000000", "unit_ref": "uom-1"}]
                return self.reply(200, {"rows": rows})
            if method == "POST" and path == "/api/v1/entities/query":
                entity = body.get("entity_type") if isinstance(body, dict) else None
                if entity == "org_legal_entity":
                    return self.reply(200, {"items": [{"record_id": "le-1", "code": e} for e in state.legal_entities
                                                      if not body["filters"] or e == body["filters"][0]["value"]]})
                if entity == "location_node":
                    records = state.location_nodes
                elif entity == "location_org_unit_link":
                    records = state.location_links
                else:
                    # the item of the run: its base unit is the fallback for the receipt when the place has no stock row
                    record_id = "item-1"
                    if isinstance(body, dict) and body.get("filters"):
                        record_id = body["filters"][0].get("value", record_id)
                    return self.reply(200, {"items": [{"record_id": record_id,
                                                        "field_values": {"base_uom_id": "uom-1"}}],
                                            "next_cursor": None})
                items = []
                for record_id, values in records.items():
                    if all(values.get(f["field"]) == f["value"] for f in body.get("filters", []) if f.get("op") == "eq"):
                        items.append({"record_id": record_id, "field_values": values})
                return self.reply(200, {"items": items, "next_cursor": None})
            if method == "POST" and path == "/api/v1/modules/locations/nodes":
                record_id = f"location-{len(state.location_nodes) + 1}"
                state.location_nodes[record_id] = dict(body, record_id=record_id, active=True)
                return self.reply(201, state.location_nodes[record_id])
            if method == "POST" and path.startswith("/api/v1/modules/locations/nodes/") and path.endswith("/retire"):
                record_id = path.rsplit("/", 2)[-2]
                node = state.location_nodes.get(record_id)
                if not node:
                    return self.reply(404, {"title": "not_found"})
                node["active"] = False
                return self.reply(200, node)
            if method == "POST" and path == "/api/v1/modules/locations/links":
                found = next((r for r in state.location_links.values()
                              if r["location_id"] == body["location_id"] and r["org_unit_id"] == body["org_unit_id"]), None)
                if found:
                    found["active"] = True
                    return self.reply(201, found)
                record_id = f"link-{len(state.location_links) + 1}"
                state.location_links[record_id] = dict(body, record_id=record_id, active=True)
                return self.reply(201, state.location_links[record_id])
            if method == "POST" and path == "/api/v1/modules/locations/links/retire":
                found = next((r for r in state.location_links.values()
                              if r["location_id"] == body["location_id"] and r["org_unit_id"] == body["org_unit_id"]), None)
                if not found:
                    return self.reply(404, {"title": "link_not_found"})
                found["active"] = False
                return self.reply(200, found)
            if method == "POST" and path == base + "/documents":
                if not body or "catalog_uom_id" not in body["lines"][0] or not body.get("org_unit_id"):
                    return self.reply(422, {"title": "field_required"})
                doc_id = f"doc-{len(state.docs) + 1}"
                state.docs[doc_id] = {"state": "draft", "qty": Decimal(body["lines"][0]["quantity"])}
                return self.reply(201, {"id": doc_id, "state": "draft"})
            if method == "GET" and path == base + "/documents":
                state.document_list_calls += 1
                if state.document_list_calls in state.document_list_faults:
                    return self.reply(state.document_list_faults[state.document_list_calls], {"title": "listing failed"})
                rows = [{"id": i, "kind": "receipt", "state": d["state"], "number": "R-" + i}
                        for i, d in reversed(list(state.docs.items()))]
                return self.reply(200, {"rows": rows, "next_cursor": None})
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
                if state.inbox_calls in state.inbox_faults:
                    return self.reply(state.inbox_faults[state.inbox_calls], {"title": "gone"})
                items = state.task_items if state.task_items is not None else self.default_task_items(inbox=True)
                return self.reply(200, self.task_page(items))
            if method == "GET" and path == "/api/v1/tasks":
                state.open_task_calls += 1
                if state.open_task_calls in state.open_task_faults:
                    return self.reply(state.open_task_faults[state.open_task_calls], {"title": "cursor_expired"})
                items = state.task_items if state.task_items is not None else self.default_task_items()
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                status = query.get("status", [None])[0]
                if status:
                    items = [item for item in items if item.get("status") == status]
                return self.reply(200, self.task_page(items))
            if method == "GET" and path.startswith("/api/v1/instances/"):
                inst = path.rsplit("/", 1)[1]
                if inst in state.instances:
                    row = state.instances[inst]
                    return self.reply(200, {"instance_id": inst, "status": row.get("status", "ACTIVE"),
                                            "variables": row.get("variables") or {}})
                if inst == "inst-decoy":
                    return self.reply(200, {"variables": {"document_id": "doc-other"}})
                task = next((t for t in state.tasks if t["instance_id"] == inst), None)
                return self.reply(200, {"variables": {"document_id": task["doc"]}}) if task else self.reply(404, {})
            if method == "POST" and path == "/api/v1/instances":
                if not state.instance_starts:
                    return self.reply(404, {"title": "no route"})
                instance_id = f"inst-started-{len(state.instances) + 1}"
                state.instances[instance_id] = {"status": state.instance_status, "variables": {}}
                return self.reply(201, {"instance_id": instance_id, "status": state.instance_status})
            if method == "POST" and path.startswith("/api/v1/instances/") and path.endswith("/cancel"):
                inst = path.split("/")[4]
                if inst not in state.instances:
                    return self.reply(404, {"title": "not found"})
                state.instances[inst]["status"] = "CANCELLED"
                return self.reply(200, {"instance_id": inst, "status": "CANCELLED"})
            if method == "POST" and path == "/api/v1/tenant/modules/stock/ensure-seeds":
                state.ensure_seeds_calls.append((who, body))
                if state.ensure_seeds_status != 200 or who != "admin":
                    return self.reply(state.ensure_seeds_status if who == "admin" else 403, {"title": "refused"})
                fixed = []
                if not state.ensure_seeds_noop:
                    for d in state.definitions:
                        if d.get("status") == "ARCHIVED":
                            d["status"] = "ACTIVE"
                            fixed.append(d["name"] + "@" + str(d.get("version")))
                return self.reply(200, {"module_id": "stock", "process_drafts": [], "process_activated": fixed})
            if method == "GET" and path == "/api/v1/definitions":
                if state.definitions_forbidden:
                    return self.reply(403, {"title": "Forbidden"})
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                name = (query.get("name", [""])[0] or "").lower()
                status = (query.get("status", [""])[0] or "").lower()
                rows = [dict(d) for d in state.definitions
                        if (not name or name in str(d.get("name", "")).lower())
                        and (not status or str(d.get("status", "")).lower() == status)]
                return self.reply(200, {"items": rows, "next_cursor": None})
            if method == "POST" and path.startswith("/api/v1/definitions/") and path.endswith("/activate"):
                ident = path.split("/")[4]
                row = next((d for d in state.definitions if d.get("id") == ident and d.get("status") == "ACTIVE"), None)
                if row is None:
                    return self.reply(404, {"title": "not found"})
                row["status"] = "DEPRECATED"
                state.definitions.append({"id": f"{ident}-v2", "name": row["name"], "version": "2.0.0",
                                          "status": "ACTIVE"})
                return self.reply(200, {"id": f"{ident}-v2", "name": row["name"], "version": "2.0.0",
                                        "status": "ACTIVE"})
            if method == "POST" and path.startswith("/api/v1/definitions/") and path.endswith("/rollback"):
                ident = path.split("/")[4]
                rows = [d for d in state.definitions if d.get("name") == ident or d.get("id") == ident]
                if not rows:
                    return self.reply(404, {"title": "not found"})
                active = next((d for d in rows if d.get("status") == "ACTIVE"), None)
                previous = [d for d in rows if d.get("status") == "DEPRECATED"]
                if active is None or not previous:
                    return self.reply(409, {"title": "no version to roll back to"})
                active["status"] = "DEPRECATED"
                target = previous[-1]
                target["status"] = "ACTIVE"
                return self.reply(200, {"id": target["id"], "name": target["name"],
                                        "version": target["version"], "status": "ACTIVE"})
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
                if method == "GET" and getattr(state, "shared_status", False):
                    exists = state.shared_value is not None
                    return self.reply(200, {"enabled": True, "exists": exists, "created_at": state.shared_created_at if exists else None,
                                            "created_by": "u1", "rotated_at": None})
                if method == "POST":
                    state.shared_value = SHARED_VALUE
                    return self.reply(201, {"value": SHARED_VALUE})
                if method == "DELETE":
                    if state.shared_value is None and getattr(state, "shared_status", False):
                        return self.reply(404, {"title": "Not Found"})
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
            if method == "GET" and path == "/api/v1/me/modules":
                if state.module_hidden_reads > 0:
                    state.module_hidden_reads -= 1
                    return self.reply(200, {"installed_modules": []})
                return self.reply(200, {"installed_modules": [{"module_id": m, "version": v} for m, v in state.modules.items()]})
            if method == "POST" and path == "/api/v1/tenant/modules":
                name = body["module_id"]
                if name not in state.module_catalog:
                    return self.reply(422, {"error": "unknown_module"})
                if name in state.modules:
                    return self.reply(409, {"error": "already_installed"})
                if any(d not in state.modules for d in state.module_needs.get(name, [])):
                    return self.reply(422, {"error": "dependency_unmet"})
                state.modules[name] = state.module_catalog[name]
                return self.reply(201, {"module_id": name})
            if method == "GET" and path == "/api/v1/tenant/config-bundle":
                return self.reply(200, {"tenant_settings": {"app_name": state.app_name} if state.app_name else {}})
            if method == "GET" and path == "/api/v1/me/access":
                return self.reply(200, dict(state.access[who], platform_tenant=False))
            if method == "POST" and path == "/api/v1/fx/find":
                found = state.fx.get(body["name"])
                return self.reply(200, {"items": [{"record_id": found}] if found else []})
            if method == "POST" and path == "/api/v1/fx/make":
                state.fx_log.append(("make", body["name"]))
                if state.fx_make_status != 201:
                    return self.reply(state.fx_make_status, {"title": "refused"})
                state.fx[body["name"]] = "rec-" + body["name"]
                return self.reply(201, {"record_id": state.fx[body["name"]]})
            if method == "POST" and path == "/api/v1/fx/drop":
                state.fx_log.append(("drop", body["name"]))
                state.fx.pop(body["name"], None)
                return self.reply(200, {"ok": True})
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


class FakeMailpit:
    """A fake Mailpit trap: the search endpoint the runner reads by recipient, and the messages it holds.
    The body of a message is never a part of the search answer (the real trap answers with a summary)."""

    def __init__(self):
        self.messages = []  # [{"ID", "Subject", "To": [{"Address"}], "Text"}]
        self.queries = []  # the queries the runner sent
        self.empty_searches = 0  # the first N searches answer with no message (a mail that arrives late)
        self.lock = threading.Lock()

    def add(self, subject, recipient, body="the body of the mail", mid=None, summary_subject=True,
            summary_recipient=True):
        """Put a mail into the trap. summary_subject=False / summary_recipient=False: the search answer carries
        no subject / no recipient (the runner then reads the message itself)."""
        with self.lock:
            mid = mid or f"m{len(self.messages) + 1}"
            self.messages.append({"ID": mid, "Subject": subject, "To": [{"Address": recipient}], "Text": body,
                                  "summary_subject": summary_subject, "summary_recipient": summary_recipient})
            return mid


def make_mailpit_handler(state):
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

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path == "/api/v1/search":
                term = (query.get("query", [""])[0] or "").strip()
                limit = int(query.get("limit", ["25"])[0] or 25)
                with state.lock:
                    state.queries.append(term)
                    rows = []
                    if state.empty_searches > 0:
                        state.empty_searches -= 1
                        return self.reply(200, {"messages": [], "total": 0})
                    for message in state.messages:
                        addresses = [str(a.get("Address", "")).lower() for a in message["To"]]
                        if term.lower().startswith("to:"):
                            wanted = term[3:].strip().lower()
                            if wanted not in addresses:
                                continue
                        row = {"ID": message["ID"]}
                        if message.get("summary_recipient", True):
                            row["To"] = message["To"]
                        if message.get("summary_subject", True):
                            row["Subject"] = message["Subject"]
                        rows.append(row)
                    return self.reply(200, {"messages": rows[:limit], "total": len(rows)})
            if parsed.path.startswith("/api/v1/message/"):
                mid = parsed.path.rsplit("/", 1)[1]
                with state.lock:
                    message = next((m for m in state.messages if m["ID"] == mid), None)
                if message is None:
                    return self.reply(404, {"title": "no message"})
                return self.reply(200, {"ID": message["ID"], "Subject": message["Subject"], "To": message["To"],
                                        "Text": message["Text"]})
            return self.reply(404, {"title": "no route"})

    return Handler


class FakeTrapCase:
    """Mixin: a fake Mailpit trap on 127.0.0.1 (no network beyond it)."""

    def start_trap(self):
        self.trap = FakeMailpit()
        self.trap_server = ThreadingHTTPServer(("127.0.0.1", 0), make_mailpit_handler(self.trap))
        self.trap_thread = threading.Thread(target=self.trap_server.serve_forever,
                                            kwargs={"poll_interval": 0.01}, daemon=True)
        self.trap_thread.start()
        self.addCleanup(self.stop_trap)
        self.trap_url = f"http://127.0.0.1:{self.trap_server.server_address[1]}"
        return self.trap_url

    def stop_trap(self):
        self.trap_server.shutdown()
        self.trap_server.server_close()


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
        script.write_text('#!/usr/bin/env bash\n[ "$1" = token ] || exit 2\n'
                          'counter="$(dirname "$0")/.token-counter"\nn=0\n[ ! -f "$counter" ] || n=$(cat "$counter")\n'
                          f'n=$((n + 1))\nprintf \'%s\' "$n" > "$counter"\nprintf \'Token: TOKEN_%s_%s_{SECRET}\\n\' "$2" "$n"\n')
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

    def run_process(self, process=None, inputs=None, actors=None, **kwargs):
        out = io.StringIO()
        r = runner.Runner(process or self.process(), base_url=self.base, tenant="qoimeks-qa2",
                          actors=USERS if actors is None else actors,
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


