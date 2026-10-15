# GH #2586 / REQ-498: effective-permission golden file in CI

Status: design (CODE-DESIGNER, WF-02 step 1). Base: `origin/main` at `ec8b9dee`.
Branch: `feat/GH-2586-permission-matrix-golden`. Gates: CODE-DESIGN-VALIDATOR,
SECURITY-REVIEWER (role-grant model, INV-10; see section 12), REVIEWER (scope, 0055 D7
wording). No migration, no route, no new permission atom, no change to what
`role_allows?/2` returns for any pair.

Sources: GH #2586 body (11 ACs, normative diff rule, "Scope of the widening rule",
"Non-circumvention"); decision 0055 D7 (D7.1, D7.2, D7.3 superseded, the open-point-1
ruling), D12 step (2a), AC10, AC26. The only issue comment is a heartbeat (no AC
revision).

## 0. Acceptance criteria (verbatim intent, numbered for the test brief)

| AC | Short form |
|---|---|
| AC1 | `--check` exits 0 on unmodified `main`; golden has 8 x length(permissions) entries; pure-function cardinality test with injected roles/permissions |
| AC2 | CI runs under the production module list: Exam's six atoms present, no `test/support/modules/**` fixture atom present, distinct failure under `MIX_ENV=test`; tests with a fixture atom and with Exam atoms missing (0055 AC26) |
| AC3 | New module atom with a `route_policies` entry only: exactly two added rows (PLATFORM_ADMIN, TENANT_ADMIN), classified `pre_approved` |
| AC4 | Failure when any other row is added/flipped true: (a) existing atom to a role lacking it; (b) new atom to a role other than PA/TA; (c) module grant or new module atom on an atom referenced by a core route policy. Three cases |
| AC5 | Non-circumvention: module widening + regenerated golden still fails; core-only change + regenerated golden passes the widening rule and is reported as a core matrix change. Two cases |
| AC6 | Narrowing without exact `widens_grants` fails; with exact entry passes; an entry matching no diff row fails. Three cases |
| AC7 | A `widens_grants` entry naming a widening row is still a failure |
| AC8 | `Catalog.validate/1` accepts `widens_grants: [{role, perm}]`, rejects unknown role / non-atom permission with stable tuples; manifests without the key stay valid |
| AC9 | CI step in `backend_static` runs the check under dev env; same invocation documented locally; `letflow.check(.static)` documents why it is separate; `mix letflow.check_requirements_registration` passes with the REQ-498 entry |
| AC10 | Core change (`core_role_allows?` or a new core atom) without regenerating the golden fails |
| AC11 | `--write` is deterministic (byte-identical twice; ordered role then permission) |

## 1. Decisions

| # | Decision | One-line rationale |
|---|---|---|
| D1 | Trusted baseline = the golden file as committed at the BASE commit, read with `git show <ref>:priv/permission_matrix/effective.golden`; never the working-tree golden | The PR cannot author an object already on `main`, so classification against it cannot be satisfied by regenerating the file in the PR |
| D2 | CI baseline ref: `pull_request` -> `HEAD^1` of the synthetic merge commit (guarded: HEAD must have exactly 2 parents); `merge_group` -> `github.event.merge_group.base_sha`; `push` to main -> `github.event.before`. Local default -> `git merge-base HEAD origin/main`. `--baseline-ref <rev>` overrides | The checked-out tree in CI IS the merge result, so the base tip is the exact "before"; merge-base would misattribute main's own later changes to the PR. Locally HEAD is not a merge tree, so merge-base is the right analogue |
| D3 | `fetch-depth: 0` is already set on `backend_static` (`ci.yml:403-405`); no fetch step added | `HEAD^1`, `base_sha` and `before` are all in full history already |
| D4 | Two independent checks, both always run: FRESHNESS (working-tree golden == computed matrix, two-way) and CLASSIFICATION (trusted baseline vs computed matrix) | Freshness makes every matrix change (core included, AC10) visible as a reviewable diff; classification is the part a PR cannot satisfy by editing data |
| D5 | Module vs core separation is per ROW, by a `via` attribute computed from live code: `via = core` when the row is true WITHOUT any Catalog `role_grants` contribution, `via = grant` when it is true only because of `Catalog.role_grants/1`. Plus an `owner` per atom (`core` or `module:<id>`) | This is the "matrix with and without Catalog contributions" split done row-wise, so a new core role or a core rule change is a core change, while anything that only a manifest's `role_grants` makes true is a module widening |
| D6 | New public `Authorization.role_allows_without_module_grants?/2` (the `:MyModulesRead` clause + the existing private `core_role_allows?/2`), body-free delegation; `core_role_allows?/2` stays private; `role_allows?/2` untouched | `via` needs the core half; exposing it through one named function keeps all authorization semantics inside `authorization.ex` (no PA/TA logic duplicated in the matrix module). It can only under-grant relative to `role_allows?/2`, so misuse fails closed |
| D7 | 0055 D7.2 `core_policy_atoms/0`: NOT built as a maintained list. The classifier's `core_policy_atoms` input is `core_permissions()` (a fail-closed over-approximation), and one test proves the premise "every core route policy resolves to a core permission" via `Code.Typespec.fetch_types/1` over `@type endpoint_policy_key` | Smaller: no new list, no new public function, no second table to keep in sync; the premise holds on `ec8b9dee` (section 6) and a test keeps it true |
| D8 | `widens_grants` declarations of module `<id>` are EVALUATED only when `<id>`'s manifest `version` differs from the baseline header's version for `<id>` (or `<id>` is new); otherwise they are inert | A declaration describes one version transition; without this, a merged narrowing's entry would match nothing on every later PR and fail unrelated work (AC6 c would make the file un-maintainable) |
| D9 | A `widens_grants` entry can only ever MATCH a narrowing row; an entry naming a widening row fails (`declaration_authorises_widening`) whether or not it is evaluated, and the widening row fails independently | Ruling: widening is refused, not signed off (0055 D7.3 superseded) |
| D10 | Golden path `priv/permission_matrix/effective.golden`; one line per (role, permission); format version 1 in the header; LF only (`.gitattributes` entry) | Issue suggestion; one-line-per-row gives exactly 8 x N lines (AC1 countable) and a one-line diff per grant change |
| D11 | Rows sorted by role name then permission name (byte order of the atom's string), not by list position | Re-ordering `@roles`/`@permissions` or the module list must not churn the file (AC11) |
| D12 | Pure logic in `Letflow.Api.PermissionMatrix` (`lib/letflow/api/permission_matrix.ex`); IO (env, files, git, exit) in `Mix.Tasks.Letflow.PermissionMatrix` (`lib/mix/tasks/letflow.permission_matrix.ex`) | AC tests call pure functions with injected inputs; the task stays thin like the precedent `letflow.check_scope_node_paths_writers` |
| D13 | Not in `@check_static_steps`. Separate CI step `MIX_ENV=dev mix letflow.permission_matrix --check` in `backend_static`; locally the same command | `letflow.check.static` is pinned to `:test` (`mix.exs:20`), where the task deliberately refuses (AC2) |
| D14 | The task refuses `MIX_ENV=test` (distinct error) and any env other than `:dev`/`:prod`, in both `--check` and `--write` | A golden written or checked over fixtures is the exact failure 0055 S3-3 names |
| D15 | Fixture atoms enumerated by a static AST scan (`Code.string_to_quoted/2`) of `test/support/modules/**/*.{ex,exs}`, collecting every `permissions:` literal atom list; a non-literal value or zero scanned files is an error; a test in the test env asserts scan == union of the compiled fixture manifests' permissions | No compile of test support in dev; self-maintaining (a committed list drifts silently); the test-env equality turns the scan's completeness into a checked fact |
| D16 | The dev-env step also runs `Catalog.validate/1` over every PRODUCTION manifest and fails on any error | A production module need not be registered in `config/test.exs` (guide section 6), so without this the validate rules (incl. `core_permission_collision`, `widens_grants` shape) might never run on it |
| D17 | Dev compile in CI: `WASMEX_BUILD: true` (same toolchain policy as the test-env steps) and a dedicated cache step for `_build/dev` keyed `${{ runner.os }}-mix-dev-${{ hashFiles('mix.lock') }}`; no database, no app start | One toolchain policy; the shared `_build` cache entry is saved first by whichever job wins (`ci.yml:501-502`), so `_build/dev` would be cached nondeterministically; a cold dev build is paid once per `mix.lock` change |
| D18 | Bootstrap (no baseline golden at the base ref) is accepted ONLY when the base ref also lacks `lib/mix/tasks/letflow.permission_matrix.ex`; otherwise it is a failure | Accepting "no baseline" generally would let a PR that moves or renames the golden path skip classification |
| D19 | On a successful run the task prints the classification report and, when `GITHUB_STEP_SUMMARY` is set, appends it there | SECURITY-REVIEWER and REVIEWER see a core matrix change and pre-approved rows without reading logs |

## 2. Golden file format (`priv/permission_matrix/effective.golden`, format 1)

### 2.1 Layout

Header lines, exactly these, in this order (each begins `# `, key and value separated by
`: `):

| Line | Value |
|---|---|
| 1 | `# letflow effective permission matrix` (title, constant) |
| 2 | `# format: 1` |
| 3 | `# regenerate: MIX_ENV=dev mix letflow.permission_matrix --write` (constant) |
| 4 | `# modules: <id>@<version>[,<id>@<version>...]` sorted by id; `-` when no module is registered. On `ec8b9dee` dev: `exam@0.1.0` |
| 5 | `# roles: <n>` (8) |
| 6 | `# permissions: <n>` (43 core + 6 Exam = 49 on `ec8b9dee`) |
| 7 | `# rows: <roles x permissions>` (392) |
| 8 | `# columns: role permission allowed owner via` (constant) |

Then exactly `rows` data lines, each five fields separated by ONE space, no trailing
space, LF line ending, file ends with a single LF:

| Field | Values |
|---|---|
| role | role atom name, e.g. `TENANT_ADMIN` |
| permission | permission atom name, e.g. `ExamSessionStart` |
| allowed | `true` / `false` = `Authorization.role_allows?(role, permission)` |
| owner | `core` when the atom is in `Authorization.core_permissions/0`; `module:<id>` otherwise, `<id>` = the first entry module in `Catalog.entry_modules/0` order whose manifest `:permissions` contains it |
| via | `core` when `allowed` and `role_allows_without_module_grants?(role, permission)`; `grant` when `allowed` and not the former (true only through `Catalog.role_grants/1`); `-` when not `allowed` |

Ordering: role name ascending (byte order), then permission name ascending. Examples
(illustrative): `CANDIDATE ExamSessionStart true module:exam grant`,
`TENANT_ADMIN ExamSessionStart true module:exam core`,
`TASK_WORKER ExamSessionStart false module:exam -`,
`TASK_WORKER MyModulesRead true core core`.

No timestamp, no git sha, no host name anywhere (determinism, AC11). `:MyModulesRead`
appears as `true ... core core` for all 8 roles (`authorization.ex:1463`, the first
`role_allows?/2` clause).

### 2.2 Parse rules (strict; errors are `{:error, term}`, never a crash)

- Header lines 1-8 must all be present in order; line 2 value other than `1` ->
  `{:unsupported_format, value}`; any other deviation -> `{:malformed_header, line_no}`.
- Every data line must have 5 fields with the value sets above ->
  `{:malformed_row, line_no}`. `allowed=false` requires `via=-` and `allowed=true` requires
  `via` in `core|grant`, else `{:malformed_row, line_no}`.
- A repeated (role, permission) -> `{:duplicate_row, role, permission}`.
- Row count, role count and permission count must match lines 5-7 and the row set must be
  the full product -> `{:count_mismatch, expected, actual}`.
- A trailing `\r` on a line is stripped before parsing (tolerates a CRLF checkout; the
  writer always writes LF, and `.gitattributes` gets `priv/permission_matrix/*.golden text eol=lf`).
- Roles and permissions stay STRINGS after parsing (no `String.to_atom/1` on file input).

## 3. `Letflow.Api.Authorization` change (one function)

```elixir
@doc "role_allows?/2 minus the Catalog.role_grants/1 fallback: the :MyModulesRead clause, then core_role_allows?/2. For the permission matrix's `via` column only; never an access decision (it can only under-grant)."
@spec role_allows_without_module_grants?(role(), permission() | atom()) :: boolean()
```

Invariant (tested, T20): for every role in `roles/0` and every atom in `permissions/0`,
`role_allows?(r, p) == (role_allows_without_module_grants?(r, p) or p in Catalog.role_grants(r))`.
`role_allows?/2` and `core_role_allows?/2` are not edited (body or position).

## 4. `Letflow.Api.PermissionMatrix` (pure; `lib/letflow/api/permission_matrix.ex`)

### 4.1 Types

```elixir
@type role_name :: String.t()
@type perm_name :: String.t()
@type module_id :: String.t()
@type owner :: :core | {:module, module_id()}
@type via :: :core | :grant | :none
@type row :: %{allowed: boolean(), owner: owner(), via: via()}
@type t :: %{
        format: 1,
        modules: %{module_id() => String.t()},      # id => version
        roles: [role_name()],                        # sorted
        permissions: [perm_name()],                  # sorted
        rows: %{{role_name(), perm_name()} => row()}
      }
@type build_inputs :: %{
        allows?: (atom(), atom() -> boolean()),       # role_allows?/2 in production
        core_allows?: (atom(), atom() -> boolean()),  # role_allows_without_module_grants?/2
        owner_of: %{atom() => owner()},
        modules: %{module_id() => String.t()}
      }
@type context :: %{
        core_policy_atoms: MapSet.t(perm_name()),
        route_refs: %{perm_name() => [module_id()]},          # atom => ids whose route_policies name it
        declarations: %{module_id() => [{role_name(), perm_name()}]}  # widens_grants, per manifest
      }
@type row_ref :: {role_name(), perm_name()}
@type widening_reason ::
        :module_grant | :new_atom_non_admin_role | :core_policy_atom | :referenced_by_other_module
@type failure ::
        {:widening, role_name(), perm_name(), widening_reason()}
        | {:unmatched_narrowing, role_name(), perm_name(), module_id() | :unknown_module}
        | {:unmatched_declaration, module_id(), role_name(), perm_name()}
        | {:declaration_authorises_widening, module_id(), role_name(), perm_name()}
@type core_change ::
        {:added, role_name(), perm_name()}
        | {:removed, role_name(), perm_name()}
        | {:owner_changed, perm_name(), owner(), owner()}
        | {:module_removed, module_id()}
@type report :: %{
        labels: [:pre_approved | :narrowing | :core_change | :bootstrap],  # sorted, unique
        pre_approved: [{role_name(), perm_name(), module_id()}],
        narrowings: [{role_name(), perm_name(), module_id() | :unknown_module}],
        core_changes: [core_change()],
        inert_declarations: [{module_id(), role_name(), perm_name()}],
        failures: [failure()]
      }
@type production_error ::
        {:wrong_env, atom()}
        | {:production_atoms_missing, [perm_name()]}
        | {:fixture_atoms_present, [perm_name()]}
@type scan_error ::
        {:unscannable_fixture_manifest, Path.t(), pos_integer()}
        | {:fixture_parse_error, Path.t()}
        | :no_fixture_sources
```

All list fields in `report` and in error payloads are sorted (deterministic output).

### 4.2 Public functions

```elixir
@spec build([atom()], [atom()], build_inputs()) :: {:ok, t()} | {:error, {:duplicate_permission, atom()} | {:duplicate_role, atom()}}
@spec current() :: {:ok, t()} | {:error, term()}
@spec current_context() :: context()
@spec render(t()) :: String.t()
@spec parse(String.t()) :: {:ok, t()} | {:error, term()}
@spec freshness(golden :: t(), computed :: t()) :: :ok | {:error, {:golden_stale, %{added: [String.t()], removed: [String.t()], header: [{atom(), term(), term()}]}}}
@spec true_set_diff(baseline :: t(), computed :: t()) :: %{added: [row_ref()], removed: [row_ref()]}
@spec classify(baseline :: t() | :absent, computed :: t(), context()) :: report()
@spec check_production_list(t(), fixture_atoms :: MapSet.t(perm_name()), env :: atom()) :: :ok | {:error, [production_error()]}
@spec fixture_permissions([{Path.t(), String.t()}]) :: {:ok, MapSet.t(perm_name())} | {:error, scan_error()}
@spec bootstrap_allowed?(baseline_golden_present? :: boolean(), baseline_task_present? :: boolean()) :: boolean()
@spec format_report(report()) :: String.t()
```

Semantics:

- `build/3`: one row per (role, permission) in the injected lists; `allowed = allows?.(r, p)`;
  `via` per section 2.1 using `core_allows?`; `owner = Map.get(owner_of, p, :core)`. Duplicate
  atoms in either list are an error (a module re-declaring a core atom would otherwise be
  silently collapsed). Atom-to-string conversion happens here.
- `current/0`: `build(Authorization.roles(), Authorization.permissions(), inputs)` with
  `allows? = &Authorization.role_allows?/2`, `core_allows? = &Authorization.role_allows_without_module_grants?/2`,
  `owner_of` from `Catalog.entry_modules/0` order, `modules` from each manifest's `id`/`version`.
- `current_context/0`: `core_policy_atoms` = strings of `Authorization.core_permissions/0`
  (D7); `route_refs` from every registered manifest's `route_policies`; `declarations` from
  `Map.get(manifest, :widens_grants, [])` per manifest id.
- `freshness/2`: equal parsed structures -> `:ok`; otherwise the two-way diff as rendered row
  lines (`added` = in computed not in golden, `removed` = in golden not in computed) plus
  differing header fields. Compares parsed values, not bytes.
- `true_set_diff/2`: `added` = rows `allowed` in computed and not `allowed` (or absent) in
  baseline; `removed` = rows `allowed` in baseline and not `allowed` (or absent) in computed.
  False rows that appear or disappear are not diff rows (a new atom's six false rows are not
  "added rows" in AC3's sense).

### 4.3 Classification algorithm (`classify/3`), normative

Inputs: B (trusted baseline, or `:absent`), C (computed), ctx. Let `atoms(M)` = M's
permission set, `PA = "PLATFORM_ADMIN"`, `TA = "TENANT_ADMIN"`.

0. If B is `:absent`: return `labels: [:bootstrap]`, empty lists, no failures (the TASK
   decides whether bootstrap is allowed, D18).
1. Evaluated modules: `E = { id in keys(C.modules) | id not in keys(B.modules) or C.modules[id] != B.modules[id] }`.
2. Compute `%{added: A, removed: R} = true_set_diff(B, C)`.
3. For each `{r, p}` in A (widening candidates), with `c = C.rows[{r, p}]`:
   1. `c.via == :grant` -> failure `{:widening, r, p, reason}` with `reason = :core_policy_atom`
      if `p in ctx.core_policy_atoms`, else `:module_grant`. (No exception, no override.)
   2. `c.via == :core` and `c.owner == {:module, id}` and `p not in atoms(B)` (a NEW module
      atom):
      - `r not in [PA, TA]` -> `{:widening, r, p, :new_atom_non_admin_role}`;
      - else `p in ctx.core_policy_atoms` -> `{:widening, r, p, :core_policy_atom}`;
      - else `Map.get(ctx.route_refs, p, []) -- [id] != []` (named by another module's
        `route_policies`) -> `{:widening, r, p, :referenced_by_other_module}`;
      - else -> `pre_approved` entry `{r, p, id}`.
   3. Otherwise (`via == :core` on a core atom, or on a module atom that already existed in B)
      -> core change `{:added, r, p}`. This is only reachable by a change to
      `authorization.ex` (a new role, a per-role list, `permission_scope/1`), never by a
      manifest alone.
4. For each `{r, p}` in R (narrowing candidates), with `b = B.rows[{r, p}]`:
   1. `b.owner == {:module, id}`:
      - `p in atoms(C)` and `b.via == :core` -> core change `{:removed, r, p}` (a core rule
        stopped granting an atom that still exists);
      - else `id not in keys(C.modules)` -> core change `{:module_removed, id}` (once per id;
        removing a module from `config/config.exs` is a core/config change);
      - else -> module narrowing attributed to `id`.
   2. `b.owner == :core`: `b.via == :grant` -> module narrowing attributed to
      `:unknown_module` (unreachable while `Catalog.validate/1` holds; fail-closed); else core
      change `{:removed, r, p}`.
5. Owner changes: for `p` in both `atoms(B)` and `atoms(C)` with different owners -> core
   change `{:owner_changed, p, b_owner, c_owner}` (moving an atom between core and a module
   edits `authorization.ex`).
6. Declarations. For every `{id, entries}` in `ctx.declarations` and every `{r, p}` in
   entries:
   - `{r, p}` in A -> failure `{:declaration_authorises_widening, id, r, p}` (always, even when
     `id not in E`);
   - else `id not in E` -> `inert_declarations` entry (informational);
   - else `{r, p}` is a module narrowing attributed to `id` or to `:unknown_module` ->
     matched (goes to `narrowings` as `{r, p, id}`);
   - else -> failure `{:unmatched_declaration, id, r, p}`.
7. Every module narrowing not matched in step 6 -> failure
   `{:unmatched_narrowing, r, p, attributed_id}`. The failure text says "bump the module
   version and declare it in `widens_grants`" when the attributed module is not in E.
8. `labels`: `:pre_approved` if any pre-approved row, `:narrowing` if any matched narrowing,
   `:core_change` if any core change; sorted, unique. `failures` sorted.

Verdict: the run passes iff `failures == []` AND freshness is `:ok` AND
`check_production_list/3` is `:ok` AND every production manifest validates (D16).

Mapping of the normative diff rule: "only pre-approved diff" = step 3.2's last branch;
"widening refused, no override" = steps 3.1 and 3.2's failure branches and step 6's first
bullet; "narrowing must exactly match, both directions" = steps 6 and 7; "core change is
not refused but reviewable" = steps 3.3, 4, 5 plus freshness (D4); ":MyModulesRead true for
every role" = section 2.1.

### 4.4 `check_production_list/3`

Collects all applicable errors (not first-only), in this order:

1. `env not in [:dev, :prod]` -> `{:wrong_env, env}`. Rendered for `:test` as the distinct
   message: `letflow.permission_matrix refuses MIX_ENV=test: config/test.exs registers the
   test/support/modules fixtures, so this would not be the production matrix. Run
   MIX_ENV=dev mix letflow.permission_matrix --check`.
2. Sentinel atoms (module attribute in `PermissionMatrix`): `ExamSessionStart`,
   `ExamSessionRead`, `ExamSessionSave`, `ExamSessionSubmit`, `ExamSessionReportEvent`,
   `ExamCertificateIssue`; any missing from `C.permissions` ->
   `{:production_atoms_missing, missing}`.
3. `fixture_atoms` intersect `C.permissions` non-empty -> `{:fixture_atoms_present, present}`.

The header line `# modules: exam@0.1.0` is printed by the task as the human-readable proof of
the list used.

### 4.5 `fixture_permissions/1` (D15)

Input: `[{path, source}]` (the task reads `Path.wildcard("test/support/modules/**/*.{ex,exs}")`,
sorted). Empty input -> `{:error, :no_fixture_sources}`. Each source is parsed with
`Code.string_to_quoted/2` (`columns: true`); a parse failure ->
`{:fixture_parse_error, path}`. Every AST occurrence of the keyword/map pair key
`:permissions` is inspected: a literal list of atoms contributes its atoms (as strings); any
other value (variable, attribute, call) -> `{:unscannable_fixture_manifest, path, line}`.
This over-approximates (a `permissions:` key in non-manifest fixture code also counts), which
can only make check 3 stricter. On `ec8b9dee` the result is `MapSet.new(["FixtureRead"])`.

Why a static scan, not the alternatives: compiling `test/support` under dev changes
`elixirc_paths(:dev)` (`mix.exs:26-27`) and drags test-only dependencies into a dev build; a
committed list silently misses a new fixture atom. T9 (test env) asserts the scan equals the
union of the compiled fixture manifests' `:permissions`, so a scanner gap fails the suite.

## 5. `Mix.Tasks.Letflow.PermissionMatrix` (`lib/mix/tasks/letflow.permission_matrix.ex`)

```elixir
@shortdoc "Writes or checks the effective role x permission golden file (production module list)"
@spec run([String.t()]) :: :ok
```

Switches (`OptionParser`, `strict`): `--check` (default when neither given), `--write`,
`--baseline-ref <git rev>`. Both `--check` and `--write` -> `Mix.raise`. Unknown switch ->
`Mix.raise`.

Steps, in order (all findings collected, one `Mix.raise/1` at the end listing every failure;
exit 0 otherwise):

1. `Mix.Task.run("compile")`. No `app.start`, no `app.config`, no Repo: nothing reads the
   database or `config/runtime.exs`.
2. `PermissionMatrix.current/0`; on `{:error, _}` raise.
3. For every `Catalog.all_manifests/0` entry, `Catalog.validate/1` (D16); collect errors as
   `{:invalid_manifest, id, error}`.
4. `fixture_permissions/1` over the scanned sources, then `check_production_list(C, fixtures, Mix.env())`.
5. `--write`: if steps 2-4 produced no error, write `render(C)` to
   `priv/permission_matrix/effective.golden` (binary write, LF, creating the directory); print
   the header and "classification not evaluated by --write; run --check". Stop.
6. `--check`: read the working-tree golden; missing or unparsable -> failure; else
   `freshness(G, C)`.
7. Resolve the baseline ref: `--baseline-ref` if given; else `git merge-base HEAD origin/main`.
   Any git failure (no git, unknown ref, no `origin/main`) -> failure
   `{:baseline_unavailable, ref, stderr_first_line}` with the hint "git fetch origin main".
   Never a silent pass.
8. Read B: `git show <ref>:priv/permission_matrix/effective.golden`. Path absent at ref ->
   check `git cat-file -e <ref>:lib/mix/tasks/letflow.permission_matrix.ex`;
   `bootstrap_allowed?(false, task_present?)` true -> B = `:absent`; false -> failure
   `{:baseline_missing, ref}`. Present -> `parse/1`; parse error -> failure.
9. `classify(B, C, current_context())`; print `format_report/1` (sections: module list,
   pre-approved rows, matched narrowings, core matrix changes, inert declarations, failures)
   and append it to `$GITHUB_STEP_SUMMARY` when that env var is set.
10. Raise if any failure from steps 2-9; message starts with the failure class and, for a
    stale golden only, ends with `MIX_ENV=dev mix letflow.permission_matrix --write`.

The task shells out with `System.cmd/3` (args as a list, no shell string). It never fetches.

## 6. Decision D7: why `core_policy_atoms/0` is not built (0055 D7.2)

Core route policies reach a permission only as `required_permission(endpoint_policy_key(m, p))`
(`authorization.ex:1230`). On `ec8b9dee` (scan of the `@type endpoint_policy_key` union
against the explicit `required_permission/1` clauses):

- every key in the union except `:UnmatchedPlatformPath` and `:UnmatchedRoute` has an
  explicit `required_permission/1` clause; those two are intercepted by `evaluate_access/2`
  before `required_permission/1` is called (`authorization.ex:1209-1217`), and `:Unknown`
  maps to `:MetricsRead`;
- every explicit clause returns an atom in `core_permissions/0`.

So the set of atoms core route policies use is a subset of `core_permissions/0`, and the
identity fallback (`authorization.ex:1393`) is reached only by module route keys. Using
`core_permissions/0` as `ctx.core_policy_atoms` is therefore a superset (fail-closed), costs
no new list, and the remaining risk (a future core key without an explicit clause whose name
equals a module atom) is pinned by T19: for every atom in the `endpoint_policy_key` typespec
union minus the two markers, `required_permission(k) in core_permissions()`. A new core key
that breaks this fails the suite and must add its explicit clause.

What replaces rule (c) concretely: (i) a `via = grant` widening on an atom in
`core_permissions()` is reported with reason `:core_policy_atom` (step 3.1); (ii) a new
module atom found in `core_policy_atoms` is never pre-approved (step 3.2); (iii)
`Catalog.validate/1`'s `core_permission_collision` and `ungranted_permission_declared`, now
also run on production manifests (D16), stop a manifest from declaring or granting a core
atom at all. Accepted limit: T19 relies on the typespec union being complete; a core
`endpoint_policy_key/2` clause returning an atom outside the union is not detected
mechanically (REVIEWER checks it, as today).

## 7. `Letflow.Modules.Catalog.validate/1` (`widens_grants`, rule 8)

New private step appended to the `with` chain after `validate_manages_entity_types/1`.
Optional key `:widens_grants`; absent is valid. Errors, checked in this order, first error
returned (same shape as every existing rule):

| Condition | Error tuple |
|---|---|
| present but not a list, or an element not a 2-tuple | `{:error, {:invalid_widens_grants, value}}` (value = the whole key value) |
| a tuple whose first element is not in `Authorization.roles/0` | `{:error, {:unknown_widens_grants_role, role}}` |
| a tuple whose second element is not an atom | `{:error, {:invalid_widens_grants_permission, permission}}` |

Deliberately NOT checked: that the permission is in the manifest's own `:permissions` (a
narrowing may remove the atom), duplicates (harmless: they match the same row). Docs to
update in the same PR: the `validate/2` docstring (rule list, "A seventh rule" paragraph
becomes seven-and-eight), `t:Letflow.Modules.Module.manifest/0` gains
`optional(:widens_grants) => [{atom(), atom()}]`, and the `defmanifest` argument table gains
the row. `defmanifest` already passes unknown keys through (`module.ex`, `Map.new(kw)`).

## 8. CI wiring (`.github/workflows/ci.yml`, job `backend_static`)

Two new steps, both `if: needs.changes.outputs.backend != 'false'`, placed after "Run static
checks (mix letflow.check.static)" and before "Run isolated tails":

1. "Cache _build/dev (permission matrix)": `actions/cache@v4`, path `_build/dev`, key
   `${{ runner.os }}-mix-dev-${{ hashFiles('mix.lock') }}`, restore-keys
   `${{ runner.os }}-mix-dev-`. Only this job uses the key.
2. "Effective permission matrix (MIX_ENV=dev, production module list)": env
   `MIX_ENV: dev`, `WASMEX_BUILD: true`, `EVENT_NAME: ${{ github.event_name }}`,
   `MERGE_GROUP_BASE: ${{ github.event.merge_group.base_sha }}`,
   `PUSH_BEFORE: ${{ github.event.before }}`. Shell (`set -euo pipefail`) behaviour:
   - `pull_request`: require `git rev-list --parents -n 1 HEAD` to show 2 parents, else
     `::error::` "expected the pull_request merge ref" and exit 1; ref = `git rev-parse HEAD^1`;
   - `merge_group`: ref = `MERGE_GROUP_BASE` (non-empty, else error);
   - `push`: ref = `PUSH_BEFORE` (non-empty and not all zeros, else error);
   - any other event: error;
   - echo the event and the resolved ref, then run
     `mix letflow.permission_matrix --check --baseline-ref "$ref"`.

No Postgres use (the job's service stays for the other steps). Cost: one dev compile of deps
and the project, cold once per `mix.lock` change, then a cache hit plus an incremental
project compile; the PR body reports the measured step duration (sizing note in the issue).
Also update `ci.yml`'s header comment item 4 to name the new step and why it is not inside
`letflow.check.static`.

Local, documented command (same invocation): `MIX_ENV=dev mix letflow.permission_matrix --check`
(PowerShell: `$env:MIX_ENV='dev'; mix letflow.permission_matrix --check`), after
`git fetch origin main`. `mix.exs` is not changed: `@check_static_steps` keeps its contents and
gains a comment stating the task is a separate CI step because the alias is pinned to `:test`
(`mix.exs:20`) and the task refuses `:test` by design.

## 9. Docs and registration (same PR)

- `docs/guides/adding-an-application-module.md`: new section "6a. The effective-permission
  golden file" (what the file is; the diff rule in five bullets; that widening `role_grants`
  is refused with no override until per-tenant snapshots exist; how to declare a narrowing
  with `widens_grants` and a version bump, and to clear the list at the next version bump;
  the regenerate command `MIX_ENV=dev mix letflow.permission_matrix --write` and the check
  command; why it never runs under `MIX_ENV=test`). Add one line to the "Checklist for adding
  module `<id>`" and to section 3's manifest fields table (`widens_grants`).
- `docs/guides/backend_developer_guide.md`: one paragraph under its CI / checks material
  pointing to 6a for any change to `core_permissions/0`, `@roles` or a `core_role_allows?/2`
  clause (regenerate the golden; SECURITY-REVIEWER sees it as a core matrix change).
- `.gitattributes`: `priv/permission_matrix/*.golden text eol=lf`.
- `docs/requirements.yaml`: REQ-498 entry (owner ELIXIR-DEV, stage S7, `gh: 2586`, the 11
  ACs mirrored, `depends_on: []`, registration line per `TASK_QUEUE.md`) so
  `mix letflow.check_requirements_registration`, `check_req_id_collision` and
  `check_deferral_staleness` pass; status-history event per `CLAUDE.md`.
- Decision 0055 is not edited. The PR body records the D7.2 choice (section 6).

## 10. Cross-module dependencies

| From | To | Kind |
|---|---|---|
| `PermissionMatrix` | `Authorization.roles/0`, `permissions/0`, `core_permissions/0`, `role_allows?/2`, `role_allows_without_module_grants?/2` | read |
| `PermissionMatrix` | `Catalog.entry_modules/0`, `all_manifests/0` | read |
| Mix task | `PermissionMatrix`, `Catalog.validate/1`, `git` via `System.cmd/3`, filesystem | IO |
| `Catalog` | `Authorization.roles/0` (rule 8) | existing direction |

No new dependency from any runtime path to `PermissionMatrix`; nothing at request time calls
it. `mix letflow.check_boundaries` is unaffected (`lib/letflow/api` is core; only
`catalog.ex` names concrete modules, unchanged).

## 11. Invariants

- I1: classification never reads the working-tree golden (only B from git and C from code).
- I2: no input authored in the PR can turn a failure into a pass except by changing code in
  `authorization.ex`, `permission_matrix.ex` or the task (all reviewed paths, section 12).
- I3: `role_allows?/2` results are unchanged for every pair (T20 plus existing suites).
- I4: `render/1` is a pure function of `t()`; `render(parse(render(m))) == render(m)`.
- I5: the task never writes outside `priv/permission_matrix/` and never runs git commands
  that mutate the repo.

## 12. Notes for SECURITY-REVIEWER (INV-3, INV-10, the role-grant model)

- INV-10: no route, no permission atom, no scope classification changes. The golden makes
  every platform-scope row visible (PA only, via `core`) and any change to a `permission_scope/1`
  outcome shows as a core change in the freshness diff. The classifier treats TENANT_ADMIN's
  implicit rows on a NEW module atom as pre-approved only because module atoms are tenant
  scope by construction (`permission_scope/1`, REQ-445 D3); a platform-scope atom is never a
  module atom (`core_permission_collision`, now enforced on production manifests too).
- INV-3 as written is untrusted-runtime sandboxing; this change touches no sandbox, script
  capability or host function. The issue cites INV-3 for the role-grant model; please rule
  whether that citation stands or is meant as the general authorization-model review.
- The one authorization-code change is a new read-only function (section 3) that can only
  return `false` where `role_allows?/2` returns `true`, never the reverse.
- Accepted limit (by design, not hidden): a PR that edits `authorization.ex` so that a core
  rule grants the same row a manifest would have granted is classified a core change. That is
  the REQ-VALIDATOR scope statement: core changes are gated by this review, not by the module
  rule. Likewise a PR that weakens `permission_matrix.ex` or the task itself is code under
  review. Recommendation (not done here, out of scope): add both files to the
  SECURITY-REVIEWER path triggers.

Why an author-written declaration alone can never satisfy the rule:

1. The only declaration is `widens_grants`, and by step 6 it can only MATCH a narrowing row;
   naming a widening row is itself a failure (D9). There is no input that marks a widening
   acceptable.
2. Which rows are widenings is computed from B and C. B is a git object at the base commit,
   which the PR cannot change; C is computed from compiled code and the manifest's actual
   `role_grants`, not from anything the author asserts about it.
3. Regenerating the working-tree golden only satisfies freshness (D4); classification never
   reads it (I1), so the AC5 "regenerated in the same PR" case still fails.
4. A narrowing declaration must match a computed narrowing exactly in both directions
   (steps 6-7), so a declaration cannot hide an undeclared diff row or stand in for one.
5. The bootstrap escape (no baseline) requires the base commit to lack the task file too
   (D18), so moving the golden path in a PR does not open it.

## 13. Test brief (TEST-DESIGNER)

File `test/letflow/api/permission_matrix_test.exs` (`async: true`, pure, no DB) unless noted.
Helpers build in-memory `t()` values (strings) directly or via `build/3` with injected
functions; no test depends on the live module list except T1b, T9, T19, T20.

| T | AC | Case |
|---|---|---|
| T1 | AC1 | `build/3` with 8 injected roles and N injected permissions -> `map_size(rows) == 8 * N`; header counts match |
| T1b | AC1 | committed golden parses; its `permissions` == strings of `core_permissions() ++ Exam.manifest().permissions`, `rows == 8 * that length`; `modules == %{"exam" => Exam.manifest().version}` (test env, reads the real file) |
| T2 | AC2 | `check_production_list` with a matrix containing `FixtureRead` and env `:dev` -> `{:error, [{:fixture_atoms_present, ["FixtureRead"]}]}` |
| T3 | AC2 | matrix lacking the Exam atoms, env `:dev` -> `{:error, [{:production_atoms_missing, six}]}` |
| T4 | AC2 | a correct matrix with env `:test` -> includes `{:wrong_env, :test}`; the rendered message contains `MIX_ENV=test` (distinct text) |
| T5 | AC3 | B without atom X; C with X owner `module:m`, PA/TA `via core`, others false; `route_refs %{X => [m]}` -> `true_set_diff.added == [PA/X, TA/X]`, `labels == [:pre_approved]`, `failures == []` |
| T6 | AC4a | existing atom gains a role with `via grant` -> `{:widening, r, p, :module_grant}` |
| T7 | AC4b | new module atom true for `CANDIDATE` via grant (and PA/TA via core) -> failure for CANDIDATE row; PA/TA still pre-approved; variant with `via core` for CANDIDATE -> `:new_atom_non_admin_role` |
| T8 | AC4c | (i) `via grant` row on an atom in `core_policy_atoms` -> `:core_policy_atom`; (ii) new module atom present in injected `core_policy_atoms` -> PA/TA rows `:core_policy_atom`, not pre-approved; (iii) new atom also named in another module's `route_refs` -> `:referenced_by_other_module` |
| T9 | AC2 | (test env) `fixture_permissions/1` over the real `test/support/modules/**` sources == union of `:permissions` of `Catalog.entry_modules() -- [Letflow.Modules.Exam]`; plus unit cases: non-literal `permissions:` -> `:unscannable_fixture_manifest`; `[]` -> `:no_fixture_sources` |
| T10 | AC5 | B lacks a widening; C has it (`via grant`); G := C -> `freshness(G, C) == :ok` AND classify has the widening failure |
| T11 | AC5 | core-only: B lacks core atom K; C has K rows (`owner core`, `via core`); G := C -> freshness ok, `failures == []`, `labels == [:core_change]`, `core_changes` lists K's true rows |
| T12 | AC6 | module m version bumped; B row true (`via grant`), C false; no declaration -> `{:unmatched_narrowing, r, p, "m"}` |
| T13 | AC6 | same with `declarations %{"m" => [{r, p}]}` -> no failure, `labels == [:narrowing]` |
| T14 | AC6 | version bumped, declaration `{r2, p2}` matching no diff row -> `{:unmatched_declaration, "m", r2, p2}` |
| T15 | AC6 | version unchanged: declaration stays inert (listed in `inert_declarations`, no failure); an undeclared narrowing with unchanged version fails with the "bump the module version" text |
| T16 | AC7 | declaration naming a widening row (B false, C true via grant) -> both `{:widening, ...}` and `{:declaration_authorises_widening, ...}`; also when the module version is unchanged |
| T17 | AC10 | injected permission list with an atom absent from the golden fixture -> `freshness` `{:error, {:golden_stale, %{added: [...]}}}`; a flipped `core_allows?` for one role -> stale with one added and one removed line |
| T18 | AC11 | `render(m) == render(m)` across two `build/3` calls with shuffled role and permission input order; lines sorted role-then-permission; `render(parse!(render(m))) == render(m)`; output ends with exactly one LF and has no `\r` |
| T19 | D7 | (test env) `Code.Typespec.fetch_types(Letflow.Api.Authorization)`: every atom of `endpoint_policy_key` except `:UnmatchedPlatformPath`/`:UnmatchedRoute` -> `required_permission(k) in core_permissions()` |
| T20 | section 3 | for all roles x `permissions()`: `role_allows?(r, p) == (role_allows_without_module_grants?(r, p) or p in Catalog.role_grants(r))`; and `role_allows_without_module_grants?(r, :MyModulesRead)` for every role |
| T21 | 2.2 | `parse/1` error cases: format `2`, missing header line, 4-field row, `false core`, duplicate row, count mismatch; CRLF input parses equal to LF input |
| T22 | D18 | `bootstrap_allowed?(false, false) == true`, `(false, true) == false` |
| T23 | 4.3 step 4 | B row of module `m`, `m` absent from C.modules -> `{:module_removed, "m"}` core change, no failure; atom kept, TA row flips false with `via core` -> core change, not a narrowing |
| T24 | AC9 | textual: `.github/workflows/ci.yml` contains a `backend_static` step whose `run` includes `mix letflow.permission_matrix --check --baseline-ref` with `MIX_ENV: dev`; `mix.exs` `@check_static_steps` does not contain `letflow.permission_matrix` |

File `test/letflow/modules/catalog_test.exs` (extend; new `describe "GH 2586 widens_grants (rule 8)"`):

| T | AC | Case |
|---|---|---|
| C1 | AC8 | `valid_manifest()` without the key -> `:ok`; with `widens_grants: []` -> `:ok`; with `[{:TASK_WORKER, :FixtureRead}]` -> `:ok`; with an atom not in the manifest's `:permissions` -> `:ok` |
| C2 | AC8 | `[{:NOT_A_ROLE, :X}]` -> `{:error, {:unknown_widens_grants_role, :NOT_A_ROLE}}` |
| C3 | AC8 | `[{:TASK_WORKER, "X"}]` -> `{:error, {:invalid_widens_grants_permission, "X"}}` |
| C4 | AC8 | `:not_a_list` and `[:TASK_WORKER]` -> `{:error, {:invalid_widens_grants, value}}` |
| C5 | AC8 | every registered manifest still validates (existing assertion stays green) |

AC1's "exits 0 on unmodified main" and AC9's "CI run shows the step executing" are verified
by the CI run on the PR (TEST-RUNNER / RELEASE-VALIDATOR quote the step log); there is no
ExUnit test that runs the task in dev.

## 14. Files touched (implementation PR)

New: `lib/letflow/api/permission_matrix.ex`, `lib/mix/tasks/letflow.permission_matrix.ex`,
`priv/permission_matrix/effective.golden` (generated by `--write` under dev),
`test/letflow/api/permission_matrix_test.exs`.
Changed: `lib/letflow/api/authorization.ex` (one function), `lib/letflow/modules/catalog.ex`
(rule 8 + docs), `lib/letflow/modules/module.ex` (type + docs table),
`test/letflow/modules/catalog_test.exs`, `.github/workflows/ci.yml`, `mix.exs` (comment only),
`.gitattributes`, `docs/guides/adding-an-application-module.md`,
`docs/guides/backend_developer_guide.md`, `docs/requirements.yaml`, the status-history volume.
Out of scope (do not build): upgrade runner, `tenant_module_upgrades`, plan endpoint,
`plan_hash` matrix digest (0055 AC23), per-tenant grant snapshots, any change to
`role_allows?/2` results.

## 15. Open questions

- OQ1 (ORCH): REQ-498's registration line (`impl_order` queue id vs deferral marker) per
  `TASK_QUEUE.md`; `check_deferral_staleness` must stay green.
- OQ2 (SECURITY-REVIEWER): whether INV-3 is the intended citation (section 12).
- OQ3 (implementation-time measurement, not a design gap): the cold dev-compile duration in
  CI with `WASMEX_BUILD: true`; if it exceeds the job's budget the PR body says so (issue
  sizing note) rather than dropping `WASMEX_BUILD`.
