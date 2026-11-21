#!/usr/bin/env python3
"""Static check of UAT process and chain files (D-167, M1). No network, standard library only.

    python3 scripts/uat/check_processes.py [--strict] [--root DIR] [FILE ...]

Without files it checks every test/uat/processes/*.json and test/uat/chains/*.json of the root
(default: the checkout this script is in). Exit 0 when everything is fine, 1 with one line per problem.

A process file is checked for:
  * valid JSON, an id, steps, every step with an id, a do and an expect (or expect_refused);
  * every actor is a role of the roster test/fixtures/uat/actors.yaml (read as text: the roster entry
    is named actor-<slug>-<role>, the role is the last part);
  * every ${name} is an input, a default, a built-in (tenant, run_id, now_utc, old_base_url), saved by
    an EARLIER step of the process, or (in a chain) an input or an output of an EARLIER process explicitly
    named in the chain's `pass` list;
  * no literal REPLACE-WITH-* placeholder occurs in any process, chain or fixture file;
  * every api path starts with /api/ and matches a route of lib/letflow/modules/stock/router.ex or
    lib/letflow/routers/*.ex (a loose check: the method and the end of the path, wildcards for :id);
    a step with http_as: shared_access is checked against lib/letflow/routers/shared_stock_access.ex;
  * `fixtures` (names of files in test/uat/fixtures/): each must exist; what they `provide` counts as defined;
    a fixture file itself needs description, leaves, provides (each saved by a step), a cleanup whose steps all
    have `requires`;
  * bp_entry and a dry_run block {tenant, actors, inputs} when present (--strict: required).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner  # noqa: E402

ROUTE_RE = re.compile(r"^\s*(?:authz_)?(get|post|put|patch|delete)\s+\"([^\"]*)\"", re.M)
ACTOR_RE = re.compile(r"^\s*(actor-[A-Za-z0-9_.-]+):", re.M)
SHARED_ROUTER = "lib/letflow/routers/shared_stock_access.ex"
STOCK_ROUTER = "lib/letflow/modules/stock/router.ex"
STOCK_MOUNT = ["modules", "stock"]


def default_root() -> Path:
    return Path(__file__).resolve().parents[2]


def segments(path: str) -> list:
    return [s for s in path.split("?")[0].split("/") if s]


def is_wild(seg: str) -> bool:
    return seg.startswith((":", "*")) or "${" in seg


class Routes:
    """The routes of the router files: (method, [segments], [mount candidates])."""

    def __init__(self, root: Path):
        self.root = root
        self.api = []  # (method, segs, mounts)
        self.shared = []
        files = [root / STOCK_ROUTER] + sorted((root / "lib/letflow/routers").glob("*.ex"))
        # the other modules' routers (exam, assets, ...) are mounted at /api/v1/modules/<module>
        other = [f for f in sorted((root / "lib/letflow/modules").glob("*/router.ex")) if f != root / STOCK_ROUTER]
        files += other
        for f in files:
            if not f.is_file():
                continue
            rel = f.relative_to(root).as_posix()
            stem = f.stem.replace("_", "-")
            if rel != STOCK_ROUTER and f.stem == "router" and f.parent.parent.name == "modules":
                mounts = [["modules", f.parent.name]]
            else:
                mounts = [[stem], STOCK_MOUNT + [stem]] if rel != STOCK_ROUTER else [STOCK_MOUNT]
            for method, route in ROUTE_RE.findall(f.read_text(encoding="utf-8", errors="replace")):
                target = self.shared if rel == SHARED_ROUTER else self.api
                target.append((method.upper(), segments(route), mounts))
        self.loaded = bool(self.api)

    @staticmethod
    def _tail_matches(path_segs, route_segs) -> bool:
        if not route_segs or len(route_segs) > len(path_segs):
            return False
        tail = path_segs[-len(route_segs):]
        return all(is_wild(r) or r == p for r, p in zip(route_segs, tail))

    def match(self, method: str, path: str, shared=False) -> bool:
        path_segs = segments(path)
        if not shared and path_segs[:2] == ["api", "v1"]:
            path_segs = path_segs[2:]
        for m, route, mounts in (self.shared if shared else self.api):
            if m != method.upper():
                continue
            has_literal = any(not is_wild(s) for s in route)
            if has_literal and self._tail_matches(path_segs, route):
                return True
            # a route that is only wildcards (GET /:id) counts only behind its router's mount name
            if any(self._tail_matches(path_segs, mount + route) for mount in mounts):
                return True
        return False


def roster_roles(root: Path) -> set:
    text = (root / "test/fixtures/uat/actors.yaml")
    if not text.is_file():
        return set()
    roles = set()
    for name in ACTOR_RE.findall(text.read_text(encoding="utf-8", errors="replace")):
        parts = name.split("-")
        for n in range(1, len(parts)):
            roles.add("-".join(parts[n:]))  # actor-qoimeks-qa2-admin2 -> admin2, qa2-admin2, ...
    return roles


def calls_of(step) -> list:
    """Every HTTP call a step makes: [(method, path)]. A wait_task makes none that the process names."""
    do = step.get("do") or {}
    out = []
    if "api" in do and "path" in do:
        out.append((str(do["api"]), str(do["path"])))
    if isinstance(do.get("assert_only"), dict):
        out.append(("GET", str(do["assert_only"].get("path", ""))))
    if isinstance(do.get("repeat"), dict):
        out.append((str(do["repeat"].get("api", "")), str(do["repeat"].get("path", ""))))
    for call in do.get("parallel") or []:
        if isinstance(call, dict):
            out.append((str(call.get("api", "")), str(call.get("path", ""))))
    for spec in (step.get("save") or {}).values():
        if isinstance(spec, dict) and "api" in spec:
            out.append((str(spec["api"]), str(spec.get("path", ""))))
    return out


def refs(value) -> set:
    return runner.referenced_names(value)


def step_refs(step) -> set:
    """Names a step reads: everything but the names it saves."""
    body = {k: v for k, v in step.items() if k not in ("id", "save")}
    names = refs(body)
    for spec in (step.get("save") or {}).values():
        names |= refs(spec)
    return names


def saves(step) -> set:
    return {n for n, spec in (step.get("save") or {}).items() if not (isinstance(spec, dict) and "secret" in spec)}


def actors_of(step) -> set:
    found = set()
    if step.get("actor") and not step.get("http_as"):
        found.add(step["actor"])
    do = step.get("do") or {}
    for call in do.get("parallel") or []:
        if isinstance(call, dict) and call.get("actor") and not call.get("http_as"):
            found.add(call["actor"])
    return found


def check_process(doc, name, roles, routes, available, strict, problems, in_chain=False):
    """available: names defined before this process (chain inputs and earlier outputs). -> its outputs.
    In a chain every declared input must come from the chain or an earlier process."""
    where = lambda step=None: f"{name}: " + (f"step {step}: " if step else "")  # noqa: E731
    if not isinstance(doc, dict) or not doc.get("id"):
        problems.append(f"{name}: a process needs an id")
        return set()
    if not isinstance(doc.get("steps"), list) or not doc["steps"]:
        problems.append(f"{name}: a process needs a non-empty steps list")
        return set()
    defined = set(available) | set(runner.BUILTIN_NAMES) | set(doc.get("inputs") or []) | set(doc.get("defaults") or {})
    if in_chain:
        missing = set(doc.get("inputs") or []) - set(available) - set(runner.BUILTIN_NAMES) - set(doc.get("defaults") or {})
        for input_name in sorted(missing):
            problems.append(f"{name}: input {input_name!r} is given by neither the chain nor an earlier process")
    if strict:
        if not isinstance(doc.get("bp_entry"), str) or not doc["bp_entry"].strip():
            problems.append(f"{name}: bp_entry is missing (the id of the map entry this process implements)")
        if not isinstance(doc.get("dry_run"), dict):
            problems.append(f"{name}: dry_run is missing (the block {{tenant, actors, inputs}} for the dry run on QA)")
    if "bp_entry" in doc and not (isinstance(doc["bp_entry"], str) and doc["bp_entry"].strip()):
        problems.append(f"{name}: bp_entry must be a text")
    if "dry_run" in doc:
        check_dry_run(doc, name, problems)
    seen_ids = set()
    steps = doc["steps"]
    for phase, group in (("step", steps), ("cleanup", doc.get("cleanup") or [])):
        for step in group:
            if not isinstance(step, dict) or "id" not in step or not isinstance(step.get("do"), dict):
                problems.append(f"{name}: a {phase} needs an id and a do")
                continue
            sid = step["id"]
            if sid in seen_ids:
                problems.append(f"{where(sid)}duplicate step id")
            seen_ids.add(sid)
            if "expect" not in step and "expect_refused" not in step:
                problems.append(f"{where(sid)}no expect (every step says what a good answer is)")
            for role in sorted(actors_of(step)):
                if roles is not None and role not in roles:
                    problems.append(f"{where(sid)}actor {role!r} is not in test/fixtures/uat/actors.yaml")
            if not step.get("http_as") and not step.get("actor"):
                problems.append(f"{where(sid)}no actor")
            for name_ in sorted(step_refs(step) - defined):
                problems.append(f"{where(sid)}${{{name_}}} is not an input and no earlier step or process saves it")
            for method, path in calls_of(step):
                check_path(problems, where(sid), routes, method, path, shared=step.get("http_as") == "shared_access")
            defined |= saves(step)
    outputs = doc.get("outputs") or {}
    for out_name, expr in outputs.items():
        for name_ in sorted(refs(expr) - defined):
            problems.append(f"{name}: output {out_name}: ${{{name_}}} is not saved by any step")
    return set(outputs)


def check_path(problems, where, routes, method, path, shared=False):
    if not method or not path:
        problems.append(f"{where}a call needs a method and a path")
        return
    if not shared and not path.startswith("/api/"):
        problems.append(f"{where}path {path!r} must start with /api/")
        return
    if routes is None or not routes.loaded:
        return  # no router files to compare with (a test root without lib/): nothing to say
    if not routes.match(method, path, shared=shared):
        problems.append(f"{where}{method.upper()} {path} matches no route of the router files")


def check_dry_run(doc, name, problems):
    block = doc["dry_run"]
    if not isinstance(block, dict):
        problems.append(f"{name}: dry_run must be an object {{tenant, actors, inputs}}")
        return
    if not isinstance(block.get("tenant"), str) or not block["tenant"]:
        problems.append(f"{name}: dry_run.tenant is missing")
    if not isinstance(block.get("actors"), dict) or not all(isinstance(v, str) and v for v in block["actors"].values()):
        problems.append(f"{name}: dry_run.actors must map each actor to a user name")
    elif "steps" in doc:
        for step in doc["steps"] + (doc.get("cleanup") or []):
            for role in actors_of(step):
                if role not in block["actors"]:
                    problems.append(f"{name}: dry_run.actors has no user for actor {role!r}")
    inputs = block.get("inputs") if isinstance(block.get("inputs"), dict) else None
    if inputs is None:
        problems.append(f"{name}: dry_run.inputs must be an object with a value for each input")
    elif "steps" in doc:
        for needed in doc.get("inputs") or []:
            if needed not in inputs and needed not in (doc.get("defaults") or {}):
                problems.append(f"{name}: dry_run.inputs has no value for the input {needed!r}")


def check_files(files, root=None, strict=False) -> list:
    """-> a list of problem lines (empty: all fine)."""
    root = Path(root or default_root())
    problems = []
    roster = root / "test/fixtures/uat/actors.yaml"
    roles = roster_roles(root) if roster.is_file() else None
    routes = Routes(root)
    for f in files:
        f = Path(f)
        name = f.name
        try:
            text = f.read_text(encoding="utf-8")
            runner.refuse_placeholders(text, f)
            doc = json.loads(text)
        except runner.ConfigError as err:
            problems.append(str(err))
            continue
        except (OSError, ValueError) as err:
            problems.append(f"{name}: not valid JSON: {err}")
            continue
        fdir = runner.fixtures_dir_for(f)
        if isinstance(doc, dict) and "processes" in doc:
            check_chain(f, doc, roles, routes, strict, problems)
        elif isinstance(doc, dict) and f.parent.name == "fixtures":
            check_fixture(f, doc, roles, routes, problems)
        else:
            provided = fixture_provides(doc, name, fdir, problems)
            check_process(doc, name, roles, routes, provided, strict, problems)
    return problems


def fixture_provides(doc, name, fixtures_dir, problems) -> set:
    """The names the `fixtures` of a process (or chain) provide. An unknown fixture is a problem."""
    if not isinstance(doc, dict) or not doc.get("fixtures"):
        return set()
    try:
        docs = runner.fixtures_for([dict(doc, id=doc.get("id") or name)], fixtures_dir)
    except runner.ConfigError as err:
        problems.append(f"{name}: {err}")
        return set()
    names = set()
    for fx in docs:
        names |= set(fx.get("provides") or [])
    return names


def check_fixture(path: Path, doc, roles, routes, problems):
    """A fixture file: a process-like file, plus description, leaves, provides (each saved by a step) and needs."""
    name = path.name
    try:
        runner.load_fixture(path)
    except runner.ConfigError as err:
        problems.append(f"{name}: {err}")
        return
    try:
        needed = runner.expand_fixtures(doc.get("needs") or [], path.parent)
    except runner.ConfigError as err:
        problems.append(f"{name}: {err}")
        return
    available = set()
    for fx in needed:
        available |= set(fx.get("provides") or [])
    if not doc.get("cleanup"):
        problems.append(f"{name}: a fixture needs a cleanup (what stays is told in `leaves`)")
    for step in doc.get("cleanup") or []:
        if isinstance(step, dict) and not step.get("requires"):
            problems.append(f"{name}: cleanup step {step.get('id')}: needs `requires` (a fixture removes only what it created)")
    check_process(doc, name, roles, routes, available, False, problems)
    saved = set()
    for step in doc["steps"]:
        saved |= saves(step)
    for n in doc["provides"]:
        if n not in saved:
            problems.append(f"{name}: provides {n!r} but no step saves it")


def check_chain(path: Path, doc, roles, routes, strict, problems):
    name = path.name
    if not doc.get("id") or not isinstance(doc.get("processes"), list) or not doc["processes"]:
        problems.append(f"{name}: a chain needs an id and a non-empty processes list")
        return
    if strict and not isinstance(doc.get("dry_run"), dict):
        problems.append(f"{name}: dry_run is missing (the block {{tenant, actors, inputs}} for the dry run on QA)")
    if isinstance(doc.get("dry_run"), dict):
        block = doc["dry_run"]
        if not isinstance(block.get("tenant"), str) or not block["tenant"]:
            problems.append(f"{name}: dry_run.tenant is missing")
        if not isinstance(block.get("actors"), dict):
            problems.append(f"{name}: dry_run.actors must map each actor to a user name")
    provided = set(doc.get("inputs") or {}) | set((doc.get("dry_run") or {}).get("inputs") or {})
    available = set(provided) | fixture_provides(doc, name, runner.fixtures_dir_for(path), problems)
    pass_map = doc.get("pass", {})
    if not isinstance(pass_map, dict):
        problems.append(f"{name}: pass must be an object {{process id: [output names]}}")
        pass_map = {}
    seen_ids = set()
    for proc_name in doc["processes"]:
        try:
            pfile = runner.resolve_process_file(path.resolve().parent, str(proc_name))
            text = pfile.read_text(encoding="utf-8")
            runner.refuse_placeholders(text, pfile)
            pdoc = json.loads(text)
        except (runner.ConfigError, OSError, ValueError) as err:
            problems.append(f"{name}: process {proc_name!r}: {err}")
            continue
        if not isinstance(pdoc, dict):
            problems.append(f"{name}: process {proc_name!r}: a process needs an id")
            continue
        seen_ids.add(pdoc.get("id"))
        available |= fixture_provides(pdoc, f"{name} > {pfile.name}", runner.fixtures_dir_for(path), problems)
        # a process inside a chain needs no dry_run of its own: the chain carries it
        outputs = check_process(pdoc, f"{name} > {pfile.name}", roles, routes, available, False, problems,
                                in_chain=True)
        passed = pass_map.get(pdoc.get("id"), [])
        if not isinstance(passed, list) or not all(isinstance(n, str) and n for n in passed):
            problems.append(f"{name}: pass.{pdoc.get('id')} must be a list of output names")
            passed = []
        for output_name in passed:
            if output_name not in outputs:
                problems.append(f"{name}: pass.{pdoc.get('id')} names non-output {output_name!r}")
        available |= set(passed)
    for pid in pass_map:
        if pid not in seen_ids:
            problems.append(f"{name}: pass names unknown process {pid!r}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="check_processes.py", description="Static check of UAT process and chain files.")
    parser.add_argument("files", nargs="*", help="process or chain files (default: all of test/uat)")
    parser.add_argument("--root", help="the product checkout (default: the one this script is in)")
    parser.add_argument("--strict", action="store_true", help="bp_entry and dry_run are required")
    args = parser.parse_args(argv)
    root = Path(args.root or default_root())
    files = [Path(f) for f in args.files] or sorted(list((root / "test/uat/processes").glob("*.json")) +
                                                  list((root / "test/uat/chains").glob("*.json")) +
                                                  list((root / "test/uat/fixtures").glob("*.json")))
    problems = check_files(files, root=root, strict=args.strict)
    for p in problems:
        print(p)
    print(f"check_processes: {len(files)} file(s), {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
