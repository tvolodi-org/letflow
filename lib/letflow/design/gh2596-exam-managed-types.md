# GH #2596: declare the exam runtime/result types managed, stamp existing installs, exam writes pass the Owner

Status: design for WF-02 run `WF02-GH2596-EXAM-MANAGED-20261016` (CODE-DESIGNER, step 03), REVISION 1.
Base: `main` at `12d03fdb4`, branch `feature/WF02-GH2596-EXAM-MANAGED-20261016`. Priority 1, SECURITY.
Gates: SECURITY-REVIEWER (tenant-data write path, DB trigger exception; INV-1, INV-3, INV-5, INV-6,
INV-7, INV-8), REVIEWER (0050 D7 / REQ-496 D3 consistency, the single documented exception).
Depends on (merged): #2583 (`Records` authority argument, `check_record_write/3`, `owner_for!/1`,
caller-scan test). Builds on: REQ-496 (`lib/letflow/design/req496-managed-by-and-scope-node-paths.md`),
`lib/letflow/design/gh2583-records-managed-type-guard.md`. Not blocked on 0055. No new HTTP route, no new
permission atom (section 11, #2612).

Design only: signatures, type shapes, SQL shape described in prose, no function bodies.

## Supervisor ruling (2026-10-16) and supersession of "ALL 16"

The 2026-10-15 amendment of the issue ("declare ALL exam types managed", 16 types) is SUPERSEDED by the
supervisor's ruling on OQ-2, option C+A:

* The exam manifest manages ONLY the 6 runtime/result types: `session`, `session_question`,
  `session_answer`, `session_event`, `session_question_score`, `certificate`.
* The 10 authoring types (`exam`, `exam_section`, `exam_question_rule`, `exam_question_rule_tag`,
  `exam_manual_question`, `question`, `answer_option`, `question_tag`, `tag`, `category`) stay
  UNMANAGED, so the BilimBaga/QA admin UI authoring (generic `/records` routes) keeps working. They become
  managed only when an exam authoring write surface exists (follow-up filed by letflow-2; NOT in this PR).
* The 6 runtime types are added to `pack.json` (the install check requires it, F1).
* The trigger-exception array narrows to the 6 names. `Exam.Authoring` and the seed-task change are
  dropped. Attachment routes stay out (#2582). Infra stamps only the 6 types, after the read-only
  inventory.

Supervisor ruling on the snapshot (section 17.5): a separate priority-1 prerequisite issue gates the
infra stamp, not this code PR; the code PR may merge dark.

Additional supervisor requirement (same revision): section 17 verifies whether scoring reads a
session snapshot or live authoring rows (RESULT: it reads LIVE authoring rows; a blocking prerequisite
issue is recommended before infra stamps), confirms how generic authoring writes are audited, and proposes
an alert. The authoring types are NOT managed by this PR.

The issue's AC wording for "all 16" (manifest, stamp, 403 matrix, migration tests) is read as "the 6" in
this design; the PR body must say the ruling supersedes it.

## 0. Findings that shape the design (verified on `12d03fdb4`)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F1 | `priv/modules/exam/pack.json` carries only the 10 AUTHORING types. The 6 runtime types have definition files but are NOT in the pack. | `pack.json` `entity_definitions` names; `generate_pack.exs` lists the same 10. | `Installs.check_managed_types_in_pack/2` fails an install whose manifest manages a name the pack did not insert (`managed_type_not_in_pack`). Declaring the 6 with a 10-type pack makes EVERY fresh exam install fail. The pack must also carry the 6 (section 3). |
| F2 | Exam has no write path for the 10 authoring types; tenant staff author them through the web admin (`BilimBagaAdminPage`/`EntityCrudPage` over generic `POST/PUT/DELETE /entities/records/<type>`). | `web/src/config/bilimbagaEntities.ts`, `web/src/api/entities.ts`; the exam router has 8 candidate routes only. | Under the ruling they stay unmanaged, so the UI keeps working. The integrity consequence is a residual risk (R1, section 12). |
| F3 | Generic attachment WRITE routes (`entities.ex:385,403`) do not call `guard_tenant_write/3`. | handlers have no `ManagedTypes` call. | Stay out of scope (#2582), by ruling. Attachments on the 6 runtime types stay open until #2582 (R2). |
| F4 | A plain record write leaves no route marker and no audit entry. | `records.ex` `to_append_attrs/4`; no `Audit.` call in `routers/entities.ex`/`records.ex`. | Module vs generic writes are not directly distinguishable; section 8 names the proxies and the blind spot. |
| F5 | `Letflow.Release` does not exist on main (#2567 not merged). Pattern on main: `Backfill.run/1` + a Mix task with `--dry-run`. | `grep -rn "Letflow.Release" lib mix.exs` empty. | This PR adds ONE wrapper module `Letflow.Release.ManagedTypes` in that pattern and says so (section 6.4). |
| F6 | Exam record writers: `session.ex:1064` (update `session_answer`), `session.ex:1263` (update `session`), `session.ex:1328` private `write_record/4` (create `session`, `session_question`, `session_answer`, `session_question_score`), `certificate.ex:335` (create `certificate`), `anti_cheat.ex:258` (create `session_event`). All write runtime types only. | grep `Records.` in `lib/letflow/modules/exam/*.ex`. | The five sites take the Owner (section 5). The seed task (`letflow.seed.exam_fixtures.ex:577`) writes ONLY authoring types (unmanaged), so it needs no change. `test/support/exam_fixtures.ex` writes unstamped tenants and needs none. |
| F7 | `solution_pack_artefact_bases` records PROCESS definitions only; no provenance link from an `entity_definitions` row to a pack. | `solution_pack.ex` `artefact_snapshots_from/1`. | "Same-named non-exam type" is decided by field-set compatibility (name + type), NOT by a digest (section 6.2). |
| F9 | The existing installs' 6 runtime rows were NOT created from `pack.json`. ISS-0690 (QA/BilimBaga seeding): the pack installs "entity DEFINITIONS only (:inactive, no DDL)"; the five session-runtime types "that priv/packs/bilimbaga/generate_pack.exs deliberately excludes from the pack ... are created ad hoc today only by test fixtures / mix letflow.seed ... no production path installs them for an arbitrary real tenant"; they were created "via POST /entities/definitions + .../activate directly (mirroring exactly what Letflow.ExamFixtures.activate_exam_definitions!/1 does for tests)" (`docs/issues/ISS-0690.yaml:74-89`). The fixture builds each definition with `foreign_keys: []` (`test/support/exam_fixtures.ex:285-291`, comment at `:116`: "different logical_shape_version due to FK-stripping"). `certificate` is NOT among the five listed types, so it is probably ABSENT on QA/BilimBaga. | as cited | Real rows carry an FK-stripped (or hand-posted, unknown) shape, so a digest comparison with `pack.json` would report every real tenant as a conflict. The rule is field-set compatibility; `certificate` is expected in `types_absent` on QA/BilimBaga and is reported, never created. |
| F8 | The API layer never issues `set_config`; only `step_writes.ex` uses it (timeouts). | `grep -rn "DISABLE TRIGGER\|set_config" lib priv`. | Mechanism choice in section 4.1. |

## 1. Acceptance criteria map (issue body, read through the ruling: "all" = the 6)

| AC | Where satisfied | Tests |
|---|---|---|
| AC1 Manifest declares the managed set; test: declared set equals the allowed set, and no pack type is silently unmanaged | sections 2, 3 | T-01, T-02 |
| AC2 Every exam write passes the exam `Owner`; scan updated | section 5 | T-03..T-06 |
| AC3 Platform data migration: only writer after insert; narrow, idempotent, per-tenant report; `Letflow.Release` wrapper; documented single D3 exception | sections 4, 6, 9 | T-07..T-19 |
| AC3 sub: tenant/definitions API and import still cannot stamp or unstamp | section 4.4 | T-12, T-13 |
| AC4 Migration tests (a)-(d) | section 7 | T-14..T-17 |
| AC5 Generic POST/PUT/DELETE/import on each of the 6 return 403 `entity_type_managed`, incl. TENANT_ADMIN; record unchanged; fail on main | section 10 | T-20 |
| AC5 control (ruling): the 10 authoring types stay writable through the generic routes | section 10.2 | T-23 |
| AC6 Exam paths keep working on a stamped tenant | section 5.4 | T-04, T-05 |
| AC7 Read-only tamper inventory + test | section 8 | T-24..T-27 |
| AC8 Reads unchanged | section 10.3 | T-22 |
| PR states managed vs tenant-editable per type | section 12.1 | - |

## 2. The manifest (`lib/letflow/modules/exam/exam.ex`)

Add `manages_entity_types:` to the `defmanifest` call with exactly:

```
certificate, session, session_answer, session_event, session_question, session_question_score
```

`Catalog.validate/2` rule 7 (name format) holds. Manifest `version` stays `"0.1.0"` (OQ-6). `on_install/2`
and the answer-key restrictions are unchanged.

## 3. Pack, fresh installs, existing installs

### 3.1 pack.json and generate_pack.exs

* `priv/modules/exam/pack.json`: `entity_definitions` grows from 10 to 16 entries (the 6 runtime types
  appended, with `definition_json`, content-derived `entity_definition_id` and `logical_shape_version`
  exactly as `generate_pack.exs` computes them). `pack_id` and `version` unchanged (OQ-6); other arrays
  stay empty.
* `priv/modules/exam/generate_pack.exs`: `entity_types` extended to the 16 names; its stale `pack_dir`
  (`priv/packs/bilimbaga`, left from REQ-411's move) repointed to `priv/modules/exam`. It stays the only
  writer of `pack.json`.

### 3.2 Fresh installs (decision)

* The pack install inserts the 6 runtime types with the exam `Owner`, so their rows are stamped `'exam'` at
  insert (all 16 pack rows are inserted; only the 6 get a stamp, the 10 are unmanaged).
* DDL: none at install. A pack install writes `:inactive` metadata rows only (`generate_pack.exs` header:
  "install/3 writes :inactive metadata rows and emits no DDL"). No records are seeded.
* OQ-5 (decision): the runtime rows are inactive after install, exactly like the 10 authoring rows today.
  Activation is a separate, unchanged step (and is where any column promotion would occur, see
  `lib/letflow/design/iss0648-pack-install-column-promotion-trigger.md`; ELIXIR-DEV confirms and records
  whether activating the 6 types promotes columns). Until a tenant activates them, exam sessions on that
  tenant fail with the existing `{:definition_not_found, _}`; this PR does not add activation (existing
  gap, unchanged for authoring types). The PR body states it. Stamped rows stay stamped across activation
  (status flips pass the trigger).

### 3.3 Existing installs (QA, BilimBaga) (decision)

* Adding the 6 types to `pack.json` creates NO rows for existing installs: `pack.json` is read only by
  `Installs.install/3`, and an installed tenant answers `:already_installed`. No migration inserts
  definitions. This PR never inserts an `entity_definitions` row for an existing tenant.
* The stamp handles each of the 6 names per tenant (section 6.1): rows present and pack-shaped -> stamped;
  no row -> reported in `types_absent`, nothing created (a tenant missing a runtime type cannot run exams
  anyway; its fix is an activation/definition action by the tenant, outside this PR); present with an
  unrelated shape -> named conflict, untouched; stamped by another module -> named conflict, untouched.
* Residual: a tenant with an absent runtime name could later create its own tenant-owned definition of
  that name, and the exam module would then write through it unmanaged. Mitigation: the report lists
  `types_absent`; infra decides per tenant (OQ-5b).
* The 10 authoring rows of existing and fresh tenants are never touched by the stamp.

### 3.4 Existing tests to update (pack 10 -> 16)

ELIXIR-DEV updates and lists: `test/letflow/modules/exam/pack_install_test.exs` (drift guard),
`test/letflow/modules/exam/entity_definitions_test.exs`,
`test/letflow/routers/solution_packs_module_owned_pack_test.exs`,
`test/letflow/definitions/solution_pack_bilimbaga_field_restrictions_test.exs`,
`test/letflow/routers/tenant_solutions_test.exs`, `test/letflow/routers/tenant_auditor_routes_test.exs`,
`test/letflow/modules/exam/on_install_test.exs`, `test/letflow/modules/install_activation_test.exs`,
`test/letflow/modules/bilimbaga_solution_e2e_test.exs`, `test/letflow/ci_backend_path_filter_test.exs`.
Any that installs exam and then writes one of the 6 runtime types through `Records.*/2` must create that
content before the stamp (T-14 pattern); writes of the 10 authoring types need no change.

## 4. The DB exception to REQ-496 D3 immutability

### 4.1 Mechanism decision (and alternatives rejected)

REQ-496 D3: a BEFORE UPDATE trigger (`entity_definitions_managed_by_guard`, a per-schema function created
by `20261014100001_add_managed_by_to_entity_definitions.exs`) refuses any change of `managed_by` and, on a
stamped row, any change of `name`/`tenant_id`; a BEFORE DELETE trigger refuses deleting a stamped row.

**Chosen: a trigger-function replacement (new tenant-scoped migration) adding ONE guarded branch, opened
by a transaction-local setting.**

| Alternative | Verdict |
|---|---|
| `ALTER TABLE ... DISABLE TRIGGER` in the stamp transaction | Rejected: needs ownership, `ACCESS EXCLUSIVE` on a hot table, disables the guard for all columns/rows, DDL from application code. |
| An Ecto tenant migration that itself stamps | Rejected for the stamp: runs at deploy before infra runs the tamper inventory, cannot report conflicts or dry-run. |
| `SECURITY DEFINER` stamp function | Rejected: the app role already owns the objects; adds a privileged surface without removing the need to signal the stamp path to the trigger. |
| Session-level (non-local) flag | Rejected: leaks into pooled connections. |

**The branch (described, not coded).** In `UPDATE` only, before the existing immutability test, the
function allows the change when ALL hold; otherwise the existing check runs unchanged:

1. `OLD.managed_by IS NULL` and `NEW.managed_by = 'exam'` (literal: NULL -> `'exam'` only; never a change
   of an existing stamp, never a clear, never another module id);
2. `NEW.name` is one of the 6 runtime names, HARD-CODED as a literal array in the function (the 10
   authoring names and every other name cannot be stamped even if the application is wrong);
3. `current_setting('letflow.managed_by_stamp', true)` equals `'exam'` (custom, transaction-local;
   `missing_ok = true`, so unset is NULL and fails);
4. the row is otherwise unchanged: `to_jsonb(NEW) - 'managed_by'` equals `to_jsonb(OLD) - 'managed_by'`
   (jsonb comparison, not text). `Stamp`'s UPDATE is an `update_all` with `set: [managed_by: "exam"]` and
   NOTHING else (no timestamp touch, or the equality fails and the tenant reports `:gap_remains`). The
   function stays non-`SECURITY DEFINER` and uses `current_setting` (pg_catalog) and schema-qualified names (no rename, status flip, definition change or `tenant_id` move in the same statement).

DELETE branch unchanged. After the stamp, condition 1 is false, so the normal refusal applies. The
function keeps its name, so both existing triggers keep pointing at it. `down` restores the exact previous
body.

### 4.2 The migration (new, tenant-scoped, registered)

`priv/repo/migrations/20261016120001_allow_exam_managed_by_stamp.exs`, module
`Letflow.Repo.Migrations.AllowExamManagedByStamp`, version `20_261_016_120_001`. Same shape as
`20261014100001`: mandatory `if prefix() do` guard, schema name from `prefix()` only, no tenant data in SQL
(INV-7). Appends
`{20_261_016_120_001, Letflow.Repo.Migrations.AllowExamManagedByStamp, "20261016120001_allow_exam_managed_by_stamp.exs"}`
to `@tenant_scoped_migration_manifest` in `lib/letflow/tenant_provisioning.ex` (and fixes any manifest
count assertion/moduledoc count). Exposes public `stamp_names/0` (the frozen 6) for T-10. Its header
comment states: the single exception to REQ-496 D3, the only permitted opener (`ManagedTypes.Stamp`),
and that a later migration should retire it once every environment is stamped (F-RETIRE). Extending the
frozen array later (e.g. when the authoring types become managed) is a new reviewed migration.

**Explicit `up`/`down` (SECURITY A-3).** The migration defines `up` and `down`, not `change`. `down`
executes `CREATE OR REPLACE FUNCTION` with the PREVIOUS body byte-for-byte copied from
`20261014100001_add_managed_by_to_entity_definitions.exs` (copied, not re-typed). `down` does NOT unstamp rows
(stamps are immutable by design); after `down`, `Stamp` reports `:exception_not_installed` for the tenant and
any NULL rows of the 6 stay unstampable until `up` is re-applied. Test T-09b covers the round trip.

Rollout precondition: the migration must be applied to a tenant before the stamp runs for it; `Stamp`
checks per tenant and reports `:exception_not_installed` instead of attempting the UPDATE.

### 4.3 Who may open the exception

Only `Letflow.Entities.ManagedTypes.Stamp` (section 6) may contain `letflow.managed_by_stamp`. It sets it
with a parameterized transaction-local `set_config(name, value, true)` as the first statement of each
per-tenant transaction.

**GUC lifetime (SECURITY F-1).** `set_config(..., true)` is reset at the end of the OUTERMOST transaction,
not at a savepoint release, and `Repo.transaction/2` JOINS an enclosing transaction. So the design does not
rely on "reset at COMMIT" alone:

* (a) `Stamp.run_tenant/2` and `TamperInventory.run_tenant/2` return a typed error when
  `Repo.in_transaction?()` is true at entry: `Stamp` reports that tenant as `status: :failed, error:
  :nested_transaction` with nothing set or written; the inventory reports `skipped: :nested_transaction`.
  Types: the `error` union of `tenant_report` gains `:nested_transaction`; `tenant_findings.skipped` gains
  `:nested_transaction`.
* (b) defence in depth: the LAST statement of `Stamp`'s transaction function is
  `set_config('letflow.managed_by_stamp', '', true)`, so a joined outer transaction also ends with the setting
  cleared. The trigger opens only for the exact value `'exam'`; `''` and unset both keep it closed.

**Tripwire, not a boundary (SECURITY F-2).** The scan T-11 makes any new opener a reviewed test change. It is
NOT a security boundary: any raw-SQL code running as the app DB role can call `set_config` (custom settings
need no privilege) or `DISABLE TRIGGER`, exactly as before this PR (R3).

Scan T-11 is an AST scan (`Code.string_to_quoted`, not a text grep) over `lib/`, `priv/` (including
`priv/repo/seeds*` and migrations), `scripts/` and `config/`, asserting:

1. the fragment `managed_by_stamp`, and `letflow.` adjacent to a binary concat or interpolation, appear only
   in `stamp.ex` and the two migration files; the scan walks string literals of EVERY form: plain strings,
   heredocs (`"""`), sigils (`~s`, `~S`, `~r`, ...), charlists, and `fragment(...)` literals;
2. every `Repo.query`/`Repo.query!`/`Ecto.Adapters.SQL.query`/`query!` call whose first argument is not a
   compile-time literal sits in an explicit allowlist of files (the current dynamic-SQL files:
   `partition_maintenance`, `retention_operations`, `projector`, `sandbox_pool`, `fixture_loader`,
   `tenant_provisioning`, `scope_node_paths`, `step_writes`, `managed_types`, plus `stamp.ex`; ELIXIR-DEV
   regenerates the list from the tree and quotes it), so a NEW dynamic-SQL site is a reviewed test change;
3. `set_config` occurs under `lib/` only in `step_writes.ex` (timeouts) and `stamp.ex`, each with a literal
   first argument; this covers `set_config` appearing inside a string literal of any form of assertion 1,
   including a `fragment("... set_config(...) ...")` literal, not only a function call;
4. `Stamp.run/1` and `Stamp.run_tenant/2` are referenced only from `lib/letflow/release/managed_types.ex` and
   the two Mix tasks (callers scan, like `@authority_callers`);
5. no `update_all`/`update` touching `:managed_by` outside `stamp.ex` and the insert-time `put_managed_by`
   path (`entity_definition.ex`, `definitions.ex`, `solution_pack.ex`, `installs.ex` as they stand);

and `DISABLE TRIGGER`, `session_replication_role` and `ALTER TABLE ... DISABLE` appear nowhere.

### 4.4 Bypass analysis

| Path | Reaches the exception? | Why / test |
|---|---|---|
| `POST /entities/definitions`, activate | No | `EntityDefinition.changeset/2` never casts `:managed_by`; stamps come only from `put_managed_by/2` on a NEW row under an `Owner`; no HTTP code calls `set_config`. REQ-496 T-08..T-11 re-run unchanged; new T-12. |
| Pack install/import with `:tenant` | No | A `managed_by` key is rejected/ignored (REQ-496 2.6); `:tenant` cannot stamp. T-13 re-runs the attempt after the new migration. |
| Record routes and import | No | They write `entity_record_*`, never `entity_definitions`. |
| Lua/script host functions (INV-3) | No | Read-only; no caller-supplied SQL. |
| Any raw-SQL code with the app DB role | Yes, by construction | Already true before this PR (same role could `DISABLE TRIGGER`). The new branch narrows what such a bug can do: NULL -> `'exam'` on 6 frozen names, row otherwise unchanged. Controls: INV-7, scan T-11. Stated in the PR body. |
| Another module id / the 10 authoring names | No | Literals in the function. |

## 5. Owner on every exam write

### 5.1 Obtaining the Owner

`Letflow.Modules.Exam` declares managed types, so `ManagedTypes.owner_for!(Letflow.Modules.Exam)` returns
the exam `Owner` (`module_id: "exam"`, `manages`: the 6). #2583's R2 directory rule allows that call in
any file under `lib/letflow/modules/exam/` (alias form `owner_for!(Exam)`). No change to `managed_types.ex`
or R2. Each of `session.ex`, `certificate.ex`, `anti_cheat.ex` gets one PRIVATE helper:

```
@spec exam_owner() :: Letflow.Entities.ManagedTypes.Owner.t()     # defp in each of the three files
```

Evaluated at each call, never stored in a module attribute. Cost: `owner_for!/1` computes the manifest hash
per call; measure in review, memo is a separate follow-up (F-MEMO).

### 5.2 The five call sites

`session.ex:1064`, `session.ex:1263`, `session.ex:1328` (`write_record/4`), `certificate.ex:335`,
`anti_cheat.ex:258` change from `Records.<fun>(attrs, prefix)` to `Records.<fun>(attrs, prefix,
exam_owner())`. Attributes, idempotency keys, actors and error shapes are unchanged.

### 5.3 Other writers

* The seed task and `test/support/exam_fixtures.ex` write authoring types (unmanaged) or unstamped
  tenants, so `/2` keeps working: NO change (the `Exam.Authoring` module of the first draft is dropped).
* New tests needing records of a STAMPED tenant create content first, then stamp (T-14); a test helper
  cannot hold the Owner by design.
* `RecordDeadlineSweep` and the generic routes pass `:tenant` and are refused on the 6 by design.

### 5.4 Behavior on a stamped tenant

Stamp `"exam"` + `%Owner{module_id: "exam"}` managing the type -> `:ok`; `/2` (`:tenant`) ->
`{:error, :entity_type_managed}`. Existing exam suites run on unstamped tenants and pass UNCHANGED (an
Owner writing an unmanaged type is `:ok`). T-04 repeats the full candidate flow on a stamped tenant.

### 5.5 Scan updates (`test/letflow/entities/managed_types_callers_test.exs`)

* `@authority_callers` gains `lib/letflow/modules/exam/session.ex`, `certificate.ex`, `anti_cheat.ex`
  (each really passes a non-`:tenant` third argument, so R1/T-17 stays non-vacuous).
* R2 (T-19): the set of files calling `owner_for!` outside `managed_types.ex` becomes the fixture file plus
  the three exam files; the directory rule needs no code change.
* NEW R6 (T-03): over `lib/letflow/modules/exam/**/*.ex`, no qualified `Records.create_record |
  update_record | delete_record` call has two arguments or a literal `:tenant` third argument (the module
  writes only runtime types, which are managed). Synthetic negatives: a `/2` call, a piped `/2` call and a
  `:tenant` literal each violate; a `/3` with a variable does not. (R7 of the first draft is dropped with
  `Exam.Authoring`.)
* Moduledocs (the test; `ManagedTypes` "Who may hold an Owner") list the exam files as origin callers.

## 6. The stamp: `Letflow.Entities.ManagedTypes.Stamp` and its wrapper

### 6.1 Core module (`lib/letflow/entities/managed_types/stamp.ex`)

Shape follows `Letflow.Identity.RoleScopeGrants.Backfill`: sequential over
`TenantProvisioning.list_registrations/0`, ONE transaction per tenant, none across tenants, under
`Letflow.Obs.Logger.with_trace/1`.

```
@type opts :: [module: String.t(), dry_run: boolean(), lock_timeout_ms: pos_integer(),
               after_precheck: (schema_name :: String.t() -> :ok)]
# after_precheck: TEST-ONLY seam (default nil), called once per tenant between the advisory pre-pass (steps
# 1-2) and the transaction (step 4). It carries no authority. The release wrapper and the Mix tasks take
# only module/dry_run and drop every other key, so production never passes it (T-11 assertion 4 pins callers).
# module: only "exam" (default "exam"); other -> {:error, :unsupported_module}
# dry_run default false; lock_timeout_ms default 3_000

@type conflict :: %{type: String.t(), rows: pos_integer(),
                    reason: :shape_not_compatible | :stamped_by_other_module}

@type tenant_status ::
        :stamped | :nothing_to_stamp | :exam_not_installed | :exception_not_installed
        | :skipped_schema_missing | :failed

@type tenant_report :: %{
        tenant_id: Ecto.UUID.t() | nil,
        schema_name: String.t(),
        status: tenant_status(),
        rows_stamped: non_neg_integer(),          # dry run: rows that WOULD be stamped
        rows_already_stamped: non_neg_integer(),
        types_stamped: [String.t()],
        types_absent: [String.t()],               # of the 6, no row in this tenant
        conflicts: [conflict()],
        differences: [%{type: String.t(), extra_fields: [String.t()], differing: [atom()]}],
        exam_named_types_present: [String.t()],   # set only when status = :exam_not_installed
        # differences (SECURITY A-1), in the dry-run AND the real report: for each STAMPABLE name, NAMES ONLY (no
        # values): field names not in the pack, and which of :required | :enum_values | :constraints | :indexes
        # differ from the pack definition, so infra can eyeball a permissive lookalike before the real stamp
        error: nil | :nested_transaction | :lock_timeout | {:audit_failed, atom()} | {:unexpected_exception, module()}
      }

@type report :: %{dry_run: boolean(), module: String.t(), tenants: [tenant_report()],
                  rows_stamped_total: non_neg_integer(), conflict_total: non_neg_integer(),
                  failed_total: non_neg_integer()}

@spec run(opts()) :: {:ok, report()} | {:error, :unsupported_module}
@spec run_tenant(schema_name :: String.t(), opts()) :: tenant_report()
```

`run/1` never halts on one tenant: a per-tenant `:failed` (lock timeout, audit failure, any exception;
only a tag or exception module kept, never a message, INV-4/INV-5) is recorded and the sweep continues; a
missing schema/table is `:skipped_schema_missing` (the `Backfill` rescue). Idempotent: a re-run finds every
frozen-name row stamped and issues no UPDATE and no audit entry.

**Per-tenant steps (real run).**

1. Pre-checks, read-only, outside the transaction, explicit `prefix:` (INV-1):
   a. exam installed: a `tenant_modules` row `module_id = 'exam'`. Absent -> `:exam_not_installed`, nothing
      touched; `exam_named_types_present` lists which of the 6 have a row (visible, untouched; case (d)).
   b. exception installed: the TENANT schema's own `schema_migrations` (read with the tenant `prefix:`, not
      `public`) has `20261016120001`, else `:exception_not_installed`.
   c. candidate names = the frozen 6 INTERSECT the manifest's `manages_entity_types` (via `Catalog.fetch("exam")`
      and `module_owner/1`); the frozen list is a constant in `Stamp` equal to the migration's (T-10).
      The 10 authoring names are never candidates.
2. ADVISORY pre-classification (outside any transaction; used ONLY by the dry run and to skip tenants with
   nothing to do; the real run NEVER stamps from it, see step 4 and SECURITY F-4). Classify each candidate
   `N` over all its `entity_definitions` rows (every version):
   * all rows already `'exam'` -> already stamped;
   * any row stamped to another module id -> conflict `:stamped_by_other_module`;
   * no row -> `types_absent` (never created by the stamp);
   * rows with `managed_by IS NULL` (alone or mixed with `'exam'`): stampable ONLY if EVERY row of `N`
     (every version, active or not, stamped or NULL) is field-compatible with the pack definition of `N`
     (rule in 6.2). All-or-nothing per name, so no older hostile or incompatible version rides along into an
     immutable stamp (SECURITY F-3); else
     conflict `:shape_not_compatible`. A conflicting name is never stamped and nothing is overwritten;
     the tenant's other names are still stamped. When stampable, ALL rows of `N` (every version) are
     stamped.
3. Dry run: report the step 2 classification only (`rows_stamped` = NULL rows of stampable names); no
   transaction, no lock, no write. The dry run is advisory by construction (it can be stale by the time of
   the real run).
0. Entry guard (before step 1): `Repo.in_transaction?()` true -> return `status: :failed, error: :nested_transaction`
   (section 4.3 F-1); nothing is read, set or written.
4. Real run, one `Repo.transaction/2` (explicit `prefix`), lock order per 6.3:
   a. `SET LOCAL` `lock_timeout` = `lock_timeout_ms` and a bounded `statement_timeout` (parameterized
      `set_config(..., true)`);
   b. `ManagedTypes.lock_names(candidate_names, schema_name)` for ALL candidate names of step 1c (not only the
      ones the advisory pass found stampable; namespace `496_001`, names ascending). A tenant create of a new
      version of any of them takes the same lock, so after this point no new row of these names can appear
      until commit (SECURITY F-4);
   c. select ALL rows of the candidate names (every version, stamped or NULL) ordered by `(name, id)` with
      `FOR UPDATE`;
   d. CLASSIFY HERE, INSIDE the transaction, from the rows of (c), with the same rules as step 2 (absent /
      stamped by another module / every row field-compatible / already stamped). This classification is the
      only one the real run acts on and the one the report carries. Names that fail are conflicts (nothing of
      them is stamped); the rest continue;
   d2. set `letflow.managed_by_stamp` = `'exam'` (parameterized, transaction-local) only now, immediately
      before the UPDATE;
   d3. ONE `UPDATE ... SET managed_by = 'exam'` over exactly the ids of the NULL rows of the stampable names
      selected in (c) (Ecto `update_all`, bound id list, `set: [managed_by: "exam"]` only);
   e. re-read: every row of every stampable name is `'exam'` and the stamped count equals the updated
      count, else roll back `:gap_remains`;
   f. only when rows were stamped, one `Audit.insert_entry(Repo, attrs, schema_name)`: `actor_id: nil`,
      `action: "entity_type.managed_by_stamped"`, `resource_type: "entity_definitions"`,
      `resource_id: tenant_id`, `after_state`: `module`, `rows_stamped`, stamped type names, conflict
      `{type, reason}` list, `source: "release_stamp"` (names and counts only); failure rolls back with
      `{:audit_failed, tag}`;
   g. as the LAST statement inside the transaction function: `set_config('letflow.managed_by_stamp', '', true)`
      (section 4.3 F-1(b)); then commit. The UPDATE in (d) sets ONLY `managed_by` (section 4.1 condition 4).
5. Status `:stamped` if rows were stamped, else `:nothing_to_stamp`.

### 6.2 Conflict rule (OQ-1)

No provenance exists (F7) and the real rows are not pack-shaped (F9), so a digest rule is rejected
(an FK-stripped legacy row, a pack-shaped row and a hand-posted row all have different
`logical_shape_version`s). DECIDED rule, field-set compatibility:

* Reference = the exam pack's own definition of `N` (the `definition_json` of `N` in `pack.json`, equal
  to `priv/modules/exam/entity_definitions/N.json`, drift-guarded by T-02). Its `fields` list gives the
  required set of `(field name, field type)` pairs.
* The rows to test = EVERY `entity_definitions` row of `N` in the tenant (all versions). A name is stampable
  only if all of them are compatible; one incompatible row makes the whole name a conflict
  (`:shape_not_compatible`, `rows` = the count of incompatible rows) and NOTHING of that name is stamped.
  Stamping only the compatible rows was rejected: it would leave a name half-stamped and break premise P2
  (every row of a managed name carries the same stamp). Accepted cost: a legitimate tenant whose OLDEST
  version predates a pack field is reported as a conflict and needs a human decision. A row is compatible iff, for EVERY pack field `(name, type)`, the row's
  `definition_json.fields` contains a field with that exact name and type. Extra fields on the tenant
  side are allowed (tenant-evolved versions pass); enum values, `required`, `queried`, indexes, foreign
  keys and constraints are NOT compared (so FK-stripped fixture rows and pack-shaped rows both pass).
* A truly unrelated same-named type (missing a pack field, or a pack field with a different type) is
  `:shape_not_compatible`, named with tenant and type, never stamped, never overwritten.
* Why this and not "digest OR FK-stripped digest": the real rows' shapes are unknown (hand-posted JSON),
  so any fixed digest set is a guess; name + type is exactly what the exam module's code reads and
  writes. Residual: a tenant type that copies every field name+type passes and is stamped; that is
  harmless (it becomes exam-owned, and the exam module is its only writer from then on).
* No "relax later": this is the rule shipped.

Implementation note (type only): `@spec field_compatible?(pack_fields :: [%{String.t() => String.t()}],
row_fields :: [map()]) :: boolean()`, private to `Stamp`; reads `definition_json` as stored (string keys).

### 6.3 Lock order and transaction bounds

Consistent with `Installs.install/3` and `Definitions.create_definition/3`: (1) `496_001` name create-locks
sorted ascending (same helper, so stampers and pack installs cannot deadlock on names); (2)
`entity_definitions` row locks in `(name, id)` order; (3) the audit insert, whose `Audit.ChainLock` is taken
inside `insert_entry` and is always LAST. The tenant-admin advisory lock is not taken (not relevant here).
No cross-tenant transaction. Bounded: at most 6 names and a handful of rows; `lock_timeout` 3 s so a
concurrent `activate_definition/4` yields `:failed` (`:lock_timeout`) for that tenant, never a hang; the
sweep continues and a re-run completes it. A concurrent tenant create of a stamped name serializes on (1)
and is then refused.

### 6.4 The wrapper (the #2567 pattern, added here)

`lib/letflow/release/managed_types.ex`, `Letflow.Release.ManagedTypes`. #2567 is not merged; this PR adds
only this module and says so in the PR body.

```
@spec stamp(opts :: [module: String.t(), dry_run: boolean()]) ::
        {:ok, Stamp.report()} | {:error, :unsupported_module}
@spec tamper_inventory(opts :: [module: String.t(), scope: TamperInventory.scope()]) ::
        {:ok, TamperInventory.report()}
```

Thin delegates; the moduledoc shows `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.stamp(dry_run:
true))"` and the same for `tamper_inventory([])`. Mix tasks (pattern of
`Mix.Tasks.Letflow.BackfillRoleScopeGrants`; strict `OptionParser`; `Mix.Task.run("app.start")`; no
`LETFLOW_DEV_DB_CONFIRMED` guard): `mix letflow.stamp_managed_types [--module exam] [--dry-run]` and
`mix letflow.managed_types_tamper_inventory [--module exam] [--scope runtime|authoring|all]`. Exit 1 on any
`:failed` tenant; conflicts are printed per tenant and counted but do not change the exit code (OQ-4).
`mix.exs` is NOT edited.

## 7. Migration tests (a)-(d)

Setup: provision tenants with `TenantFixture` (full manifest, so the new trigger exists).

| Case | Setup | Assert |
|---|---|---|
| (a) fresh install | `Installs.install("exam", ...)` on a tenant with no exam | the 6 runtime names have rows `managed_by = 'exam'` (every version); the 10 authoring rows are present and `managed_by IS NULL`; `owner_of/2` is `{:ok, "exam"}` for the 6 and `:unmanaged` for the 10; `Stamp.run_tenant` -> `:nothing_to_stamp`, `rows_stamped: 0` |
| (b) installed before the change | THREE unstamped builds of the 6 runtime rows, each in its own tenant (all with the exam `tenant_modules` row inserted DIRECTLY, as `ExamFixtures.provisioned_tenant_with_exam_definitions/1` does, never via `Installs.install/3`): **b1 FK-stripped legacy** = `ExamFixtures.provisioned_tenant_with_exam_definitions/1` as is (definitions built from `priv/modules/exam/entity_definitions/*.json` with `foreign_keys: []`, `Definitions.create_definition/2` + activate, `:tenant`; this is the shape ISS-0690 says QA/BilimBaga rows have); **b2 pack-shaped** = the same tenant provisioning without the fixture definitions, then `SolutionPack.install/3` of the 16-type pack document with the `:tenant` owner (no Owner, so rows are inserted UNSTAMPED, full `foreign_keys`), then activate; **b3 hand-posted** = definitions created through `POST /entities/definitions` from the JSON files WITH an extra tenant field and without `indexes`/`constraints`. Plus records of the 6 (created before stamping with `Records.*/2`, `:tenant`) | in b1, b2 and b3: `Stamp.run_tenant` -> `:stamped`, 6 types stamped, every row of the 6 is `'exam'`; the 10 authoring rows byte-identical; second run -> `rows_stamped: 0`, no new audit entry, definitions rows byte-identical. Variant b4: `certificate` absent (the expected QA/BilimBaga state, F9) -> `types_absent: ["certificate"]`, nothing inserted, the other 5 stamped |
| (c) same-named non-exam type | tenant with exam row (inserted directly) and the b1 definitions for 5 runtime types, but `certificate` created by the tenant through `create_definition/2` with an UNRELATED shape (fields `foo: string`, `bar: integer`; no pack field) | conflict `%{type: "certificate", reason: :shape_not_compatible}` for THAT tenant; its row untouched; the other 5 stamped; a second tenant (b1) processed AFTER it in the same `run/1` is fully stamped. Variants: a type with the right field names but a wrong TYPE on one pack field (e.g. `score_pct: string`) -> conflict; a runtime-named row already `managed_by = 'other_module'` -> `:stamped_by_other_module`. A tenant-created `tag` (authoring name) is simply untouched and NOT reported |
| (d) no exam | tenant with no exam row (with and without an unrelated `session`) | `:exam_not_installed`; every `entity_definitions` row identical before/after (full row dump); `exam_named_types_present` lists present names |

## 8. Read-only tamper inventory

### 8.1 What a write event records and what distinguishes the sources (F4)

Each record write appends one `events` row in the tenant schema: `instance_id` = the entity type's
synthetic instance (`entity_type_instances.entity_type -> instance_id`), `event_type` in
`ENTITY_RECORD_CREATED|UPDATED|DELETED`, `actor_id`, `idempotency_key`, `created_at`; payload `entity_type`
and `record_id` (a payload over 4096 bytes is a `{"$ref": id}` pointer into `event_payload_store`, which the
query resolves). There is NO route/source/module field for plain record writes and no audit entry, so
module and generic writes are NOT distinguishable by one column. Proxies, reported as `evidence`:

| evidence | Rule | Strength |
|---|---|---|
| `:import_key` | `idempotency_key` starts with `entities-record-import:` | definite: only the import route mints it (`entities.ex:1359`) |
| `:client_key` | key starts with `client:rec:` | definite: only create/update routes, only when the client supplied a key (GH #2550) |
| `:unrecognised_key_shape` | neither UUID-shaped, nor `client:rec:`/`entities-record-import:`, nor `certificate:issue:<uuid>` | likely a pre-#2550 raw client key |
| `:non_owner_actor` | runtime type and `actor_id` differs from the owning session's `user_id` (the `session` record itself; `field_values.session_id` -> session for the others, from `entity_record_latest`) | likely: every exam module write is made as the session's candidate |
| `:authoring_type` | authoring type, ANY event (only under `scope: :authoring | :all`) | informational: the exam module has no authoring write path, so every such event is a non-module write (normal admin authoring included) |

Default `scope` is `:runtime` (the 6 types being stamped); `:authoring` and `:all` are opt-in, since the 10
authoring types stay tenant-editable by ruling.

**Blind spot (repeated in the PR body):** a generic write of a runtime type with NO client key (a bare
minted UUID, indistinguishable from a module key) by the SAME user as the session owner is not detected;
it needs a candidate who also holds `:EntitiesRecordsWrite` (CANDIDATE grants only the six exam
permissions). Generic DELETEs always use a fresh UUID key, so a delete is detected only through
`:non_owner_actor`. Events moved to `events_archive` by retention are not scanned (OQ-7).

### 8.2 Module (`lib/letflow/entities/managed_types/tamper_inventory.ex`)

```
@type scope :: :runtime | :authoring | :all        # default :runtime
@type finding :: %{
        tenant_id: Ecto.UUID.t() | nil, entity_type: String.t(), record_id: Ecto.UUID.t() | nil,
        event_type: String.t(), actor_id: Ecto.UUID.t(), occurred_at: DateTime.t(),
        evidence: :import_key | :client_key | :unrecognised_key_shape
                  | :non_owner_actor | :authoring_type}
@type tenant_findings :: %{tenant_id: Ecto.UUID.t() | nil, schema_name: String.t(),
                           findings: [finding()], truncated: boolean(),
                           skipped: nil | :schema_missing}
@type report :: %{scope: scope(), tenants: [tenant_findings()], finding_total: non_neg_integer()}

@spec run(opts :: [module: String.t(), scope: scope()]) :: {:ok, report()}
@spec run_tenant(schema_name :: String.t(), opts :: [scope: scope()]) :: tenant_findings()
```

* Tenants covered: the exam `tenant_modules` row OR any of the 6 runtime names present.
* Payload minimisation (SECURITY B-3): the query projects ONLY the two keys it needs from the payload
  (`entity_type` and `record_id`, extracted in SQL) and NEVER selects the `payload` column (or
  `field_values`) into Elixir; for an over-4096-byte event it resolves only `record_id`/`entity_type` from
  the sidecar the same way. Findings are returned to the operator (Mix task stdout / `rpc` return value)
  and are NEVER passed to `Logger`; the module contains no `Logger` call carrying a finding or a row.
* Strictly read-only: each tenant's reads run in a transaction whose first statement is `SET TRANSACTION
  READ ONLY`; no insert/update/delete in the module; explicit `prefix:` (INV-1); bound parameters (INV-7).
  A finding carries ids, event type, actor id and timestamp only: no `field_values`/payload (INV-5).
* Ordered by tenant, `occurred_at`, `global_seq`; capped per tenant (default 10_000) with
  `truncated: true`.
* Delivered as the function plus the mix task; no separate `.sql` file (one source of truth). Running it on
  QA/prod is an infra request, not part of this PR.

## 9. Rollout (PR body and infra request)

1. Merge and deploy (code, pack, trigger migration applied to every tenant by the normal mechanism). From
   then FRESH installs stamp the 6 runtime types; existing installs are not stamped.
2. Infra runs the tamper inventory on QA and prod (default scope `:runtime`); findings are reviewed BEFORE
   step 4.
3. Infra runs `stamp --dry-run`; any `conflicts`, `types_absent`, `exception_not_installed`, or
   `exam_not_installed` with `exam_named_types_present` are read and decided.
4. Infra stamps ONLY the 6 runtime types (the only types the stamp can touch), then re-runs once (second
   run reports 0 stamped). GATE (supervisor ruling, section 17.5): infra must NOT be asked to run this step until the
   session-content-snapshot prerequisite issue has landed.
5. Authoring types are not part of this rollout; they stay tenant-editable until the follow-up.

## 10. HTTP behavior after the stamp (no router code change)

`guard_tenant_write/3` already answers the constant 403 `Error.entity_type_managed()` for any stamped name
on `POST/PUT/DELETE /entities/records/...` and `POST /entities/records/:type/import`, before the body is
read, for every caller including TENANT_ADMIN. No router change.

### 10.1 What the tests prove (fail on main: the 6 are unmanaged there)

T-20: on a stamped tenant, for each of the 6 types and each of {`POST`, `PUT`, `DELETE`, `POST
.../import`} and each of {a user holding `:EntitiesRecordsWrite`/`:EntitiesRecordsImport`, a
TENANT_ADMIN}: 403, problem body equal to `Error.entity_type_managed()`'s constant body, no new
`ENTITY_RECORD_*` event, and `POST /entities/query` returns the pre-existing record unchanged. PUT/DELETE
targets are created BEFORE the stamp.

### 10.2 Authoring types stay writable; attachments out (ruling)

* T-23: on the same stamped tenant each of the 10 authoring types is still writable through the generic
  POST/PUT/DELETE/import for both caller kinds (the ruling's whole point); the stamp touched none of their
  definition rows.
* Attachment routes are OUT of this PR (#2582). The PR body states that attachment writes on exam records,
  including the 6 stamped types, remain open to `:EntitiesAttachmentsManage` holders until #2582.

### 10.3 Reads

T-22: `POST /entities/query`, `/query/aggregate` and `GET /entities/definitions...` on the exam types behave
as today under the same permissions and field restrictions.

## 11. Gates, #2612, invariants

* #2612 mandatory trigger: NOT triggered. The design touches none of `ci.yml`, `cd.yml`,
  `scripts/cd_qa_decide.sh`, `scripts/ci_changed_paths.sh`, `mix.exs` aliases/`elixirc_paths`, `config
  :letflow, :modules`, `letflow.permission_matrix.ex`, `api/permission_matrix.ex`, `api/authorization.ex`,
  `modules/catalog.ex`, `priv/permission_matrix/`. Only `manages_entity_types` is added; `role_grants` and
  `permissions` are unchanged, so the golden does not change (the implementer quotes `mix
  letflow.permission_matrix --check`). The new Mix tasks are new files, not alias edits. SECURITY-REVIEWER
  is mandatory anyway (migration + tenant-data write path).
* INV-1: every new query has an explicit `prefix:` from the registration; `tenant_id` from
  `tenant_id_for_schema_name/1`. INV-3: no sandbox surface. INV-4: reports keep tags/exception modules,
  never messages. INV-5: constant 403 body; reports/findings hold ids and names, no field values. INV-6:
  section 4.4 + this list are the scoping proof; no new route. INV-7: Ecto queries and bound `set_config`
  parameters; the only interpolated text is the schema name from `prefix()` in the trigger migration.
  INV-8: per-tenant failure is caught, counted, non-zero exit. INV-10: n/a (release/mix entry points).
* Decision records: 0050 D7 gets a one-line note and REQ-496 design D3 an "Amendment 2026-10-16 (GH #2596)":
  the stamp is written at insert, with ONE exception, the platform stamp of exam's 6 frozen runtime names
  NULL -> `'exam'` through `ManagedTypes.Stamp`. DOC-UPDATER writes them; the migration comment carries the
  same text. The note also records the supersession of "ALL 16".

## 11b. PR-body residuals (must be stated verbatim in intent)

1. Attachment writes on the 6 stamped types stay open to `:EntitiesAttachmentsManage` holders until #2582.
2. The authoring types (including the answer key) stay writable by `:EntitiesRecordsWrite` holders, and
   scoring reads those live rows (section 17.1); therefore infra must NOT request the stamp until the
   session-content-snapshot prerequisite issue has landed (section 17.5).
3. After the stamp, any tenant process or script that wrote a runtime type through `Records` with
   `:tenant` (generic routes, import, ad-hoc scripts, the deadline sweep) starts failing with
   `entity_type_managed`; only the exam module's own paths keep writing.
4. The trigger exception and its scan are a tripwire, not a boundary against raw SQL as the app DB role
   (section 4.3), as before this PR.
5. A tenant type that copies every pack field name+type is stamped as exam-owned; the dry-run
   `differences` field lets infra review that before the real stamp (section 6.1).

## 12. Product consequence and risks

### 12.1 Managed vs tenant-editable, per type (PR body table)

| Type | Class | After this PR | Reason |
|---|---|---|---|
| `session` | runtime | MANAGED (exam module only) | candidate session state: start/expiry/status/score |
| `session_question` | runtime | MANAGED | the questions a session was dealt |
| `session_answer` | runtime | MANAGED | candidate answers (post-submission tampering is the reported hole) |
| `session_question_score` | runtime | MANAGED | per-question scores |
| `session_event` | runtime | MANAGED | anti-cheat evidence |
| `certificate` | result | MANAGED | issued certificates |
| `exam` | authoring | tenant-editable, by supervisor ruling 2026-10-16 | admin UI authors it through generic routes; becomes managed with the authoring write surface follow-up |
| `exam_section`, `exam_question_rule`, `exam_question_rule_tag`, `exam_manual_question` | authoring | tenant-editable, by ruling | same |
| `question`, `answer_option`, `question_tag` | authoring | tenant-editable, by ruling | same (they hold the answer key; see R1) |
| `category`, `tag` | authoring | tenant-editable, by ruling | same |

### 12.2 Risks

| Id | Risk | Mitigation |
|---|---|---|
| R1 | Authoring types stay writable by `:EntitiesRecordsWrite` holders. `question`/`answer_option` hold the answer key that scoring reads at submit, so a privileged user can still change future scores by editing the key; already-stored scores are protected. Accepted by the ruling. | Follow-up: exam authoring write surface, then add the 10 names by a new reviewed migration + manifest change. The allowlist test (T-02) forces that decision to be explicit. Inventory `scope: :authoring` available. |
| R2 | Attachments on the 6 runtime types stay writable (#2582). | Stated in the PR; #2582 owns it. |
| R3 | The trigger exception is a new bypass surface for raw-SQL code. | Section 4.4: frozen 6 names, literal module id, whole-row equality, txn-local, scan T-11, retire follow-up F-RETIRE. |
| R4 | Pack grows 10 -> 16; ~10 existing tests need count edits; inactive runtime rows after fresh install (OQ-5). | Section 3. |
| R5 | A tenant lacking a runtime type (`types_absent`) can later define its own. | Reported; infra decides (OQ-5b). |
| R6 | Rolling deploy: new code on a tenant whose migration has not run. | Per-tenant `schema_migrations` check; Owner calls are harmless on unstamped tenants. |
| R7 | `owner_for!/1` computes the manifest hash per write. | F-MEMO. |
| R8 | A tenant type that copies every pack field name+type is stamped as exam-owned. | Accepted: harmless, the exam module becomes its only writer (6.2). |

## 13. Open questions

* OQ-1 RESOLVED: field-set (name + type) compatibility, section 6.2. No digest rule, no "relax later".
* OQ-4 Mix task exit code on conflicts: default 0 (printed, counted).
* OQ-5b Tenants with an absent runtime type: report only (default) vs a later reinstall/activation action.
* OQ-6 Bump exam manifest/pack version: default no (`BackfillExamTenantModules` pins `0.1.0`).
* OQ-7 Archived events (`events_archive`) are not scanned: default documented limit.
* Resolved by the ruling: OQ-2 (option C+A), OQ-3 (attachments out, #2582), OQ-5 (inactive rows, activation
  unchanged, section 3.2), OQ-8 (`Exam.Authoring` dropped).

## 14. Test list (ids binding; TEST-DESIGNER fixes file names)

Existing suites that must pass UNCHANGED (modulo the pack count edits in 3.4): exam session, scoring,
certificate, anti_cheat, exam_sessions; `entities_managed_by_test.exs`; `records_managed_by_test.exs`;
`managed_types_test.exs`; tenant provisioning manifest tests.

| Id | AC | Assertion |
|---|---|---|
| T-01 | AC1 | `Exam.manifest().manages_entity_types` as a set equals the literal 6 runtime names; every name satisfies `ManagedTypes.managed_name?/1`; `Catalog.validate/1` is `:ok`. Fails on main (key absent) |
| T-02 | AC1 | Completeness: the set of `priv/modules/exam/entity_definitions/*.json` basenames (excluding `README-constraints.md`) equals the `pack.json` `entity_definitions` names, equals (declared 6) UNION (an explicit test-local allowlist map of the 10 authoring names, each with a written reason "tenant-editable by ruling 2026-10-16 until the exam authoring write surface exists"); declared and allowlist are disjoint. A new pack/file type that is in neither fails the test, so a type cannot be silently unmanaged. Each pack entry's `definition_json` equals its source file (drift guard at 16). A fresh `Installs.install("exam", ...)` succeeds (no `managed_type_not_in_pack`) |
| T-03 | AC2 | R6 on the real tree + synthetic negatives (section 5.5) |
| T-04 | AC6 | Stamped tenant (content first, then `Stamp.run_tenant`): start session, save answer (path 1064), submit (1263 + scores), report anti-cheat event, issue certificate and re-issue idempotently: normal results, records persisted **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-05 | AC2 | Same tenant: `Records.create_record(session_attrs, prefix)` (`/2`) and an `Owner` for another module id both return `{:error, :entity_type_managed}`; no event |
| T-06 | AC2 | R1/T-17 expected set == updated `@authority_callers`; R2/T-19 caller set == fixture + the 3 exam files; the seed task test passes unchanged on a freshly installed (stamped) tenant (it writes authoring types only) |
| T-07 | AC3 | Trigger matrix on raw rows in a tenant schema, no setting: `NULL -> 'exam'` refused; `'exam' -> NULL`, `'exam' -> 'other'`, rename of a stamped row refused. **T-07..T-09b run OUTSIDE the Ecto sandbox transaction** (SECURITY F-1): a dedicated `async: false` case with `Ecto.Adapters.SQL.Sandbox` mode `:auto` (the mode `TenantFixture.provisioned_tenant!/1` already sets for real DDL, as in `backfill_exam_tenant_modules_test.exs`), real commits, and `on_exit` cleanup deleting the tenant, so each `Repo.transaction` really begins and ends the transaction under test; inside a sandbox-wrapped test "reset at commit" would be vacuous |
| T-08 | AC3 | With the setting `'exam'` in a transaction: `NULL -> 'exam'` succeeds on each of the 6; REFUSED on each of the 10 authoring names and on `org_unit`; `NULL -> 'other'` refused; `NULL -> 'exam'` combined with rename, status flip or `definition_json` change refused; `'exam' -> NULL`/`'other'` refused; setting `'other'` refused |
| T-09 | AC3 | (non-sandbox case) After commit and after rollback of a real transaction the setting reads NULL/empty in the same connection and a plain `NULL -> 'exam'` is refused again; both triggers `tgenabled = 'O'`. NESTED-transaction tests: (i) `Stamp.run_tenant/2` called inside an outer `Repo.transaction` returns `status: :failed, error: :nested_transaction` and writes nothing, then in the SAME outer transaction a raw `NULL -> 'exam'` on a runtime name is refused; same entry refusal for `TamperInventory.run_tenant/2`; (ii) the clearing statement: in an outer transaction the test sets the setting to `'exam'`, executes `set_config('letflow.managed_by_stamp', '', true)`, then a raw `NULL -> 'exam'` is refused (pins that `''` keeps the trigger closed, which is what `Stamp`'s last statement relies on) |
| T-09b | AC3 | down/up round-trip of `AllowExamManagedByStamp` (non-sandbox case): after `down` both triggers still reference `entity_definitions_managed_by_guard`, the function body equals the `20261014100001` body byte-for-byte, and `NULL -> 'exam'` is refused even with the setting; after `up` it works with the setting; `Stamp.run_tenant` between them reports `:exception_not_installed` |
| T-10 | AC3 | `AllowExamManagedByStamp.stamp_names/0` == `Stamp`'s frozen list == the literal 6, subset of the manifest set |
| T-11 | AC3 | The AST scan of section 4.3 (five assertions over `lib/`, `priv/`, `scripts/`, `config/`) with synthetic negatives per assertion (a concatenated or `$1`-bound setting name; `set_config` in a new file; a new non-literal `Repo.query` site outside the allowlist; a `Stamp.run/1` call from a router; an `update_all(set: [managed_by: ...])` elsewhere). The test moduledoc states: a tripwire, not a boundary |
| T-12 | AC3 | After the new migration: `POST /entities/definitions` with a `managed_by` key (and the activate route) leaves/gets NULL or a 422 exactly as REQ-496 T-08..T-11; no path sets or clears it |
| T-13 | AC3 | After the new migration: a pack install/import document carrying `managed_by`, and an install with `:tenant`, leave NULL / are rejected as in REQ-496 T-12..T-19; a stamped row cannot be unstamped through any exercised path |
| T-14 | AC4(b) | Case (b) b1 (FK-stripped legacy), b2 (pack-shaped), b3 (hand-posted) each stamp all 6 types; second run stamps 0 with no new audit entry; b4 certificate-absent variant. Stamped-tenant tests in general stamp fixture tenants with `Stamp.run_tenant` (tenant_modules row inserted directly), never via `Installs.install/3` on a fixture tenant (it would hit `managed_name_taken`) **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-15 | AC4(a) | Case (a) **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-16 | AC4(c) | Case (c): unrelated shape -> named conflict with tenant id + type, row untouched; wrong-type variant -> conflict; OLDER-VERSION variant (SECURITY F-3): `certificate` v1 incompatible (hostile shape) superseded by a compatible active v2 -> whole name `:shape_not_compatible`, NEITHER row stamped; reverse (compatible v1, incompatible v2) -> conflict; all versions compatible -> all rows stamped; continues with the next tenant (conflict tenant first); `:stamped_by_other_module`; a tenant `tag` untouched/unreported. Compatibility semantics through `run_tenant` dry-run: superset passes, missing field fails, enum/required/FK differences ignored but listed in `differences`; RACE variant (SECURITY F-4): `after_precheck` creates, via `Definitions.create_definition/2` (`:tenant`) in that tenant, an incompatible NEW VERSION of `certificate` AFTER the advisory pre-pass found `certificate` compatible and BEFORE the transaction -> the real run reports `certificate` as `:shape_not_compatible` (classification happens under the name locks), NO row of `certificate` is stamped, the other 5 are; the same hook creating the incompatible version in a SECOND connection while the stamp holds the locks blocks on the `496_001` lock (assert it only completes after commit and is then refused as managed for the stamped names) **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-17 | AC4(d) | Case (d), incl. `exam_named_types_present` and `:exception_not_installed` (delete the tenant's `schema_migrations` row for `20261016120001`) **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-18 | AC3 | Dry run writes nothing (definitions and audit identical) and reports the rows it would stamp plus `differences` (names only: a stampable `certificate` with extra tenant fields and a differing `required` lists them, no values); `run(module: "other")` -> `{:error, :unsupported_module}`; the audit entry has `action "entity_type.managed_by_stamped"`, names and counts, no `definition_json`; the 10 authoring rows are byte-identical after a real run **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-19 | AC3 | Failure isolation: a row lock held on a runtime definition row by a second connection + `lock_timeout_ms: 200` -> that tenant `:failed, error: :lock_timeout`, nothing stamped, other tenants stamped, task exit non-zero; a re-run after release stamps it. Mix task `--dry-run`, bad args -> usage, conflict lines **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-20 | AC5 | 403 matrix of 10.1 (6 types x POST/PUT/DELETE/import x write-permission user and TENANT_ADMIN); record unchanged; no new event |
| T-22 | AC8 | Reads unchanged (10.3) on a stamped tenant |
| T-23 | AC5 control | Section 10.2: the 10 authoring types remain writable via generic routes for both caller kinds on a stamped tenant; an unrelated unmanaged type likewise |
| T-24 | AC7 | Inventory (scope `:runtime`): one real module write (candidate starts a session) and one generic write (admin `POST /entities/records/session_answer` with a client key, on an unstamped tenant) -> only the generic event listed, `evidence: :client_key`; the module's `session`/`session_question` events absent **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-25 | AC7 | Evidence variants: a keyless admin write of a `session_answer` for another user's session -> `:non_owner_actor`; an import -> `:import_key`; a legacy raw key -> `:unrecognised_key_shape`; an authoring-type write is absent under `:runtime` and listed as `:authoring_type` under `:authoring`/`:all` **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-26 | AC7 | Read-only: row counts/checksums of `events`, `entity_record_latest`, `entity_definitions`, `audit_entries` identical before/after; a write attempted inside the inventory's transaction is refused (`read_only_sql_transaction`); the source has no insert/update/delete call; findings have no `field_values` key Payload minimisation: the module's SQL text never selects the `payload` column (scan of the query source), and with `ExUnit.CaptureLog` at debug level over a full inventory run no log line contains `field_values` or any payload bytes (seeded payload values include a unique marker string; assert the marker is absent from all captured logs and from the returned findings). **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-27 | AC7 | Blind-spot characterization: a keyless generic write by the session's own user is NOT listed **Runs outside the Ecto sandbox** (`async: false`, `Ecto.Adapters.SQL.Sandbox` mode `:auto` via `TenantFixture.provisioned_tenant!/1`, real commits, `on_exit` tenant cleanup), because `Stamp`/`TamperInventory` refuse to run inside a transaction (F-1). |
| T-28 | all | TEST-RUNNER/RELEASE-VALIDATOR: full `mix test`, `mix letflow.check`, `mix letflow.check_boundaries`, `mix letflow.permission_matrix --check`, real output quoted |

(T-21 of the first draft, attachments, is dropped by the ruling.)

## 15. Files touched

Changed: `lib/letflow/modules/exam/exam.ex` (manifest key), `session.ex`, `certificate.ex`,
`anti_cheat.ex` (Owner helper + 5 call sites), `priv/modules/exam/pack.json`, `generate_pack.exs`,
`lib/letflow/tenant_provisioning.ex` (manifest entry/count), `test/letflow/entities/managed_types_callers_test.exs`
(5.5), `lib/letflow/entities/managed_types.ex` (moduledoc paragraph only), the pack-count tests of 3.4.
New: `priv/repo/migrations/20261016120001_allow_exam_managed_by_stamp.exs`,
`lib/letflow/entities/managed_types/stamp.ex`, `lib/letflow/entities/managed_types/tamper_inventory.ex`,
`lib/letflow/release/managed_types.ex`, `lib/mix/tasks/letflow.stamp_managed_types.ex`,
`lib/mix/tasks/letflow.managed_types_tamper_inventory.ex`, new test files. Docs: 0050 D7 note, REQ-496
design D3 amendment (DOC-UPDATER).
Unchanged: `routers/entities.ex`, `records.ex`, `catalog.ex`, `authorization.ex`, `mix.exs`, `config/*`,
the seed task, `test/support/exam_fixtures.ex`. No `Exam.Authoring`.

## 16. Invariants

* I1 A stamped `entity_definitions` row cannot change its stamp, name or tenant, or be deleted (D3).
* I2 The ONLY post-insert stamp write is `NULL -> 'exam'` on a frozen runtime name, by `Stamp`, inside a
  transaction that set `letflow.managed_by_stamp = 'exam'`, row otherwise unchanged. The 10 authoring
  names can never be stamped by it.
* I3 Every exam module record write passes the exam `Owner`; no `Records` write from the exam directory is
  `:tenant` (R6).
* I4 A re-run of the stamp writes and logs nothing.
* I5 The inventory writes nothing and discloses no field values.
* I6 No stamp or inventory query runs without an explicit tenant `prefix`.

## 17. Supervisor requirement: session snapshot, authoring-write audit, alert

### 17.1 Does a session snapshot the exam and questions, and does scoring read only it? NO.

What a session stores at start (`session.ex`, `materialize_session/5`):

* `session` record (`session.ex:748-756`): `exam_id`, `user_id`, `status`, `seed`, `started_at`,
  `expires_at`, `passed`. `expires_at` is computed once from the exam's `time_limit_minutes`
  (`session.ex:746`), so the time limit is effectively snapshotted. No exam version, no content hash, no
  threshold, no title.
* `session_question` records (`session.ex:900-905`, `write_question_rows/4`): `session_id`,
  `question_id`, `sort_order`, `options_order`. Only IDs and an option order: no question text, type,
  answer key, weights, version or hash. The seed (`session.ex:751`) plus the shuffle result freeze WHICH
  questions and the option order.

Live reads of authoring data during scoring, grading and certification (every one traced):

| # | Read | Where | Authoring type | What it decides |
|---|---|---|---|---|
| L1 | `build_question_row/2` -> `Latest.get(question_id, "question", prefix)` | `session.ex:1190-1191` | `question` | question `type`, picks the scoring clause |
| L2 | same function -> `query_all("answer_option", [eq("question_id", ...)])` | `session.ex:1193` | `answer_option` | `is_correct` -> `correct_option_ids` (`session.ex:1196-1197`); `likert_weight`/`likert_polarity` (`session.ex:1200-1206`). THE ANSWER KEY |
| L3 | `passing_threshold_for/2` -> `Latest.get(exam_id, "exam", prefix)` | `session.ex:1225-1229` | `exam` | `passing_score_pct`; if the exam row is missing the code silently uses `60.0` |
| L4 | `Scoring.score_session(questions, answers, passing_threshold)` | `session.ex:1141`, `scoring.ex` | none | PURE: `scoring.ex` has no `Repo`/`Records` call; it scores exactly the rows L1-L3 hand it |
| L5 | `Certificate.fetch_exam/2` -> `Latest.get(session.exam_id, "exam", prefix)` | `certificate.ex:290-291` | `exam` | `certificate_enabled` gate (`certificate.ex:313`, live) and `exam_title` (`certificate.ex:328`, copied INTO the certificate) |
| L6 | session-state display `build_question_state` / `build_option_states` | `session.ex:440-458` | `question`, `answer_option` | the stem and option text the candidate sees; not scoring, but changes mid-session |
| L7 | start-time gates | `session.ex:282-286` (`check_exam_status`, availability dates, `max_attempts`) | `exam` | admission at start (intended live) |

NOT live (safe once written): `score_pct`, `passed`, `status`, `submitted_at` are stored on the `session`
at submit (`session.ex:1245-1260`); each question score is a `session_question_score` record; the
certificate record stores `session_id`, `issued_at`, `candidate_name`, `exam_title`, `score_pct`,
`branding_snapshot` (`certificate.ex:324-331`); `certificate_document.ex` is "a pure function of its
input", no `Repo` call (`certificate_document.ex:46`); the public projection reads the certificate record
only (`certificate_public_projection.ex:62`). "Still grading" (`:grading_pending`, short-text) has NO
resolving code path in `lib/` (the only files naming it are `certificate.ex`, `router.ex`, `scoring.ex`,
`session.ex` and the seed task, which set or refuse it), so no live read exists there today. Scoring runs
exactly once: at submit (`session.ex:578`) or lazily at the first access after the deadline
(`session.ex:612`, auto-submit).

Consequence: until a session is scored, an edit to the answer key (`answer_option.is_correct`,
`likert_*`), a question `type`, or the exam `passing_score_pct` changes that session's outcome. The window
runs from session start to first scoring (for an expired session, until someone next touches it). After
scoring, stored results are immune to authoring edits (and, after this PR's stamp, to generic writes).
With the authoring types unmanaged by ruling, this is residual risk R1.

Recommendation (inside #2596 or a blocking prerequisite?): a BLOCKING PREREQUISITE ISSUE that gates infra
step 4 (the stamp), not the code PR. Why not inside #2596: it needs new definition fields (new shape
versions of `session`/`session_question` that every live tenant must receive and activate: a definition
rollout, not just code), answer-key fields inside a candidate-readable type (needs
`entity_field_restrictions` seeding as `Exam.on_install/2` does for `answer_option`), a policy for
in-flight sessions without a snapshot, and changes to materialize, scoring and certificate. Folding that
into a priority-1 security PR that already carries a DB trigger exception widens review and delays the fix
for the reported hole (post-submission tampering of stored results), which the stamp closes independent of
the snapshot. Size estimate: L, two PRs. Design sketch for the prerequisite:

* Stored at session start, in the same transaction as the session rows: on `session`, an `exam_snapshot`
  JSON field (`passing_score_pct`, `certificate_enabled`, `title`, `time_limit_minutes`,
  `exam_content_hash`, `exam_def_version` = the exam record's `entity_def_version`); on each
  `session_question`: `question_type`, `correct_option_ids`, `likert_options` (id -> weight, polarity),
  `question_content_hash`, `question_def_version`. Hash = SHA-256 over the canonical JSON of the record's
  `field_values` (`Records` already has `canonical_json/1`).
* Scoring (`build_question_row/2`, `passing_threshold_for/2`) and `certificate.ex` read ONLY the snapshot;
  the `60.0` fallback is removed (no threshold fails closed).
* Legacy/in-flight sessions without a snapshot: scored from live rows as today and flagged in the result;
  rollout drains or snapshots them.
* The new answer-key fields get `entity_field_restrictions` rows for `session_question`; whether the
  candidate view keeps reading stem/option TEXT live is that issue's decision.

### 17.2 Are generic authoring-type writes audited with the actor? As events, not audit entries.

* There is NO `audit_entries` row for record writes: `grep "Audit\." lib/letflow/entities/records.ex
  lib/letflow/routers/entities.ex` is empty.
* Every create/update/delete appends an `events` row in the tenant schema (`EventStore.append_multi`,
  `records.ex:805-806`) with the actor: `to_append_attrs/4` sets `actor_id: attrs.actor_id` and
  `idempotency_key` (`records.ex:846-853`); create and update carry the FULL new document in the payload
  (`records.ex:821-823`, `Map.put("field_values", ctx.field_values)`). The router takes `actor_id` from
  the authenticated caller (`entities.ex:976-979`, `conn.assigns.auth_context.user_id`). So an answer-key
  edit through `PUT /entities/records/answer_option/:id` is recorded with actor, timestamp
  (`events.created_at`) and the complete new `field_values` (the previous state is the prior event of that
  record). Events are append-only (`event.ex` moduledoc) but not hash-chained like `audit_entries`, and
  retention can move old rows to `events_archive` (OQ-7).
* Not recorded: the route taken (F4), request trace/IP, a before/after diff; nobody is alerted.

### 17.3 Proposed alert/report (follow-up F-ALERT, may be a separate issue)

A read-only report, a sibling of the section 8 inventory: "edits to an exam that has sessions in progress
or in grading". Per tenant, list authoring events (`exam`, `exam_section`, `exam_question_rule`,
`exam_question_rule_tag`, `exam_manual_question` by `field_values.exam_id`; `question` and `answer_option`
via the `session_question.question_id` of the sessions' questions) whose `events.created_at` is later than
a session's `started_at`, where that session is still `in_progress` or `grading_pending` (or was scored
after the event). Output: tenant, authoring type, record id, event type, actor id, event time, affected
session ids. Run on a schedule; a non-empty result raises an alert or log line (channel is that issue's
decision, OQ-10). Once the snapshot prerequisite lands the report is informational only.

### 17.4 Note only: narrowing who can write the authoring types

Restricting WHO may write the authoring types via `entity_type_restrictions` +
`user_entity_type_grants` is optional hardening; per 0050 D7 those grants govern reads only, so using them
for writes would be a new mechanism. Noted, not designed, not in this PR. The authoring types stay
UNMANAGED.

### 17.5 Supervisor ruling on the snapshot (binding) and the in-flight policy

* The content snapshot is a SEPARATE priority-1 prerequisite issue (filed by letflow-2; owner after this
  PR: letflow-9c). It gates the infra STAMP (section 9 step 4), NOT this code PR. This PR may merge "dark":
  the manifest, pack, Owner calls, trigger exception, `Stamp` and inventory ship, but infra does not
  request the stamp on QA/BilimBaga/prod until the snapshot issue has landed. Fresh exam installs stamp
  the 6 types at install regardless (their sessions start after install, and the snapshot issue changes
  session start for all tenants).
* PR-body text (verbatim intent): "This PR does not change how sessions are scored. Scoring still reads
  the live answer key, pass threshold and question type (design section 17.1), and the authoring types stay
  tenant-editable by ruling. The infra stamp must not be requested until the separate session-content
  snapshot issue (priority 1) has landed. The tamper inventory and the stamp dry-run may be run earlier."
* In-flight policy for the snapshot issue (decided): LAZY SNAPSHOT AT FIRST TOUCH. On the day the snapshot
  ships, a session that is `in_progress` and has no snapshot gets one at its next touch (get state,
  autosave, submit, or the deadline auto-submit), built from the live authoring rows under the existing
  session row lock (`lock_session_row/2`) and stored with `snapshot_origin: "late"` plus the time taken;
  sessions started after the ship day store `snapshot_origin: "start"`. Scoring ALWAYS goes through
  that same ensure-snapshot step first, so after the ship day no scoring path reads live authoring rows;
  there is no unsnapshotted scoring. A `grading_pending` session is already scored (its scores are stored)
  and needs no snapshot. Why lazy-at-first-touch and not a release-time backfill or lazy-at-scoring:
  (a) every scoring path is a touch (submit, lazy expiry), so nothing escapes; (b) no bulk job, no extra
  lock traffic and no second tool to run on deploy day; (c) it narrows the exposure window to "until the
  candidate's next action" instead of "until scoring"; (d) the `"late"` flag lets the F-ALERT report and
  a review list exactly which sessions were snapshotted from live data after an authoring edit may have
  happened. Honest limit: a late snapshot cannot undo an edit made before the touch, so `"late"` sessions
  keep the residual risk; they drain within the exam time limit (sessions are time-boxed by
  `expires_at`).

Open questions added: OQ-10 alert channel. (OQ-9 is RESOLVED by the ruling above.)
