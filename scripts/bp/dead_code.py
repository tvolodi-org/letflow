#!/usr/bin/env python3
"""dead_code.py -- the MECHANICAL, function-level DEAD-CODE inventory (D-172).

`bp_inventory.py` lists what a business process could USE (routes, screens, pack nodes,
write handlers, scripts, rule files). It has no function-level items for the context
modules, so a dead context function -- a public function of `lib/letflow/` that nothing
calls -- is invisible to it (see `project/bp-orphans.md`, "LIMIT OF THE TOOL").

This tool closes that hole. It is mechanical and deterministic: the same checkout gives
the same bytes, every list is sorted, and nothing is decided by a model.

    python3 scripts/bp/dead_code.py                  # the report + the counts
    python3 scripts/bp/dead_code.py --area stock     # one area
    python3 scripts/bp/dead_code.py --json           # the report on stdout
    python3 scripts/bp/dead_code.py --check          # the CI gate (see below)

WHAT IS REPORTED

For every PUBLIC function (`def`, `defmacro`) of every module under `lib/letflow/`:

  reason = no_caller        no caller in lib/ and no caller in test/
  reason = test_only        a caller in test/ but none in lib/
  reason = dynamic_suspect  no caller at all, but the module is the target of a dynamic
                             dispatch, so the tool cannot prove the function is dead

A function with a caller in lib/ is NOT reported. Nothing is deleted and nothing in
`lib/` is changed by this tool: it only writes a report, an allow-list and a baseline.

WHERE THE CALLERS COME FROM

  * `mix xref` (`scripts/bp/xref_calls.exs`, run through `mix run --no-start`): the
    runtime call graph of the compiled project -- the authoritative source for the
    calls in `lib/`. It sees REMOTE calls only.
  * the source of `lib/` and `test/`: the local calls (a call to a function of the same
    module), the calls through an `import`, the calls the compiler cannot see
    (`apply/3`, `{Mod, :fun, args}` tuples, `&Mod.fun/n`) and the calls of the test
    files (`test/**` is not compiled into the graph).

  A caller is matched by module and function NAME (not by arity): a call to `Mod.fun/1`
  counts as a caller of `Mod.fun/2` as well. That keeps the false-positive count low;
  the price is that a function whose only caller is a call of another arity is not
  reported. The tool errs towards "not dead".

THE ROOTS (a function with one of them is never reported)

  * `@impl` -- an implementation of a behaviour;
  * a `defimpl` module -- a protocol implementation;
  * a callback of a behaviour the module declares (`@behaviour`), of a behaviour it
    `use`s (GenServer, Plug, Ecto.Schema, Oban.Worker, ...) or of one of the project's
    own behaviours (the `@callback` names of the project's behaviour modules);
  * `child_spec/1`, `init/1` and `call/2` of a Plug, `run/1` of a Mix task, `start/2` of
    an application, a `defoverridable` function, a route action of a router module;
  * a reference as a value: `&Mod.fun/n`, `{Mod, :fun, args}`, `apply(Mod, :fun, args)`
    with literal atoms, a `{Mod, :fun}` in the config, a function named by a string of
    a pack or of the config;
  * an entry of `docs/bp/dead-code-allow.json` (the business analyst's list, with a
    reason per entry -- the tool never adds to it).

THE FILES

  docs/bp/dead-code.json          the report (this tool writes it)
  docs/bp/dead-code-allow.json    the allow-list (the BA fills it in; the tool never
                                  writes to it)
  docs/bp/dead-code-baseline.json the functions that were dead at the first run; `--check`
                                  fails only when a NEW dead function appears

`--check` reads the baseline and the allow-list and fails when a dead function that is
in neither of them appears: the number of dead functions cannot grow. Removing one from
the baseline is allowed.

Standard library only. `--root DIR` points at another checkout.
"""
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parents[1]

REPORT_FILE = "docs/bp/dead-code.json"
ALLOW_FILE = "docs/bp/dead-code-allow.json"
BASELINE_FILE = "docs/bp/dead-code-baseline.json"
TOOL_VERSION = 1


# The area table is the one of bp_inventory.py (D-168/D-169): ONE table, shared.
def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


INV = _load("bp_inventory", HERE.parent / "uat" / "bp_inventory.py")
AREAS = INV.AREAS

# --------------------------------------------------------------------------------------- the source scan
DEFMODULE_RE = re.compile(r"^(\s*)defmodule\s+([\w.]+)\s+do\b")
END_RE = re.compile(r"^(\s*)end\b")
DEF_RE = re.compile(r"^(\s*)def\s+([a-z_][\w]*[?!]?)\s*(\(|\bwhen\b|\bdo\b|,|$)")
DEFMACRO_RE = re.compile(r"^(\s*)defmacro\s+([a-z_][\w]*[?!]?)\s*(\(|\bwhen\b|\bdo\b)")
DEFGUARD_RE = re.compile(r"^(\s*)defguard\s+([a-z_][\w]*[?!]?)\s*\(")
DEFDEL_RE = re.compile(r"^(\s*)defdelegate\s+([a-z_][\w]*[?!]?)\s*(\(|,|$)")
BEHAVIOUR_RE = re.compile(r"^\s*@behaviour\s+([\w.]+)\s*$")
IMPL_RE = re.compile(r"^\s*@impl\b")
CALLBACK_RE = re.compile(r"^\s*@callback\s+([a-z_][\w]*[?!]?)\s*(\(|$)")
USE_RE = re.compile(r"^\s*use\s+([\w.]+)")
IMPORT_RE = re.compile(r"^\s*import\s+([\w.]+)")
ALIAS_RE = re.compile(r"^\s*alias\s+([A-Z][\w.]*)(?:\s*,\s*as:\s*([A-Z][\w]*))?\s*$", re.MULTILINE)
DEFOVERRIDABLE_RE = re.compile(r"^\s*defoverridable\s+(.*)$")
DELEGATE_TO_RE = re.compile(r"\bto:\s*([A-Z][\w.]*)")
DELEGATE_AS_RE = re.compile(r"\bas:\s*:([a-z_][\w]*[?!]?)")
DEFIMPL_RE = re.compile(r"^\s*defimpl\s+([\w.]+)")

# a remote call: `Mod.fun(`, `Letflow.Mod.fun(`
REMOTE_CALL_RE = re.compile(r"(?<![\w.$@])([A-Z][\w]*(?:\.[A-Z][\w]*)*)\.([a-z_][\w]*[?!]?)\s*\(")
# a capture: `&Mod.fun/3`
CAPTURE_RE = re.compile(r"&([A-Z][\w]*(?:\.[A-Z][\w]*)*)\.([a-z_][\w]*[?!]?)\s*/\s*(\d+)")
# `apply(Mod, :fun, args)` -- a literal target: a root
LITERAL_APPLY_RE = re.compile(r"\bapply\(\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)\s*,\s*:([a-z_][\w]*[?!]?)\s*,")
# `apply(Mod, fun, args)` -- a literal module, an unknown function: the module is a
# dynamic target (its functions may be the one dispatched).
APPLY_VARIABLE_FUN_RE = re.compile(r"\bapply\(\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)\s*,\s*([a-z_][\w]*)\s*,")
# `apply(mod, fun, args)` -- a variable module and a variable function: a dynamic call site
DYNAMIC_APPLY_RE = re.compile(r"\bapply\(\s*([a-z_][\w]*)\s*,")
MODULE_CONCAT_RE = re.compile(r"\bModule\.concat\(")
ATOM_FROM_STRING_RE = re.compile(r"\bString\.to_existing_atom\(")
# `{Mod, :fun}` or `{Mod, :fun, args}` -- a reference as a value: a root
MFA_TUPLE_RE = re.compile(r"\{\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)\s*,\s*:([a-z_][\w]*[?!]?)\s*[,}]")
# the head of a definition: `def foo(`, `defp foo(`, `defmacro foo(` -- the name in it is
# not a call, but the body of a one-line definition can hold one.
DEF_HEAD_RE = re.compile(r"^(\s*)def(p|macro|guard|delegate)?\s+([a-z_][\w]*[?!]?)")
# a local call: `fun(` with no module in front
LOCAL_CALL_RE = re.compile(r"(?<![\w.$@])([a-z_][\w]*[?!]?)\s*\(")
# a plug of the pipeline named by its atom: `plug(:authenticate)` -- Phoenix calls it
PLUG_ATOM_RE = re.compile(r"\bplug\s*\(?\s*:([a-z_][\w]*[?!]?)")
# a plug or a forward of another module: Phoenix calls its `call/2`
PLUG_MODULE_RE = re.compile(r"\bplug\s*\(\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)")
FORWARD_MODULE_RE = re.compile(r"\bforward\s+\"[^\"]*\"\s*,\s*to:\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)")

# The callbacks of the frameworks the product uses. A function with one of these names
# in a module that uses the framework is called by the framework, not by the code.
FRAMEWORK_CALLBACKS = {
    "GenServer": {"init/1", "handle_call/3", "handle_cast/2", "handle_info/2", "handle_continue/2",
                  "terminate/2", "code_change/3", "format_status/1", "start_link/1"},
    "Supervisor": {"init/1", "start_link/1"},
    "DynamicSupervisor": {"init/1", "start_link/1"},
    "PartitionSupervisor": {"init/1", "start_link/1"},
    "Task": {"child_spec/1", "start_link/1"},
    "Task.Supervisor": {"init/1"},
    "Registry": {"child_spec/1"},
    "Plug": {"init/1", "call/2"},
    "Plug.Builder": {"init/1", "call/2"},
    "Ecto.Schema": {"changeset/2", "put_changeset/2", "apply_changeset/2", "valid_changeset/2",
                    "prepare_changes/2"},
    "Ecto.Changeset": {"changeset/2", "put_changeset/2", "apply_changeset/2", "valid_changeset/2"},
    "Ecto.Repo": {"insert/2", "update/2", "delete/2", "get/2", "get!/2", "all/2", "one/2", "insert!/2",
                  "update!/2", "delete!/2", "insert_all/2", "delete_all/2", "update_all/3",
                  "transaction/1", "transaction/2", "rollback/1", "prepare_query/2", "exists?/2",
                  "one!/2", "aggregate/2", "preload/3", "checkout/1", "reload/1"},
    "Oban.Worker": {"perform/1", "perform/2", "timeout/1"},
    "Oban.Engine": {"init/1", "child_spec/1", "start_link/1"},
    "Application": {"start/2", "stop/1"},
    "GenEvent": {"init/1", "handle_event/2", "handle_call/2", "handle_info/2", "terminate/2",
                 "code_change/3"},
    "Connection": {"init/1", "handle_info/2", "handle_cast/2", "terminate/2"},
    "WebSock": {"init/1", "handle_in/3", "handle_info/2", "terminate/2"},
    "Phoenix.Component": {"render/1"},
    "Phoenix.LiveView": {"mount/3", "handle_params/3", "handle_event/3", "handle_info/2", "render/1"},
    "Mix.Task": {"run/1"},
    "Access": {"fetch/2", "get_and_update/3"},
}
# A function with one of these names is called by OTP or by the compiler, whatever the module.
GENERIC_CALLBACKS = {"child_spec/1"}
# The compiler calls these two of every macro module.
COMPILER_CALLBACKS = {"__using__", "__before_compile__"}
# The names a router module may use for the action of a route.
ROUTER_ACTION_PREFIXES = ("handle_", "action_")


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


# -------------------------------------------------------------------------------------- the area table
def area_patterns(areas: dict) -> list[tuple[str, str]]:
    """(pattern, area) pairs: an exact file path, a directory prefix ('.../') or a glob."""
    out: list[tuple[str, str]] = []
    for area, spec in areas.items():
        for module in spec.get("modules", []):
            out.append((f"lib/letflow/modules/{module}/", area))
        for router in spec.get("routers", []):
            if router.endswith(".ex"):
                out.append((router, area))
            elif router == "router":
                out.append(("lib/letflow/router.ex", area))
            else:
                out.append((f"lib/letflow/routers/{router}.ex", area))
        for rule in spec.get("rules", []):
            out.append((rule, area))
        for script in spec.get("scripts", []):
            out.append((script, area))
    return out


def area_of(path: str, patterns: list[tuple[str, str]]) -> str:
    """The area that owns a file. The longest matching pattern wins; no owner = 'unassigned'."""
    best: tuple[int, str] | None = None
    for pattern, area in patterns:
        if pattern.endswith("/"):
            if not path.startswith(pattern):
                continue
            size = len(pattern)
        elif any(ch in pattern for ch in "*?["):
            if not fnmatch.fnmatch(path, pattern):
                continue
            size = len(pattern)
        else:
            if path != pattern:
                continue
            size = len(pattern) + 1  # an exact path beats a prefix of the same length
        if best is None or size > best[0]:
            best = (size, area)
    return best[1] if best else "unassigned"


# -------------------------------------------------------------------------------------- the file scan
class FileScan:
    """What one source file says: its modules, its calls, its roots and its dynamic sites."""

    def __init__(self, path: str, lines: list[str]):
        self.path = path
        self.lines = lines
        self.modules: list[dict] = []
        self.remote_calls: list[tuple[str, str, int]] = []   # (module, function, line)
        self.local_calls: list[tuple[str, int]] = []          # (function, line)
        self.roots: list[tuple[str, str, int]] = []           # (module, function, line)
        self.dynamic: list[tuple[str, int]] = []              # (kind, line)
        self.dynamic_targets: list[tuple[str, int]] = []      # (module, line)
        self.imports: list[str] = []
        self.aliases: dict[str, str] = {}
        self.words: set[str] = set()


def resolve_alias(module: str, aliases: dict[str, str]) -> str:
    """`alias Letflow.Identity` makes `Identity` mean `Letflow.Identity`."""
    if module in aliases:
        return aliases[module]
    head, _, tail = module.rpartition(".")
    if head and tail in aliases:
        return aliases[tail]
    return module


def module_blocks(lines: list[str]) -> list[tuple[str, int, int, int]]:
    """(module name, indent, first line, last line) of every defmodule block (1-based lines)."""
    blocks: list[tuple[str, int, int, int]] = []
    stack: list[tuple[str, int, int]] = []
    for index, line in enumerate(lines):
        match = DEFMODULE_RE.match(line)
        if match:
            stack.append((match.group(2), len(match.group(1)), index + 1))
            continue
        end = END_RE.match(line)
        if end and stack:
            name, indent, start = stack[-1]
            if len(end.group(1)) == indent:
                stack.pop()
                blocks.append((name, indent, start, index + 1))
    return blocks


def head_arity(lines: list[str], index: int) -> int:
    """The arity of the definition head at `index` (the maximum arity: a default counts)."""
    text = lines[index]
    column = text.find("(")
    if column < 0:
        return 0
    joined = text
    for extra in range(12):
        depth = 0
        args: list[str] = []
        current = ""
        in_string: str | None = None
        for char in joined[column:]:
            if in_string:
                current += char
                if char == in_string:
                    in_string = None
                continue
            if char in "\"'":
                in_string = char
                current += char
                continue
            if char in "([{":
                depth += 1
                if depth == 1:
                    continue
            elif char in ")]}":
                depth -= 1
                if depth == 0:
                    break
            if char == "," and depth == 1:
                args.append(current)
                current = ""
                continue
            current += char
        if depth == 0:
            if current.strip():
                args.append(current)
            args = [a for a in args if a.strip() and a.strip() != "_"]
            return len(args)
        if index + extra + 1 >= len(lines):
            break
        joined = joined + "\n" + lines[index + extra + 1]
    return 0


def scan_file(path: str, lines: list[str]) -> FileScan:
    scan = FileScan(path, lines)
    blocks = module_blocks(lines)
    text = "\n".join(lines)

    for match in ALIAS_RE.finditer(text):
        full, as_name = match.group(1), match.group(2)
        scan.aliases[as_name or full.split(".")[-1]] = full
    scan.words = set(re.findall(r"[a-z_][\w]*[?!]?", text))

    # --- the modules and their functions ---
    for name, _indent, start, end in blocks:
        module = {
            "name": name,
            "file": path,
            "line": start,
            "functions": [],
            "behaviours": [],
            "uses": [],
            "imports": [],
            "impls": set(),
            "callbacks": set(),
            "defoverridable": set(),
            "is_defimpl": False,
        }
        scan.modules.append(module)
        pending_impl = False
        for number in range(start, end + 1):
            line = lines[number - 1]
            if IMPL_RE.match(line):
                pending_impl = True
                continue
            behaviour = BEHAVIOUR_RE.match(line)
            if behaviour:
                module["behaviours"].append(behaviour.group(1))
                continue
            callback = CALLBACK_RE.match(line)
            if callback:
                module["callbacks"].add(callback.group(1))
                continue
            use = USE_RE.match(line)
            if use:
                module["uses"].append(use.group(1))
                continue
            imported = IMPORT_RE.match(line)
            if imported:
                module["imports"].append(imported.group(1))
                scan.imports.append(imported.group(1))
                continue
            if DEFIMPL_RE.match(line):
                module["is_defimpl"] = True
                continue
            overridable = DEFOVERRIDABLE_RE.match(line)
            if overridable:
                for entry in overridable.group(1).split(","):
                    name_match = re.match(r"\s*([a-z_][\w]*[?!]?)\s*:", entry)
                    if name_match:
                        module["defoverridable"].add(name_match.group(1))
                continue
            match = DEF_RE.match(line)
            kind = "def"
            if not match:
                match = DEFMACRO_RE.match(line)
                kind = "defmacro"
                if not match:
                    match = DEFGUARD_RE.match(line)
                    kind = "defguard"
                    if not match:
                        match = DEFDEL_RE.match(line)
                        kind = "defdelegate"
            if not match:
                pending_impl = False
                continue
            if kind == "defdelegate":
                # `defdelegate foo(a), to: Mod, as: :bar` calls Mod.bar/1
                head = " ".join(lines[number - 1: number + 2])
                target = DELEGATE_TO_RE.search(head)
                if target:
                    alias_name = DELEGATE_AS_RE.search(head)
                    delegated = alias_name.group(1) if alias_name else match.group(2)
                    scan.roots.append((resolve_alias(target.group(1), scan.aliases), delegated, number))
            function = match.group(2)
            if any(f["name"] == function for f in module["functions"]):
                pending_impl = False
                continue   # the first clause of a name is its definition
            module["functions"].append({
                "name": function,
                "arity": head_arity(lines, number - 1),
                "line": number,
                "kind": kind,
                "public": not line.lstrip().startswith("defp"),
                "impl": pending_impl,
            })
            pending_impl = False

    # --- the calls, the roots and the dynamic sites ---
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        # the head of a definition is not a call, but its one-line body can hold one
        head = DEF_HEAD_RE.match(line)
        if head:
            line = " " * len(head.group(0)) + line[head.end(0):]
        for match in REMOTE_CALL_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.remote_calls.append((module_name, match.group(2), number))
        for match in CAPTURE_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.roots.append((module_name, match.group(2), number))
        for match in LITERAL_APPLY_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.roots.append((module_name, match.group(2), number))
        for match in MFA_TUPLE_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.roots.append((module_name, match.group(2), number))
        for match in APPLY_VARIABLE_FUN_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.dynamic_targets.append((module_name, number))
        for match in DYNAMIC_APPLY_RE.finditer(line):
            scan.dynamic.append(("apply_variable", number))
        if MODULE_CONCAT_RE.search(line):
            scan.dynamic.append(("module_concat", number))
        if ATOM_FROM_STRING_RE.search(line):
            scan.dynamic.append(("atom_from_string", number))
        for match in LOCAL_CALL_RE.finditer(line):
            scan.local_calls.append((match.group(1), number))
        for match in PLUG_ATOM_RE.finditer(line):
            # `plug(:authenticate)`: Phoenix calls the function of this module by its name
            for module in scan.modules:
                scan.roots.append((module["name"], match.group(1), number))
        for match in PLUG_MODULE_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.roots.append((module_name, "call", number))
        for match in FORWARD_MODULE_RE.finditer(line):
            module_name = resolve_alias(match.group(1), scan.aliases)
            scan.roots.append((module_name, "call", number))
    return scan


def elixir_files(root: Path, folder: str) -> list[Path]:
    base = root / folder
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob("*.ex") if p.is_file()) + \
        sorted(p for p in base.rglob("*.exs") if p.is_file())


# ---------------------------------------------------------------------------------------- the xref
def xref_env(root: Path, mix_env: str) -> dict[str, str]:
    """The environment of the `mix run` of the xref dump.

    config/runtime.exs refuses to boot without the secrets of the product. The dump runs
    `mix run --no-start`: the application is never started, no database is touched, and
    the values are generated for this run only (never written to a file).
    """
    env = dict(os.environ)
    env["MIX_ENV"] = mix_env
    env.setdefault("LETFLOW_SECRETS_MASTER_KEY", os.urandom(32).hex())
    env.setdefault("LETFLOW_LOGIN_DIRECTORY_PEPPER", os.urandom(32).hex())
    env.setdefault("LETFLOW_LOGIN_DIRECTORY_PEPPER_ID", "dead-code-tool")
    return env


def xref_cache_path(root: Path, mix_env: str) -> Path:
    """Where the xref dump is cached: under _build, never in the repository."""
    return root / "_build" / "dead-code" / f"xref-calls-{mix_env}.json"


def run_xref(root: Path, mix_env: str, timeout: int, use_cache: bool = False) -> list[dict]:
    """The runtime call graph of the project, as the JSON of scripts/bp/xref_calls.exs."""
    script = root / "scripts" / "bp" / "xref_calls.exs"
    if not script.is_file():
        return []
    cache = xref_cache_path(root, mix_env)
    if use_cache and cache.is_file():
        return load_xref_file(cache)
    command = ["mix", "run", "--no-start", str(script)]
    env = xref_env(root, mix_env)
    cache.parent.mkdir(parents=True, exist_ok=True)
    env["LETFLOW_XREF_OUT"] = str(cache)
    try:
        done = subprocess.run(command, cwd=str(root), env=env,
                              capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"mix xref failed: {exc}") from exc
    if done.returncode != 0:
        raise RuntimeError(f"mix xref failed (exit {done.returncode}): {done.stderr[-2000:]}")
    try:
        return json.loads(cache.read_text(encoding="utf-8") or "[]")
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"the xref dump is not JSON: {exc}") from exc


def load_xref_file(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data if isinstance(data, list) else []


# ---------------------------------------------------------------------------------- the string corpus
def config_roots(root: Path) -> set[tuple[str, str]]:
    """The `{Module, :function}` pairs of the config: the functions the config names."""
    out: set[tuple[str, str]] = set()
    folder = root / "config"
    if not folder.is_dir():
        return out
    for path in sorted(folder.glob("*.exs")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in MFA_TUPLE_RE.finditer(text):
            out.add((match.group(1), match.group(2)))
    return out


def string_corpus(root: Path) -> set[str]:
    """Every quoted string, every atom literal and every module reference of the config,
    the packs and the definitions -- the values that can name a function at runtime."""
    out: set[str] = set()
    folders = ("config", "priv/modules", "priv/letflow")
    files: list[Path] = []
    for folder in folders:
        base = root / folder
        if not base.is_dir():
            continue
        files += [p for p in sorted(base.rglob("*"))
                  if p.is_file() and p.suffix in (".exs", ".json", ".yaml", ".yml")]
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        out |= set(re.findall(r"""["']([^"'\n]{2,})["']""", text))
        out |= set(re.findall(r"(?<![\w.]):([a-z_][\w]{3,}[?!]?)", text))
        for module in re.findall(r"\b([A-Z][\w]*(?:\.[A-Z][\w]*)+)\b", text):
            out.add(module)
            out.add(module.split(".")[-1])
    return out


# -------------------------------------------------------------------------------------- the analysis
def summarize(entries: list[dict], scanned: dict[str, int] | None = None) -> dict:
    by_area: dict[str, int] = {}
    by_reason: dict[str, int] = {}
    by_area_reason: dict[str, dict[str, int]] = {}
    for entry in entries:
        by_area[entry["area"]] = by_area.get(entry["area"], 0) + 1
        by_reason[entry["reason"]] = by_reason.get(entry["reason"], 0) + 1
        by_area_reason.setdefault(entry["area"], {})
        by_area_reason[entry["area"]][entry["reason"]] = by_area_reason[entry["area"]].get(entry["reason"], 0) + 1
    summary = {
        "total": len(entries),
        "by_area": dict(sorted(by_area.items())),
        "by_reason": dict(sorted(by_reason.items())),
        "by_area_and_reason": {area: dict(sorted(reasons.items()))
                               for area, reasons in sorted(by_area_reason.items())},
    }
    if scanned is not None:
        summary["scanned"] = sum(scanned.values())
        summary["scanned_by_area"] = dict(sorted(scanned.items()))
    return summary


def is_callback(module: dict, name: str, arity: int, uses: set[str],
                project_callbacks: dict[str, set[str]]) -> bool:
    """A callback of a behaviour: the framework calls it, not the code."""
    if f"{name}/{arity}" in GENERIC_CALLBACKS:
        return True
    if name in COMPILER_CALLBACKS:
        return True
    for used in sorted(uses):
        if f"{name}/{arity}" in FRAMEWORK_CALLBACKS.get(used, set()):
            return True
        if name in project_callbacks.get(used, set()):
            return True
    for behaviour in module["behaviours"]:
        if name in project_callbacks.get(behaviour, set()):
            return True
    if "/mix/tasks/" in module["file"] and name == "run":
        return True
    if "/migrations/" in module["file"] and name in ("up", "down"):
        return True
    if module["name"].endswith("Application") and name in ("start", "stop"):
        return True
    if ("/routers/" in module["file"] or module["file"].endswith("lib/letflow/router.ex")) \
            and name.startswith(ROUTER_ACTION_PREFIXES):
        return True
    if uses and ((name == "init" and arity == 1) or (name == "call" and arity == 2)):
        # a module that uses a framework and defines init/1 or call/2 is a plug, a
        # GenServer or a supervisor: the framework calls it.
        return True
    return False


def analyze(root: Path, xref_calls: list[dict], allow: set[tuple[str, str, int]]) -> dict:
    """The dead-code report of a checkout."""
    patterns = area_patterns(AREAS)

    lib_scans: list[FileScan] = []
    test_scans: list[FileScan] = []
    for path in elixir_files(root, "lib"):
        lib_scans.append(scan_file(rel(root, path), read_lines(path)))
    for path in elixir_files(root, "test"):
        test_scans.append(scan_file(rel(root, path), read_lines(path)))

    # --- every module of the product and its public functions ---
    # The scope of the report is lib/letflow/ (the context modules); the callers are
    # collected from all of lib/ and from test/.
    modules: dict[str, dict] = {}
    for scan in lib_scans:
        if not scan.path.startswith("lib/letflow/"):
            continue
        for module in scan.modules:
            modules.setdefault(module["name"], module)

    # the callbacks the project's own behaviour modules declare
    project_callbacks: dict[str, set[str]] = {}
    for module in modules.values():
        if module["callbacks"]:
            project_callbacks[module["name"]] = set(module["callbacks"])

    # --- the callers ---
    lib_callers: set[tuple[str, str]] = set()
    test_callers: set[tuple[str, str]] = set()
    dynamic_sites: list[dict] = []
    dynamic_targets: set[str] = set()

    for call in xref_calls:
        callee = str(call.get("callee", ""))
        file = str(call.get("file", ""))
        if "." not in callee:
            continue
        module_name, _, function = callee.rpartition(".")
        if file.startswith("lib/"):
            lib_callers.add((module_name, function))
        elif file.startswith("test/"):
            test_callers.add((module_name, function))

    for scan in lib_scans:
        for module_name, function, _line in scan.remote_calls:
            lib_callers.add((module_name, function))
        for function, _line in scan.local_calls:
            for module in scan.modules:
                if any(f["name"] == function for f in module["functions"]):
                    lib_callers.add((module["name"], function))
        for imported in scan.imports:
            target = modules.get(imported)
            if not target:
                continue
            for function, _line in scan.local_calls:
                if any(f["name"] == function for f in target["functions"]):
                    lib_callers.add((imported, function))
            # a macro of the imported module is called without parentheses
            for function in target["functions"]:
                if function["kind"] == "defmacro" and function["name"] in scan.words:
                    lib_callers.add((imported, function["name"]))
        for module in scan.modules:
            for used in module["uses"]:
                target = modules.get(used)
                if not target:
                    continue
                for function in target["functions"]:
                    if function["kind"] == "defmacro" and function["name"] in scan.words:
                        lib_callers.add((used, function["name"]))
        for kind, line in scan.dynamic:
            dynamic_sites.append({"file": scan.path, "line": line, "kind": kind})
        for module_name, _line in scan.dynamic_targets:
            dynamic_targets.add(module_name)

    for scan in test_scans:
        for module_name, function, _line in scan.remote_calls:
            test_callers.add((module_name, function))
        for function, _line in scan.local_calls:
            for module in scan.modules:
                if any(f["name"] == function for f in module["functions"]):
                    test_callers.add((module["name"], function))
            for imported in scan.imports:
                target = modules.get(imported)
                if not target:
                    continue
                if any(f["name"] == function for f in target["functions"]):
                    test_callers.add((imported, function))
                for function in target["functions"]:
                    if function["kind"] == "defmacro" and function["name"] in scan.words:
                        test_callers.add((imported, function["name"]))

    # --- the roots: a reference as a value ---
    rooted: set[tuple[str, str]] = set()
    for scan in lib_scans + test_scans:
        for module_name, function, _line in scan.roots:
            rooted.add((module_name, function))
    rooted |= config_roots(root)

    # the corpus of the strings: a function named by a string in the config or a pack
    corpus = string_corpus(root)
    for module_name, module in modules.items():
        short = module_name.split(".")[-1]
        for function in module["functions"]:
            name = function["name"]
            if f"{module_name}.{name}" in corpus or f"{short}.{name}" in corpus:
                rooted.add((module_name, name))
            elif name in corpus and (module_name in corpus or short in corpus):
                rooted.add((module_name, name))
            else:
                # "stock.post_document": the name of the module part must be the module
                for item in corpus:
                    if len(item) > 120 or not item.endswith("." + name):
                        continue
                    head = item[: -len(name) - 1]
                    if head == module_name or head.lower() == short.lower():
                        rooted.add((module_name, name))
                        break

    # --- the report ---
    entries: list[dict] = []
    scanned: dict[str, int] = {}
    for module_name in sorted(modules):
        module = modules[module_name]
        area = area_of(module["file"], patterns)
        uses = set(module["uses"]) | set(module["behaviours"])
        for function in module["functions"]:
            if function["public"] and function["kind"] != "defguard":
                scanned[area] = scanned.get(area, 0) + 1
            if not function["public"] or function["kind"] == "defguard":
                continue   # a private function is not in scope; a guard is a macro used in
                #           guards, and its callers are not statically resolvable
            name = function["name"]
            key = (module_name, name)
            if module["is_defimpl"] or function["impl"]:
                continue   # a protocol implementation or an @impl
            if name in module["defoverridable"]:
                continue
            if key in rooted:
                continue
            if (module_name, name, function["arity"]) in allow or (module_name, name) in allow:
                continue
            if is_callback(module, name, function["arity"], uses, project_callbacks):
                continue
            if key in lib_callers:
                continue
            if module_name in dynamic_targets:
                # the module is the target of a dynamic dispatch: the tool cannot prove
                # that the function is dead, whatever the tests say
                reason = "dynamic_suspect"
            elif key in test_callers:
                reason = "test_only"
            else:
                reason = "no_caller"
            entries.append({
                "area": area,
                "module": module_name,
                "function": name,
                "arity": function["arity"],
                "file": module["file"],
                "line": function["line"],
                "kind": function["kind"],
                "reason": reason,
            })

    entries.sort(key=lambda e: (e["area"], e["module"], e["function"], e["arity"], e["file"], e["line"]))
    dynamic_sites.sort(key=lambda d: (d["file"], d["line"], d["kind"]))

    return {
        "functions": entries,
        "dynamic_call_sites": dynamic_sites,
        "summary": summarize(entries, scanned),
    }


# ----------------------------------------------------------------------------------- the allow-list
def load_allow(root: Path) -> tuple[set[tuple[str, str, int]], list[str]]:
    """The allow-list of the BA: {module, function, arity, reason}. The tool never writes it."""
    path = root / ALLOW_FILE
    errors: list[str] = []
    out: set[tuple[str, str, int]] = set()
    if not path.is_file():
        return out, errors
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return out, [f"ERROR {ALLOW_FILE}: invalid JSON ({exc})"]
    if not isinstance(data, list):
        return out, [f"ERROR {ALLOW_FILE}: the file must be a JSON list of entries"]
    for index, entry in enumerate(data, 1):
        if not isinstance(entry, dict):
            errors.append(f"ERROR {ALLOW_FILE}: entry {index} is not an object")
            continue
        module_name = entry.get("module")
        function = entry.get("function")
        arity = entry.get("arity")
        reason = entry.get("reason")
        if not (isinstance(module_name, str) and module_name.strip()):
            errors.append(f"ERROR {ALLOW_FILE}: entry {index}: module must be a text")
            continue
        if not (isinstance(function, str) and function.strip()):
            errors.append(f"ERROR {ALLOW_FILE}: entry {index}: function must be a text")
            continue
        if not (isinstance(reason, str) and reason.strip()):
            errors.append(f"ERROR {ALLOW_FILE}: entry {index}: a reason is required")
            continue
        out.add((module_name, function, arity if isinstance(arity, int) else -1))
    return out, errors


def load_baseline(root: Path) -> list[dict]:
    path = root / BASELINE_FILE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return data if isinstance(data, list) else []


def key_of(entry: dict) -> tuple[str, str, int]:
    return (entry.get("module", ""), entry.get("function", ""), entry.get("arity", -1))


# ------------------------------------------------------------------------------------------ the web
def web_section(root: Path) -> dict:
    """The unused exports of the web app -- only if a cheap tool already exists."""
    package = root / "web" / "package.json"
    if not package.is_file():
        return {"status": "not_covered", "reason": "web/package.json is not there"}
    try:
        data = json.loads(package.read_text(encoding="utf-8"))
    except ValueError as exc:
        return {"status": "not_covered", "reason": f"web/package.json is not readable ({exc})"}
    deps = {**data.get("dependencies", {}), **data.get("devDependencies", {})}
    for name in ("knip", "ts-prune"):
        if name in deps:
            return {"status": "tool_available", "tool": name,
                    "reason": f"{name} is in web/package.json: run it and add its output"}
    eslint = root / "web" / ".eslintrc.json"
    if eslint.is_file():
        try:
            rules = json.loads(eslint.read_text(encoding="utf-8")).get("rules", {})
        except ValueError:
            rules = {}
        if "no-unused-modules" in rules:
            return {"status": "tool_available", "tool": "eslint no-unused-modules",
                    "reason": "the eslint rule is on: run it and add its output"}
    return {"status": "not_covered",
            "reason": "web/ has no unused-export tool (no knip, no ts-prune, no eslint "
                      "no-unused-modules); the task forbids adding a dependency"}


# ------------------------------------------------------------------------------------------ the run
def build_report(root: Path, xref_calls: list[dict], mix_env: str, versions: dict) -> dict:
    allow, errors = load_allow(root)
    result = analyze(root, xref_calls, allow)
    return {
        "tool": "scripts/bp/dead_code.py",
        "tool_version": TOOL_VERSION,
        "versions": versions,
        "xref": {"source": "mix xref (Mix.Tasks.Xref.calls)", "mix_env": mix_env,
                 "calls": len(xref_calls)},
        "summary": result["summary"],
        "functions": result["functions"],
        "dynamic_call_sites": result["dynamic_call_sites"],
        "web": web_section(root),
        "errors": errors,
    }


def tool_versions() -> dict:
    versions: dict[str, str | None] = {"tool": str(TOOL_VERSION), "elixir": None, "otp": None}
    try:
        done = subprocess.run(["elixir", "--version"], capture_output=True, text=True,
                              timeout=60, check=False)
        text = (done.stdout or "") + (done.stderr or "")
        match = re.search(r"Erlang/OTP\s+(\d+)", text)
        if match:
            versions["otp"] = match.group(1)
        match = re.search(r"Elixir\s+(\S+)", text)
        if match:
            versions["elixir"] = match.group(1)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return versions


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def summary_lines(report: dict) -> list[str]:
    summary = report["summary"]
    lines = [f"DEAD FUNCTIONS {summary['total']} of {summary.get('scanned', 0)} public functions"]
    reasons = ", ".join(f"{reason}={count}" for reason, count in summary["by_reason"].items())
    lines.append(f"  per reason: {reasons or '(none)'}")
    for area, count in summary["by_area"].items():
        area_reasons = summary["by_area_and_reason"].get(area, {})
        detail = ", ".join(f"{r}={c}" for r, c in area_reasons.items())
        lines.append(f"  {area}: {count} ({detail})")
    lines.append(f"  dynamic call sites: {len(report['dynamic_call_sites'])}")
    return lines


def check(root: Path, report: dict) -> tuple[bool, list[str]]:
    """The CI gate: fails only when a NEW dead function appears."""
    baseline = load_baseline(root)
    allow, _errors = load_allow(root)
    baseline_keys = {key_of(entry) for entry in baseline}
    allow_keys = {(m, f) for m, f, _a in allow}
    new: list[dict] = []
    for entry in report["functions"]:
        if key_of(entry) in baseline_keys:
            continue
        if (entry["module"], entry["function"]) in allow_keys:
            continue
        new.append(entry)
    lines: list[str] = []
    for entry in new:
        lines.append(f"ERROR new dead function {entry['module']}.{entry['function']}/{entry['arity']} "
                     f"({entry['file']}:{entry['line']}, {entry['area']}, {entry['reason']})")
    total = report["summary"]["total"]
    if not new and baseline and total > len(baseline):
        lines.append(f"ERROR the number of dead functions grew ({len(baseline)} -> {total})")
    lines.append(f"dead functions: {total} (baseline {len(baseline)}), new: {len(new)}")
    return (not new and not (baseline and total > len(baseline))), lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="the product checkout")
    parser.add_argument("--area", help="one area of the shared table (default: all)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--check", action="store_true",
                        help="fail when a new dead function appears (the CI gate)")
    parser.add_argument("--write", action="store_true", help="write the report file")
    parser.add_argument("--no-write", action="store_true", help="do not write the report file")
    parser.add_argument("--update-baseline", action="store_true",
                        help="write the baseline from this run (a deliberate act)")
    parser.add_argument("--xref-file", help="read the xref dump from a file instead of running mix")
    parser.add_argument("--xref-cache", action="store_true",
                        help="read the cached xref dump under _build instead of running mix")
    parser.add_argument("--mix-env", default="dev", help="the mix environment of the xref dump")
    parser.add_argument("--timeout", type=int, default=600, help="seconds the xref dump may take")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if args.xref_file:
        xref_calls = load_xref_file(Path(args.xref_file))
    else:
        try:
            xref_calls = run_xref(root, args.mix_env, args.timeout, use_cache=args.xref_cache)
        except RuntimeError as exc:
            print(f"dead_code: {exc}", file=sys.stderr)
            return 2

    report = build_report(root, xref_calls, args.mix_env, tool_versions())
    if args.area:
        report["functions"] = [f for f in report["functions"] if f["area"] == args.area]
        scanned = report["summary"].get("scanned_by_area", {})
        report["summary"] = summarize(report["functions"], {args.area: scanned.get(args.area, 0)})

    if args.update_baseline:
        write_json(root / BASELINE_FILE, report["functions"])

    write = not args.no_write and (args.write or not args.check)
    if write:
        write_json(root / REPORT_FILE, report)

    if args.json:
        print(json.dumps(report, indent=1, sort_keys=True, ensure_ascii=False))
    else:
        for line in summary_lines(report):
            print(line)
        for error in report.get("errors", []):
            print(error)

    if args.check:
        ok, lines = check(root, report)
        for line in lines:
            print(line)
        print("dead_code --check: " + ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
