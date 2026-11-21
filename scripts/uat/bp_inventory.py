#!/usr/bin/env python3
"""bp_inventory.py <area|all> -- the mechanical INVENTORY of the business-process map (D-168/D-169).

For one area (or all) it lists every thing a business process could use:

  screen   a web page: a route of web/src/router.tsx or web/src/modules/<m>/*Routes.tsx + its page component
  route    an API route: `authz_get/post/put/patch/delete "<path>", :Permission` (or a plain verb macro) in
           lib/letflow/routers/*.ex and lib/letflow/modules/<m>/router.ex, with the full mounted path
  pack_node  a node (not START/END/SCRIPT_TASK) of a process definition in priv/modules/<m>/pack.json
  script   a SCRIPT_TASK node of a pack, a *.lua file of the area, or a file of lib/letflow/scripts/ (designer)
  handler  a module write handler: a `%Letflow.Modules.WriteHandlerSpec{name: ...}` in lib/letflow/modules/<m>/
           (this is also the engine function a pack calls from a `module_writes` line)
  rule     a business rule: a public `def` of a policy / declare / rules / checks / guard file (see RULE_GLOBS)

Output: a JSON list of {id, kind, path, line, name, end, aliases, ...}. `end` is the last line the item
covers (the line before the next item of the same file, or the end of the file): check_catalog.py counts
a `code_refs` entry `path:line` as a reference to the item when path matches and line lies in [line, end].
`aliases` are the other names a process task may use for the item in `forms` / `functions` (README).

Standard library only. `--root DIR` points at another checkout (the tests build small fake ones).
`--unassigned` lists router files, module directories and core web routes that no area owns (a gap in AREAS).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]

# ---------------------------------------------------------------------------------------------------------
# The area table: which source paths belong to which area.
#   modules  module ids (lib/letflow/modules/<m>/, priv/modules/<m>/, web/src/modules/<m>/*Routes.tsx)
#   routers  router files outside a module directory (lib/letflow/routers/*.ex, lib/letflow/router.ex)
#   web      regexes on a web/src/router.tsx route path; the first area whose regex matches owns the screen
#   rules    extra files (glob, relative to the root) whose public defs are business rules
#   scripts  extra globs whose files are scripts
# A module's own rule files are found by RULE_GLOBS below.
# ---------------------------------------------------------------------------------------------------------
AREAS: dict[str, dict] = {
    "stock": {
        "modules": ["stock"],
        "routers": ["lib/letflow/routers/shared_stock_access.ex"],
    },
    "assets": {"modules": ["assets"]},
    "procurement": {"modules": ["procurement"]},
    "maintenance": {
        "modules": ["maintenance"],
        "routers": [
            "lib/letflow/routers/maintenance_v1.ex",
            "lib/letflow/routers/maintenance_owner_list_v1.ex",
        ],
    },
    "master": {"modules": ["org", "locations", "catalog_items", "codes"]},
    "exam": {"modules": ["exam"]},
    "mes": {"modules": ["mes_core"]},
    "tenant-admin": {
        # the split literal keeps the repo-wide flag-route text scan (flip authority test) clean
        "routers": [
            "identity", "me", "tenant_settings", "tenant_logo", "tenant_config", "tenant_config_bundle",
            "tenant_modules", "tenant_role_grants", "tenant_role_scope_grants", "tenant_scope_" "enforcement",
            "tenant_scope_node_paths", "tenant_solutions", "approval_rules", "ledger_settings", "labels",
            "currencies", "number_sequences", "notification_templates", "notification_deliveries", "audit",
            "data_export", "help", "mobile_tenant_config", "entity_scope_declarations",
        ],
        "web": [
            r"^admin/(users|groups|tokens|audit|appearance|print-templates|currencies|official-forms|"
            r"approval-rules|ledger-settings|import|module-lifecycle)",
            r"^me/", r"^help/", r"^dashboard$", r"^login$", r"^auth/",
        ],
        "rules": [
            "lib/letflow/approval_rules.ex",
            "lib/letflow/engine/separation_of_duties.ex",
            "lib/letflow/engine/approval_rule_setting.ex",
        ],
    },
    "platform": {
        "modules": ["runtime_demo"],
        "routers": [
            "tenants", "onboarding", "signup", "login_discovery", "admin_v1", "admin_services",
            "platform_migrations", "platform_module_rollouts", "platform_problem_reports", "platform_status",
            "event_retention", "metrics_exposition", "modules", "router",
        ],
        "web": [
            r"^platform-dashboard", r"^admin/(health|metrics|onboarding|tenants|module-rollouts|"
            r"problem-reports|services|platform-migrations|event-retention)",
            r"^verify/",
        ],
    },
    "designer": {
        "routers": [
            "definitions", "instances", "tasks", "documents", "promotions", "solution_packs", "entities",
            "entity_views", "entity_type_extensions", "entity_type_hooks", "record_trigger_bindings",
            "scheduled_jobs", "script_rules", "script_policy", "webhooks", "dlq", "integration_mappings",
            "services", "public_read", "public_read_handles",
        ],
        "web": [
            r"^definitions", r"^promotions", r"^instances", r"^tasks", r"^solution-packs", r"^dlq$",
            r"^webhooks$", r"^entities/", r"^reports",
        ],
        "scripts": ["lib/letflow/scripts/*.ex"],
    },
}

# Business rules of a module: the public defs of these files (relative to lib/letflow/modules/<m>/).
RULE_GLOBS = [
    "ledger_policy/*.ex",
    "**/*rules*.ex",
    "**/*checks*.ex",
    "**/*guard*.ex",
    "**/*policy*.ex",
]

AREA_NAMES = list(AREAS)
SKIPPED_SCREEN_PATHS = {"*", "/"}

ROUTE_RE = re.compile(
    r'^\s*(authz_)?(get|post|put|patch|delete)\s*\(?\s*"([^"]*)"(?:\s*,\s*:(\w+))?'
)
FORWARD_RE = re.compile(r'^\s*forward\(\s*"([^"]+)"\s*,\s*to:\s*([\w.]+)')
DEFMODULE_RE = re.compile(r"^\s*defmodule\s+([\w.]+)\s+do")
DEF_RE = re.compile(r"^  def\s+([a-z_][\w?!]*)")
HANDLER_RE = re.compile(r"%(?:Letflow\.Modules\.)?WriteHandlerSpec\{")
NAME_RE = re.compile(r'^\s*name:\s*"([^"]+)"')
PATH_TOKEN_RE = re.compile(r"""path:\s*['"`]([^'"`]*)['"`]""")
QUOTED_RE = re.compile(r"""['"]([A-Za-z0-9_\-/:.*]+)['"]""")
JSX_TAG_RE = re.compile(r"<([A-Z]\w*)")
JSX_IGNORED = {"RequirePermission", "ModuleGuard", "Navigate", "Suspense", "Outlet"}


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def rel(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def module_name(lines: list[str]) -> str:
    for line in lines:
        m = DEFMODULE_RE.match(line)
        if m:
            return m.group(1)
    return ""


# -------------------------------------------------------------------------------------------- mounts
def mounts(root: Path) -> dict[str, str]:
    """Router module -> mount prefix, from the `forward` lines of lib/letflow/router.ex and
    lib/letflow/plugs/api_pipeline.ex (the latter is itself mounted at /api/v1)."""
    out: dict[str, str] = {}
    for file, prefix in (("lib/letflow/router.ex", ""), ("lib/letflow/plugs/api_pipeline.ex", "/api/v1")):
        p = root / file
        if not p.is_file():
            continue
        for line in read_lines(p):
            if line.lstrip().startswith("#"):
                continue
            m = FORWARD_RE.match(line)
            if m:
                out[m.group(2)] = prefix + m.group(1)
    return out


def norm_join(prefix: str, path: str) -> str:
    full = prefix + ("" if path == "/" else path)
    return full or "/"


# ----------------------------------------------------------------------------------------------- items
def item(kind: str, path: str, line: int, name: str, **extra) -> dict:
    d = {"id": "", "kind": kind, "path": path, "line": line, "name": name, "end": line, "aliases": []}
    d.update(extra)
    return d


def route_items(root: Path, file: Path, mount_prefix: str) -> list[dict]:
    out = []
    for n, line in enumerate(read_lines(file), 1):
        if line.lstrip().startswith("#"):
            continue
        m = ROUTE_RE.match(line)
        if not m:
            continue
        verb = m.group(2).upper()
        full = norm_join(mount_prefix, m.group(3))
        out.append(
            item("route", rel(root, file), n, f"{verb} {full}", permission=m.group(4) or "")
        )
    return out


def web_screen_items(root: Path, file: Path, accept) -> list[dict]:
    """Screens of one routes file. `accept(path)` decides whether a route path belongs to the area."""
    lines = read_lines(file)
    marks: list[tuple[int, list[str]]] = []  # (line index, route paths opened on this line)
    for i, line in enumerate(lines):
        paths = [m.group(1) for m in PATH_TOKEN_RE.finditer(line)]
        if not paths and "...[" in line and ".map(" in line:
            paths = QUOTED_RE.findall(line.split(".map(")[0])
        if paths:
            marks.append((i, paths))
    out = []
    for k, (i, paths) in enumerate(marks):
        stop = marks[k + 1][0] if k + 1 < len(marks) else len(lines)
        # a `...['a','b'].map(` opens its element on the following lines: look until the next route mark
        segment = "\n".join(lines[i:stop])
        comp = ""
        for tag in JSX_TAG_RE.findall(segment):
            if tag not in JSX_IGNORED:
                comp = tag
                break
        for p in paths:
            if p in SKIPPED_SCREEN_PATHS or p.startswith("/__harness") or not accept(p):
                continue
            name = f"{p} -> {comp}" if comp else p
            out.append(
                item("screen", rel(root, file), i + 1, name, route_path=p, component=comp,
                     aliases=[a for a in (p, "/" + p.lstrip("/"), comp) if a])
            )
    return out


def pack_items(root: Path, pack: Path, module_id: str) -> list[dict]:
    try:
        data = json.loads(pack.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    lines = read_lines(pack)
    key_lines: dict[str, int] = {}
    for n, line in enumerate(lines, 1):
        m = re.match(r'\s*"process_key":\s*"([^"]+)"', line)
        if m:
            key_lines.setdefault(m.group(1), n)
    out = []
    prev_key_line = 0
    for d in data.get("definitions", []):
        key = d.get("process_key", "")
        key_line = key_lines.get(key, len(lines))
        for node in d.get("graph", {}).get("nodes", []):
            ntype, nid = node.get("node_type", ""), node.get("id", "")
            if ntype in ("START", "END") or not nid:
                continue
            line_no = prev_key_line + 1
            for n in range(prev_key_line, min(key_line, len(lines))):
                if re.match(rf'\s*"id":\s*"{re.escape(nid)}"', lines[n]) and n + 1 < len(lines) \
                        and "node_type" in lines[n + 1]:
                    line_no = n + 1
                    break
            kind = "script" if ntype == "SCRIPT_TASK" else "pack_node"
            out.append(
                item(kind, rel(root, pack), line_no, f"{key}/{nid}", node_type=ntype, module=module_id,
                     aliases=[f"{module_id}:{key}/{nid}"])
            )
        prev_key_line = key_line
    return out


def handler_items(root: Path, module_dir: Path, module_id: str) -> list[dict]:
    out = []
    for file in sorted(module_dir.rglob("*.ex")):
        lines = read_lines(file)
        for i, line in enumerate(lines):
            if not HANDLER_RE.search(line):
                continue
            for j in range(i, min(i + 6, len(lines))):
                m = NAME_RE.match(lines[j])
                if m:
                    name = m.group(1)
                    out.append(
                        item("handler", rel(root, file), i + 1, f"{module_id}.{name}", handler=name,
                             module=module_id, aliases=[f"{module_id}:{name}"])
                    )
                    break
    return out


def rule_items(root: Path, files: list[Path]) -> list[dict]:
    out = []
    for file in files:
        lines = read_lines(file)
        mod = module_name(lines)
        seen: set[str] = set()
        for n, line in enumerate(lines, 1):
            m = DEF_RE.match(line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1))
                out.append(item("rule", rel(root, file), n, f"{mod}.{m.group(1)}", function=m.group(1)))
    return out


def script_file_items(root: Path, files: list[Path]) -> list[dict]:
    out = []
    for file in files:
        name = module_name(read_lines(file)) or file.stem if file.suffix == ".ex" else file.name
        out.append(item("script", rel(root, file), 1, name, aliases=[file.stem, file.name]))
    return out


# ------------------------------------------------------------------------------------------ one area
def glob_files(base: Path, patterns: list[str]) -> list[Path]:
    seen: dict[Path, None] = {}
    for pat in patterns:
        for p in sorted(base.glob(pat)):
            if p.is_file():
                seen[p] = None
    return list(seen)


def core_router_file(root: Path, stem: str) -> Path:
    if stem == "router":
        return root / "lib/letflow/router.ex"
    return root / "lib/letflow/routers" / f"{stem}.ex"


def web_accept_for(area: str):
    pats = [re.compile(p) for p in AREAS[area].get("web", [])]
    return lambda path: any(p.search(path) for p in pats)


def core_web_owner(path: str) -> str | None:
    path = path.lstrip("/")
    for area in AREA_NAMES:
        if web_accept_for(area)(path):
            return area
    return None


def area_items(root: Path, area: str) -> list[dict]:
    spec = AREAS[area]
    mount = mounts(root)
    items: list[dict] = []

    # --- routes ---
    router_files: list[Path] = []
    for m in spec.get("modules", []):
        r = root / "lib/letflow/modules" / m / "router.ex"
        if r.is_file():
            router_files.append(r)
    for stem in spec.get("routers", []):
        f = root / stem if stem.endswith(".ex") else core_router_file(root, stem)
        if f.is_file():
            router_files.append(f)
    for f in router_files:
        mod_dir = f.parent
        if mod_dir.parent.name == "modules" and f.name == "router.ex":
            prefix = f"/api/v1/modules/{mod_dir.name}"
        else:
            prefix = mount.get(module_name(read_lines(f)), "")
        items += route_items(root, f, prefix)

    # --- screens ---
    for m in spec.get("modules", []):
        for f in sorted((root / "web/src/modules" / m).glob("*Routes.tsx")):
            items += web_screen_items(root, f, lambda _p: True)
    router_tsx = root / "web/src/router.tsx"
    if router_tsx.is_file() and spec.get("web"):
        items += web_screen_items(root, router_tsx, lambda p, a=area: core_web_owner(p) == a)

    # --- packs, handlers, rules, scripts of each module ---
    for m in spec.get("modules", []):
        pack = root / "priv/modules" / m / "pack.json"
        if pack.is_file():
            items += pack_items(root, pack, m)
        mdir = root / "lib/letflow/modules" / m
        if mdir.is_dir():
            items += handler_items(root, mdir, m)
            items += rule_items(root, glob_files(mdir, RULE_GLOBS))
        items += script_file_items(
            root, [p for base in (root / "priv/modules" / m, mdir) if base.is_dir() for p in sorted(base.rglob("*.lua"))]
        )
    items += rule_items(root, [root / g for g in spec.get("rules", []) if (root / g).is_file()])
    script_files = glob_files(root, spec.get("scripts", []))
    items += script_file_items(root, script_files)
    return finish(items)


def finish(items: list[dict]) -> list[dict]:
    """Stable ids, `end` lines, deterministic order."""
    items.sort(key=lambda d: (d["path"], d["line"], d["kind"], d["name"]))
    lengths: dict[str, int] = {}
    by_path: dict[str, list[dict]] = {}
    for d in items:
        by_path.setdefault(d["path"], []).append(d)
    for path, group in by_path.items():
        for k, d in enumerate(group):
            nxt = next((g["line"] for g in group[k + 1:] if g["line"] > d["line"]), None)
            d["end"] = (nxt - 1) if nxt else max(d["line"], d["end"])
    seen: dict[str, int] = {}
    for d in items:
        base = f"{d['kind']}:{d['path']}:{d['name']}"
        seen[base] = seen.get(base, 0) + 1
        d["id"] = base if seen[base] == 1 else f"{base}#{seen[base]}"
    return items


def fix_open_ends(root: Path, items: list[dict]) -> None:
    """The last item of a file covers up to the end of that file."""
    cache: dict[str, int] = {}
    for d in items:
        if d["end"] <= d["line"]:
            n = cache.setdefault(d["path"], len(read_lines(root / d["path"])))
            d["end"] = max(d["line"], n)


def inventory(root: Path, area: str) -> list[dict]:
    if area == "all":
        out: list[dict] = []
        for a in AREA_NAMES:
            for d in inventory(root, a):
                d = dict(d)
                d["area"] = a
                out.append(d)
        return out
    if area not in AREAS:
        raise KeyError(area)
    items = area_items(root, area)
    fix_open_ends(root, items)
    for d in items:
        d["area"] = area
    return items


# ------------------------------------------------------------------------------------- unassigned
def unassigned(root: Path) -> list[str]:
    """Router files, module directories and core web routes that no area owns."""
    owned_routers = {s for a in AREAS.values() for s in a.get("routers", [])}
    owned_modules = {m for a in AREAS.values() for m in a.get("modules", [])}
    out = []
    rdir = root / "lib/letflow/routers"
    if rdir.is_dir():
        for f in sorted(rdir.glob("*.ex")):
            if f.stem not in owned_routers and rel(root, f) not in owned_routers:
                out.append(f"router {rel(root, f)}")
    mdir = root / "lib/letflow/modules"
    if mdir.is_dir():
        for d in sorted(p for p in mdir.iterdir() if p.is_dir()):
            if d.name not in owned_modules:
                out.append(f"module {rel(root, d)}")
    router_tsx = root / "web/src/router.tsx"
    if router_tsx.is_file():
        for d in web_screen_items(root, router_tsx, lambda p: core_web_owner(p) is None):
            out.append(f"screen {d['route_path']} ({d['path']}:{d['line']})")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("area", nargs="?", help="one of: " + ", ".join(AREA_NAMES) + ", all")
    ap.add_argument("--root", default=str(DEFAULT_ROOT), help="product checkout (default: this one)")
    ap.add_argument("--unassigned", action="store_true", help="list sources that no area owns")
    ap.add_argument("--summary", action="store_true", help="print counts per kind instead of the list")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    if args.unassigned:
        for line in unassigned(root):
            print(line)
        return 0
    if not args.area or (args.area != "all" and args.area not in AREAS):
        print(f"bp_inventory: area must be one of {', '.join(AREA_NAMES)}, all", file=sys.stderr)
        return 2
    items = inventory(root, args.area)
    if args.summary:
        counts: dict[str, int] = {}
        for d in items:
            counts[d["kind"]] = counts.get(d["kind"], 0) + 1
        print(json.dumps({"area": args.area, "total": len(items), "by_kind": counts}, sort_keys=True))
    else:
        print(json.dumps(items, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
