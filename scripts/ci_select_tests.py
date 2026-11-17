#!/usr/bin/env python3
"""T-1297 (item L-24): choose the backend test files a pull request / merge-queue / push run needs.

Consumer: .github/workflows/ci.yml, job `changes`, step "Select backend tests". Stdlib only
(python3 is on every GitHub ubuntu runner); no Elixir toolchain, no compile, so the step takes
seconds and stays off the critical path.

Contract
  stdin   the changed-file list (`git diff --name-only --no-renames`), one path per line.
  stdout  `key=value` lines, written to $GITHUB_OUTPUT by the caller:
            mode=selective|full
            reason=<one line>
            skip_shards=<space separated shard numbers that have nothing to run; empty = none>
            selected_count=<number of test files; 0 in full mode>
  --plan-out FILE   (selective only) lines `<global partition> <test path>` for scripts/test_parallel.sh
                    (TEST_PARALLEL_PLAN). Partitions are numbered like the manifest's: shard K owns
                    (K-1)*N+1 .. K*N.
  exit    0 always for a decision; any internal error is reported as mode=full (fail safe) and,
          when the process cannot even print, a non-zero exit, which the caller also turns into full.

Why not `mix xref`: xref only sees compiled project sources (lib/), not test/*.exs, so the test
side of the map would need text matching anyway; and it needs a compile (about 1.5 min cold) in a
job every other job waits for. The map here is a textual module-reference graph, deliberately
OVER-approximate (a false dependency only runs one test more; a missed one is the risk the owner
accepted, bounded by the full run every 10th merge):
  * a file F depends on module M (`Letflow.A.B`) when F contains the dotted token `Letflow.A.B`, or
    contains the last segment `B` as a capitalised word AND a dotted prefix of M with >= 2
    segments (`alias Letflow.A`, `alias Letflow.A.{B, C}`, `use Letflow.A.B`);
  * the lib closure of a change is the dependents of the changed file and the dependents of those
    (--depth 2). A full runtime-transitive closure is useless: hub modules (Help, Engine,
    NumberSequences) reach 90% of lib/ within 4 hops, which would make every change a full run;
  * a test is selected when it mentions a module of the closure, names a changed file by path or
    base name (source-scanning tests), is the conventional `test/<path>_test.exs` of a closure
    file, or is itself changed. Tests that scan the whole lib tree by glob ("scanners") run on any
    lib change.
Not visible to this map (hence the full-suite rules below): Postgres triggers, migrations, pins
(permission matrix, route counts, table lists), config-selected modules, docs checks.

Floor (T-1403): a change under lib/letflow/engine*, record_triggers* or entities/ also selects every
test under test/letflow/engine/ and test/letflow/record_triggers/, on top of the closure.

Single-module selective mode (T-2137): when every changed file lies in ONE module's directories
(priv/modules/<m>/**, lib/letflow/modules/<m>/**, test/letflow/modules/<m>/**) plus module-neutral
docs, the selector adds (a) the closure it already finds, (b) every test under
test/letflow/modules/<m>/, and (c) the SINGLE_MODULE_PIN_TESTS global pin list (route scope,
permission matrix, install boundaries, previous pack, ledger registration, engine and
record_triggers floor). Other modules' tests are excluded. Reason line: "single module <m>".
priv/modules/<m>/ files do not go through the lib closure (not Elixir modules) but do go through
source-scanning. A diff spanning two modules falls back to the normal closure and does NOT apply the
single-module exclusion; priv/modules/ spanning two modules raises Full (no closure path for them).
Module-subdir lib files skip ROLE_GRANTS_RE and SENSITIVE_LIB_NAME_RE checks (after T-2136,
each module's permission_matrix_test reads only that module's rows, so a role_grants change in a
module only requires that module's tests plus the global pin set, not the full suite).

Full suite when: event is not pull_request/merge_group/push (nightly, workflow_dispatch), kill
switch `off`, the counter is unknown or >= --every, no changed files, more than --max-files files,
a sensitive path (including, T-1403, the module-write authorization and module-install files: lib/letflow/engine.ex
(Engine.authorize_module_writes), engine/entity_port*, modules/{install*,ledger_registration,tenant_module*},
entities/{handler_writes,entity_port*}, definitions/{module_writes,solution_pack_install}, routers/tenant_modules;
other files under engine/ are floor-only: they do not hold the authorization), a deleted lib file, an unclassifiable file, a module named in config/, a lib
file without a module, priv/modules/ spanning two modules, or the selection covers more than
--max-share of all tests.
"""
import argparse
import math
import os
import re
import subprocess
import sys

SENSITIVE_RE = re.compile(
    # T-2137: priv/modules/<m>/ is excluded here; handled by single-module detection below.
    r"^(priv/(?!modules/)|config/|mix\.exs$|mix\.lock$|\.tool-versions$|\.formatter\.exs$|\.gitattributes$|"
    r"\.env\.example$|deploy/|\.github/|scripts/|handoffs/|test/support/|test/test_helper\.exs$|"
    r"test/shard_manifest\.txt$|lib/mix/|lib/letflow/(application|repo|repository|ledger|event_store|"
    r"release)(\.ex$|/))"
)
# Pins, permission atoms and matrices, tenant tables: anywhere under lib/ by name.
SENSITIVE_LIB_NAME_RE = re.compile(
    r"permission|authoriz|scope_enforc|route_polic|tenant_schema|tenant_template|"
    r"migration|schema_registry|storage"
)
# T-1403: module-write authorization and module installs reach record triggers / handlers through the
# engine at runtime, a path the textual module graph does not see (T-1371 broke
# record_triggers/apply_test.exs in the merge queue after a green selective PR run).
SENSITIVE_LIB_PATH_RE = re.compile(
    r"^lib/letflow/(engine\.ex$|engine/entity_port|modules/(install|ledger_registration|tenant_module)|"
    r"entities/(handler_writes|entity_port)|definitions/(module_writes|solution_pack_install)|"
    r"routers/tenant_modules)"
)
# T-1428: a new role or permission changes priv/permission_matrix/effective.golden, which other
# modules' tests read (Storekeeper role PR, red main at c31490d0f). Identity role / permission seeding
# and any lib file that defines role_grants (module manifests) therefore run the full suite.
# Exception (T-2137): files under lib/letflow/modules/<m>/ skip ROLE_GRANTS_RE; after T-2136 each
# module's permission_matrix_test reads only that module's rows, so a role_grants change inside a
# module only requires that module's tests plus the global pin set.
SENSITIVE_IDENTITY_RE = re.compile(r"^lib/letflow/(identity(\.ex$|_migration\.ex$|/))")
ROLE_GRANTS_RE = re.compile(r"\brole_grants\b")
# Floor: a change under these lib paths always also runs these test directories.
FLOOR_LIB_RE = re.compile(r"^lib/letflow/(engine\.ex$|engine/|record_triggers(\.ex$|/)|entities/)")
FLOOR_TEST_PREFIXES = ("test/letflow/engine/", "test/letflow/record_triggers/")

# T-2137: single-module selective mode.
# Regex to extract <m> from module-scoped paths: priv/modules/<m>/*, lib/letflow/modules/<m>/*,
# test/letflow/modules/<m>/*.  Top-level files (no subdirectory) do not match.
MODULE_PATH_RE = re.compile(
    r"^(?:priv/modules/([^/]+)/|lib/letflow/modules/([^/]+)/|test/letflow/modules/([^/]+)/)"
)
# Global pin tests always added when running in single-module selective mode.
# They cover cross-module constraints that any module change can break.
SINGLE_MODULE_PIN_TESTS = [
    "test/letflow/api/permission_matrix_test.exs",        # permission atoms, role_grants
    "test/letflow/api/route_scope_test.exs",              # route scope inventory
    "test/letflow/api/route_scope_walk_test.exs",         # route scope walk
    "test/letflow/api/route_scope_self_service_entry_test.exs",  # self-service guard
    "test/letflow/engine/entity_port_boundary_test.exs",  # install boundaries
    "test/letflow/module_upgrade/previous_pack_test.exs", # pack backward compat
    "test/letflow/modules/ledger_registration_test.exs",  # ledger registration list
]
# Directory prefixes whose full contents are always added in single-module mode (floor).
SINGLE_MODULE_PIN_PREFIXES = ("test/letflow/engine/", "test/letflow/record_triggers/")

TOKEN_RE = re.compile(r"[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*")
DEFMODULE_RE = re.compile(r"^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)", re.M)
SCANNER_RE = re.compile(r"lib/[A-Za-z0-9_/.-]*\*\*|lib_files\(")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


class Full(Exception):
    pass


def tracked(root):
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True
    ).stdout.decode("utf-8", "replace")
    return [p for p in out.split("\0") if p]


def backend_re(root):
    """The single source of 'a path the backend gate reads': scripts/ci_changed_paths.sh."""
    text = read(os.path.join(root, "scripts/ci_changed_paths.sh")) or ""
    m = re.search(r"^BACKEND_PATHS_RE='(.*)'$", text, re.M)
    if not m:
        raise Full("cannot read BACKEND_PATHS_RE from scripts/ci_changed_paths.sh")
    return re.compile(m.group(1))


class Doc:
    __slots__ = ("path", "text", "tokens", "words")

    def __init__(self, path, text):
        self.path = path
        self.text = text
        self.tokens = set(TOKEN_RE.findall(text))
        self.words = set()
        for t in self.tokens:
            self.words.update(t.split("."))


def prefixes(mod):
    parts = mod.split(".")
    return [".".join(parts[:i]) for i in range(2, len(parts))]


def mentions(doc, mod):
    if mod in doc.tokens:
        return True
    last = mod.rsplit(".", 1)[-1]
    if "." not in mod or last not in doc.words:
        return False
    return any(p in doc.tokens for p in prefixes(mod))


def module_of(path):
    """Return the module name <m> if path is under a module-specific subdirectory, else None.

    Matches priv/modules/<m>/*, lib/letflow/modules/<m>/*, test/letflow/modules/<m>/*.
    Top-level files in those directories (no slash after the name) return None.
    """
    m = MODULE_PATH_RE.match(path)
    if not m:
        return None
    return m.group(1) or m.group(2) or m.group(3)


def decide(changed, root, args, manifest_weights):
    event, every = args.event, args.every
    if event not in ("pull_request", "merge_group", "push"):
        raise Full("event %s: nightly / manual runs always run the full suite" % event)
    if args.force_full:
        raise Full(args.force_full)
    if args.kill_switch.strip().lower() == "off":
        raise Full("kill switch CI_SELECTIVE=off")
    if args.commits_since_full is None:
        raise Full("no green full run marker reachable (counter unknown)")
    if args.commits_since_full >= every:
        raise Full(
            "%d merges since the last green full run (limit %d)" % (args.commits_since_full, every)
        )
    if not changed:
        raise Full("empty change list")
    if len(changed) > args.max_files:
        raise Full("%d changed files (limit %d)" % (len(changed), args.max_files))

    files = tracked(root)
    fileset = set(files)
    bre = backend_re(root)

    lib_changed, tests_changed, other_changed = [], [], []
    priv_module_changed = []  # T-2137: priv/modules/<m>/ files (packs, manifests)
    docs_backend = False
    for p in changed:
        if SENSITIVE_RE.search(p):
            raise Full("sensitive path %s" % p)
        exists = p in fileset and os.path.exists(os.path.join(root, p))
        if p.startswith("lib/"):
            if not exists:
                raise Full("lib file removed or renamed: %s" % p)
            if SENSITIVE_LIB_PATH_RE.search(p):
                raise Full("sensitive lib path %s (module-write authorization / module installs)" % p)
            if SENSITIVE_IDENTITY_RE.search(p):
                raise Full("sensitive lib path %s (identity role / permission seeding)" % p)
            # T-2137: files under lib/letflow/modules/<m>/ skip ROLE_GRANTS_RE and
            # SENSITIVE_LIB_NAME_RE; the global pin tests cover their cross-module effects.
            is_module_subdir = bool(MODULE_PATH_RE.match(p))
            if not is_module_subdir:
                if not p.startswith("lib/letflow/design/") and ROLE_GRANTS_RE.search(
                    read(os.path.join(root, p)) or ""
                ):
                    raise Full("sensitive lib path %s (defines role_grants)" % p)
                if SENSITIVE_LIB_NAME_RE.search(p):
                    raise Full("sensitive lib path %s (permission / pins / tenant tables)" % p)
            lib_changed.append(p)
        elif p.startswith("test/"):
            if p.endswith("_test.exs"):
                if exists:
                    tests_changed.append(p)  # a removed test file needs nothing
            elif exists:
                other_changed.append(p)  # fixture etc.: found by mention below
            elif not exists:
                raise Full("test support file removed: %s" % p)
        elif p.startswith("priv/modules/"):
            # T-2137: module-scoped priv files (pack.json, manifests, generate_pack.exs).
            # Classified by single-module detection below; priv/repo/, priv/permission_matrix/
            # etc. are still caught by SENSITIVE_RE above.
            priv_module_changed.append(p)
        elif p.startswith("docs/"):
            if bre.search(p):
                docs_backend = True
        elif bre.search(p):
            raise Full("unclassified backend-relevant path %s" % p)
        # else: web/, apps/, other docs: not read by the backend suite

    all_tests = [p for p in files if p.startswith("test/") and p.endswith("_test.exs")]
    test_set = set(all_tests)
    selected = set(tests_changed)

    if docs_backend:
        out = subprocess.run(
            ["bash", "scripts/ci_docs_only.sh", "files"], cwd=root, capture_output=True, text=True
        )
        if out.returncode != 0:
            raise Full("scripts/ci_docs_only.sh files failed")
        selected.update(x for x in out.stdout.split() if x in test_set)

    # T-2137: single-module detection.
    # A diff qualifies when every backend-relevant changed file lies in one module's directories
    # (priv/modules/<m>/, lib/letflow/modules/<m>/, test/letflow/modules/<m>/) or docs.
    _all_classified = lib_changed + priv_module_changed + tests_changed + other_changed
    _module_names = {module_of(p) for p in _all_classified} - {None}
    _no_module = [p for p in _all_classified if module_of(p) is None]

    sole_module = None
    if priv_module_changed:
        # priv/modules/ files have no Elixir closure; only valid in single-module mode.
        if len(_module_names) == 1 and not _no_module:
            sole_module = next(iter(_module_names))
        else:
            raise Full(
                "priv/modules change spans multiple modules or includes non-module paths (%s)"
                % ", ".join(priv_module_changed[:2])
            )
    elif _module_names and not _no_module and len(_module_names) == 1:
        sole_module = next(iter(_module_names))
    # else: multi-module or non-module lib/test change — normal closure, no single-module mode.

    lib_docs = {}
    for p in files:
        if p.startswith("lib/") and p.endswith(".ex"):
            t = read(os.path.join(root, p))
            if t is not None:
                lib_docs[p] = (Doc(p, t), DEFMODULE_RE.findall(t))
    test_docs = {}
    if lib_changed or other_changed or priv_module_changed:
        for p in all_tests:
            t = read(os.path.join(root, p))
            if t is not None:
                test_docs[p] = Doc(p, t)

    if lib_changed:
        config_tokens = set()
        for p in files:
            if p.startswith("config/") and p.endswith(".exs"):
                config_tokens.update(TOKEN_RE.findall(read(os.path.join(root, p)) or ""))
        by_last = {}
        for p, (_, mods) in lib_docs.items():
            for m in mods:
                by_last.setdefault(m.rsplit(".", 1)[-1], []).append((m, p))

        # forward graph: lib file -> modules of other lib files it mentions
        def deps_of(doc):
            hits = set()
            for w in doc.words:
                for m, p in by_last.get(w, ()):
                    if mentions(doc, m):
                        hits.add(p)
            return hits

        dependents = {}
        for p, (doc, _) in lib_docs.items():
            for q in deps_of(doc):
                if q != p:
                    dependents.setdefault(q, set()).add(p)

        closure, frontier = set(), []
        for p in lib_changed:
            if p not in lib_docs:
                raise Full("lib file %s is not an .ex module file" % p)
            if not lib_docs[p][1]:
                raise Full("lib file %s defines no module" % p)
            # T-2137: in single-module mode, config-atom invisibility is handled by exhaustive
            # module test selection; skip this check for module-subdir files.
            if not sole_module and any(m in config_tokens for m in lib_docs[p][1]):
                raise Full("%s defines a module named in config/ (selected by atom, invisible)" % p)
            closure.add(p)
            frontier.append(p)
        depth = 0
        while frontier and depth < args.depth:
            depth += 1
            nxt = []
            for p in frontier:
                for q in dependents.get(p, ()):
                    if q not in closure:
                        closure.add(q)
                        nxt.append(q)
            frontier = nxt
            if len(closure) > args.max_closure:
                raise Full("lib dependents closure over %d files" % args.max_closure)

        mods = [(m, p) for p in closure for m in lib_docs[p][1]]
        for p, doc in test_docs.items():
            if any(mentions(doc, m) for m, _ in mods):
                selected.add(p)
            elif SCANNER_RE.search(doc.text):
                selected.add(p)  # scans the whole lib tree: any lib change can break it
        for p in closure:  # conventional pair: lib/letflow/a/b.ex -> test/letflow/a/b_test.exs
            conv = "test/" + p[len("lib/"):-len(".ex")] + "_test.exs"
            if conv in test_set:
                selected.add(conv)

    # source-scanning tests name the changed file (lib or fixture) by path or base name
    for p in lib_changed + other_changed + priv_module_changed:
        base = os.path.basename(p)
        pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(base) + r"(?![A-Za-z0-9_])")
        for t, doc in test_docs.items():
            if pat.search(doc.text):
                selected.add(t)
        if not any(pat.search(d.text) for d in test_docs.values()) and p in other_changed:
            raise Full("fixture %s is read by no test we can find" % p)

    if any(FLOOR_LIB_RE.search(p) for p in lib_changed):
        selected.update(t for t in all_tests if t.startswith(FLOOR_TEST_PREFIXES))

    # T-2137: single-module additions — (b) all module tests, (c) global pins, exclusions.
    if sole_module:
        this_module_test_dir = "test/letflow/modules/%s/" % sole_module
        # (b) Every test file under this module's test directory.
        selected.update(t for t in all_tests if t.startswith(this_module_test_dir))
        # (c) Global pin tests (cross-module constraints).
        for pin in SINGLE_MODULE_PIN_TESTS:
            selected.add(pin)
        selected.update(t for t in all_tests if t.startswith(SINGLE_MODULE_PIN_PREFIXES))
        # Exclude tests in OTHER modules' subdirectories that the closure may have pulled via scanners.
        module_test_root = "test/letflow/modules/"
        selected = {
            t for t in selected
            if not t.startswith(module_test_root)
            or t.startswith(this_module_test_dir)
            or "/" not in t[len(module_test_root):]
        }

    selected &= test_set
    if not selected:
        # a pure web/ or docs change: nothing for the backend shards; one cheap test keeps a shard honest
        return [], "no backend test is related to this change (web/apps/docs only)"
    if len(selected) > args.max_share * len(all_tests):
        raise Full(
            "selection covers %d of %d test files (over %d%%)"
            % (len(selected), len(all_tests), round(args.max_share * 100))
        )
    if sole_module:
        return sorted(selected), "single module %s; %d of %d test files" % (
            sole_module, len(selected), len(all_tests)
        )
    return sorted(selected), "%d of %d test files related to %d changed file(s)" % (
        len(selected),
        len(all_tests),
        len(changed),
    )


def read_manifest(path):
    weights = {}
    total = None
    text = read(path)
    if text is None:
        raise Full("manifest %s unreadable" % path)
    for line in text.replace("\r", "").splitlines():
        m = re.match(r"# partitions: (\d+)$", line)
        if m:
            total = int(m.group(1))
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            try:
                weights[parts[1]] = float(parts[2]) if len(parts) > 2 else 0.0
            except ValueError:
                weights[parts[1]] = 0.0
    if total is None:
        raise Full("manifest has no '# partitions:' header")
    return weights, total


def plan(selected, weights, shards, per_shard, target_ms):
    """LPT-bin the selected files into as few partitions as their weight needs (fewer shards)."""
    known = sorted(w for w in weights.values() if w > 0)
    median = known[len(known) // 2] if known else 1000.0
    w = {f: (weights.get(f) or median) for f in selected}
    total = sum(w.values())
    parts = max(1, min(len(selected), shards * per_shard, math.ceil(total / target_ms)))
    bins = [[0.0, []] for _ in range(parts)]
    for f in sorted(selected, key=lambda x: (-w[x], x)):
        b = min(bins, key=lambda b: (b[0], len(b[1])))
        b[0] += w[f]
        b[1].append(f)
    lines = []
    for idx, (_, fs) in enumerate(bins, start=1):
        for f in sorted(fs):
            lines.append("%d %s" % (idx, f))
    active = math.ceil(parts / per_shard)
    skip = [str(k) for k in range(active + 1, shards + 1)]
    return lines, skip, parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--event", default="")
    ap.add_argument("--kill-switch", default="")
    ap.add_argument("--commits-since-full", type=int, default=None)
    ap.add_argument("--every", type=int, default=10)
    ap.add_argument("--force-full", default="", help="reason string: run the full suite")
    ap.add_argument("--max-files", type=int, default=40)
    ap.add_argument("--max-closure", type=int, default=300)
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--max-share", type=float, default=0.55)
    ap.add_argument("--shards", type=int, default=8)
    ap.add_argument("--per-shard", type=int, default=4)
    ap.add_argument("--target-ms", type=float, default=150000.0)
    ap.add_argument("--manifest", default="test/shard_manifest.txt")
    ap.add_argument("--root", default=".")
    ap.add_argument("--plan-out", default="")
    args = ap.parse_args()

    changed = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
    try:
        weights, total = read_manifest(os.path.join(args.root, args.manifest))
        if total != args.shards * args.per_shard:
            raise Full("manifest has %d partitions, expected %d" % (total, args.shards * args.per_shard))
        selected, reason = decide(changed, args.root, args, weights)
        if selected:
            lines, skip, parts = plan(selected, weights, args.shards, args.per_shard, args.target_ms)
            if args.plan_out:
                with open(args.plan_out, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(lines) + "\n")
            reason += "; %d partition(s), shards %s idle" % (parts, ",".join(skip) or "none")
        else:
            skip = [str(k) for k in range(1, args.shards + 1)]
            if args.plan_out:
                open(args.plan_out, "w").close()
        print("mode=selective")
        print("reason=" + reason)
        print("skip_shards=" + " ".join(skip))
        print("selected_count=%d" % len(selected))
    except Full as e:
        print("mode=full")
        print("reason=" + str(e))
        print("skip_shards=")
        print("selected_count=0")
    except Exception as e:  # selection must never block a run: unsure means everything
        print("mode=full")
        print("reason=selection error: %s: %s" % (type(e).__name__, str(e).replace("\n", " ")))
        print("skip_shards=")
        print("selected_count=0")


if __name__ == "__main__":
    main()
