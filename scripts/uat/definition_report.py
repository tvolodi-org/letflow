#!/usr/bin/env python3
"""definition_report (T-2982): READ-ONLY report of the stock process definitions of ONE QA tenant.

    python3 -B scripts/uat/runner.py definition-report --tenant qoimeks-qa2 --admin qoimeks-qa2-admin

Why: the stock `issue`/`post` routes answer 409 `definition_not_active` when Posting.ensure_active/3 finds no usable
stock_<kind> definition, and that function logs nothing on three of its branches. This report shows what it sees:
for every definition of the tenant whose name starts with `stock` or whose `owner_module` is `stock`, every version
row (id, version, status, owner_module, activation_state, needs_reactivation_*, created_by, created_at, updated_at)
and one verdict line per name:

  ok            an ACTIVE row stamped owner_module=stock exists (ensure_active would pass)
  foreign       an ACTIVE row exists that is not stamped stock          (ensure_active: foreign_definition)
  no-active     no ACTIVE row; the newest row is a DRAFT                (ensure_active would activate it)
  dead-newest   no ACTIVE row; the newest row is not a DRAFT            (ensure_active: activation refused)

The report only GETs /api/v1/definitions as the tenant admin: no SQL, no write, same safety guards as
residue-sweep (QA host or loopback only, retired tenants refused). The definitions list does not carry a history or
the minute/actor of a status change: `updated_at` and `created_by` are the nearest the API gives, and the report
says so in its last line. Output also goes to <run-dir>/definition_report.json. Exit 0 always when the read worked,
2 on a refused guard, 1 when the read failed.
"""

from __future__ import annotations

import json
import re
import sys

QA_HOST_RE = re.compile(r"^https://[a-z0-9-]+\.letflow\.qa\.bizdala\.com/?$")
LOOPBACK_RE = re.compile(r"^http://(127\.0\.0\.1|localhost)(:\d+)?/?$")
FIELDS = ("id", "name", "version", "status", "owner_module", "owner_module_version", "activation_state",
          "needs_reactivation_reason", "needs_reactivation_at", "created_by", "created_at", "updated_at")


def is_stock(row):
    return str(row.get("name") or "").startswith("stock") or row.get("owner_module") == "stock"


def list_definitions(run):
    """-> every definition row of the tenant that is a stock one (read-only, paged, no status filter)."""
    rows, cursor = [], None
    for _ in range(100):
        path = "/api/v1/definitions?page_size=100" + (f"&cursor={cursor}" if cursor else "")
        status, body, _ = run.request("admin", "GET", path)
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"the definitions list answered {status}")
        rows += [{k: r.get(k) for k in FIELDS} for r in body.get("items") or [] if isinstance(r, dict) and is_stock(r)]
        cursor = body.get("next_cursor")
        if not cursor or not body.get("items"):
            return rows
    raise RuntimeError("the definitions list has more than 100 pages")


def verdicts(rows):
    """-> {name: (verdict, rows newest first)} by the three paths of Posting.ensure_locked."""
    by_name = {}
    for r in rows:
        by_name.setdefault(str(r["name"]), []).append(r)
    out = {}
    for name, items in sorted(by_name.items()):
        items.sort(key=lambda r: str(r.get("created_at") or ""), reverse=True)
        active = [r for r in items if str(r.get("status")).upper() == "ACTIVE"]
        if active:
            out[name] = ("ok" if all(r.get("owner_module") == "stock" for r in active) else "foreign", items)
        elif str(items[0].get("status")).upper() == "DRAFT" and all(r.get("owner_module") == "stock" for r in items):
            out[name] = ("no-active", items)
        else:
            out[name] = ("dead-newest", items)
    return out


def guard(tenant, admin, base_url, runner):
    runner.refuse_retired(runner.load_retired_checked(), tenant, {"admin": admin}, [base_url])
    if not (QA_HOST_RE.match(base_url) or LOOPBACK_RE.match(base_url)):
        raise runner.ConfigError(f"base url {base_url!r} is not a QA host: refused")
    if base_url.startswith("https://") and f"//{tenant}." not in base_url:
        raise runner.ConfigError(f"base url {base_url!r} is not the host of the tenant {tenant!r}: refused")


def main(args, runner, out=None) -> int:
    out = out or sys.stdout
    try:
        base_url = (args.base_url or runner.base_url_for(args.tenant, args.base_url_template)).rstrip("/")
        guard(args.tenant, args.admin, base_url, runner)
        actors = runner.normalize_actors({"admin": args.admin})
        run_dir = runner.new_run_dir(args, "definition-report-" + args.tenant)
    except runner.ConfigError as err:
        print(f"runner.py: {err}", file=sys.stderr)
        return 2
    run = runner.Runner([{"id": "definition-report", "steps": []}], base_url=base_url, tenant=args.tenant,
                        actors=actors, run_dir=run_dir, poll_interval=0.5, out=out)
    try:
        rows = list_definitions(run)
    except (runner.RunnerError, RuntimeError) as err:
        print(f"definition-report: failed: {err}", file=out)
        return 1
    result = verdicts(rows)
    print(f"stock definitions of {args.tenant}: {len(rows)} rows, {len(result)} names", file=out)
    for name, (verdict, items) in result.items():
        print(f"{name}: {verdict}", file=out)
        for r in items:
            print("  " + " ".join(f"{k}={r.get(k)}" for k in FIELDS), file=out)
    print("no stock definition row" if not rows else "end of rows", file=out)
    print("note: the API gives no status-change history; updated_at and created_by are the nearest", file=out)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "definition_report.json").write_text(
        json.dumps({"tenant": args.tenant, "verdicts": {n: v for n, (v, _) in result.items()}, "rows": rows},
                   indent=2, sort_keys=True), encoding="utf-8")
    return 0


# -- the shared run path (T-2992): a baseline at the start of the stock leg, a report on the first 409 ------------

TIMEOUT_S = 60


class _AdminView:
    """list_definitions asks for the role "admin"; the run may call its administrator by another role name."""

    def __init__(self, run, role):
        self.run, self.role = run, role

    def request(self, _role, method, path, *args, **kwargs):
        return self.run.request(self.role, method, path, *args, **kwargs)


def admin_role(actors):
    if "admin" in actors:
        return "admin"
    return next((r for r in actors if "admin" in r.lower() and "platform" not in r.lower()), None)


def capture(run, kind, runner):
    """-> (path or None, note). Read-only, bounded by TIMEOUT_S, never raises: a failure is a note, not a verdict."""
    import threading

    tenant = run.tenant
    if kind not in ("before", "after"):
        raise ValueError(kind)
    try:
        role = admin_role(run.actors)
        if not role:
            return None, f"{tenant}: no admin actor in the plan, no definition report"
        guard(tenant, run.actor_spec(role).get("user") or "", run.base_url, runner)
        box = {}

        def work():
            try:
                box["rows"] = list_definitions(_AdminView(run, role))
            except BaseException as err:  # noqa: BLE001 - reported as a note
                box["err"] = err

        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        thread.join(TIMEOUT_S)
        if thread.is_alive():
            return None, f"{tenant}: definition report ({kind}) timed out after {TIMEOUT_S} s"
        if "err" in box:
            return None, f"{tenant}: definition report ({kind}) failed: {box['err']}"
        rows = box["rows"]
        result = verdicts(rows)
        base = f"definition_report_{kind}"
        name = base + ".json"
        if (run.run_dir / name).exists() or name in getattr(run, "_definition_names", set()):
            name = f"{base}.{tenant}.json"
        run._definition_names = getattr(run, "_definition_names", set()) | {name}
        run._atomic_write(name, json.dumps(
            {"tenant": tenant, "kind": kind, "verdicts": {n: v for n, (v, _) in result.items()}, "rows": rows},
            indent=2, sort_keys=True))
        return str((run.run_dir / name).resolve()), None
    except Exception as err:  # noqa: BLE001
        return None, f"{tenant}: definition report ({kind}) failed: {err}"
