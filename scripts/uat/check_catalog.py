#!/usr/bin/env python3
"""check_catalog.py [area ...|all] -- checks the business-process map (D-168/D-169) and its COVERAGE.

The map is docs/bp/<area>.json (a JSON list of process entries, schema: docs/bp/README.md) plus
docs/bp/orphans-<area>.md (the inventory items no process uses, one table row each).

Checks (every problem is one line `ERROR <file>: <what>`):
  * the JSON is valid and every entry has the required fields with the right types;
  * ids are unique across all catalog files and have the form BP-<AREA>-nn for the area of the file;
  * status is implemented | partial | planned (planned needs a `requirement`; the other two need tasks with code_refs);
  * every code_ref `path:line` resolves: the file exists under the root and the line is within its length;
  * every `scenario` path exists, or is null;
  * the optional `executed_by` of every entry: `direct` (the default) or `definition:<process_key>`; any
    other form is an error, and a `definition:` value must name a process key;
  * COVERAGE: every item of `bp_inventory.py <area>` is referenced by at least one process task (code_refs /
    route / forms / functions, see docs/bp/README.md "How coverage is counted") OR is listed in the area's
    orphan file; the percentage per area is printed, and the exit code is 1 below 100%.
  * the orphan file: each row has function, file:line, what it does, history, why it exists, proposed action;
    file:line resolves and falls inside an inventory item (a stale row is an error); the action is one of
    `give a process`, `keep as a platform function`, `remove`.

Areas: with no argument, every area that has a catalog or orphan file; `all` = every area (an area with no
file then has 0% coverage and fails); or a list of area names. An area with an empty inventory has no items to
cover (100%).

The report counts, per area and for all areas together, how many processes are `direct` (a hard-coded route or
function) and how many are `definition:` (the process runs as a BPM definition of the engine). The owner's rule
D-175: a new business process is a definition, so the counts show how far the map has come.

Exit code: 0 all fine, 1 an error or coverage below 100%, 2 usage. Standard library only; `--root DIR` points
at another checkout; `--json` prints the result as JSON.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

# JSON support files under docs/bp/ that are not area catalogs (docs/bp/README.md).
NON_AREA_FILES = frozenset({
    "public-routes.json",
    "dead-code.json",
    "dead-code-allow.json",
    "dead-code-baseline.json",
})

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parents[1]
STATUSES = ("implemented", "partial", "planned")
ACTIONS = ("give a process", "keep as a platform function", "remove")
ORPHAN_COLUMNS = ("function", "file:line", "what it does", "history", "why it exists", "proposed action")
ENTRY_FIELDS = (
    "id", "area", "title", "description", "actors", "preconditions", "tasks", "inputs", "outputs",
    "refusals", "scenario", "status",
)
TASK_FIELDS = ("actor", "forms", "functions", "route", "code_refs", "result")
REF_RE = re.compile(r"^(.+):(\d+)$")

# The optional `executed_by` of an entry (D-175): who runs the process.
#   `direct`            -- a hard-coded route or function (the default of every existing entry);
#   `definition:<key>`  -- a BPM definition of the engine, named by its process key.
# A missing field means `direct`: the existing maps are not rewritten by this tool.
EXECUTED_BY_DIRECT = "direct"
EXECUTED_BY_DEFINITION = "definition:"
# A process key: the name of a definition (`stock_receipt`, `platform.register_tenant`). The
# engine accepts any name of 1..255 characters; the tool refuses the shapes that could not
# name a definition at all (spaces, a leading dot, an empty key).
PROCESS_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]*$")
MAX_PROCESS_KEY = 255


def load_inventory_module():
    spec = importlib.util.spec_from_file_location("bp_inventory", HERE / "bp_inventory.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["bp_inventory"] = mod
    spec.loader.exec_module(mod)
    return mod


INV = load_inventory_module()


def norm_route(route: str) -> str:
    """`post /api/v1/x/:Id/` -> `POST /api/v1/x/:`: verb upper-case, path parameters unnamed, no trailing slash."""
    parts = route.strip().split(None, 1)
    if len(parts) != 2:
        return route.strip()
    path = re.sub(r":\w+", ":", parts[1].strip()).rstrip("/") or "/"
    return f"{parts[0].upper()} {path}"


def line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="replace").splitlines())


def check_ref(root: Path, ref: str) -> str | None:
    """None when `path:line` resolves, else the reason."""
    m = REF_RE.match(ref) if isinstance(ref, str) else None
    if not m:
        return f"code_ref {ref!r} is not path:line"
    path, line = m.group(1), int(m.group(2))
    full = (root / path).resolve()
    try:
        full.relative_to(root)
    except ValueError:
        return f"code_ref {ref!r} leaves the repository"
    if not full.is_file():
        return f"code_ref {ref!r}: file does not exist"
    if line < 1 or line > line_count(full):
        return f"code_ref {ref!r}: line outside the file ({line_count(full)} lines)"
    return None


def is_str_list(v) -> bool:
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def parse_executed_by(entry: dict) -> tuple[str | None, str | None, str | None]:
    """The `executed_by` of an entry: (value, kind, problem).

    The field is optional: a missing one means `direct` (D-175 -- the existing entries are
    direct until they are migrated). `kind` is `direct`, `definition` or None when the value
    is not one of the two allowed forms; then `problem` says why.
    """
    if "executed_by" not in entry:
        return EXECUTED_BY_DIRECT, "direct", None
    raw = entry["executed_by"]
    if not isinstance(raw, str):
        return None, None, "executed_by must be a text"
    value = raw.strip()
    if value == EXECUTED_BY_DIRECT:
        return value, "direct", None
    if value.startswith(EXECUTED_BY_DEFINITION):
        key = value[len(EXECUTED_BY_DEFINITION):]
        if not key:
            return value, None, "executed_by 'definition:' must name a process key"
        if len(key) > MAX_PROCESS_KEY or not PROCESS_KEY_RE.fullmatch(key):
            return value, None, (
                f"executed_by {value!r} must name a process key "
                "(letters, digits, '_', '-', '.', at most 255 characters)"
            )
        return value, "definition", None
    return value, None, (
        f"executed_by {value!r} must be {EXECUTED_BY_DIRECT!r} or 'definition:<process_key>'"
    )


def executed_by_counts(entries: list[dict]) -> dict[str, int]:
    """How many entries are `direct` and how many are `definition:` (a wrong form counts as neither)."""
    counts = {"direct": 0, "definition": 0}
    for entry in entries:
        _value, kind, _problem = parse_executed_by(entry)
        if kind in counts:
            counts[kind] += 1
    return counts


def validate_entry(root: Path, fname: str, area: str, e, errors: list[str]) -> None:
    if not isinstance(e, dict):
        errors.append(f"ERROR {fname}: an entry is not an object")
        return
    eid = e.get("id", "?")
    where = f"{fname} {eid}"
    for f in ENTRY_FIELDS:
        if f not in e:
            errors.append(f"ERROR {where}: missing field {f!r}")
    if "id" in e:
        want = f"BP-{area.upper()}-"
        if not (isinstance(eid, str) and re.fullmatch(re.escape(want) + r"\d{2,}", eid)):
            errors.append(f"ERROR {where}: id must be {want}nn")
    if e.get("area") != area:
        errors.append(f"ERROR {where}: area is {e.get('area')!r}, the file is for {area!r}")
    for f in ("title", "description"):
        if f in e and not (isinstance(e[f], str) and e[f].strip()):
            errors.append(f"ERROR {where}: {f} must be a non-empty text")
    for f in ("preconditions", "inputs", "outputs", "refusals"):
        if f in e and not is_str_list(e[f]):
            errors.append(f"ERROR {where}: {f} must be a list of texts")
    actors = e.get("actors")
    if "actors" in e:
        if not (isinstance(actors, list) and actors and all(
                isinstance(a, dict) and isinstance(a.get("role"), str) and isinstance(a.get("permission"), str)
                for a in actors)):
            errors.append(f"ERROR {where}: actors must be a non-empty list of {{role, permission}}")
    status = e.get("status")
    if "status" in e and status not in STATUSES:
        errors.append(f"ERROR {where}: status {status!r} is not one of {', '.join(STATUSES)}")
    if status == "planned" and not (isinstance(e.get("requirement"), str) and e["requirement"].strip()):
        errors.append(f"ERROR {where}: a planned process names its `requirement`")
    _executed_by, _kind, problem = parse_executed_by(e)
    if problem:
        errors.append(f"ERROR {where}: {problem}")
    scenario = e.get("scenario", None)
    if "scenario" in e and scenario is not None:
        if not isinstance(scenario, str) or not (root / scenario).is_file():
            errors.append(f"ERROR {where}: scenario {scenario!r} does not exist (use null when there is none)")
    tasks = e.get("tasks")
    if "tasks" in e:
        if not isinstance(tasks, list):
            errors.append(f"ERROR {where}: tasks must be a list")
            return
        if status in ("implemented", "partial") and not tasks:
            errors.append(f"ERROR {where}: an {status} process has at least one task")
        for i, t in enumerate(tasks, 1):
            tw = f"{where} task {i}"
            if not isinstance(t, dict):
                errors.append(f"ERROR {tw}: not an object")
                continue
            for f in TASK_FIELDS:
                if f not in t:
                    errors.append(f"ERROR {tw}: missing field {f!r}")
            if "actor" in t and not (isinstance(t["actor"], str) and t["actor"].strip()):
                errors.append(f"ERROR {tw}: actor must be a non-empty text")
            for f in ("forms", "functions", "code_refs"):
                if f in t and not is_str_list(t[f]):
                    errors.append(f"ERROR {tw}: {f} must be a list of texts")
            r = t.get("route")
            if "route" in t and not (r is None or isinstance(r, str) or is_str_list(r)):
                errors.append(f"ERROR {tw}: route must be a text, a list of texts or null")
            if "result" in t and not (isinstance(t["result"], str) and t["result"].strip()):
                errors.append(f"ERROR {tw}: result must be a non-empty text")
            refs = t.get("code_refs") if is_str_list(t.get("code_refs")) else []
            if status in ("implemented", "partial") and "code_refs" in t and not refs:
                errors.append(f"ERROR {tw}: an {status} process names code_refs (file:line)")
            for ref in refs:
                problem = check_ref(root, ref)
                if problem:
                    errors.append(f"ERROR {tw}: {problem}")


def load_catalog(root: Path, area: str, errors: list[str]) -> list[dict]:
    path = root / "docs/bp" / f"{area}.json"
    if not path.is_file():
        return []
    fname = f"docs/bp/{area}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        errors.append(f"ERROR {fname}: invalid JSON ({exc})")
        return []
    if not isinstance(data, list):
        errors.append(f"ERROR {fname}: the file must be a JSON list of entries")
        return []
    for e in data:
        validate_entry(root, fname, area, e, errors)
    return [e for e in data if isinstance(e, dict)]


def parse_orphans(root: Path, area: str, errors: list[str]) -> list[dict]:
    path = root / "docs/bp" / f"orphans-{area}.md"
    if not path.is_file():
        return []
    fname = f"docs/bp/orphans-{area}.md"
    rows = []
    header = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        if header is None:
            header = [c.lower() for c in cells]
            if tuple(header) != ORPHAN_COLUMNS:
                errors.append(f"ERROR {fname}: the table header must be | {' | '.join(ORPHAN_COLUMNS)} |")
                return []
            continue
        if len(cells) != len(ORPHAN_COLUMNS):
            errors.append(f"ERROR {fname}: a row has {len(cells)} cells, expected {len(ORPHAN_COLUMNS)}: {line[:60]}")
            continue
        row = dict(zip(ORPHAN_COLUMNS, cells))
        for col, val in row.items():
            if not val:
                errors.append(f"ERROR {fname}: orphan {row['function'] or '?'}: column {col!r} is empty")
        if row["proposed action"] and row["proposed action"].lower() not in ACTIONS:
            errors.append(
                f"ERROR {fname}: orphan {row['function']}: proposed action must be one of {', '.join(ACTIONS)}"
            )
        ref = row["file:line"].strip("` ")
        problem = check_ref(root, ref)
        if problem:
            errors.append(f"ERROR {fname}: orphan {row['function']}: {problem}")
            continue
        m = REF_RE.match(ref)
        row["_path"], row["_line"] = m.group(1), int(m.group(2))
        rows.append(row)
    return rows


def covers(item: dict, entries: list[dict]) -> bool:
    names = {item["name"], *item.get("aliases", [])}
    route = norm_route(item["name"]) if item["kind"] == "route" else None
    for e in entries:
        for t in e.get("tasks", []) if isinstance(e.get("tasks"), list) else []:
            if not isinstance(t, dict):
                continue
            for ref in t.get("code_refs") or []:
                m = REF_RE.match(ref) if isinstance(ref, str) else None
                if m and m.group(1) == item["path"] and item["line"] <= int(m.group(2)) <= item["end"]:
                    return True
            routes = t.get("route")
            routes = [routes] if isinstance(routes, str) else (routes or [])
            if route and any(isinstance(r, str) and norm_route(r) == route for r in routes):
                return True
            for field in ("forms", "functions"):
                if any(isinstance(x, str) and x in names for x in t.get(field) or []):
                    return True
    return False


def orphan_covers(item: dict, orphans: list[dict]) -> bool:
    return any(o["_path"] == item["path"] and item["line"] <= o["_line"] <= item["end"] for o in orphans)


def check_area(root: Path, area: str, entries: list[dict], orphans: list[dict], errors: list[str]) -> dict:
    inv = INV.inventory(root, area)
    covered, missing = 0, []
    for it in inv:
        if covers(it, entries) or orphan_covers(it, orphans):
            covered += 1
        else:
            missing.append(it)
    for o in orphans:
        if not any(it["path"] == o["_path"] and it["line"] <= o["_line"] <= it["end"] for it in inv):
            errors.append(
                f"ERROR docs/bp/orphans-{area}.md: orphan {o['function']} ({o['file:line']}) matches no "
                f"inventory item of area {area} (stale row?)"
            )
    pct = 100.0 if not inv else 100.0 * covered / len(inv)
    return {"area": area, "items": len(inv), "covered": covered, "percent": round(pct, 1),
            "missing": [{"id": m["id"], "path": m["path"], "line": m["line"], "name": m["name"]} for m in missing]}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("areas", nargs="*", help="area names, or `all` (default: areas that have a file)")
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--max-missing", type=int, default=20, help="uncovered items listed per area (default 20)")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    names = list(INV.AREA_NAMES)
    if args.areas == ["all"]:
        areas = names
    elif args.areas:
        bad = [a for a in args.areas if a not in names]
        if bad:
            print(f"check_catalog: unknown area {', '.join(bad)} (known: {', '.join(names)})", file=sys.stderr)
            return 2
        areas = args.areas
    else:
        areas = [a for a in names if (root / "docs/bp" / f"{a}.json").is_file()
                 or (root / "docs/bp" / f"orphans-{a}.md").is_file()]

    errors: list[str] = []
    results = []
    all_entries: dict[str, list[dict]] = {}
    for a in areas:
        all_entries[a] = load_catalog(root, a, errors)
    # A JSON file for a name that is neither an area nor a documented support file is an error.
    bp_dir = root / "docs/bp"
    if bp_dir.is_dir() and not args.areas:
        for f in sorted(bp_dir.glob("*.json")):
            if f.stem not in names and f.name not in NON_AREA_FILES:
                errors.append(f"ERROR docs/bp/{f.name}: not an area catalog (areas: {', '.join(names)})")
    ids: dict[str, str] = {}
    for a, entries in all_entries.items():
        for e in entries:
            eid = e.get("id")
            if isinstance(eid, str):
                if eid in ids:
                    errors.append(f"ERROR docs/bp/{a}.json: id {eid} is already used in {ids[eid]}")
                ids[eid] = f"docs/bp/{a}.json"
    every_entry = [e for es in all_entries.values() for e in es]
    for a in areas:
        orphans = parse_orphans(root, a, errors)
        result = check_area(root, a, every_entry, orphans, errors)
        result["executed_by"] = executed_by_counts(all_entries[a])
        results.append(result)
    totals = {"direct": 0, "definition": 0}
    for r in results:
        for kind in totals:
            totals[kind] += r["executed_by"][kind]

    failed = bool(errors) or any(r["percent"] < 100.0 for r in results) or not areas
    if args.json:
        print(json.dumps({"ok": not failed, "areas": results, "executed_by": totals, "errors": errors}, indent=1))
    else:
        if not areas:
            print("check_catalog: no catalog files under docs/bp/ (name an area, or `all`)")
        for r in results:
            print(f"COVERAGE {r['area']}: {r['covered']}/{r['items']} = {r['percent']:.1f}%")
            for m in r["missing"][: args.max_missing]:
                print(f"  uncovered {m['name']}  ({m['path']}:{m['line']})")
            if len(r["missing"]) > args.max_missing:
                print(f"  ... and {len(r['missing']) - args.max_missing} more (--max-missing)")
            print(
                f"EXECUTED BY {r['area']}: {r['executed_by']['direct']} direct, "
                f"{r['executed_by']['definition']} definition"
            )
        print(f"EXECUTED BY total: {totals['direct']} direct, {totals['definition']} definition")
        for line in errors:
            print(line)
        print("check_catalog: " + ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
