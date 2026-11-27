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
  * a `platform_residue` block (what the run watches on the platform tenant, G18): only `definitions` and
    `instances`, each a list of names; a ${name} in it must be defined like any other name;
  * a `wait_mail` step (the mail trap, G18): a recipient, a subject and a time the runner can read (a number,
    a numeric text or a ${name} of the context);
  * (--strict, T-2885) every document a step CREATES (a POST to a document collection route: a route of a
    module router without wildcards that the same router can undo with POST <it>/:id/reverse|cancel; /quick-counts counts as /documents) has a cleanup step of the same file that undoes that
    collection (a reverse, cancel or delete), or a top-level `residue_allow` entry
    {"type": "<collection>[:<kind>]", "reason": "...", "owner": "..."} with a reason and an owner;
  * bp_entry and a dry_run block {tenant, actors, inputs} when present (--strict: required).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retired  # noqa: E402
import runner  # noqa: E402

ROUTE_RE = re.compile(r"^\s*(?:authz_)?(get|post|put|patch|delete)\s+\"([^\"]*)\"", re.M)
ACTOR_RE = re.compile(r"^\s*(actor-[A-Za-z0-9_.-]+):", re.M)
SHARED_ROUTER = "lib/letflow/routers/shared_stock_access.ex"
STOCK_ROUTER = "lib/letflow/modules/stock/router.ex"
STOCK_MOUNT = ["modules", "stock"]
API_PIPELINE = "lib/letflow/plugs/api_pipeline.ex"
FORWARD_RE = re.compile(r"^\s*forward\(\s*\"([^\"]*)\"\s*,\s*to:\s*Letflow\.Routers\.([A-Za-z0-9_.]+)", re.M)


UNDO_TAILS = ("reverse", "cancel")
COLLECTION_ALIASES = {"quick-counts": "documents"}  # creates a stock document, undone through /documents/:id/...


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name.rsplit(".", 1)[-1]).lower()


def forwarded_mounts(root: Path) -> dict:
    """router file stem -> mounts (segment lists) that api_pipeline.ex forwards to it, e.g. tenant_modules -> [[tenant, modules]]."""
    f = root / API_PIPELINE
    found = {}
    if f.is_file():
        for mount, module in FORWARD_RE.findall(f.read_text(encoding="utf-8", errors="replace")):
            found.setdefault(snake(module), []).append(segments(mount))
    return found


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
        forwarded = forwarded_mounts(root)
        for f in files:
            if not f.is_file():
                continue
            rel = f.relative_to(root).as_posix()
            stem = f.stem.replace("_", "-")
            if rel != STOCK_ROUTER and f.stem == "router" and f.parent.parent.name == "modules":
                mounts = [["modules", f.parent.name]]
            else:
                mounts = [[stem], STOCK_MOUNT + [stem]] if rel != STOCK_ROUTER else [STOCK_MOUNT]
            if f.parent.name == "routers":  # a router forwarded at another mount, e.g. /tenant/modules
                mounts = [m for m in forwarded.get(f.stem, []) if m not in mounts] + mounts
            for method, route in ROUTE_RE.findall(f.read_text(encoding="utf-8", errors="replace")):
                target = self.shared if rel == SHARED_ROUTER else self.api
                target.append((method.upper(), segments(route), mounts))
        self.loaded = bool(self.api)
        self.families = self._families()

    def _families(self):
        """Document collections: (mounts, segs) of POST routes without wildcards that the router can undo."""
        found = {}
        for method, segs, mounts in self.api:
            if method != "POST" or not segs or any(is_wild(s) for s in segs):
                continue
            undo = any(
                m == "POST" and r == segs + [":id", t] and ms == mounts
                for t in UNDO_TAILS for m, r, ms in self.api
            )
            if undo:
                found[(tuple(map(tuple, mounts)), tuple(segs))] = mounts
        for method, segs, mounts in self.api:  # aliases: /quick-counts -> /documents of the same router
            if method == "POST" and segs and segs[-1] in COLLECTION_ALIASES and not any(is_wild(s) for s in segs):
                target = segs[:-1] + [COLLECTION_ALIASES[segs[-1]]]
                if (tuple(map(tuple, mounts)), tuple(target)) in found:
                    found[(tuple(map(tuple, mounts)), tuple(segs))] = mounts
        return found

    def family_of(self, path: str):
        """-> the collection name ("documents", "counts") a POST path creates, or None. Aliases resolve."""
        psegs = segments(path)
        if psegs[:2] == ["api", "v1"]:
            psegs = psegs[2:]
        for (_, segs), mounts in self.families.items():
            if any(self._tail_matches(psegs, mount + list(segs)) and len(psegs) == len(mount) + len(segs) for mount in mounts):
                name = segs[-1]
                return "/".join(mounts[-1][-1:] + [COLLECTION_ALIASES.get(name, name)])
        return None

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
    if isinstance(do.get("page_through"), dict):
        out.append(("GET", str(do["page_through"].get("path", ""))))
    if isinstance(do.get("sweep"), dict):
        out.append(("GET", "/api/v1/definitions"))
        out.append(("DELETE", "/api/v1/definitions/${id}"))
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


ANONYMOUS_ACTOR = "anonymous"  # the public routes: no token, no roster entry, no dry_run user


def actors_of(step) -> set:
    return _actors_of(step) - {ANONYMOUS_ACTOR}


def _actors_of(step) -> set:
    found = set()
    if step.get("actor") and not step.get("http_as"):
        found.add(step["actor"])
    do = step.get("do") or {}
    for call in do.get("parallel") or []:
        if isinstance(call, dict) and call.get("actor") and not call.get("http_as"):
            found.add(call["actor"])
    return found


def _post_bodies(step) -> list:
    do = step.get("do") or {}
    calls = [do] + [c for c in (do.get("parallel") or []) if isinstance(c, dict)]
    if isinstance(do.get("repeat"), dict):
        calls.append(do["repeat"])
    return [c for c in calls if str(c.get("api", "")).upper() == "POST" and "path" in c]


def check_cleanup_coverage(doc, name, routes, problems):
    """T-2885: a created document type has a cleanup that undoes it, or a residue_allow with reason and owner."""
    allow = doc.get("residue_allow", [])
    allowed = set()
    if not isinstance(allow, list):
        problems.append(f"{name}: residue_allow must be a list of {{type, reason, owner}}")
        allow = []
    for i, entry in enumerate(allow):
        ok = isinstance(entry, dict) and all(isinstance(entry.get(k), str) and entry[k].strip() for k in ("type", "reason", "owner"))
        if not ok:
            problems.append(f"{name}: residue_allow[{i}] needs a type, a reason and an owner (all non-empty text)")
        else:
            allowed.add(entry["type"].strip())
    undone = set()
    for step in doc.get("cleanup") or []:
        if not isinstance(step, dict):
            continue
        for call in _post_bodies(step) + [c for c in [step.get("do") or {}] if str(c.get("api", "")).upper() == "DELETE"]:
            segs = segments(str(call.get("path", "")))
            method = str(call.get("api", "")).upper()
            if method == "POST" and segs and segs[-1] in UNDO_TAILS:
                base = segs[:-2]
            elif method == "DELETE":
                base = segs[:-1]
            else:
                continue
            family = routes.family_of("/" + "/".join(base))
            if family:
                undone.add(family)
    for step in doc.get("steps") or []:
        if not isinstance(step, dict) or not isinstance(step.get("do"), dict):
            continue
        for call in _post_bodies(step):
            family = routes.family_of(str(call["path"]))
            if not family:
                continue
            body = call.get("body")
            kind = body.get("kind") if isinstance(body, dict) else None
            dtype = f"{family}:{kind}" if isinstance(kind, str) else family
            if family in undone or dtype in allowed or family in allowed:
                continue
            problems.append(
                f"{name}: step {step.get('id')}: creates a {dtype} and no cleanup step undoes {family} "
                "(reverse, cancel or delete it in `cleanup`, or add a residue_allow entry with type, reason and owner)"
            )


def check_platform_residue(doc, name, problems, defined):
    """The `platform_residue` block of a process: what the run watches on the platform tenant (G18)."""
    block = doc.get("platform_residue")
    if block is None:
        return
    if not isinstance(block, dict):
        problems.append(f"{name}: platform_residue must be an object {{definitions, instances}}")
        return
    unknown = set(block) - {"definitions", "instances"}
    if unknown:
        problems.append(f"{name}: platform_residue has unknown keys: " + ", ".join(sorted(unknown)))
    for key in ("definitions", "instances"):
        value = block.get(key)
        if value is None:
            continue
        if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
            problems.append(f"{name}: platform_residue.{key} must be a list of names")
            continue
        for item in value:
            for ref in sorted(refs(item) - defined):
                problems.append(f"{name}: platform_residue.{key}: ${{{ref}}} is not an input and no step saves it")


POSITIONAL = re.compile(r"\$\.items\[\d+\]")


def positional_reads(value) -> list:
    """Every JSON path in a step that indexes an API list answer by position (`$.items[3].name`).
    `$[0]` and `$.rows[0]` read a database answer, not an API list, and are not this rule."""
    found = []
    if isinstance(value, str):
        found.extend(POSITIONAL.findall(value))
    elif isinstance(value, dict):
        for key, sub in value.items():
            found.extend(positional_reads(key))
            found.extend(positional_reads(sub))
    elif isinstance(value, list):
        for sub in value:
            found.extend(positional_reads(sub))
    return found


def check_positional(step, where, problems):
    """No positional index into a list that can grow: assert by name/key (`$.items[?name=x].field`).

    A list that is sorted by contract, or holds exactly one row by its own filter, is exempted by the step key
    `positional_ok` with the reason as text (T-3105: a catalogue grew and moved `$.items[12]`)."""
    reads = positional_reads({k: v for k, v in step.items() if k != "positional_ok"})
    if not reads:
        return
    reason = step.get("positional_ok")
    if isinstance(reason, str) and reason.strip():
        return
    problems.append(f"{where}positional index {reads[0]!r}: assert by name/key ($.items[?name=x].field), "
                    "or give the step a positional_ok reason (a list sorted by contract or filtered to one row)")


def check_wait_mail(step, where, problems):
    """The wait_mail step (G18): a recipient, a subject and a time the runner can read.

    The loader (scripts/uat/runner.py) refuses the same shapes, so the two tools never disagree about one file."""
    spec = (step.get("do") or {}).get("wait_mail")
    if not isinstance(spec, dict):
        return
    if not all(isinstance(spec.get(key), str) and spec.get(key).strip() for key in ("recipient", "subject")):
        problems.append(f"{where}wait_mail needs a recipient and a subject")
    for key in ("within_s", "interval_s"):
        if key in spec and not runner.wait_time_ok(spec[key]):
            problems.append(f"{where}wait_mail {key} must be a number (a ${{name}} of the context is read as one)")


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
                check_path(problems, where(sid), routes, method, path, shared=step.get("http_as") == "shared_access",
                           platform_route=step.get("platform_route") is True)
            if "wait_mail" in (step.get("do") or {}):
                check_wait_mail(step, where(sid), problems)
            check_positional(step, where(sid), problems)
            defined |= saves(step)
    outputs = doc.get("outputs") or {}
    for out_name, expr in outputs.items():
        for name_ in sorted(refs(expr) - defined):
            problems.append(f"{name}: output {out_name}: ${{{name_}}} is not saved by any step")
    check_platform_residue(doc, name, problems, defined)
    if strict and routes.loaded:
        check_cleanup_coverage(doc, name, routes, problems)
    return set(outputs)


def check_path(problems, where, routes, method, path, shared=False, platform_route=False):
    if not method or not path:
        problems.append(f"{where}a call needs a method and a path")
        return
    if platform_route:  # T-3108: only a step flagged `platform_route: true`, only the provisioner mount
        if not path.startswith("/admin/v1/") or ".." in path:
            problems.append(f"{where}path {path!r} of a platform_route step must start with /admin/v1/")
        return  # the provisioner router is not in the router files compared below
    if not shared and not path.startswith("/api/"):
        problems.append(f"{where}path {path!r} must start with /api/")
        return
    if routes is None or not routes.loaded:
        return  # no router files to compare with (a test root without lib/): nothing to say
    if not routes.match(method, path, shared=shared):
        problems.append(f"{where}{method.upper()} {path} matches no route of the router files")


def actor_value_ok(value) -> bool:
    """An actor is a user name, or an object {user, tenant, base_url}: the actor of another tenant."""
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, dict):
        user = value.get("user")
        if not isinstance(user, str) or not user.strip():
            return False
        for key in ("tenant", "base_url"):
            if value.get(key) is not None and (not isinstance(value[key], str) or not value[key].strip()):
                return False
        return True
    return False


def check_dry_run(doc, name, problems):
    block = doc["dry_run"]
    if not isinstance(block, dict):
        problems.append(f"{name}: dry_run must be an object {{tenant, actors, inputs}}")
        return
    if not isinstance(block.get("tenant"), str) or not block["tenant"]:
        problems.append(f"{name}: dry_run.tenant is missing")
    if not isinstance(block.get("actors"), dict) or not all(actor_value_ok(v) for v in block["actors"].values()):
        problems.append(f"{name}: dry_run.actors must map each actor to a user name (or to {{user, tenant, base_url}})")
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
    try:
        retired_map = retired.load_retired(root)
    except retired.RetiredError as err:
        retired_map = {}
        problems.append(f"retired-tenants: {err}")
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
        problems.extend(retired.violations(doc, name, retired_map))
        fdir = runner.fixtures_dir_for(f)
        if isinstance(doc, dict) and "processes" in doc:
            check_chain(f, doc, roles, routes, strict, problems, retired_map)
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


def check_chain(path: Path, doc, roles, routes, strict, problems, retired_map=None):
    name = path.name
    if not doc.get("id") or not isinstance(doc.get("processes"), list) or not doc["processes"]:
        problems.append(f"{name}: a chain needs an id and a non-empty processes list")
        return
    mode = doc.get("cleanup", "end")
    if mode not in runner.CLEANUP_MODES:
        problems.append(f"{name}: cleanup must be one of {', '.join(runner.CLEANUP_MODES)}, got {mode!r}")
    if strict and not isinstance(doc.get("dry_run"), dict):
        problems.append(f"{name}: dry_run is missing (the block {{tenant, actors, inputs}} for the dry run on QA)")
    if isinstance(doc.get("dry_run"), dict):
        block = doc["dry_run"]
        if not isinstance(block.get("tenant"), str) or not block["tenant"]:
            problems.append(f"{name}: dry_run.tenant is missing")
        if not isinstance(block.get("actors"), dict) or not all(actor_value_ok(v) for v in block["actors"].values()):
            problems.append(f"{name}: dry_run.actors must map each actor to a user name (or to {{user, tenant, base_url}})")
    provided = set(doc.get("inputs") or {}) | set((doc.get("dry_run") or {}).get("inputs") or {})
    available = set(provided) | fixture_provides(doc, name, runner.fixtures_dir_for(path), problems)
    pass_map = doc.get("pass", {})
    if not isinstance(pass_map, dict):
        problems.append(f"{name}: pass must be an object {{process id: [output names]}}")
        pass_map = {}
    seen_ids = set()
    for entry in doc["processes"]:
        proc_name = entry.get("process") if isinstance(entry, dict) else entry
        own = None  # an object entry runs on its own tenant: its own inputs only
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
        if isinstance(entry, dict):
            try:
                own = runner.chain_overrides({"processes": [entry]}, [pdoc]).get(pdoc.get("id"))
            except runner.ConfigError as err:
                problems.append(f"{name}: {err}")
                continue
            if own:
                for line in retired.violations(dict(own), f"{name} entry {pdoc.get('id')}", retired_map or {}):
                    problems.append(line)
        available |= fixture_provides(pdoc, f"{name} > {pfile.name}", runner.fixtures_dir_for(path), problems)
        # a process inside a chain needs no dry_run of its own: the chain carries it
        outputs = check_process(pdoc, f"{name} > {pfile.name}", roles, routes,
                                (set(own.get("inputs") or {}) | set(runner.BUILTIN_NAMES)) if own else available,
                                False, problems, in_chain=True)
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
    if any("retired" in p for p in problems):
        return 2
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
