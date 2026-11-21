#!/usr/bin/env python3
"""check_routes.py -- the MECHANICAL ROUTE INVENTORY (D-170): every API route declares how it is
authenticated, how it is tenant-scoped and which permission guards it, or the check fails.

Routes: every `authz_get/post/put/patch/delete` (and plain verb macro) of lib/letflow/router.ex,
lib/letflow/routers/*.ex and lib/letflow/modules/<m>/router.ex, with the full mounted path (the mount comes
from the `forward` lines, as in bp_inventory.py). The old-address routes (/qoimeks, /maintenance/v1,
/admin/v1), public_read, signup, webhooks, uploads and health are routes of those files too.

For each route three facts are known:

  authentication  oidc-or-api-token | shared-access | shared-secret | api-token | none-by-design
  tenant scope    tenant-prefix | platform-level | host | none-by-design
  permission      the policy atom of the `authz_*` macro, or `exempt`

DERIVED (no declaration needed): a route mounted under /api/v1 (Letflow.Plugs.ApiPipeline: AuthPipeline, tenant
status, per-tenant admission) is authenticated `oidc-or-api-token` and scoped `tenant-prefix` (`platform-level` in
a router of the area `platform`); an `authz_*` route has its permission atom.

DECLARED: everything else is declared in docs/bp/public-routes.json, a JSON list of
  {"route": "GET /health" (or a list), "authentication": ..., "tenant_scope": ..., "permission": ...
   (any of the three; the others stay derived), "reason": "...", "owner": "..."}
A declared value `none-by-design` (or permission `exempt`) needs a non-empty reason and owner. The file is the allow-list
of public routes: an unknown public route (outside /api/v1 and not listed) fails.

Checks (one line `ERROR ...` each; exit 1 on any, or on an uncovered route):
  * a route with no authentication, no tenant scope or no permission (plain verb macro) and no declaration;
  * a declaration with a bad value, a `none-by-design` / `exempt` value without reason and owner, an unknown route
    (stale), or a duplicate;
  * COVERAGE of routes: every route is referenced by a business-process task (docs/bp/<area>.json, rules of
    check_catalog.py) or is on the orphan list (docs/bp/orphans-<area>.md);
  * WRITE-TARGETS (T-2299 hole): in a pack, a variable a `module_writes` argument reads must not be declared a
    completer input (`completer_inputs`, `form_schema` property) of any node, except the reviewed pairs below;
    an argument source other than {"var": text} / {"const": _} is a source the engine rule cannot see.

`--gaps-md FILE` writes the result as a table (docs/bp/route-gaps.md); `--json` prints it as JSON.
Standard library only; `--root DIR` points at another checkout.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parents[1]
AUTH_KINDS = ("oidc-or-api-token", "shared-access", "shared-secret", "api-token", "none-by-design")
SCOPE_KINDS = ("tenant-prefix", "platform-level", "host", "none-by-design")
ALLOW_FILE = "public-routes.json"
API_PREFIX = "/api/v1"

# {pack, process_key, node, key}: a key a person supplies at that node (mirror of @completer_provided in
# test/letflow/modules/write_target_sources_scan_test.exs; a reviewed security decision)
COMPLETER_PROVIDED = {("maintenance", "maintenance_work_order", "maintenance_work", "work_done")}


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


CAT = _load("check_catalog")
INV = CAT.INV


# ------------------------------------------------------------------------------------------ the routes
def router_files(root: Path) -> list[Path]:
    files = []
    top = root / "lib/letflow/router.ex"
    if top.is_file():
        files.append(top)
    files += sorted((root / "lib/letflow/routers").glob("*.ex"))
    files += sorted((root / "lib/letflow/modules").glob("*/router.ex"))
    return [f for f in files if f.is_file()]


def platform_routers() -> set[str]:
    out = set()
    for stem in INV.AREAS["platform"].get("routers", []):
        out.add(stem)
    return out


def all_routes(root: Path) -> list[dict]:
    mount = INV.mounts(root)
    platform = platform_routers()
    owner: dict[tuple[str, int], str] = {}
    for d in INV.inventory(root, "all"):
        if d["kind"] == "route":
            owner[(d["path"], d["line"])] = d["area"]
    out = []
    for f in router_files(root):
        mod_dir = f.parent
        if mod_dir.parent.name == "modules" and f.name == "router.ex":
            prefix = f"/api/v1/modules/{mod_dir.name}"
        else:
            prefix = mount.get(INV.module_name(INV.read_lines(f)), "")
        for it in INV.route_items(root, f, prefix):
            it["area"] = owner.get((it["path"], it["line"]), "unassigned")
            it["platform"] = f.stem in platform
            it["mounted"] = bool(prefix)
            it["key"] = CAT.norm_route(it["name"])
            out.append(it)
    return out


# ---------------------------------------------------------------------------------------- the allow-list
def load_allow(root: Path, errors: list[str]) -> dict[str, dict]:
    path = root / "docs/bp" / ALLOW_FILE
    fname = f"docs/bp/{ALLOW_FILE}"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        errors.append(f"ERROR {fname}: invalid JSON ({exc})")
        return {}
    if not isinstance(data, list):
        errors.append(f"ERROR {fname}: the file must be a JSON list of entries")
        return {}
    out: dict[str, dict] = {}
    for i, e in enumerate(data, 1):
        if not isinstance(e, dict):
            errors.append(f"ERROR {fname}: entry {i} is not an object")
            continue
        r = e.get("route")
        routes = [r] if isinstance(r, str) else r
        if not (isinstance(routes, list) and routes and all(isinstance(x, str) and x.strip() for x in routes)):
            errors.append(f"ERROR {fname}: entry {i}: route must be a text or a list of texts")
            continue
        auth, scope, perm = e.get("authentication"), e.get("tenant_scope"), e.get("permission")
        where = f"{fname} {routes[0]}"
        if auth is not None and auth not in AUTH_KINDS:
            errors.append(f"ERROR {where}: authentication {auth!r} is not one of {', '.join(AUTH_KINDS)}")
        if scope is not None and scope not in SCOPE_KINDS:
            errors.append(f"ERROR {where}: tenant_scope {scope!r} is not one of {', '.join(SCOPE_KINDS)}")
        if perm is not None and not (isinstance(perm, str) and perm.strip()):
            errors.append(f"ERROR {where}: permission must be a permission name or 'exempt'")
        if all(v is None for v in (auth, scope, perm)):
            errors.append(f"ERROR {where}: the entry declares none of authentication, tenant_scope, permission")
        if "none-by-design" in (auth, scope) or perm == "exempt":
            for f in ("reason", "owner"):
                if not (isinstance(e.get(f), str) and e[f].strip()):
                    errors.append(f"ERROR {where}: a none-by-design / exempt declaration needs a {f}")
        for x in routes:
            k = CAT.norm_route(x)
            if k in out:
                errors.append(f"ERROR {fname}: route {k} is declared twice")
            out[k] = e
    return out


# ------------------------------------------------------------------------------------------- one route
def classify(rt: dict, decl: dict | None) -> dict:
    """Fill authentication, tenant_scope, permission and the list of problems of one route."""
    under_api = rt["name"].split(" ", 1)[1].startswith(API_PREFIX + "/") or rt["name"].endswith(" " + API_PREFIX)
    auth = "oidc-or-api-token" if under_api else None
    scope = ("platform-level" if rt["platform"] else "tenant-prefix") if under_api else None
    perm = rt.get("permission") or None
    if decl:
        auth = decl.get("authentication", auth)
        scope = decl.get("tenant_scope", scope)
        perm = decl.get("permission", perm)
    problems = []
    if not auth:
        problems.append("no declared authentication" + ("" if rt["mounted"] else " (router is not mounted)"))
    if not scope:
        problems.append("no declared tenant scope")
    if not perm:
        problems.append("no permission (plain route, no declared exemption)")
    if (auth == "none-by-design" or scope == "none-by-design" or perm == "exempt") and not decl:
        problems.append("none-by-design without an entry in the allow-list")
    if not under_api and not decl:
        problems.append("unknown public route (outside /api/v1, not in the allow-list)")
    rt.update(authentication=auth or "-", tenant_scope=scope or "-", permission=perm or "-",
              source="declared" if decl else "derived", problems=problems)
    return rt


# ----------------------------------------------------------------------------------------- coverage
def coverage(root: Path, routes: list[dict], errors: list[str]) -> None:
    sink: list[str] = []  # the catalog's own errors are check_catalog.py's job
    entries, orphans = [], []
    for a in INV.AREA_NAMES:
        entries += CAT.load_catalog(root, a, sink)
        orphans += CAT.parse_orphans(root, a, sink)
    for rt in routes:
        rt["covered"] = CAT.covers(rt, entries) or CAT.orphan_covers(rt, orphans)


# ----------------------------------------------------------------------------------- write targets
def write_target_problems(root: Path) -> list[str]:
    out = []
    for pack in sorted((root / "priv/modules").glob("*/pack.json")):
        name = pack.parent.name
        try:
            data = json.loads(pack.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for d in data.get("definitions", []) or []:
            key = d.get("process_key", "?")
            nodes = (d.get("graph") or {}).get("nodes") or []
            read: set[str] = set()
            for node in nodes:
                writes = (node.get("attributes") or {}).get("module_writes")
                for line in writes if isinstance(writes, list) else []:
                    for arg, src in ((line or {}).get("args") or {}).items():
                        where = f"{name}/{key}/{node.get('id')}/{line.get('handler')}.{arg}"
                        if isinstance(src, dict) and len(src) == 1 and isinstance(src.get("var"), str):
                            read.add(src["var"])
                        elif not (isinstance(src, dict) and len(src) == 1 and "const" in src):
                            out.append(f"{where}: source {src!r} is not {{'var': text}} or {{'const': _}}")
            for node in nodes:
                attrs = node.get("attributes") or {}
                declared = set()
                ci = attrs.get("completer_inputs")
                if isinstance(ci, list):
                    declared |= {x for x in ci if isinstance(x, str)}
                props = (attrs.get("form_schema") or {}).get("properties")
                if isinstance(props, dict):
                    declared |= set(props)
                for k in sorted(declared & read):
                    if (name, key, node.get("id"), k) not in COMPLETER_PROVIDED:
                        out.append(f"{name}/{key}/{node.get('id')}: write target {k!r} is completer-writable "
                                   f"(a module_writes argument reads it; supply it from engine-owned data)")
    return out


# ------------------------------------------------------------------------------------------- the run
def run(root: Path) -> dict:
    errors: list[str] = []
    allow = load_allow(root, errors)
    routes = all_routes(root)
    seen = set()
    for rt in routes:
        classify(rt, allow.get(rt["key"]))
        seen.add(rt["key"])
    for k in allow:
        if k not in seen:
            errors.append(f"ERROR docs/bp/{ALLOW_FILE}: route {k} is declared but no router has it (stale entry)")
    coverage(root, routes, errors)
    wt = write_target_problems(root)
    gaps = [r for r in routes if r["problems"]]
    uncovered = [r for r in routes if not r["covered"]]
    return {"routes": routes, "gaps": gaps, "uncovered": uncovered, "errors": errors, "write_targets": wt,
            "ok": not (gaps or uncovered or errors or wt)}


def gaps_markdown(res: dict) -> str:
    routes, gaps, unc = res["routes"], res["gaps"], res["uncovered"]
    lines = [
        "# Route gaps (D-170)", "",
        "Generated by `python3 scripts/uat/check_routes.py --gaps-md docs/bp/route-gaps.md` (the first run of the "
        "mechanical route inventory). This is the TO-DO list: nothing here was fixed by the task that wrote it. "
        "A gap is closed by declaring the route (an entry in `docs/bp/public-routes.json` with a reason and an "
        "owner), by giving it a permission, or by a business-process task / orphan row (coverage).", "",
        f"Routes: {len(routes)}; with a declaration gap: {len(gaps)}; not referenced by a process or an orphan row: "
        f"{len(unc)}; write-target violations: {len(res['write_targets'])}.", "",
        "## Routes without a declared authentication, tenant scope or permission", "",
        "| route | file:line | area | authentication | tenant scope | permission | problem |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in gaps:
        lines.append(f"| `{r['name']}` | `{r['path']}:{r['line']}` | {r['area']} | {r['authentication']} | "
                     f"{r['tenant_scope']} | {r['permission']} | {'; '.join(r['problems'])} |")
    if not gaps:
        lines.append("| (none) | | | | | | |")
    lines += ["", "## Coverage: routes no process task or orphan row references (per area)", "",
              "| area | routes | not referenced |", "|---|---|---|"]
    for a in sorted({r["area"] for r in routes}):
        total = sum(1 for r in routes if r["area"] == a)
        miss = sum(1 for r in unc if r["area"] == a)
        lines.append(f"| {a} | {total} | {miss} |")
    lines += ["", "The per-route list is `python3 scripts/uat/check_routes.py` (the lines `uncovered ...`).", "",
              "## Write targets a completer can write (T-2299 form)", ""]
    lines += [f"- {w}" for w in res["write_targets"]] or ["(none)"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--gaps-md", metavar="FILE", help="write the failing routes as a markdown table")
    ap.add_argument("--max-missing", type=int, default=20, help="uncovered routes listed (default 20)")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    res = run(root)
    if args.gaps_md:
        Path(args.gaps_md).write_text(gaps_markdown(res), encoding="utf-8")
    if args.json:
        slim = {k: v for k, v in res.items() if k != "routes"}
        slim["routes"] = len(res["routes"])
        print(json.dumps(slim, indent=1, default=str))
    else:
        routes = res["routes"]
        print(f"ROUTES {len(routes)}: {len(routes) - len(res['gaps'])} declared, {len(res['gaps'])} with a gap; "
              f"{len(routes) - len(res['uncovered'])} covered, {len(res['uncovered'])} not")
        for r in res["gaps"]:
            print(f"ERROR {r['name']} ({r['path']}:{r['line']}): {'; '.join(r['problems'])}")
        for r in res["uncovered"][: args.max_missing]:
            print(f"  uncovered {r['name']}  ({r['path']}:{r['line']})")
        if len(res["uncovered"]) > args.max_missing:
            print(f"  ... and {len(res['uncovered']) - args.max_missing} more (--max-missing)")
        for w in res["write_targets"]:
            print(f"ERROR write target {w}")
        for e in res["errors"]:
            print(e)
        print("check_routes: " + ("PASS" if res["ok"] else "FAIL"))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
