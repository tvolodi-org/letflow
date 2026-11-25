#!/usr/bin/env python3
"""Bounded standard backend CI (T-2155); full suites only on schedule/dispatch.

stdin: changed paths. stdout: mode, reason, skip_shards, selected_count, deferred_count,
reserved_count.
--plan-out writes explicit partition/test lines; --deferred-out lists budget overflow.
Standard runs keep the textual two-hop module map, source scans, conventional pairs,
config-selected module tests and explicit sensitive-path families. Global pins are
reserved, then direct tests, high-risk families, owner-module tests and at most three
related families compete for 160 files / 120s measured time per partition. Unknown
files cost 15s. Deferred tests still run in the full nightly; estimates are not a
runtime guarantee. Job deadlines fail closed when execution exceeds the budget.

Former full-suite fallbacks (large diffs, config/identity/ledger, removed sources,
missing manifest, kill switch, red-main repair) now use bounded safety coverage.
An unrecoverable selector error exits nonzero; CI must never run without a plan.
--nightly-log-dir compares real failure headings with a successful standard push
plan at the same SHA and emits selector miss lines with the test name.

T-2691: the whole-tree source scans (the "real tree" scans: a test that reads a whole
tree of the backend source and pins it) are MANDATORY for a diff that touches the backend
source, and the stamp opener scan is mandatory whenever the diff adds or changes a query
call site or touches a file of its @dynamic_sql_files list. A scan that is only a
candidate is deferred to the nightly run when the budget is exceeded, and a deferred scan
is a scan that does not run: main went red on 0d2bbf8b5 because the stamp opener scan ran
only in the extended run. Every whole-tree reader is a member of that class, including a
file that also holds database-backed cases: the scan itself is a pure function of the
tree. A member reads a whole tree directly (a recursive glob over a backend-source root or
subtree, however the path is assembled: one literal, or a `**` token plus a root literal of
the same definition) or through a helper module of lib/ that walks a tree. A fixed-depth
reader (`lib/letflow/ledger*.ex`, `priv/modules/*/pack.json`) is not recursive and is not a
member. A scan of the handoff tree is not a member (it is outside the backend source).
A mandatory check is never omitted, so the file cap and the per-partition target budget
the optional candidates only; the whole run's budget is the hard bound.
"""
import argparse
import glob
import math
import os
import posixpath
import re
import subprocess
import sys

# The helper-module index of a tree, cached per root: the class derivation reads it for
# every test file, and the tree does not change while the selector runs.
_HELPER_INDEX = {}
# The backend-source roots a helper names, cached per helper module.
_HELPER_ROOTS = {}

# T-2638 (G-11): the security probes are the mechanical half of the security gates. A change to
# a probe (or to the triage list it reads) therefore gets the high-risk coverage: a gate that
# guards the gates must not be changed unnoticed.
SENSITIVE_RE = re.compile(
    # T-2137: priv/modules/<m>/ is excluded here; handled by single-module detection below.
    r"^(priv/(?!modules/)|config/|mix\.exs$|mix\.lock$|\.tool-versions$|\.formatter\.exs$|\.gitattributes$|"
    r"\.env\.example$|deploy/|\.github/|scripts/|handoffs/|test/support/|test/test_helper\.exs$|"
    r"test/shard_manifest\.txt$|test/letflow/security_probe/|lib/mix/|"
    r"lib/letflow/(application|repo|repository|ledger|event_store|"
    r"release)(\.ex$|/))"
)
# T-1403: module-write authorization and module installs reach record triggers / handlers through the
# engine at runtime, a path the textual module graph does not see (T-1371 broke
# record_triggers/apply_test.exs in the merge queue after a green selective PR run).
SENSITIVE_LIB_PATH_RE = re.compile(
    r"^lib/letflow/(engine\.ex$|engine/entity_port|modules/(install|tenant_module)|"
    r"entities/(handler_writes|entity_port)|definitions/(module_writes|solution_pack_install)|"
    r"routers/tenant_modules)"
)
# Identity seeding and permission changes nominate high-risk tests plus global pins.
# Module manifests have module-local permission tests after T-2136.
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
# Identity writer inventories run for EVERY standard change, including web-only diffs.
# These are pure source scans; DB-heavy identity coverage remains change-directed.
STANDARD_IDENTITY_PIN_TESTS = [
    "test/letflow/identity/binding_writers_scan_test.exs",
    "test/letflow/identity/tenant_update_changeset_removed_test.exs",
]
# D-173: the business-process map documents. The committed document of every area must equal
# the render of its map (scripts/bp/bp_doc.py), so the map and its plain-word description
# cannot drift apart. The check is pure (no database, no model) and reads only the map
# files, so it runs for EVERY standard change, including a web-only diff.
STANDARD_BP_DOC_TEST = [
    "test/scripts/bp_doc_test.exs",
]
# D-184/D-186: the security probes are mandatory on every bounded run: they are the mechanical
# half of the security gates (the coverage map in the team repository names the open gaps).
# Their module is also tagged security_probe for the operator's tagged checks hook.
# G-01: the generated real-HTTP route x role x tenant x request-shape matrix (golden as the
# oracle, foreign/missing byte identity, no write on denial or into another tenant).
# G-02: the pure AST writer/start inventory is mandatory on every bounded run.
# G-05: the generated audit-writer by caller matrix and the database-row schema assertions
# for actor id/kind, required fields and payload redaction.
# G-06: every outbound HTTP call site is inventoried and classified, and the
# dispatch-time probes refuse a private-range URL, do not follow a redirect and
# keep the URL out of the failure value.
# G-07: every keyset cursor builder is inventoried, and the cursor/codec
# properties hold over arbitrary legal ids, separators, legacy prefixes and
# expiry; a cursor-paged listing shows every row exactly once.
# G-08: the UAT runner and its cleanup replay must judge the same safety checks.
# G-09: a migration change shifts the manifest positions the tenant tests pin.
# G-03: the generated source-provenance matrix of the platform-call authority
# rule: the catalogue validator refuses a write-like entry with a person input,
# the activation refuses the foreign sources and the dual-route nodes, and the
# variables a catalogue call reads are refused to a completer.
# G-13: the generated malformed-input / no-5xx matrix over every mutating route
# (body shapes, content types, caps), the SUB_PROCESS child and start refusals
# and the cursor codec fallback.
# G-11: the route inventory and the secret scanner must run on the REAL tree, not only on the
# fake checkouts their own tests use.
STANDARD_SECURITY_PROBE_TESTS = [
    "test/letflow/security_probe/g01_matrix_shard_0_test.exs",
    "test/letflow/security_probe/g01_matrix_shard_1_test.exs",
    "test/letflow/security_probe/g01_matrix_shard_2_test.exs",
    "test/letflow/security_probe/g01_matrix_shard_3_test.exs",
    "test/letflow/security_probe/g01_route_role_matrix_test.exs",
    "test/letflow/security_probe/g02_writer_start_inventory_test.exs",
    "test/letflow/security_probe/g05_audit_writer_matrix_test.exs",
    "test/letflow/security_probe/g05_audit_row_schema_test.exs",
    "test/letflow/security_probe/g06_outbound_http_inventory_test.exs",
    "test/letflow/security_probe/g06_outbound_dispatch_probes_test.exs",
    "test/letflow/security_probe/g07_cursor_codec_probe_test.exs",
    "test/letflow/security_probe/g07_cursor_traversal_probe_test.exs",
    "test/letflow/security_probe/g08_uat_safety_equivalence_test.exs",
    "test/letflow/security_probe/g09_migration_impact_test.exs",
    "test/letflow/security_probe/g03_source_provenance_test.exs",
    "test/letflow/security_probe/g13_malformed_input_matrix_test.exs",
    "test/letflow/security_probe/g13_route_no_5xx_test.exs",
    "test/letflow/security_probe/g11_route_inventory_probe_test.exs",
    "test/letflow/security_probe/g11_secret_scan_probe_test.exs",
]
# T-2691: the whole-tree source scans (the "real tree" scans): a test that reads a whole
# tree of the backend source and pins it (an allowlist, a ledger or a count). A diff that
# touches the tree can break such a pin, so the scan is a MANDATORY check of a
# backend-source diff: as a mere CANDIDATE it is deferred to the nightly run when the
# budget is exceeded, and that is how ~21 non-literal SQL sites merged unseen (T-2689;
# main went red on 0d2bbf8b5 because the stamp opener scan ran only in the extended run).
# The class is DERIVED from the tree, never a hand list, so a scan that lands later is
# covered on the day it lands.
#
# The class does NOT exclude a scan whose file also holds database-backed cases: the scan
# itself is a pure function of the tree, and the file that carries it is still a whole-tree
# reader (T-2691 rework: `write_handler_registration_surface_test.exs` reads every
# `lib/**/*.ex` and pins the allowed write-handler callers; it was excluded only because the
# file also uses `Letflow.DataCase`, so a forbidden caller could merge unseen).
#
# A member reads a whole tree in one of TWO ways, and both count:
#   * directly: a recursive glob over a backend-source root or subtree ("lib/**",
#     "priv/**/*", "lib/letflow/modules/**/*"), also when the `**` is a token of its own
#     and the root another literal of the definition (`["lib", "**", "*.ex"]`,
#     `Path.join([root, dir, "**", "*.ex"])` with `@roots ["lib", "priv"]`);
#   * through a helper: the test calls a module of lib/ that walks a tree, and the roots
#     that helper scans lie in the backend source (the review's counterexample:
#     `Scan.scan(["lib", "priv/modules"])` in the role-scope-grants writer scan, whose
#     helper reads every file under those roots). A helper-backed scan is a whole-tree
#     reader exactly like a direct one, so it belongs to the class (T-2691 rework 2).
# A fixed-depth reader (`lib/letflow/ledger*.ex`, `priv/modules/*/pack.json`) is not
# recursive and is not a member. A scan of a tree OUTSIDE the backend source (the handoff
# tree) is not a member: a backend-source diff cannot break its pin. The test tree counts
# as backend source because it contains `test/support/`.
# The `/**` marker of a whole-tree glob, and the path characters that may precede it.
# The root is the path before the marker, so the pattern stays linear: a nested-quantifier
# pattern over every source file is quadratic and the class derivation reads the tree.
WHOLE_TREE_GLOB_MARKER_RE = re.compile(r"/\*\*")
PATH_TAIL_RE = re.compile(r"[A-Za-z0-9_./-]*$")
# A root written relative to the test file: `Path.expand("../../../lib/x", __DIR__)`. The
# literal names no backend-source prefix until it is resolved against the test's directory.
EXPAND_ROOT_RE = re.compile(r'Path\.expand\(\s*"([^"\n]*)"\s*,\s*__DIR__\s*\)')
# The other spellings of a recursive glob: the `**` is a token of its own in a path chain
# (`Path.join([root, dir, "**", "*.ex"])`, `["lib", "**", "*.ex"]`, `@lib |> Path.join("**/*.ex")`),
# so the root is a different literal of the same definition (T-2691 rework 3).
GLOB_TOKEN_RE = re.compile(r'"(?:[^"\\]*/)?\*\*(?:/[^"]*)?"')
UNIT_START_RE = re.compile(r"^  (?:defp?|test|describe|setup|@)\b", re.M)
ATTRIBUTE_REF_RE = re.compile(r"@([a-z_]\w*)")
STRING_LITERAL_RE = re.compile(r'"([^"\n]*)"')
# A module alias in a test file: `alias Full.Name` or `alias Full.Name, as: Short`.
ALIAS_RE = re.compile(
    r"^\s*alias\s+([A-Z][A-Za-z0-9_.]*)(?:\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*))?", re.M
)
# A call of an aliased or fully qualified module: `Short.fun(args)`.
MODULE_CALL_RE = re.compile(
    r"\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_?!]*)\(([^()]*)\)"
)
# A list literal in a source file: `[ "lib", "priv" ]` (the roots a helper scans).
HELPER_LIST_RE = re.compile(r"\[([^\[\]]*)\]")
# A single-valued module attribute: `@default_dir "test"` (another way a helper names a root).
HELPER_ATTRIBUTE_RE = re.compile(r"@\w+\s+\"([^\"]*)\"")
# A directory literal: a relative path whose last segment has no file extension.
DIRECTORY_LITERAL_RE = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")
# The roots the whole-tree scans read: lib/ (the sources), priv/ (migrations and seeds),
# config/, scripts/ and test/support/ (four of the scans read the support tree as well,
# so a change there can break their pin).
BACKEND_SOURCE_PREFIXES = ("lib/", "priv/", "config/", "scripts/", "test/support/")
BACKEND_SOURCE_RE = re.compile(
    "^(?:%s)" % "|".join(re.escape(prefix) for prefix in BACKEND_SOURCE_PREFIXES)
)
# A query call site: Repo.query / Repo.query! / SQL.query / Ecto.Adapters.SQL.query, piped
# or not. The scan counts a receiver variable (`repo.query!`) as well, so the lower case
# name is here too.
SQL_CALL_RE = re.compile(r"\b(?:Repo|repo|SQL|sql|Ecto\.Adapters\.SQL)\s*\.\s*query!?\s*\(")
# The stamp opener scan: the mined instance of the class (T-2689). Its oracle is its own
# @dynamic_sql_files list, read from the scan itself.
DYNAMIC_SQL_SCAN_TEST = "test/letflow/entities/managed_types/stamp_opener_scan_test.exs"
# G-09: the test files a tenant-migration change must run. The list is the reviewed expectation
# of the migration impact runner (test/support/migration_impact.ex): the manifest-position pins,
# the tenant table oracle comparisons and the manifest replay / existing-row cases. The probe
# re-derives the same set from the tree and fails when this list and the tree disagree.
MIGRATION_IMPACT_FIXTURE = "test/fixtures/security_probes/g09_migration_impact_tests.txt"
# T-2223: route/permission inventories are mandatory for changes to their inputs,
# not ordinary related candidates that may be deferred by family or time budgets.
# Keep the family spelling used by risk_tests: the authority scan forbids the
# column spelling even in scripts that only name test files, not flag writers.
SCOPE_FAMILY = "scope-enforcement".replace("-", "_")
FLAG_AUTHORITY_TEST = "test/letflow/%s_flip_authority_test.exs" % SCOPE_FAMILY
ROUTE_INVENTORY_TESTS = [
    "test/letflow/routers/tenant_admin_routes_test.exs",
    "test/letflow/routers/platform_scope_routes_test.exs",
    "test/letflow/api/platform_scope_inventory_test.exs",
    "test/letflow/%s_on_e2e_test.exs" % SCOPE_FAMILY,
    FLAG_AUTHORITY_TEST,
    "test/letflow/docs/roles_on_flip_docs_test.exs",
    "test/letflow/api/route_scope_test.exs",
    "test/letflow/api/route_scope_walk_test.exs",
    "test/letflow/api/route_scope_self_service_test.exs",
    "test/letflow/api/route_scope_self_service_entry_test.exs",
    "test/letflow/api/route_scope_resolver_test.exs",
    "test/letflow/api/route_scope_on_flip_blocker_test.exs",
    "test/letflow/api/route_scope_exam_guard_test.exs",
] + ["test/letflow/api/%s_route_classes_test.exs" % name for name in (
    "tasks", "number_sequences", "notification_templates", "notification_deliveries",
    "labels", "entity_views", "entity_type_extensions", "documents", "currencies",
)]
ROUTE_SOURCE_RE = re.compile(
    r"^lib/letflow/(router\.ex$|routers/|plugs/|api/(authorized_router|authorization|"
    r"permission|route|scope)|.*(?:scope|permission|authoriz)|modules/.*/router\.ex$|"
    r"modules/router_kit\.ex$)|^test/fixtures/route_scope/|^priv/permission_matrix/"
)
ROUTE_DECLARATION_RE = re.compile(r"\b(?:authz_\w+|route_policies|role_grants|permissions)\b")
# Directory prefixes whose full contents are always added in single-module mode (floor).
SINGLE_MODULE_PIN_PREFIXES = ("test/letflow/engine/", "test/letflow/record_triggers/")

# T-2737: a change to the activation checks (outbound destinations, validators, authority) reaches
# every test that activates a definition, usually through a shipped-definition helper the textual
# module graph does not see (24 Nov: the G14 outbound allow-list turned 90 tests red in the extended
# CI only). The reviewed list below is mandatory; every test that calls the activation API
# directly is also nominated as a high-risk candidate (deferrable by budget, never silently).
ACTIVATION_SOURCE_RE = re.compile(
    r"^lib/letflow/(outbound_destinations(\.ex$|/)|definitions(\.ex$|/)|routers/definitions\.ex$|"
    r"engine/service_task_dispatcher\.ex$|notifications\.ex$)"
)
ACTIVATION_CALL_RE = re.compile(r"Definitions\.activate|/activate\"|activate_definition")
ACTIVATION_TESTS_FIXTURE = "test/fixtures/ci_selection/activation_tests.txt"
# T-2737 (covers the Repo.query/SQL.query rule of T-2691): raw SQL needs the dynamic-SQL scan and the
# whole security probe set; the probes are already mandatory on every bounded run (safety_tests).
RAW_SQL_RE = re.compile(r"\b(?:Repo|SQL)\.query!?\(")
RAW_SQL_TESTS = ["test/letflow/entities/managed_types/stamp_opener_scan_test.exs"]

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
    event = args.event
    if event not in ("pull_request", "merge_group", "push"):
        raise Full("event %s: nightly / manual runs always run the full suite" % event)
    reasons = []
    if args.force_full:
        reasons.append(args.force_full + " (bounded repair)")
    if args.kill_switch.strip().lower() == "off":
        reasons.append("kill switch CI_SELECTIVE=off (bounded safety set)")
    if not changed:
        reasons.append("empty change list; bounded safety set")
    if len(changed) > args.max_files:
        reasons.append("%d changed files (limit %d); bounded cross-module set" % (len(changed), args.max_files))

    files = tracked(root)
    fileset = set(files)
    bre = backend_re(root)

    lib_changed, tests_changed, other_changed = [], [], []
    priv_module_changed = []  # T-2137: priv/modules/<m>/ files (packs, manifests)
    docs_backend = False
    for p in changed:
        if SENSITIVE_RE.search(p):
            reasons.append("sensitive path %s" % p)
        exists = p in fileset and os.path.exists(os.path.join(root, p))
        if p.startswith("lib/"):
            if not exists:
                reasons.append("lib file removed or renamed: %s" % p)
                other_changed.append(p)
                continue
            if SENSITIVE_LIB_PATH_RE.search(p):
                reasons.append("module-write authorization / module installs: %s" % p)
            if SENSITIVE_IDENTITY_RE.search(p):
                reasons.append("identity role / permission seeding: %s" % p)
            # T-2137: files under lib/letflow/modules/<m>/ skip ROLE_GRANTS_RE;
            # T-2141: top-level lib/letflow/modules/*.ex files also skip it (global pins cover their
            # cross-module effects, e.g. ledger_registration.ex defines role_grants but its
            # effects are covered by SINGLE_MODULE_PIN_TESTS).
            is_module_subdir = bool(MODULE_PATH_RE.match(p))
            is_modules_toplevel = (
                p.startswith("lib/letflow/modules/") and "/" not in p[len("lib/letflow/modules/"):]
            )
            if not is_module_subdir and not is_modules_toplevel:
                if not p.startswith("lib/letflow/design/") and ROLE_GRANTS_RE.search(
                    read(os.path.join(root, p)) or ""
                ):
                    reasons.append("defines role_grants: %s" % p)
            lib_changed.append(p)
        elif p.startswith("test/"):
            if p.endswith("_test.exs"):
                if exists:
                    tests_changed.append(p)  # a removed test file needs nothing
            elif exists:
                other_changed.append(p)  # fixture etc.: found by mention below
            elif not exists:
                reasons.append("test support file removed: %s" % p)
                other_changed.append(p)
        elif p.startswith("priv/modules/"):
            # T-2137: module-scoped priv files (pack.json, manifests, generate_pack.exs).
            # Classified by single-module detection below; priv/repo/, priv/permission_matrix/
            # etc. are still caught by SENSITIVE_RE above.
            priv_module_changed.append(p)
        elif p.startswith("docs/"):
            if bre.search(p):
                docs_backend = True
        elif bre.search(p):
            other_changed.append(p)
            reasons.append("backend-relevant path %s" % p)
        # else: web/, apps/, other docs: not read by the backend suite

    all_tests = [p for p in files if p.startswith("test/") and p.endswith("_test.exs")]
    test_set = set(all_tests)
    selected = set(tests_changed)

    if docs_backend:
        out = subprocess.run(
            ["bash", "scripts/ci_docs_only.sh", "files"], cwd=root, capture_output=True, text=True
        )
        if out.returncode != 0:
            raise ValueError("scripts/ci_docs_only.sh files failed")
        selected.update(x for x in out.stdout.split() if x in test_set)

    # T-2137: single-module detection.
    # A diff qualifies when every backend-relevant changed file lies in one module's directories
    # (priv/modules/<m>/, lib/letflow/modules/<m>/, test/letflow/modules/<m>/) or docs.
    _all_classified = lib_changed + priv_module_changed + tests_changed + other_changed
    _module_names = {module_of(p) for p in _all_classified} - {None}
    _no_module = [p for p in _all_classified if module_of(p) is None]

    sole_module = None
    if priv_module_changed:
        # priv/modules/ files have no Elixir closure; nominate their own source scans.
        if len(_module_names) == 1 and not _no_module:
            sole_module = next(iter(_module_names))
        else:
            reasons.append(
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
    if lib_changed or other_changed or priv_module_changed or docs_backend:
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
                reasons.append("lib file %s is not an .ex module file" % p)
                continue
            if not lib_docs[p][1]:
                reasons.append("lib file %s defines no module" % p)
            # Config atoms nominate the module's tests even in a mixed diff.
            if any(m in config_tokens for m in lib_docs[p][1]):
                reasons.append("%s defines a module named in config/; include module tests" % p)
                owner = module_of(p)
                if owner:
                    selected.update(t for t in all_tests if module_of(t) == owner)
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
                reasons.append("lib dependents closure over %d files; bounded" % args.max_closure)
                break

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
            reasons.append("fixture %s is read by no test we can find" % p)

    if any(FLOOR_LIB_RE.search(p) for p in lib_changed):
        selected.update(t for t in all_tests if t.startswith(FLOOR_TEST_PREFIXES))

    # T-2137: single-module additions — (b) all module tests, exclusions.
    if sole_module:
        this_module_test_dir = "test/letflow/modules/%s/" % sole_module
        # (b) Every test file under this module's test directory.
        selected.update(t for t in all_tests if t.startswith(this_module_test_dir))
        # Exclude tests in OTHER modules' subdirectories that the closure may have pulled via scanners.
        module_test_root = "test/letflow/modules/"
        selected = {
            t for t in selected
            if not t.startswith(module_test_root)
            or t.startswith(this_module_test_dir)
            or "/" not in t[len(module_test_root):]
        }

    selected &= test_set

    # T-2141: global pin tests are added to any selective run with a lib change.
    # They cover cross-module constraints (permission matrix, route scope, ledger registration)
    # for changes to core or cross-cutting lib files, replacing the SENSITIVE_LIB_NAME_RE
    # full-suite rule.
    if lib_changed or priv_module_changed or reasons:
        for pin in SINGLE_MODULE_PIN_TESTS:
            if pin in test_set:
                selected.add(pin)
        selected.update(t for t in all_tests if t.startswith(SINGLE_MODULE_PIN_PREFIXES))
    if not selected:
        return [], "no change-related backend tests; fixed identity/global pins still required"
    if len(selected) > args.max_share * len(all_tests):
        reasons.append(
            "selection covers %d of %d test files (over %d%%)"
            % (len(selected), len(all_tests), round(args.max_share * 100))
        )
    # Config-selected modules and sensitive paths have explicit high-risk coverage even
    # when no static caller exists. The budget below prioritises these over broad scanners.
    selected.update(risk_tests(changed, all_tests, root))
    if reasons:
        selected.update(safety_tests(all_tests))
    reason = "%d of %d test files related to %d changed file(s)" % (
        len(selected),
        len(all_tests),
        len(changed),
    )
    if sole_module:
        reason = "single module %s; " % sole_module + reason
    return sorted(selected), reason + ("; " + "; ".join(reasons) if reasons else "")


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


def safety_tests(all_tests):
    return set(
        SINGLE_MODULE_PIN_TESTS
        + STANDARD_IDENTITY_PIN_TESTS
        + STANDARD_SECURITY_PROBE_TESTS
        + STANDARD_BP_DOC_TEST
    ) & set(all_tests)


def attribute_block(text, name):
    """The body of a module attribute list (`@name [ ... ]`), or None when there is none."""
    m = re.search(r"@" + re.escape(name) + r"\s*\[", text)
    if not m:
        return None
    depth = 0
    for i in range(m.end() - 1, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[m.end():i]
    return None


def whole_tree_scan_tests(all_tests, root):
    """The whole-tree source scans: a test that reads a whole tree of the backend source.

    Such a scan is a pure function of the tree, so a diff that touches the tree can break
    its pin. Derived from the tree, so a scan that lands later is covered on the day it
    lands. A file that also holds database-backed cases is still a member: the exclusion of
    such files left real whole-tree scans deferrable (T-2691 rework).

    A member reads a whole tree either directly (a glob over a backend-source root) or
    through a helper module of `lib/` that walks a tree (T-2691 rework 2: the role-scope-
    grants writer scan calls `Scan.scan(["lib", "priv/modules"])`, so its wildcard lives in
    the called scanner and not in the test source; a literal-only discovery left that scan
    deferrable and its pin unverified).
    """
    scans = set()
    for path in all_tests:
        text = read(os.path.join(root, path)) or ""
        if not text:
            continue
        if (whole_tree_glob_roots(text) or chain_glob_roots(text)
                or expand_glob_roots(text, path) or indirect_tree_roots(text, root)):
            scans.add(path)
    return scans


def source_root(literal):
    """The backend-source root a directory literal names, or None.

    A literal that names a file (its last segment has an extension) is not a root, and a
    root outside the backend source (the handoff tree, the web tree) is not a root of this
    class: a backend-source diff cannot break the pin of a scan of another tree. A root
    that CONTAINS a domain root ("test" contains "test/support/") is one: the tree it
    reads overlaps the backend source.
    """
    if not DIRECTORY_LITERAL_RE.match(literal):
        return None
    if "." in literal.rsplit("/", 1)[-1]:
        return None
    if BACKEND_SOURCE_RE.match(literal + "/"):
        return literal
    if any(prefix.startswith(literal + "/") for prefix in BACKEND_SOURCE_PREFIXES):
        return literal
    return None


def expand_glob_roots(text, path):
    """The backend-source roots of a recursive glob whose root is `Path.expand(rel, __DIR__)`.

    The relative literal is resolved against the test file's directory; the definition must
    also hold a `**` token and a `wildcard` call, so a single-file read through the same
    form is not a member (T-2691 rework 4: the token-issuer, TA-audit-path and version-
    binding scans were deferrable).
    """
    if "**" not in text or "wildcard" not in text:
        return set()
    roots = set()
    for rel in EXPAND_ROOT_RE.findall(text):
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), rel))
        root = source_root(resolved)
        if root:
            roots.add(root)
    return roots


def whole_tree_glob_roots(text):
    """The backend-source roots a source file reads as a whole tree (`lib/**` -> "lib")."""
    roots = set()
    for m in WHOLE_TREE_GLOB_MARKER_RE.finditer(text):
        tail = PATH_TAIL_RE.search(text, 0, m.start())
        if not tail or not tail.group(0):
            continue
        # The path is a glob root only when a quote opens it: a mention of a tree in a
        # message ("expected no lib/letflow_web/** files touched") is not a read.
        if tail.start() == 0 or text[tail.start() - 1] not in "\"'":
            continue
        root = source_root(tail.group(0))
        if root:
            roots.add(root)
    return roots


def definition_units(text):
    """The text split into top-level definitions (a function, a test, an attribute)."""
    starts = [m.start() for m in UNIT_START_RE.finditer(text)]
    if not starts:
        return [text]
    return [text[a:b] for a, b in zip(starts, starts[1:] + [len(text)])]


def chain_glob_roots(text):
    """The backend-source roots of a recursive glob spelled as a chain of tokens.

    A definition that calls `Path.wildcard` and holds a `**` token reads a whole tree; the
    root is a directory literal of the same definition or of a module attribute it names
    (`@roots ["lib", "priv"]`, `@lib Path.join(File.cwd!(), "lib")`). The text marker alone
    left three scans of lib/ and priv/ outside the class (T-2691 rework 3).
    """
    if "**" not in text or "wildcard" not in text:
        return set()
    units = definition_units(text)
    attributes = {}
    for unit in units:
        m = re.match(r"\s*@([a-z_]\w*)\b", unit)
        if m:
            attributes[m.group(1)] = unit
    roots = set()
    for unit in units:
        if "wildcard" not in unit or not GLOB_TOKEN_RE.search(unit):
            continue
        literals = STRING_LITERAL_RE.findall(unit)
        for name in ATTRIBUTE_REF_RE.findall(unit):
            literals.extend(STRING_LITERAL_RE.findall(attributes.get(name, "")))
        for literal in literals:
            root = source_root(literal)
            if root:
                roots.add(root)
    return roots


def helper_module_index(root):
    """The modules of lib/ and test/support/ that walk a tree, by name, with their file.

    Only a tree-walking module can be the helper of a whole-tree reader, so the index
    holds those alone (cached per root: the tree does not change while the selector runs).
    """
    key = os.path.abspath(root)
    cached = _HELPER_INDEX.get(key)
    if cached is not None:
        return cached
    index = {}
    for pattern in ("lib/**/*.ex", "test/support/**/*.ex"):
        for path in sorted(glob.glob(os.path.join(root, pattern), recursive=True)):
            text = read(path)
            if not text or not walks_a_tree(text):
                continue
            for module in DEFMODULE_RE.findall(text):
                index.setdefault(module, path)
    _HELPER_INDEX[key] = index
    return index


def walks_a_tree(text):
    """True when a module walks a tree: a `Path.wildcard` over a `**` pattern."""
    return "Path.wildcard" in text and '"**' in text


def indirect_tree_roots(text, root):
    """The backend-source roots a test reads as a whole tree through a helper module.

    The helper must be a module of lib/ (or of test/support/) that walks a tree; the roots
    it scans are the ones its source names (in a list: `@default_roots`, the `for dir <-`
    of a comprehension, ...) and the ones the test passes to the call.
    """
    aliases = {}
    for full, short in ALIAS_RE.findall(text):
        aliases[short or full.rsplit(".", 1)[-1]] = full
    index = helper_module_index(root)
    roots = set()
    for module, _function, arguments in MODULE_CALL_RE.findall(text):
        target = aliases.get(module)
        if target is None and "." in module:
            target = module
        if target is None:
            matches = [v for k, v in aliases.items() if k.rsplit(".", 1)[-1] == module]
            target = matches[0] if matches else None
        if not target or target not in index:
            continue
        helper = read(index[target]) or ""
        if not walks_a_tree(helper):
            continue
        roots.update(helper_source_roots(target, helper))
        argument = arguments.strip()
        if argument.startswith("["):
            candidates = re.findall(r'"([^"]*)"', argument)
        elif argument.startswith("@"):
            block = attribute_block(text, argument[1:])
            candidates = re.findall(r'"([^"]*)"', block) if block else []
        else:
            candidates = []
        for candidate in candidates:
            scanned = source_root(candidate)
            if scanned:
                roots.add(scanned)
    return roots


def helper_source_roots(module, helper):
    """The backend-source roots a helper names in its source (cached per module).

    The cache is keyed by the module name: the source is read again on every call, and
    the identity of a temporary string is not stable (the allocator reuses it), so a key
    built from it can return another module's roots.
    """
    key = module
    cached = _HELPER_ROOTS.get(key)
    if cached is not None:
        return cached
    roots = set()
    candidates = []
    for match in HELPER_LIST_RE.finditer(helper):
        candidates.extend(re.findall(r'"([^"]*)"', match.group(1)))
    candidates.extend(HELPER_ATTRIBUTE_RE.findall(helper))
    for candidate in candidates:
        scanned = source_root(candidate)
        if scanned:
            roots.add(scanned)
    _HELPER_ROOTS[key] = roots
    return roots


def dynamic_sql_files(root, scan_test=DYNAMIC_SQL_SCAN_TEST):
    """The files the stamp opener scan pins as dynamic-SQL sites.

    Read from the scan itself (the authority), never from a hand list: the scan's
    `@dynamic_sql_files` block with its module attributes resolved.
    """
    text = read(os.path.join(root, scan_test)) or ""
    block = attribute_block(text, "dynamic_sql_files")
    if block is None:
        return set()
    body = "\n".join(line.split("#", 1)[0] for line in block.splitlines())
    attrs = dict(re.findall(r'@(\w+)\s+"([^"]+)"', text))
    files = set()
    for name, literal in re.findall(r'@(\w+)|"([^"]+)"', body):
        if name:
            if name in attrs:
                files.add(attrs[name])
        elif literal:
            files.add(literal)
    return files


def sql_call_sites(text):
    """The query call sites of a source file (`Repo.query`, `SQL.query`, ...)."""
    return [m.group(0) for m in SQL_CALL_RE.finditer(text)]


def dynamic_sql_trigger(changed, root, scan_test=DYNAMIC_SQL_SCAN_TEST):
    """True when the diff can change the stamp opener scan's oracle.

    A diff that adds or changes a `Repo.query` / `SQL.query` / `Ecto.Adapters.SQL.query`
    call, or that touches a file of the scan's `@dynamic_sql_files` list, can add or remove a
    dynamic-SQL site: the scan must then run in the bounded plan and may not be deferred to
    the nightly run (T-2689: ~21 non-literal SQL sites merged unseen).
    """
    pinned = dynamic_sql_files(root, scan_test)
    for path in changed:
        if path in pinned:
            return True
        if not BACKEND_SOURCE_RE.match(path) or not path.endswith((".ex", ".exs")):
            continue
        text = read(os.path.join(root, path))
        if text and sql_call_sites(text):
            return True
    return False


def whole_tree_scan_required(changed, all_tests, root):
    """The whole-tree source scans the diff can break: MANDATORY, never deferred."""
    if not any(BACKEND_SOURCE_RE.match(p) for p in changed):
        return set()
    scans = whole_tree_scan_tests(all_tests, root)
    if dynamic_sql_trigger(changed, root):
        scans.add(DYNAMIC_SQL_SCAN_TEST)
    return scans & set(all_tests)


def inventory_tests(changed, all_tests, root):
    """Explicit input/file map, including removed files and nested module routers."""
    required = set()
    # G-09: a tenant-migration change shifts the manifest positions the tenant tests pin and
    # can change the tenant table set. The manifest-position, table-oracle and replay cases are
    # mandatory for it: they may not be deferred to the nightly run. The list is the reviewed
    # one of the migration impact runner; the probe re-derives it from the tree.
    if any(
        path.startswith("priv/repo/migrations/") or path == "lib/letflow/tenant_provisioning.ex"
        for path in changed
    ):
        required.update(migration_impact_tests(root))
    for path in changed:
        if ROUTE_SOURCE_RE.search(path) or (
            path.startswith("lib/") and path.endswith(".ex")
            and ROUTE_DECLARATION_RE.search(read(os.path.join(root, path)) or "")
        ):
            required.update(ROUTE_INVENTORY_TESTS)
        # Mirrors the authority test's AST and text scan roots, including AC24's
        # scripts, workflow files, seeds, migrations and solution-pack data.
        if (path.startswith("lib/") and path.endswith(".ex")) or path.startswith(
            ("priv/", "config/", "scripts/", ".github/", "deploy/", "rel/")
        ) or path == "mix.exs":
            required.add(FLAG_AUTHORITY_TEST)
        # T-2606 (G18): the UAT runner and the static check of the process files are Python tooling whose
        # only coverage is their own stdlib suite; a change of that tooling must run it (the test runs the
        # whole suite). It is a mandatory check, not a candidate: it may not be deferred to the nightly run.
        if path.startswith("scripts/uat/"):
            required.add("test/scripts/uat_tooling_test.exs")
        if path.startswith("lib/") and path.endswith(".ex") and RAW_SQL_RE.search(
            read(os.path.join(root, path)) or ""
        ):
            required.update(RAW_SQL_TESTS)
    if any(ACTIVATION_SOURCE_RE.search(p) for p in changed):
        required.update(activation_tests(root))
    # T-2691: the whole-tree source scans pin the tree they read, so a backend-source diff
    # may break them. They are mandatory checks, not candidates: a deferred scan is a scan
    # that does not run until the nightly job.
    required.update(whole_tree_scan_required(changed, all_tests, root))
    return required & set(all_tests)


def activation_tests(root):
    """The reviewed list of test files that activate definitions (T-2737)."""
    text = read(os.path.join(root, ACTIVATION_TESTS_FIXTURE))
    if text is None:
        raise Full("activation test list %s unreadable" % ACTIVATION_TESTS_FIXTURE)
    return [
        line.strip()
        for line in text.replace("\r", "").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def migration_impact_tests(root):
    """The test files a tenant-migration change must run (G-09)."""
    path = os.path.join(root, MIGRATION_IMPACT_FIXTURE)
    text = read(path)
    if text is None:
        raise Full("migration impact list %s unreadable" % MIGRATION_IMPACT_FIXTURE)
    files = [
        line.strip()
        for line in text.replace("\r", "").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if not files:
        raise Full("migration impact list %s is empty" % MIGRATION_IMPACT_FIXTURE)
    return files


def risk_tests(changed, all_tests, root):
    """Explicit high-risk families; config atoms also map through module mentions."""
    groups = []
    for p in changed:
        if "identity" in p or p.startswith("priv/permission_matrix/"):
            groups.extend(("identity", "api", "scope-enforcement"))
        elif "ledger" in p or "event_store" in p or p.startswith("priv/repo/"):
            groups.extend(("ledger", "event_store", "migrations"))
        elif SENSITIVE_LIB_PATH_RE.search(p) or FLOOR_LIB_RE.search(p):
            groups.extend(("engine", "record_triggers", "modules"))
        elif p.startswith(("config/", "mix.", "test/support/")):
            groups.extend(("identity", "engine", "ledger"))
    if any(ACTIVATION_SOURCE_RE.search(p) for p in changed):
        selected_calls = {
            t for t in all_tests
            if ACTIVATION_CALL_RE.search(read(os.path.join(root, t)) or "")
        }
    else:
        selected_calls = set()
    # Family labels use hyphens; source paths use underscores. Include root-level
    # family variants as well as the main test and nested test directory.
    selected = {t for t in all_tests if any(
        t.startswith(("test/letflow/%s/" % g, "test/letflow/%s_" % g))
        for g in (label.replace("-", "_") for label in dict.fromkeys(groups))
    )}
    selected |= selected_calls
    config_modules = set()
    for p in changed:
        if p.startswith("config/"):
            config_modules.update(m for m in TOKEN_RE.findall(read(os.path.join(root, p)) or "")
                                  if m.startswith("Letflow."))
    if config_modules:
        for t in all_tests:
            doc = Doc(t, read(os.path.join(root, t)) or "")
            if any(mentions(doc, m) for m in config_modules):
                selected.add(t)
    return selected


def bounded_plan(selected, changed, weights, args, all_tests):
    """Priority admission into fixed bins. Overflow is evidence, never a full-suite fallback.

    Reserve global pins first, changed tests / conventional pairs next, high-risk tests
    and the changed module next, then at most three related families. Unknown timings
    cost 15 seconds rather than the old optimistic median. A mandatory pin that cannot
    fit fails selection; CI must not silently omit its fixed checks.

    T-2691: the file cap and the per-partition target budget the OPTIONAL candidates. A
    reserved check is never omitted, so it is admitted even when it does not fit the
    target of its bin (the whole-tree scans are reserved and the heaviest of them is
    slower than the target) and even when the optional file cap is reached. The hard
    bound is the whole run's budget: a reserved set that does not fit it fails the
    selection, which is loud, instead of being omitted.
    """
    required = safety_tests(all_tests) | inventory_tests(changed, all_tests, args.root)
    if any(FLOOR_LIB_RE.search(p) for p in changed):
        # Preserve the T-1403 regression floor even when broad, costly high-risk
        # candidates exhaust admission before record-trigger files are reached.
        required |= {"test/letflow/record_triggers/apply_test.exs"} & set(all_tests)
    direct = {p for p in changed if p.endswith("_test.exs")}
    direct.update("test/" + p[4:-3] + "_test.exs" for p in changed
                  if p.startswith("lib/") and p.endswith(".ex"))
    owners = {module_of(p) for p in changed} - {None}
    high_risk = risk_tests(changed, all_tests, args.root)
    selected = set(selected) | required

    def priority(t):
        if t in required:
            return 0
        if t in direct:
            return 1
        if t in high_risk:
            return 2
        if module_of(t) in owners:
            return 3
        return 4

    bins = [[0.0, []] for _ in range(args.shards * args.per_shard)]
    # The optional candidates' own account per bin: the reserved weight is not charged
    # against the per-partition target that measures them (T-2691 rework), or a heavy
    # high-risk check would lose its place to the reserved set.
    optional_load = {id(b): 0.0 for b in bins}
    optional_weight = 0.0
    deferred, families, optional_admitted = [], set(), 0
    # The optional file cap: never admit the whole corpus, even in a small synthetic
    # repository. The reserved set is admitted on top of it (T-2691), so it is never
    # omitted to keep the plan under the cap.
    optional_limit = min(args.standard_max_tests, max(0, len(all_tests) - 1))
    # The whole run's budget: the sum of the per-partition targets. A reserved check may
    # overrun its own partition's target, never the whole run's budget.
    capacity = len(bins) * args.target_ms
    reserved_weight = 0.0
    for t in sorted(selected, key=lambda t: (priority(t), -(weights.get(t) or 15000), t)):
        weight = max(1000.0, weights.get(t) or 15000.0)
        b = min(bins, key=lambda b: (b[0], len(b[1])))
        family = module_of(t) or t.split("/")[2]
        extra_family = priority(t) == 4 and family not in families and len(families) >= 3
        if t in required:
            # A reserved check is never omitted: it is admitted even when it does not fit
            # its partition's target and even when the optional file cap is reached. The
            # whole run's budget is the hard bound.
            if reserved_weight + weight > capacity:
                raise ValueError("mandatory global check does not fit standard budget: " + t)
            b[0] += weight
            b[1].append(t)
            reserved_weight += weight
            continue
        if (optional_admitted >= optional_limit
                or optional_load[id(b)] + weight > args.target_ms
                or reserved_weight + optional_weight + weight > capacity
                or extra_family):
            deferred.append(t)
            continue
        b[0] += weight
        optional_load[id(b)] += weight
        optional_weight += weight
        b[1].append(t)
        optional_admitted += 1
        if priority(t) == 4:
            families.add(family)
    # Compact the active bins so idle shards remain the tail.
    bins = [b for b in bins if b[1]]
    lines = ["%d %s" % (i, t) for i, (_, fs) in enumerate(bins, 1) for t in sorted(fs)]
    active = math.ceil(len(bins) / args.per_shard)
    skip = [str(k) for k in range(active + 1, args.shards + 1)]
    return lines, skip, sorted(deferred), len(required)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--event", default="")
    ap.add_argument("--kill-switch", default="")
    ap.add_argument("--force-full", default="", help="legacy repair reason; standard events stay bounded")
    ap.add_argument("--max-files", type=int, default=40)
    ap.add_argument("--max-closure", type=int, default=300)
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--max-share", type=float, default=0.55)
    ap.add_argument("--shards", type=int, default=8)
    ap.add_argument("--per-shard", type=int, default=4)
    ap.add_argument("--target-ms", type=float, default=120000.0)
    ap.add_argument("--standard-max-tests", type=int, default=160)
    ap.add_argument("--manifest", default="test/shard_manifest.txt")
    ap.add_argument("--root", default=".")
    ap.add_argument("--plan-out", default="")
    ap.add_argument("--deferred-out", default="")
    ap.add_argument("--nightly-log-dir", default="")
    ap.add_argument("--standard-plan", default="")
    ap.add_argument("--commit-range", default="unavailable")
    args = ap.parse_args()

    if args.nightly_log_dir:
        print(nightly_summary(args.nightly_log_dir, args.standard_plan, args.commit_range))
        return 0

    changed = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
    try:
        if args.event in ("schedule", "workflow_dispatch"):
            raise Full("event %s: nightly / manual runs always run the full suite" % args.event)
        if args.event not in ("pull_request", "merge_group", "push"):
            raise ValueError("unsupported event " + args.event)
        manifest_note = ""
        try:
            weights, total = read_manifest(os.path.join(args.root, args.manifest))
            if total != args.shards * args.per_shard:
                raise Full("manifest partition count mismatch")
        except Full as e:
            weights = {}
            manifest_note = "; %s; conservative timing weights" % e
        all_tests = [p for p in tracked(args.root) if p.startswith("test/") and p.endswith("_test.exs")]
        try:
            selected, reason = decide(changed, args.root, args, weights)
        except Exception as e:
            selected = safety_tests(all_tests) | risk_tests(changed, all_tests, args.root)
            reason = "bounded safety set after selection error: %s: %s" % (type(e).__name__, e)
        lines, skip, deferred, reserved = bounded_plan(selected, changed, weights, args, all_tests)
        if selected and not lines:
            raise ValueError("no tests fit standard budget")
        for path, output in ((args.plan_out, lines), (args.deferred_out, deferred)):
            if path:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(output) + ("\n" if output else ""))
        reason += manifest_note + "; bounded %d tests; %d deferred to nightly" % (len(lines), len(deferred))
        print("mode=selective")
        print("reason=" + reason.replace("\n", " ")[:3000])
        print("skip_shards=" + " ".join(skip))
        print("selected_count=%d" % len(lines))
        print("deferred_count=%d" % len(deferred))
        # T-2691: the reserved checks (the fixed pins and the whole-tree scans) are never
        # deferred and are admitted on top of the optional file cap.
        print("reserved_count=%d" % reserved)
    except Full as e:
        print("mode=full")
        print("reason=" + str(e))
        print("skip_shards=")
        print("selected_count=0")
    except Exception as e:
        # Fail closed. An absent/malformed plan must never start an unbounded test command.
        print("mode=error")
        print("reason=selection error: %s: %s" % (type(e).__name__, str(e).replace("\n", " ")))
        return 1
    return 0


def nightly_summary(log_dir, standard_plan, commit_range):
    """Compare real ExUnit failure headings with the successful push plan at this SHA."""
    plan_text = read(standard_plan)
    if plan_text is None:
        return ("Compared commit range: `%s`\n" % commit_range +
                "Selector coverage unavailable: no successful standard push plan for this SHA.")
    selected = {line.split()[-1] for line in plan_text.splitlines() if line.strip()}
    failures = set()
    for path in glob.glob(os.path.join(log_dir, "letflow_test_parallel.*", "partition-*.log")):
        text = read(path) or ""
        for name, test in re.findall(
            r"^\s*\d+\) (test .+)\n\s+(test/[^\n]+?_test\.exs):\d+", text, re.M
        ):
            failures.add((test, name))
    misses = sorted((test, name) for test, name in failures if test not in selected)
    lines = ["### Nightly selector comparison", "Compared commit range: `%s`" % commit_range,
             "selector miss count: %d" % len(misses)]
    lines.extend("- selector miss: `%s` — %s" % (test, name) for test, name in misses)
    if failures and not misses:
        lines.append("Failing files were present in the standard plan; investigate runtime differences.")
    if not failures:
        lines.append("No ExUnit failure headings found; crashes/timeouts are not selector misses.")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())
