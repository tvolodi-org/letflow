"""residue_sweep (T-2869, D-208): remove the residue of a DISCARDED walk from ONE named QA tenant, by a reviewed LIST FILE.

    python3 -B scripts/uat/runner.py residue-sweep test/uat/sweeps/residue-sweep-qoimeks-qa2.json --tenant qoimeks-qa2

The list file names the tenant, its admin actor, the documents to reverse (id, number optional) and the tasks to
complete. The sweep refuses (exit 2, nothing requested) a tenant that is retired, is not the list file's tenant, a
base url that is not a QA host (or loopback for the tests). One line per item: done / already gone / refused
(<status>). "already gone" never fails the sweep; a refusal does (exit 1). No SQL, no clicks: the product's own
reversal route and task route, as the admin of that tenant. After the sweep the residue baseline is read again and
its sha256 is printed.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

REASON = {"reason_code": "other", "reason_text": "D-208 discarded walk"}
QA_HOST_RE = re.compile(r"^https://[a-z0-9-]+\.letflow\.qa\.bizdala\.com/?$")
LOOPBACK_RE = re.compile(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$")
FINAL = ("reversed", "cancelled", "rejected")


def load_list(path, runner):
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        raise runner.ConfigError(f"cannot read the sweep list {path}: {err}") from None
    if not isinstance(doc, dict) or not isinstance(doc.get("tenant"), str):
        raise runner.ConfigError(f"{path}: 'tenant' (string) is needed")
    for key in ("documents", "tasks"):
        items = doc.get(key, [])
        if not isinstance(items, list) or not all(isinstance(i, dict) and (i.get("id") or i.get("number")) for i in items):
            raise runner.ConfigError(f"{path}: '{key}' must be a list of objects with an id (documents: or a number)")
    if not isinstance(doc.get("admin"), str):
        raise runner.ConfigError(f"{path}: 'admin' (the keycloak user of the tenant admin) is needed")
    return doc


def guard(doc, tenant, base_url, runner):
    """Exit-2 checks before any request."""
    if doc["tenant"] != tenant:
        raise runner.ConfigError(f"tenant {tenant!r} is not the tenant of the list file ({doc['tenant']!r}): refused")
    retired_map = runner.load_retired_checked()
    runner.refuse_retired(retired_map, tenant, {"admin": doc["admin"]}, [base_url])
    if not (QA_HOST_RE.match(base_url) or LOOPBACK_RE.match(base_url)):
        raise runner.ConfigError(f"base url {base_url!r} is not a QA host: refused")
    if base_url.rstrip("/").startswith("https://") and f"//{tenant}." not in base_url:
        raise runner.ConfigError(f"base url {base_url!r} is not the host of the tenant {tenant!r}: refused")


def list_documents(run):
    """-> {id: {number, state}} of the tenant's documents (read-only, paged)."""
    docs, cursor = {}, None
    for _ in range(50):
        status, body, _ = run.request("admin", "GET", "/api/v1/modules/stock/documents?limit=100" + (f"&cursor={cursor}" if cursor else ""))
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"documents list answered {status}")
        for row in body.get("rows") or []:
            if isinstance(row, dict) and row.get("id") is not None:
                docs[str(row["id"])] = {"number": row.get("number"), "state": str(row.get("state"))}
        cursor = body.get("next_cursor")
        if not cursor or not body.get("rows"):
            break
    return docs


def sweep(run, doc, out):
    """-> exit code: 0 when every item is done or already gone, 1 when one was refused."""
    refused = 0
    known = list_documents(run)
    before_tasks = set(run._open_tasks())
    for item in doc.get("documents", []):
        ident = str(item["id"]) if item.get("id") else next((i for i, d in known.items() if d["number"] == item.get("number")), None)
        label = item.get("number") or ident
        row = known.get(ident) if ident else None
        if row is None or row["state"] in FINAL:
            print(f"document {label}: already gone", file=out)
            continue
        status, _, _ = run.request("admin", "POST", f"/api/v1/modules/stock/documents/{ident}/reverse", dict(REASON))
        if status == 404:
            print(f"document {label}: already gone", file=out)
        elif status == 200:
            print(f"document {label}: done (reversed)", file=out)
        else:
            refused += 1
            print(f"document {label}: refused ({status})", file=out)
    # the reversals open Reverse tasks of their own: those are part of the sweep, they are completed too
    after = set(run._open_tasks())
    new_tasks = sorted(after - before_tasks)
    wanted = [str(t["id"]) for t in doc.get("tasks", []) if t.get("id")]
    open_now = after
    for task_id in wanted + [t for t in new_tasks if t not in wanted]:
        if task_id not in open_now:
            print(f"task {task_id}: already gone", file=out)
            continue
        run.request("admin", "POST", f"/api/v1/tasks/{task_id}/claim", {})  # a claim the user already holds may answer 409
        status, _, _ = run.request("admin", "POST", f"/api/v1/tasks/{task_id}/complete", {})
        if status == 200:
            print(f"task {task_id}: done (completed)", file=out)
        elif status == 404:
            print(f"task {task_id}: already gone", file=out)
        else:
            refused += 1
            print(f"task {task_id}: refused ({status})", file=out)
    return 1 if refused else 0


def baseline_sha(run):
    docs, tasks = run._snapshot()
    if docs is None:
        raise RuntimeError(f"baseline unavailable: {tasks}")
    blob = json.dumps({"docs": docs, "tasks": tasks}, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest(), len(docs), len(tasks)


def main(args, runner, out=None) -> int:
    out = out or sys.stdout
    try:
        doc = load_list(args.list_file, runner)
        tenant = args.tenant
        base_url = (args.base_url or runner.base_url_for(tenant, args.base_url_template)).rstrip("/")
        guard(doc, tenant, base_url, runner)
        actors = runner.normalize_actors({"admin": doc["admin"]})
        run_dir = runner.new_run_dir(args, "residue-sweep-" + tenant)
    except runner.ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    run = runner.Runner([{"id": "residue-sweep", "steps": []}], base_url=base_url, tenant=tenant, actors=actors,
                        run_dir=run_dir, poll_interval=0.5, out=out)
    try:
        code = sweep(run, doc, out)
        sha, n_docs, n_tasks = baseline_sha(run)
    except (runner.RunnerError, RuntimeError) as err:
        print(f"residue-sweep: failed: {err}", file=out)
        return 1
    print(f"residue baseline of {tenant}: sha256 {sha} ({n_docs} open documents, {n_tasks} open tasks)", file=out)
    return code
