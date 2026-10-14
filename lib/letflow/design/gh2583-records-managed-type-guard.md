# GH #2583: `managed_by` write lock enforced inside `Letflow.Entities.Records`

Status: design for WF-03 run `WF03-GH2583-RECORDS-GUARD-20261015` (CODE-DESIGNER, step 03).
Base: `main` at `c55baa4f5`. Input: ISSUE-FIXER diagnosis
`handoffs/WF03-GH2583-RECORDS-GUARD-20261015/step-01-issue-fixer.json` and the ORCH rulings on its
OQ1-OQ6 (recorded in section 1). Gates: SECURITY-REVIEWER (INV-6), REVIEWER. No migration, no new
route, no new permission.

## Changelog

### Revision 1 (2026-10-14, after SECURITY-REVIEWER FAIL and CODE-DESIGN-VALIDATOR FAIL, both on section 7)

| Finding | Change | Sections |
|---|---|---|
| SEC B1 = CDV B2 (call-form completeness) | Scan normalises pipes for ALL rules (fixes the existing create_definition/3 and install/4 rules too); R1 also flags `/3` captures, `Function.capture/3`, `apply/3` / `Kernel.apply/3` / `:erlang.apply/3` with literal module + function; atom receivers recognised; R4 flags `%{__struct__: Owner}` map literals and `Map.put`-family `:__struct__` forgery; uncovered forms listed as accepted limits; D6 / I3 corrected (Owner values do flow as parameters); R1 named load-bearing; one test per new form | 1 (D6), 7, 12 (I3), 10 (T-22..T-28) |
| CDV B1 (test/support widening breaks the existing rule) | All call rules match only QUALIFIED receivers (plus piped / apply / capture forms), never bare local calls; the edit to the existing test file is listed explicitly; existing assertions keep their intent | 7.2, 7.4, 11 |
| CDV advisory, #2596 composition (adopted) | `owner_for!(EntryAlias)` allowed in files under the entry module's OWN directory; R2 becomes a directory rule; no public `owner/0` | 1 (D2), 3.3, 7.3 (R2), 8.4 |
| SEC A1 | `command_multi` checks every line | 8.2 |
| SEC A2 | D8 premise named; T-29 | 1 (D8), 10 |
| SEC A3 | T-13 asserts the logged reason atom with metadata captured | 10 |
| SEC A4 + CDV | T-15 asserts `pg_trigger.tgenabled = 'O'` for both triggers afterwards; teardown with the stamped row stated | 10 |
| CDV | Section 3.3 boundary claim corrected; I5 reworded; T-12 tenant has no other `org_unit` rows | 3.3, 12, 10 |
| SEC A5 / A6 | Listed as follow-ups | 14 |

### Revision 2 (2026-10-14, CODE-DESIGN-VALIDATOR PASS on r1; SECURITY-REVIEWER blocker B2)

| Finding | Change | Sections |
|---|---|---|
| SEC B2 (import + bare call escapes R2/R3; regression vs today's name-based T-34 match, `managed_types_callers_test.exs:95`) | `owner_for!` and `module_owner` are matched BY NAME regardless of receiver (local, alias, atom); no other file defines these names (grep: only `managed_types.ex:69`); R1b also bans importing/renaming `Letflow.Entities.ManagedTypes`, the only allowed import being `records.ex`'s `import ManagedTypes, only: [is_authority: 1]` | 7.3 (R1b, R2, R3) |
| SEC advisory | "under `D/`" compares whole path segments; T-27 case `test/support/modules/fixture_managed_x/w.ex` is a violation | 7.3 (R2), 10 (T-27) |
| SEC advisory | An `EntryAlias` R2 cannot resolve is a violation (fail closed) | 7.3 (R2) |
| SEC advisory | R1b allows a plain multi-alias `alias Letflow.Entities.{Records, ...}` without `as:` | 7.3 (R1b) |
| SEC advisory | A directory with two entry modules lets its files mint both Owners; accepted | 8.4 |
| SEC advisory | Scan rule forbidding a public function that returns an `Owner`: follow-up idea | 14 |
| CDV | T-27 snippet input includes a `defmanifest`-defining file | 10 (T-27) |

## 0. Binding acceptance criteria (issue body, no revision in comments)

| AC | Text (short) | Where satisfied |
|---|---|---|
| AC1 | Enumerate and classify every core caller of `Records.create/update/delete` | section 2 (table), copied into the PR body (section 9) |
| AC2 | Move the enforcement point so no core path writes a managed type without an explicit typed ownership proof; boundaries/CI check against new unguarded callers | sections 3, 4, 5, 7 |
| AC3 | `RecordDeadlineSweep` proves ownership or is shown to touch no managed type, with a test | section 6, T-12..T-14 |
| AC4 | Coordinate with REQ-484 / 0054 so step writes use the same check | section 8 |

## 1. Decisions (ORCH rulings applied)

* D1 (OQ1) `create_record/3`, `update_record/3`, `delete_record/3` are added with a third argument
  `authority :: ManagedTypes.owner()` (`:tenant | %ManagedTypes.Owner{}`). The existing `/2`
  arities stay and are exactly the `/3` call with the literal `:tenant` (fail-closed default),
  mirroring `Definitions.create_definition/2,/3`. Every existing caller is unchanged except the three
  calls in `test/support/modules/fixture_managed/fixture_managed.ex`.
* D2 (OQ2) A runtime `Owner` is obtained only through `ManagedTypes.owner_for!/1` (new) or the
  existing `ManagedTypes.module_owner/1`, each pinned by the caller-scan test (section 7).
  `owner_for!/1` takes an entry module (a compile-time atom, never request data), checks it is a
  registered `Letflow.Modules.Catalog` entry module that declares at least one managed type, and
  returns its manifest-derived `Owner`. Outside `managed_types.ex` it may only be called as
  `owner_for!(__MODULE__)` inside the `defmanifest` module, or as `owner_for!(EntryAlias)` in a file
  under that entry module's OWN directory (section 8.4, R2). No public `owner/0` accessor. Passing
  the resulting `Owner` to `Records` additionally requires the file to be in the static
  `@authority_callers` list (R1, the load-bearing rule). The REQ-501 hook is documented in section
  8.3; nothing for it is built now.
* D3 (OQ3) The refusal is `{:error, :entity_type_managed}`, the atom the router and
  `ManagedTypes.check_create/3` already use.
* D4 (OQ4) The sweep gets no rule pre-check and no code change. Each due record of a managed type is
  refused per record, rolled back, and logged by the existing warning (ids and the reason atom only,
  no field values).
* D5 (OQ5) Exam types being writable via the generic routes is OUT of scope (ORCH asks letflow-2 to
  file it).
* D6 (OQ6) Caller-scan strictness as section 7: a non-`:tenant` authority reaches `Records` only
  from `@authority_callers` files (R1, load-bearing); `Owner` construction only in allow-listed
  places (R2-R4). Correction (Revision 1): `Owner` values already flow as PARAMETERS through files
  that do not originate them (`definitions/solution_pack.ex:1654` passes `owner` to
  `Definitions.create_definition/3`; `entities/definitions.ex:137` receives it), so the design does
  NOT claim an `Owner` variable can exist only in allow-listed files. What it claims: an `Owner` can
  be ORIGINATED only in allow-listed places, and can be HANDED TO `Records` only from
  `@authority_callers`; the forms the AST scan cannot see are listed in 7.5.
* D7 The ownership predicate (which pattern-matches `%Owner{}`) lives in `managed_types.ex`
  (`ManagedTypes.check_record_write/3`, pure, no DB), so the existing T-34 rule "the `Owner`
  struct appears only in `managed_types.ex`" stays true. `Records` calls it through one private
  `check_write_authority/3` that `command_multi/3` (REQ-499) must reuse.
* D8 The check reads `definition.managed_by` from the `%EntityDefinition{}` that
  `fetch_active_definition/2` already loaded: zero extra queries.
  **Premise P (named, Revision 1, SEC A2):** for a managed name N, the row `Records` resolves for N
  carries N's stamp. It rests on three facts: (P1) `fetch_active_definition/2` resolves through
  `Activation.resolve(:entity, N, prefix)`, keyed by `artifact_name` (`activation.ex:160-177`), and
  an entity definition's version is created under the artifact named by its own `name`; (P2) every
  `entity_definitions` row of a managed N carries the same stamp: a name is claimed only when it has
  no row (`managed_types.ex:171`), later rows of N are created only with the stamping `Owner`
  (`check_create/3`), tenant creates of N are refused (`check_create/3` `:tenant` clause, router
  guard on create and activate); (P3) the DB trigger `entity_definitions_managed_by_guard` makes the
  stamp and, on a stamped row, `name`/`tenant_id` immutable, and refuses deleting a stamped row. So no
  tenant definition or version can become the active version under a managed artifact name. T-29
  pins P2/P1 behaviourally; T-15 deliberately breaks P (trigger disabled) only to reach the race
  clause.

## 2. AC1: classified core callers (grep of `lib/`, `priv/`, `lib/mix/tasks`, `test/support` on `c55baa4f5`)

There is no `Records` import function (import is router-only). No other writer of
`entity_record_latest` / `ENTITY_RECORD_*` exists outside `records.ex` except
`Record.Projector` rebuild (`projector.ex:285`), which replays existing events (not a new write).

| # | Site | Path | Can reach a managed type after this fix | Class | Authority passed |
|---|---|---|---|---|---|
| 1 | `routers/entities.ex:1008` create | `POST /entities/records/:type`, guarded `:993` | no (403 first; race -> Records refuses) | TENANT | `:tenant` (via `/2`) |
| 2 | `entities.ex:1067` update | `PUT`, guarded `:1047` | no | TENANT | `:tenant` |
| 3 | `entities.ex:1116` delete | `DELETE`, guarded `:1098` | no | TENANT | `:tenant` |
| 4 | `entities.ex:1319` create per entry | `POST .../import`, guarded `:1179` | no | TENANT | `:tenant` |
| 5 | `modules/exam/anti_cheat.ex:258` create `session_event` | exam candidate request | no (exam declares no managed types) | TENANT semantics | `:tenant` |
| 6 | `modules/exam/certificate.ex:335` create `certificate` | exam issuance | no | TENANT semantics | `:tenant` |
| 7 | `modules/exam/session.ex:1064` update `session_answer` | exam | no | TENANT semantics | `:tenant` |
| 8 | `session.ex:1263` update `session` | exam submit | no | TENANT semantics | `:tenant` |
| 9 | `session.ex:1328` `write_record/4` create (`session`, `session_question`, `session_answer`, `session_question_score`) | exam | no | TENANT semantics | `:tenant` |
| 10 | `scheduler/record_deadline_sweep.ex:254` update | deploy-config rule, system actor | was YES (any configured type); now refused per record | CORE, MUST REFUSE (0054 D12) | `:tenant` |
| 11 | `lib/mix/tasks/letflow.seed.exam_fixtures.ex:577` create exam pack types | seed task | no | TENANT semantics | `:tenant` |
| 12 | `test/support/exam_fixtures.ex:220` `create_record!/4` | test fixture, exam types | no | TENANT semantics | `:tenant` |
| 13-15 | `test/support/modules/fixture_managed/fixture_managed.ex:72/87/102` | stands in for an owning module | YES, by purpose | MODULE-OWNED | `ManagedTypes.owner_for!(__MODULE__)` (CHANGED) |

Engine step writes: none exist on `main` (`EntityPort`, `StepWrites`, `command_multi` NOT FOUND;
grep of `lib/` returned no hits). Test callers in `test/**/*.exs`: about 217 direct `/2` calls in 24
files; none writes a managed type; they stay unchanged and become `:tenant` callers.

## 3. `Letflow.Entities.ManagedTypes` changes (`lib/letflow/entities/managed_types.ex`)

### 3.1 New: `defguard is_authority/1`

```
@doc "Guard: `term` is a valid write authority (`:tenant` or an `%Owner{}`)."
defguard is_authority(term)   # true iff term == :tenant or is_struct(term, Owner)
```

Used in `Records`' `/3` heads so a bad authority raises `FunctionClauseError` before any query.

### 3.2 New: `check_record_write/3` (pure, no DB, no `prefix`)

```
@spec check_record_write(managed_by :: String.t() | nil, entity_type :: String.t(), owner()) ::
        :ok | {:error, :entity_type_managed}
```

Decision table (total; any other third argument raises `FunctionClauseError`):

| `managed_by` | authority | result |
|---|---|---|
| `nil` | `:tenant` | `:ok` |
| `nil` | `%Owner{}` (any) | `:ok` (an Owner may write unmanaged types; same as a tenant) |
| `m` (binary) | `:tenant` | `{:error, :entity_type_managed}` |
| `m` | `%Owner{module_id: m, manages: s}` and `MapSet.member?(s, entity_type)` | `:ok` |
| `m` | `%Owner{module_id: m}` and `entity_type` NOT in `manages` | `{:error, :entity_type_managed}` |
| `m` | `%Owner{module_id: other}` with `other != m` | `{:error, :entity_type_managed}` |

### 3.3 New: `owner_for!/1`

```
@spec owner_for!(entry_module :: module()) :: Owner.t()
```

* Head guard `when is_atom(entry_module)`; a non-atom raises `FunctionClauseError`.
* If `entry_module not in Letflow.Modules.Catalog.entry_modules()` -> raises `ArgumentError`
  (message names the module, e.g. "not a registered Catalog entry module"). Checked BEFORE calling
  `entry_module.manifest()`.
* If the manifest's `:manages_entity_types` is absent or `[]` -> raises `ArgumentError`
  ("declares no managed entity types").
* Otherwise returns `module_owner(entry_module)` (same struct as the install-time Owner).
* Lookup is per call (no cache); `Catalog.entry_modules/0` is a compile-time list, so it is a list
  membership test, no I/O.
* Boundary (corrected, Revision 1): this is a NEW code edge `Letflow.Entities.ManagedTypes ->
  Letflow.Modules.Catalog` (today `managed_types.ex` names `Catalog` only in docs, and
  `solution_pack.ex` is `Letflow.Definitions`, not `Letflow.Entities`). `mix
  letflow.check_boundaries` Rule 0 allows it: the target `lib/letflow/modules/catalog.ex` is not
  inside a `lib/letflow/modules/<id>/` subdirectory (`letflow.check_boundaries.ex:29,190`). Other core
  files already reference `Catalog` (`api/authorization.ex`, `routers/solution_packs.ex`,
  `modules/installs.ex`). ELIXIR-DEV runs `mix letflow.check_boundaries` and quotes the result.
* Callers outside `managed_types.ex`: `owner_for!(__MODULE__)` in a `defmanifest` module, or
  `owner_for!(EntryAlias)` in a file under that entry module's own directory (8.4, R2).

### 3.4 Moduledoc update ("Who may hold an `Owner`")

State: an `Owner` comes only from `module_owner/1` (callers: `managed_types.ex`, `installs.ex`) or
`owner_for!/1` (callers: `managed_types.ex`, and files under an entry module's own directory naming
that entry module, today only `test/support/modules/fixture_managed/fixture_managed.ex`); it reaches
`Records` only from the `@authority_callers` files;
pinned by `test/letflow/entities/managed_types_callers_test.exs` (section 7). Record writes are
checked by `check_record_write/3` from `Letflow.Entities.Records`.

## 4. `Letflow.Entities.Records` changes (`lib/letflow/entities/records.ex`)

### 4.1 Types

* `command_error` gains `| {:error, :entity_type_managed}` (before the `{:error, term()}` arm).
* Add `alias Letflow.Entities.ManagedTypes` and `import ManagedTypes, only: [is_authority: 1]`
  (a `defguard` needs `import`/`require`).

### 4.2 Public functions (exact @specs)

```
@spec create_record(create_attrs(), prefix :: String.t()) :: {:ok, command_result()} | command_error()
@spec create_record(create_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, command_result()} | command_error()

@spec update_record(update_attrs(), prefix :: String.t()) :: {:ok, command_result()} | command_error()
@spec update_record(update_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, command_result()} | command_error()

@spec delete_record(delete_attrs(), prefix :: String.t()) :: {:ok, command_result()} | command_error()
@spec delete_record(delete_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, command_result()} | command_error()
```

* `/2` = the `/3` call with the literal `:tenant` (one-line delegate each; it is NOT a separate
  code path). Head guard of `/2` unchanged (`when is_binary(prefix)`).
* `/3` heads: the existing attr pattern plus `when is_binary(prefix) and is_authority(authority)`.
  A bad authority (e.g. `"fixture_managed"`, `%{module_id: ...}` plain map, `nil`) raises
  `FunctionClauseError` before any query.
* `authority` is never read from `attrs`; an `:authority`/`:owner`/`:managed_by` key inside `attrs`
  is ignored exactly as any unknown key is today (T-09).

### 4.3 The shared private check and its exact position

```
@spec check_write_authority(EntityDefinition.t(), entity_type :: String.t(), ManagedTypes.owner()) ::
        :ok | {:error, :entity_type_managed}
defp check_write_authority(%EntityDefinition{managed_by: managed_by}, entity_type, authority)
# body: delegates to ManagedTypes.check_record_write(managed_by, entity_type, authority)
```

Position in each `with` chain: the step immediately after
`{:ok, definition} <- fetch_active_definition(entity_type, prefix)` and before every other step:

* `create_record/3`: `fetch_active_definition` -> **`check_write_authority`** -> `validate_field_values` -> (unchanged).
* `update_record/3`: `fetch_active_definition` -> **`check_write_authority`** -> `ensure_mutable` -> `fetch_existing_record` -> `ensure_not_deleted` -> `validate_field_values` -> (unchanged).
* `delete_record/3`: `fetch_active_definition` -> **`check_write_authority`** -> `ensure_mutable` -> `fetch_existing_record` -> already-deleted no-op -> (unchanged).

Consequences (each tested): on a refusal no record lookup, no payload validation, no
`EntityTypeInstance.get_or_create/2`, no idempotency claim and no event happen; the answer does not
depend on `record_id`, `field_values`, record existence/deleted state or `append_only` (matches the
router's ordering; no existence or append-only leak). Query count of a refused call equals the
queries of `fetch_active_definition/2` alone (T-11). A missing definition still answers
`{:definition_not_found, _}` first (nothing to check; unchanged and not a leak: the router guard
already answered for managed names).

### 4.4 Docs

Each `@doc` of the three functions gains: "Step 1a (GH #2583): `authority` must hold the type. A
`managed_by` type is written only with that module's `Owner` naming the type; `:tenant` (the `/2`
default) and any other `Owner` get `{:error, :entity_type_managed}` with nothing read beyond the
definition." Moduledoc gets a short "Managed types" paragraph pointing to this design and to
`ManagedTypes.check_record_write/3`.

### 4.5 `command_multi/3` (REQ-499, not on `main`)

Not built here. Section 8 states the contract PR A must meet.

## 5. Router (`lib/letflow/routers/entities.ex`): race-only renders, constant body

`guard_tenant_write/3` stays as is (constant 403 before body/path id/query is read). The `/2`
calls stay. New clauses, reachable only when the guard's read and the row `Records` resolves
disagree (a race; simulated deterministically in T-15/T-16):

* `render_record_command/3`: add, before the `{:error, reason}` catch-all clauses,
  `defp render_record_command(conn, {:error, :entity_type_managed}, _status)` ->
  `Response.send_problem(conn, Error.entity_type_managed())` (the same constant 403 body the guard
  sends). Add the row `:entity_type_managed -> 403 (race only; same body as the guard)` to the
  mapping comment above the clauses.
* Import: `import_reason_json/1` gains `defp import_reason_json(:entity_type_managed)` ->
  `%{"type" => "entity_type_managed"}` (constant, no detail), before the catch-all, so the race is
  not logged as an internal error. Import itself is unchanged: it calls `Records.create_record/2`
  (`:tenant`) per entry.

No change to `routers/solution_packs.ex` or any other router.

## 6. AC3: `Letflow.Scheduler.RecordDeadlineSweep`

No code change. It keeps `Records.update_record/2` (`:tenant`). A rule on a managed type: each due
record gets `{:error, :entity_type_managed}` from `Records`, `claim_and_transition_one/3` rolls
back that one transaction, the existing `Logger.warning("deadline sweep: one record failed to
transition, continuing with the rest", schema:, entity_type:, record_id:, reason: inspect(reason))`
fires (ids and the reason atom only, never `field_values`), the id joins `failed_ids` for the rest
of the call, the next tick retries (and is refused again). So the sweep touches no managed type by
construction. Moduledoc gains one paragraph "Managed types (GH #2583)" saying exactly this and
citing 0054 D12 ("no entity write from timers").

## 7. CI check: extend `test/letflow/entities/managed_types_callers_test.exs` (AST, not grep)

### 7.1 Scan set

`lib/**/*.ex` plus `test/support/**/*.ex` (so the fixture's Owner use is visible and the rules are
non-vacuous). `test/**/*.exs` stays excluded: test bodies must forge `%Owner{}` values to test
refusals; they are not shipped code. The vacuity test also asserts
`test/support/modules/fixture_managed/fixture_managed.ex` is in the set.

### 7.2 Normalisation and call matching (shared by ALL rules, new and existing)

Test-private helpers (signatures only; TEST-DESIGNER writes them):

```
@spec normalize_pipes(Macro.t()) :: Macro.t()
# postwalk: every {:|>, _, [lhs, {fun, meta, args}]} becomes {fun, meta, [lhs | args]};
# nested pipes flatten innermost first, so `a |> f(b) |> g(c)` yields g(f(a, b), c).
@spec calls(Macro.t()) :: [{fun :: atom(), receiver :: [atom()] | nil, args :: [Macro.t()]}]
# walks the NORMALISED ast; receiver is the alias segments of {:__aliases__, _, segs}, or
# Module.split/1 of an atom receiver such as :"Elixir.Letflow.Entities.Records"
# (so atom receivers are recognised), or nil for a local call.
@spec qualified?(receiver :: [atom()] | nil, target :: :records | :definitions) :: boolean()
# :records     -> receiver in [[:Records], [:Entities, :Records], [:Letflow, :Entities, :Records]]
# :definitions -> receiver in [[:Definitions], [:Entities, :Definitions], [:Letflow, :Entities, :Definitions]]
# nil (bare local call) -> always false.
```

The `Records`/`Definitions` call rules (R1, R5) match ONLY qualified receivers (plus the piped,
capture and apply forms of a qualified call); bare local calls are never matched by them. Exception
(Revision 2): R2 and R3 match `owner_for!` and `module_owner` BY NAME with any receiver, local
included. Rationale (CDV B1): with `test/support` in the
scan, `test/support/script_policy_fixture.ex:25,36,40` makes LOCAL 3-arg `create_definition/3` calls
to its own private helper, and `fixture_managed.ex` defines local 3-arity `create_record` /
`delete_record` helpers. Local calls cannot reach `Records`/`Definitions` because R1b forbids
importing them, so matching qualified receivers loses no coverage. `[:Definitions]` is unambiguous
for `create_definition`: `Letflow.Definitions` and `Letflow.Routers.Definitions` define no
`create_definition` (grep on `c55baa4f5`).

### 7.3 Rules (one ExUnit test each)

Static allow-list (module attribute in the test; adding a file is a reviewed diff):

```
@authority_callers ["test/support/modules/fixture_managed/fixture_managed.ex"]
# module_owner/1 callers stay [managed_types.ex, installs.ex]; Owner builders stay [managed_types.ex]
```

* **R1 (LOAD-BEARING) Records write calls.** For every scanned file except
  `lib/letflow/entities/records.ex` (the definer), a site is a violation unless the file is in
  `@authority_callers`, for each form below, with `fun in [:create_record, :update_record,
  :delete_record, :command_multi]`:
  * (a) a qualified call (direct or piped) with 3 args whose third arg is not the literal `:tenant`;
  * (b) a capture `&Records.<fun>/3` (alias or atom receiver); a capture with explicit args,
    `&Records.<fun>(&1, &2, x)`, is caught by (a) because the inner call is walked;
  * (c) `Function.capture(<Records>, :<fun>, 3)` with a literal Records module (alias or atom);
  * (d) `apply/3`, `Kernel.apply/3` or `:erlang.apply/3` (direct or piped) whose first arg is a
    literal Records module (alias or atom) and second a literal `fun` atom, unless the third arg is a
    literal list of length 2, or a literal list of length 3 ending in `:tenant`.

  Expected set: exactly `@authority_callers` (non-vacuous: the fixture's three calls). R1 decides
  whether an `Owner` can reach `Records`; R2-R4 are defence in depth on where an `Owner` can
  originate.
* **R1b** No scanned file other than the definer contains `import Letflow.Entities.Records`,
  `alias Letflow.Entities.Records, as: _`, `import Letflow.Entities.Definitions` or
  `alias Letflow.Entities.Definitions, as: _`. (Revision 2) The same ban covers
  `Letflow.Entities.ManagedTypes`: no `import` and no `alias ..., as: _` of it anywhere except the
  single allowed import in `lib/letflow/entities/records.ex`, which must be exactly
  `import ManagedTypes, only: [is_authority: 1]` (or the fully qualified equivalent); any other
  `only:` list, `except:`, or bare import there is a violation. A `require` of `ManagedTypes` is
  allowed (it brings no function into local scope). A plain multi-alias without `as:`, e.g.
  `alias Letflow.Entities.{Records, Definitions, ManagedTypes}`, is ALLOWED: it still yields the
  qualified receivers `[:Records]` / `[:Definitions]` / `[:ManagedTypes]` that the rules match. Today:
  no violation (grep).
* **R2 `owner_for!` callers.** (Revision 2: matched BY NAME.) Every call named `owner_for!` with
  ANY receiver (bare local, any alias, any atom; direct, piped, captured as `&owner_for!/1` or
  `&X.owner_for!/1`, `Function.capture(_, :owner_for!, 1)`, or applied with the literal atom
  `:owner_for!`) outside `managed_types.ex` must have exactly one argument, which is either
  `__MODULE__` inside a `defmodule` that calls `defmanifest`, or an alias `EntryAlias` such that:
  EntryAlias (expanded via the calling file's own `alias` directives) names a module defined in a
  scanned file by a `defmodule` that calls `defmanifest`; that defining file's directory `D` is
  exactly `lib/letflow/modules/<id>` or `test/support/modules/<id>`; and the calling file's path is
  under `D/` (8.4). "Under `D/`" compares whole path segments (`Path.split/1` of the calling file
  starts with `Path.split(D)` and is longer), never a string prefix, so
  `test/support/modules/fixture_managed_x/w.ex` is NOT under `test/support/modules/fixture_managed`.
  Fail closed: an `EntryAlias` that R2 cannot resolve to a `defmanifest` module in the scan set
  (unknown alias, non-alias argument, variable, function call, atom literal) is a violation. Matching
  by name is safe because no other scanned file defines a function named `owner_for!` or
  `module_owner` (grep on `c55baa4f5`: only `managed_types.ex:69` defines `module_owner`); a future
  file defining either name is itself reported by R2/R3. A capture `&ManagedTypes.owner_for!/1`, `Function.capture` of it, or an `apply` of it
  is a violation anywhere outside `managed_types.ex`. No static file list: the directory rule is the
  allow-list for origination; R1's `@authority_callers` is the static list for use.
* **R3 (existing, widened scan, pipes normalised)** calls named `module_owner` BY NAME with any
  receiver (Revision 2; as today's T-34 at `managed_types_callers_test.exs:95`), plus captures and
  applies of it, only in `managed_types.ex` and `installs.ex`. The existing expected list is kept.
  The name match also catches `managed_types.ex`'s own local call inside `owner_for!/1`, which is in
  the allowed set.
* **R4 (existing, extended) Owner construction** only in `managed_types.ex`: `%Owner{}` /
  `%ManagedTypes.Owner{}` / `%Letflow.Entities.ManagedTypes.Owner{}` (literal, pattern or update
  syntax), `struct`/`struct!`/`Kernel.struct(!)` with an Owner alias; NEW: a map literal
  `%{__struct__: X, ...}` where X is an alias ending `:Owner` or the atom
  `:"Elixir.Letflow.Entities.ManagedTypes.Owner"`; NEW: `Map.put/3`, `Map.put_new/3`,
  `Map.replace/3`, `Map.replace!/3` (direct or piped) with key `:__struct__` and such an X
  (`Map.merge` with a literal `%{__struct__: X}` is caught by the map-literal clause).
* **R5 (existing rules, edited)** `create_definition/3` with a non-`:tenant` third arg only in
  `solution_pack.ex` threading `owner`, and `SolutionPack.install/4` with a non-`:tenant` owner only
  in `installs.ex`: both now run on the normalised AST, and the create_definition rule matches only
  `qualified?(receiver, :definitions)` (today it also matches bare local calls,
  `managed_types_callers_test.exs:106-120`). Expected values unchanged
  (`[{solution_pack.ex, "owner"}]`, `[installs.ex]`), so the assertions keep their intent; the
  `definitions.ex` exclusion becomes redundant (its delegate is a local call) and is kept.

### 7.4 Edit to the existing test file (explicit)

`test/letflow/entities/managed_types_callers_test.exs`: `lib_files/0` becomes `scanned_files/0`
(7.1); `calls/1` is replaced by `normalize_pipes/1` plus a `calls/1` that recognises atom receivers
(7.2); `builds_owner?/1` is extended (R4); the create_definition/3 test filters with
`qualified?(_, :definitions)` (R5); the install/4 test runs on the normalised AST (R5); the
moduledoc lists R1-R5 and 7.5. New tests: R1, R1b, R2, and the negative-form tests T-22..T-28.

### 7.5 Accepted, documented limits (not covered by the AST scan)

Computed module or function names (`apply(mod_var, fun_var, args)`, `Module.concat/1`,
`String.to_atom/1`), `:erlang.binary_to_term/1` producing an `Owner`, `Code.eval_*` and
`Code.compile_*`, code generated by macros defined away from the call site (the scan sees source
AST, not expansions), `.exs` files and dependencies. Each needs deliberate obfuscation in code that
is itself reviewed (REVIEWER/SECURITY-REVIEWER gate every PR). `mix letflow.check_boundaries` is
unchanged (it cannot express per-function allow-lists, `managed_types.ex:17-20`). The test is
`async: true`, pure file reads, part of the normal `mix test` CI run.

## 8. AC4: coordination with REQ-484 / 0054 / REQ-499 (#2587 PR A) / REQ-501 (#2590)

### 8.1 What exists after this PR

`Records` holds the single ownership check `check_write_authority/3`. Every write that goes
through `Records` is checked against the definition row it resolved.

### 8.2 Contract for REQ-499 PR A (`Records.command_multi/3`)

If PR A lands after this PR, it MUST:

1. Take `authority :: ManagedTypes.owner()` as the LAST positional argument, so the arity is /3 and
   R1 applies unchanged: `command_multi(command, prefix, authority)` where `command` carries
   `:kind`, `:line_key` and the attrs (exact `command` shape is PR A's design; the authority must
   not travel inside `command`, opts or JSON). Head guard `is_authority(authority)`.
2. (SEC A1) Run the check PER LINE: every line (every `command_multi/3` call, one per declared
   line) calls the SAME `check_write_authority(definition, entity_type, authority)` on the
   definition resolved for THAT line's `entity_type`, right after resolving it and before
   `ensure_mutable` and any record read, with zero extra queries. No batching shortcut, no "checked
   once per node" cache across lines of different types. If it re-reads the definition under lock
   (0054 D2.3), it calls the check again on that row. Any refused line refuses the whole completion
   Multi (nothing commits, 0054 D8).
3. `Letflow.Entities.StepWrites` passes the literal `:tenant` for every declarative line (0054 D4
   option-A correction: managed types are never declarative targets; D6 "until the stamp exists ...
   REFUSE"). `StepWrites` is NOT added to `@authority_callers` by PR A.
4. Map `{:error, :entity_type_managed}` to 0054 D8 `write_not_permitted` (generic response, detailed
   reason logged/audited, INV-5).
5. Not add a duplicate-as-success path for this error (it is a refusal, never `is_duplicate`).

If PR A lands first, this PR rebases onto it and adds the `authority` argument to `command_multi`
in the shape above (ELIXIR-DEV of whichever lands second does the merge). #2550 (sys: refusal in
`Records`) also edits `records.ex`; merges are sequenced, not concurrent.

### 8.3 REQ-501 hook (documented, not built)

A module write handler (0054 D4 ruling) lives in its module's own directory and receives an `Owner`
for its own entry module. Under 8.4 it obtains it itself with `ManagedTypes.owner_for!(EntryAlias)`,
so `StepWrites` never needs to mint an `Owner`; REQ-501 only adds each handler file to
`@authority_callers`. If REQ-501 instead wants a narrower Owner (manages = the handler's registered
targets, enforcing "a handler write outside its registered target list is refused"), it adds a
constructor `ManagedTypes.handler_owner/2` with its own R2-style rule in the same reviewed PR. The
`owner_module` stamp/hash verification (0054 D6) stays in the dispatch path, before the handler runs.

### 8.4 Module-internal writers (#2596 composition)

A module's writers are often not the entry module (exam: `session.ex`, `certificate.ex`,
`anti_cheat.ex` under `lib/letflow/modules/exam/`, entry module `Letflow.Modules.Exam` in
`lib/letflow/modules/exam/exam.ex`). Rule (R2): a file may call `ManagedTypes.owner_for!(EntryAlias)`
when EntryAlias is the `defmanifest` module defined in a file whose directory `D` is
`lib/letflow/modules/<id>` or `test/support/modules/<id>`, and the calling file is under `D/`
(any depth). A file can therefore only obtain ITS OWN module's Owner; `owner_for!/1`'s runtime
Catalog check and `Records`' `manages` check bound it further to the types that module declares.
There is no public `owner/0` accessor on entry modules. Accepted consequence (Revision 2): a
directory holding two `defmanifest` modules lets every file under it mint BOTH Owners; today only
`test/support/modules/fixture_managed/fixture_managed.ex` does this (`FixtureManaged` and
`FixtureManagedNoPack`, both test-only). This is accepted: both modules ship from the same reviewed
directory, so they are one trust unit; minting still needs R1's `@authority_callers` to reach
`Records`. Once exam declares `manages_entity_types`
(#2596), that PR adds `session.ex`, `certificate.ex`, `anti_cheat.ex` (and only those that pass an
Owner) to `@authority_callers`; no scan-rule change is needed.

## 9. PR body requirements (AC1)

The PR body MUST contain the section 2 table verbatim (site, path, class, authority), plus the line
"Test callers: about 217 `/2` calls in 24 `test/**/*.exs` files, unchanged, `:tenant`."

## 10. Tests (ids binding; files suggested)

Common setup: as `test/letflow/routers/entities_managed_by_test.exs` (tenant provisioned,
`Installs.install("fixture_managed", ...)`, `async: false`). "Seven" = the seven managed fixture
types; `fxm_free` is the unmanaged control. "No event" = no new `ENTITY_RECORD_*` row in the tenant
event store and no `entity_record_latest` change.

New file `test/letflow/entities/records_managed_by_test.exs` unless noted.

| Id | AC | Assertion |
|---|---|---|
| T-01 | AC2 | `:tenant` explicit and `/2` default: `create_record` on each of seven -> `{:error, :entity_type_managed}`; no event |
| T-02 | AC2 | `:tenant`: `update_record` and `delete_record` on each of seven (except `fxm_ledger`, see T-05) with (a) an existing record id created via `FixtureManaged`, (b) an absent uuid -> both `{:error, :entity_type_managed}`; record unchanged |
| T-03 | AC2 | Owner path: `owner_for!(FixtureManaged)` with `create_record/3`, `update_record/3`, `delete_record/3` on each of the six non-append-only types -> `{:ok, _}`; `fxm_ledger` create -> `{:ok, _}`; existing T-06 in `entities_managed_by_test.exs` still passes unchanged |
| T-04 | AC2 | Owner mismatch: `%Owner{module_id: "other_module", manages: MapSet.new(seven)}` (forged in the test) -> create/update/delete each `{:error, :entity_type_managed}`; no event |
| T-05 | AC2 | Owner for a type it does not manage: `%Owner{module_id: "fixture_managed", manages: MapSet.new(["org_site"])}` writing `org_unit` -> `{:error, :entity_type_managed}`; `:tenant` update and delete on `fxm_ledger` (managed + append_only) -> `{:error, :entity_type_managed}`, NOT `{:entity_append_only, _}` |
| T-06 | AC2 | Order pins with `:tenant` on a managed type: create with invalid `field_values` -> `:entity_type_managed` (not `record_payload_invalid`); delete of an already-deleted record (deleted via Owner) -> `:entity_type_managed` (not the no-op success); update with a stale `expected_last_event_global_seq` -> `:entity_type_managed` (not `record_version_conflict`) |
| T-07 | AC2 | Control: `fxm_free` with `:tenant` (`/2` and `/3`) and with `owner_for!(FixtureManaged)` -> create/update/delete `{:ok, _}` |
| T-08 | AC2 | Bad authority raises `FunctionClauseError` before any query: `"fixture_managed"`, `%{module_id: "fixture_managed", manages: MapSet.new(seven)}` (plain map), `nil`, `:owner` for each of the three `/3` functions; no event |
| T-09 | AC2 | Request data cannot carry ownership: `attrs` with `authority: owner`, `owner: owner`, `managed_by: "fixture_managed"` keys via `/2` on a managed type -> `{:error, :entity_type_managed}` |
| T-10 | AC2 | `test/letflow/entities/managed_types_test.exs` (extend): `check_record_write/3` full table of section 3.2 (six rows) plus a non-authority third argument -> `FunctionClauseError`; `owner_for!(FixtureManaged)` == `module_owner(FixtureManaged)`; `owner_for!(Letflow.Modules.Fixture)` (registered, no managed types) -> `ArgumentError`; `owner_for!(Letflow.Entities.Records)` (not registered) -> `ArgumentError`; `owner_for!("fixture_managed")` -> `FunctionClauseError` |
| T-11 | AC2 | Zero extra queries: attach a telemetry handler on the Repo query event (`Letflow.Repo.config()[:telemetry_prefix] ++ [:query]`); queries issued by a refused `create_record/2` on `org_unit` == queries issued by `Definitions.get_active_definition_by_name("org_unit", schema)` alone |
| T-12 | AC3 | `test/letflow/scheduler/record_deadline_sweep_managed_test.exs`, fresh tenant: assert the tenant has NO `org_unit` record before the owner creates exactly one, `%{"name" => "2020-01-01T00:00:00Z"}` (so the rule's only due record is this one). Rule `%{entity_type: "org_unit", datetime_field: "name", status_field: "name", due_status_value: "2020-01-01T00:00:00Z", new_status_value: "2020-01-02T00:00:00Z"}` (the fixture types have only a `name` string field; one field serves as both date and status). `RecordDeadlineSweep.run(schema, rule)` -> `:ok`; record `field_values` unchanged; no new `ENTITY_RECORD_UPDATED` event |
| T-13 | AC3 | (SEC A3) Same run with the log captured WITH metadata: `ExUnit.CaptureLog.capture_log([metadata: [:schema, :entity_type, :record_id, :reason]], fun)` (if the project's Elixir version does not take `:metadata` there, use `with_log/2` with the formatter configured for those keys in the test). Assert the captured text contains "deadline sweep: one record failed to transition", `reason=:entity_type_managed`, `entity_type=org_unit` and the record id, and does NOT contain the field value `2020-01-01T00:00:00Z` |
| T-14 | AC3 | Control: same rule shape on `fxm_free` (record created via `/2`) -> the record's `name` becomes `2020-01-02T00:00:00Z` and one `ENTITY_RECORD_UPDATED` event exists |
| T-15 | AC2 | `entities_managed_by_test.exs` (extend), race render: in ONE `Repo.transaction` in the tenant schema: `ALTER TABLE "<schema>".entity_definitions DISABLE TRIGGER entity_definitions_managed_by_no_update`; `UPDATE ... SET managed_by = 'fixture_managed', name = 'fxm_free_raced' WHERE name = 'fxm_free'`; `ALTER TABLE ... ENABLE TRIGGER entity_definitions_managed_by_no_update`. The guard (`owner_of("fxm_free")`, reads `entity_definitions.name`) now sees no stamped row, while `Records` resolves `fxm_free` through `Activation.resolve/3` (keyed by `artifact_name`) to the stamped row. (SEC A4) After the transaction: `SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = '"<schema>".entity_definitions'::regclass AND tgname IN ('entity_definitions_managed_by_no_update', 'entity_definitions_managed_by_no_delete')` returns both rows with `tgenabled = 'O'`. POST/PUT/DELETE `/entities/records/fxm_free` -> 403 with body byte-identical to the guard's 403 (REQ-496 T-01 body, pinned `x-trace-id`); no event. Teardown: the tenant fixture drops the schema with `DROP SCHEMA ... CASCADE` (`test/support/tenant_fixture.ex:995`), which fires no row-level DELETE trigger, so the stamped, renamed row does not block it (the REQ-496 suite already tears down stamped rows this way); the test adds no extra cleanup |
| T-16 | AC2 | Same setup, `POST /entities/records/fxm_free/import` with 2 entries -> 200, each result `%{"status" => "error", "reason" => %{"type" => "entity_type_managed"}, ...}`; no record; no "entity record import entry failed" warning logged |
| T-17 | AC2 | R1 on the real tree: the violation set (all forms a-d) == `@authority_callers` |
| T-18 | AC2 | R1b on the real tree: no `import`/`alias ..., as:` of `Letflow.Entities.Records`, `Letflow.Entities.Definitions` or `Letflow.Entities.ManagedTypes` outside their definers, except `records.ex`'s exact `import ManagedTypes, only: [is_authority: 1]` (asserted present) |
| T-19 | AC2 | R2 on the real tree: every `owner_for!` call outside `managed_types.ex` satisfies the `__MODULE__` or own-directory rule; the set of calling files == `["test/support/modules/fixture_managed/fixture_managed.ex"]` |
| T-20 | AC2 | R3/R4/R5 on the widened, pipe-normalised scan keep their current expected values; vacuity test asserts `fixture_managed.ex` and `script_policy_fixture.ex` are in the scanned set and that R5 does NOT report `script_policy_fixture.ex` (local calls ignored) |
| T-21 | all | TEST-RUNNER/RELEASE-VALIDATOR: full `mix test` plus `mix letflow.check` (format, credo, boundaries), real output quoted |
| T-22 | AC2 | Rule-engine negatives on SYNTHETIC sources (each rule is a function over `[{path, ast}]`; the test feeds `Code.string_to_quoted!/1` snippets under a fake path `lib/letflow/fake.ex`). Piped: `attrs |> Records.create_record(prefix, owner)` -> R1 violation; `attrs |> Letflow.Entities.Definitions.create_definition(prefix, owner)` -> R5 violation; `attrs |> Records.create_record(prefix, :tenant)` -> none |
| T-23 | AC2 | Capture: `&Records.update_record/3` and `Function.capture(Records, :delete_record, 3)` -> R1 violations; `&Records.update_record/2` -> none |
| T-24 | AC2 | Apply: `apply(Records, :create_record, [a, p, owner])`, `Kernel.apply(Records, :create_record, args)`, `:erlang.apply(Letflow.Entities.Records, :command_multi, [c, p, o])` -> R1 violations; `apply(Records, :create_record, [a, p])` and `apply(Records, :create_record, [a, p, :tenant])` -> none |
| T-25 | AC2 | Atom receiver: `:"Elixir.Letflow.Entities.Records".create_record(a, p, owner)` -> R1 violation; `:"Elixir.Letflow.Entities.ManagedTypes".owner_for!(X)` in `lib/letflow/fake.ex` -> R2 violation |
| T-26 | AC2 | Forged struct: `%{__struct__: Owner, module_id: "m", manages: s}`, `%{__struct__: :"Elixir.Letflow.Entities.ManagedTypes.Owner"}`, `Map.put(m, :__struct__, ManagedTypes.Owner)`, `m |> Map.merge(%{__struct__: Owner})` -> R4 violations |
| T-27 | AC2 | R2 directory rule. The snippet input ALWAYS includes a `defmanifest`-defining file, e.g. `{"test/support/modules/fixture_managed/fixture_managed.ex", "defmodule Letflow.Modules.FixtureManaged do\n defmanifest(id: \"fixture_managed\")\nend"}`, plus the caller snippets: `ManagedTypes.owner_for!(Letflow.Modules.FixtureManaged)` under `test/support/modules/fixture_managed/writer.ex` -> none; the same with `alias Letflow.Modules.FixtureManaged` and `owner_for!(FixtureManaged)` -> none; the same call under `test/support/modules/fixture/writer.ex`, `test/support/modules/fixture_managed_x/w.ex` (segment compare) or `lib/letflow/scheduler/x.ex` -> violation; `owner_for!(Unknown.Alias)` and `owner_for!(mod)` (unresolvable, fail closed) -> violation; `owner_for!(__MODULE__)` in a module without `defmanifest` -> violation; `&ManagedTypes.owner_for!/1` anywhere -> violation; (Revision 2, SEC B2) `import Letflow.Entities.ManagedTypes` + bare `owner_for!(X)` and bare `module_owner(X)` in `lib/letflow/fake.ex` -> R1b, R2 and R3 violations; `import ManagedTypes, only: [is_authority: 1]` under fake path `lib/letflow/entities/records.ex` -> none, under any other path -> R1b violation; `alias Letflow.Entities.{Records, ManagedTypes}` without `as:` -> none |
| T-28 | AC2 | Local calls ignored: a synthetic file with `defp create_definition(a, b, c)` and a local `create_definition(x, y, owner)` call, and a local `create_record(x, y, z)` -> no R1/R5 violation |
| T-29 | AC2 | (SEC A2, premise P) `managed_types_test.exs` (extend), after install: for each of seven, every `ArtifactVersion` of artifact `(:entity, name)` maps to an `entity_definitions` row with `managed_by == "fixture_managed"` and `name == name`; `Definitions.create_definition/2` (`:tenant`) of a new shape named `org_unit` -> `{:error, :entity_type_managed}` with the version count and row count of `org_unit` unchanged; `Definitions.activate_definition("org_unit", ...)` leaves the active row stamped; the active row `Records` resolves for each of seven has `managed_by == "fixture_managed"` |

Existing suites that must stay green unchanged: `test/letflow/routers/entities_managed_by_test.exs`
(T-01..T-20 of REQ-496), `test/letflow/scheduler/record_deadline_sweep_test.exs`, all exam and
records tests (they use `/2`).

## 11. Files touched

Changed: `lib/letflow/entities/managed_types.ex` (3.1-3.4), `lib/letflow/entities/records.ex`
(4.1-4.4), `lib/letflow/routers/entities.ex` (section 5, two clauses + comment),
`lib/letflow/scheduler/record_deadline_sweep.ex` (moduledoc only),
`test/support/modules/fixture_managed/fixture_managed.ex` (three calls pass
`ManagedTypes.owner_for!(__MODULE__)` to the `/3` functions; moduledoc says so; public helper
arities unchanged), `test/letflow/entities/managed_types_callers_test.exs` (EXISTING file edited
as listed in 7.4, plus new rules and T-17..T-20, T-22..T-28),
`test/letflow/entities/managed_types_test.exs` (T-10, T-29),
`test/letflow/routers/entities_managed_by_test.exs` (T-15, T-16).
New: `test/letflow/entities/records_managed_by_test.exs`,
`test/letflow/scheduler/record_deadline_sweep_managed_test.exs`.
Unchanged: exam modules, seed task, `test/support/exam_fixtures.ex`,
`test/support/script_policy_fixture.ex`, `installs.ex`, `catalog.ex`, migrations, `mix.exs`. Docs:
`docs/migration/decisions/0050-...md` D7 placement note gets a one-line "superseded in placement by
GH #2583: also enforced in `Records`" (DOC-UPDATER).

## 12. Invariants

* I1 No `Records` write of a `managed_by` type succeeds unless the caller passes an `Owner` whose
  `module_id` equals the stamp and whose `manages` contains the type.
* I2 The `/2` arities are `:tenant`; there is no default that grants ownership.
* I3 (reworded) An `Owner` is never derived from attrs, opts, JSON, headers or config. It is
  ORIGINATED only by `module_owner/1` (in `managed_types.ex`, `installs.ex`), `owner_for!/1` (own
  entry module, 8.4) or a struct built in `managed_types.ex`; it may then flow as a parameter
  (e.g. `solution_pack.ex:1654` -> `definitions.ex:137`), but it is HANDED TO `Records` only from
  `@authority_callers` files (R1, load-bearing). These statements hold for every form the AST scan
  sees (7.3); the forms listed in 7.5 are accepted, documented limits.
* I4 The refusal happens before any record read or write and costs no query beyond the definition
  lookup; its result does not depend on record id, payload, record state or `append_only`.
* I5 (reworded) Single-record routes (POST/PUT/DELETE): the managed answer is the same constant 403
  body whether the guard or `Records` refuses. Import: the guard answers the constant 403 before the
  body is read; in the race only, the call answers 200 with each refused entry reported as
  `%{"type" => "entity_type_managed"}` and no record written.
* I6 INV-1 unchanged: every query still carries the explicit `prefix`. INV-6: the core write path
  gains an authority check; no new data-access path.

## 13. Open questions

* OQ-A R2's "`defmanifest` module" check matches the bare (imported) `defmanifest` call used by
  every entry module today. Default: also accept the fully qualified
  `Letflow.Modules.Module.defmanifest(...)` form.
* OQ-B T-15's trigger toggle needs the test DB role to own `entity_definitions` (tests run DDL
  during tenant provisioning, so it does). If REVIEWER rejects trigger toggling in tests, fallback:
  drop T-15/T-16 to a review-only check of the two router clauses; T-01/T-02 still prove `Records`
  refuses regardless of the guard.

## 14. Follow-ups (not in this PR)

* SEC A5: an upfront sweep rule check (skip a rule on a managed type with one warning per tick
  instead of one per due record). Optional hardening; AC3 is met without it.
* SEC A6: attachment writes (`POST/DELETE /records/:entity_type/:record_id/attachments...`) on
  managed types are not locked; tracked as GH #2582.
* OQ5 (ORCH): exam types writable through the generic routes; letflow-2 files it.
* (Revision 2, idea) A scan rule forbidding any public function (`def`, not `defp`) outside
  `managed_types.ex` whose body returns an `owner_for!`/`module_owner` result, so a module cannot
  re-export its Owner to files outside its directory. Optional; R1 already confines use.
