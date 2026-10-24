# GH #2596 test spec: exam runtime/result types managed, stamped on existing installs, exam writes pass the Owner

Design: `lib/letflow/design/gh2596-exam-managed-types.md` (CDV PASS r3; SECURITY design PASS incl. F-1..F-4,
B-1..B-3). Code gates: SECURITY-REVIEWER PASS (step 07), REVIEWER PASS (step 08). Run
`WF02-GH2596-EXAM-MANAGED-20261016`, step 09 (TEST-DESIGNER). Test ids T-01..T-28 are the design's section 14.

**Scope ruling (supervisor, 2026-10-16, supersedes "ALL 16").** The manifest manages ONLY the six runtime/result
types (`session`, `session_question`, `session_answer`, `session_event`, `session_question_score`,
`certificate`). The ten authoring types stay UNMANAGED so the BilimBaga/QA admin UI keeps authoring them through the
generic `/records` routes. Every "all types" wording of the issue is read as "the six". Attachment routes are out
(#2582). Scoring still reads live authoring rows (design 17); the infra stamp is gated on a separate snapshot issue,
not on this PR.

## Files

New:

| File | Ids |
|---|---|
| `test/letflow/modules/exam/exam_managed_manifest_test.exs` | T-01, T-02 |
| `test/letflow/entities/managed_types/stamp_trigger_test.exs` | T-07, T-08, T-09, T-09b, T-10 |
| `test/letflow/entities/managed_types/stamp_opener_scan_test.exs` | T-11 (+ synthetic negatives per assertion) |
| `test/letflow/entities/managed_types/stamp_test.exs` | T-14..T-19, T-16 race variants, Mix task, wrapper |
| `test/letflow/modules/exam/exam_stamped_tenant_test.exs` | T-04, T-05 |
| `test/letflow/routers/exam_managed_types_http_test.exs` | T-12, T-13, T-20, T-22, T-23 |
| `test/letflow/entities/managed_types/tamper_inventory_test.exs` | T-24..T-27 |
| `test/support/exam_stamp_fixtures.ex` | shared fixtures (b1/b2/b3 tenants, dumps, audit count) |

Changed: `test/letflow/entities/managed_types_callers_test.exs` (T-03 R6, T-06 R1/R2 expected sets),
`test/letflow/modules/exam/pack_install_test.exs` (pack 10 -> 16), `test/support/exam_fixtures.ex`
(`activate_exam_definitions_after_pack_install!/1`), `test/letflow/modules/bilimbaga_solution_e2e_test.exs` (uses it;
see "Existing tests" below).

**Sandbox note.** Everything that calls `Stamp` or `TamperInventory` runs OUTSIDE the Ecto sandbox transaction:
`async: false`, and `TenantFixture.provisioned_tenant!/1` (or `Letflow.ExamFixtures`) switches
`Ecto.Adapters.SQL.Sandbox` to `:auto`, which checks in the case's own sandbox checkout, so `Repo.in_transaction?()`
is false in the test process, every `Repo.transaction/1` really begins and commits, and "the setting resets at commit"
is not vacuous (SECURITY F-1). Teardown is the fixtures' `on_exit` (schema drop, registration/tenant delete, global
pack-install rows).

## Acceptance criteria -> tests
> **Superseded in part by GH #2680 slice 3 (the AC1 row below):** the manifest now declares sixteen names
> (the six runtime/result types and the ten authoring types). The ten-name allowlist of the 2026-10-16
> unmanaged-authoring ruling is gone, and T-01 and T-02 pin the sixteen. The AC1 row is kept as the record of that ruling.


| AC (issue, read through the ruling) | Tests | Why it exists |
|---|---|---|
| AC1 Manifest declares exactly the six; the ten authoring types stay in the pack and unmanaged; a new pack type must be classified | T-01 (3 tests), T-02 (5 tests) in `exam_managed_manifest_test.exs` | T-01 pins the declared SET to the literal six and validates the manifest; T-02 proves source files == pack entries == declared six UNION the ten-name allowlist, that every declared name is in the pack (else every fresh install fails `managed_type_not_in_pack`), and a synthetic negative shows a new type, or a dropped declared name, is reported by `unclassified/3` |
| AC2 Every exam write passes the exam `Owner`; scan updated | T-03 (3 tests, R6 real tree + synthetic), T-06 (R1 `@authority_callers` incl. the three exam writers, non-vacuous site list; R2 caller set = three exam files + fixture) in `managed_types_callers_test.exs`; T-04, T-05 in `exam_stamped_tenant_test.exs` | The scan pins the static property (no `/2`, no `:tenant` literal under `lib/letflow/modules/exam/`); T-04/T-05 prove it dynamically: the five `Records` write sites only succeed on a stamped tenant if they really pass the Owner, and a plain `/2`, `:tenant`, or foreign/forged Owner is refused with no event |
| AC3 platform stamp: single exception, narrow, idempotent, per-tenant report, wrapper | T-07, T-08, T-09, T-09b, T-10 (`stamp_trigger_test.exs`); T-11 (`stamp_opener_scan_test.exs`); T-18, T-19 (`stamp_test.exs`) | Trigger matrix on raw rows (what the DB permits, with and without the setting, on six vs ten vs other names, combined mutations, wrong values), transaction lifetime and the nested-transaction refusal, the migration down/up round trip with a byte comparison of the restored body, the three frozen name lists, the opener tripwire, dry run writes nothing, audit entry holds names and counts only, `unsupported_module`, wrapper drops the test seam |
| AC3 sub: definitions API and import cannot stamp/unstamp | T-12, T-13 (`exam_managed_types_http_test.exs`) | After the exception exists: `POST /definitions` and `/activate` with and without a `managed_by` key leave stamps untouched; pack documents carrying `managed_by` are rejected; a tenant install over stamped names changes nothing |
| AC4 migration cases (a)-(d) | T-15 (a), T-14 (b1/b2/b3/b4), T-16 (c, incl. older-version F-3 variants and F-4 races), T-17 (d, `:exception_not_installed`) in `stamp_test.exs` | Four builds of the "installed before" state (FK-stripped legacy, pack-shaped, hand-posted, certificate absent), conflicts by unrelated shape / wrong type / missing field / other-module stamp, all-or-nothing per name across versions, the in-lock re-classification, the name-lock serialization with a second connection, tenants without exam untouched |
| AC5 generic POST/PUT/DELETE/import on each of the six -> 403 `entity_type_managed`, TENANT_ADMIN included, record unchanged; fails on main | T-20 (3 tests) | 6 types x {POST, PUT, DELETE} x {write-permission role, TENANT_ADMIN} + import (admin), byte-equal constant body, record unchanged, `POST /query` returns the pre-stamp items, no `ENTITY_RECORD_*` event. On main the six are unmanaged so these writes succeed and the tests fail |
| AC5 control (ruling): the ten authoring types stay writable | T-23 (2 tests) | The ruling's whole point: both caller kinds can POST/PUT/DELETE/import every authoring type on a stamped tenant; the stamp left their rows byte-identical and NULL |
| AC6 exam paths keep working on a stamped tenant | T-04 | Full candidate flow (create session, save answer on the create AND update paths, anti-cheat signal, submit with scores, issue + idempotent re-issue certificate) on a stamped tenant; the existing session/scoring/certificate/anti_cheat suites run UNCHANGED on unstamped tenants |
| AC7 read-only tamper inventory | T-24, T-25, T-26, T-27 (`tamper_inventory_test.exs`) | Module vs generic write (only the generic one listed), every evidence value, scope option, cap, wrapper and Mix task, strict read-only (row digests, telemetry capture shows `SET TRANSACTION READ ONLY` right after `begin` and no write statement, no write call in the module source), no payload (select list contains only JSON key extractions, finding key set is fixed, a unique payload marker is absent from findings and debug logs), blind-spot characterisation |
| AC8 reads unchanged | T-22 (2 tests) | query, aggregate, definitions read, and the answer-key field restriction all behave on a stamped tenant |
| T-28 full suite / checks | TEST-RUNNER / RELEASE-VALIDATOR | not run by TEST-DESIGNER (instructed: only new and directly affected files) |

## Test list (what each proves and why it exists)

* **T-01 / T-02** (`exam_managed_manifest_test.exs`): manifest set, name format, `Catalog.validate/1`, manifest and pack
  versions unchanged (OQ-6), source files == pack == declared UNION allowlist (16), drift guard per entry, every declared
  name in the pack, and a real `Installs.install("exam", ...)` succeeds.
* **T-03** (`managed_types_callers_test.exs`, describe "GH #2596 T-03"): R6 over `lib/letflow/modules/exam/**` on the
  real tree, with synthetic negatives (`/2`, piped `/2`, `:tenant` literal, `:tenant` piped) and positives (a `/3` with a
  variable, files outside the directory).
* **T-04 / T-05** (`exam_stamped_tenant_test.exs`): dynamic proof of the five call sites; the genuine exam Owner
  writes, a forged "other module" Owner and a forged Owner claiming all six names both fail.
* **T-06** (`managed_types_callers_test.exs`): `@authority_callers` now lists the three exam writers (R1 stays
  non-vacuous: the exact site list is asserted: 2x `update_record` + 1x `create_record` in `session.ex`, one create each in
  `certificate.ex` and `anti_cheat.ex`); R2 caller set = the three exam files + the fixture.
* **T-07 / T-08** (`stamp_trigger_test.exs`): raw `UPDATE` matrix. T-07: no setting, NULL -> 'exam' refused; stamped row
  cannot be cleared, re-stamped, renamed or deleted, even with the setting; status flip still allowed. T-08: with the
  setting `'exam'`: allowed on each of the six; refused on each of the ten authoring names and `org_unit`; refused for
  another module id, another/empty/upper-case setting value; refused when the same statement also changes `name`,
  `status`, `display_name`, `definition_json`, `content_hash` or `tenant_id` (whole-row equality condition).
* **T-09**: setting closed after commit and after rollback in the SAME connection; both triggers `tgenabled = 'O'`;
  `Stamp.run_tenant/2` and `TamperInventory.run_tenant/2` inside an outer transaction return the typed refusal and a
  plain stamp in that outer transaction is still refused; `set_config(..., '', true)` keeps the branch closed.
* **T-09b**: `AllowExamManagedByStamp` down then up through `Ecto.Migrator.run/4` with the tenant prefix: the migration's
  `down` text equals the `20261014100001` body (extracted from both files), the restored `prosrc` equals it byte for byte,
  triggers still point at the same function, the setting does nothing while down, `Stamp` reports
  `:exception_not_installed`, up restores the exception.
* **T-10**: migration `stamp_names/0` == `Stamp.stamp_names/0` == the literal six, subset of the manifest; the function
  body's `ARRAY[...]` holds exactly the six.
* **T-11** (`stamp_opener_scan_test.exs`): five AST assertions + forbidden DDL, each a pure function fed by the real tree
  and by synthetic negatives of every literal form (plain, concatenated, interpolated, heredoc, `~s`, `~S`, `~r`,
  charlist, `fragment/1`), a bound setting name (`set_config($1, ...)`), a new dynamic-SQL file, a router calling
  `Stamp.run`, a qualified/captured/`apply` form, an `update_all`/`Changeset.change |> Repo.update` writing `:managed_by`,
  and `DISABLE TRIGGER` / `session_replication_role` / `ALTER TABLE ... DISABLE`. **A tripwire, not a boundary** (any raw
  SQL as the app DB role can still `set_config`). The one real-tree finding the first run produced: the dynamic-SQL file
  list (16 files) was regenerated from the tree and is quoted in the test; the migration FILE NAME in
  `TenantProvisioning`'s manifest is explicitly not counted as a spelling of the setting.
* **T-12 / T-13**: see AC table.
* **T-14..T-17** (`stamp_test.exs`): see AC4 row. Variants quoted: b1 legacy, b2 pack-shaped, b3 hand-posted, b4
  certificate absent; unrelated shape; wrong type (`score_pct: string`); missing field; superset passes; older-version
  (hostile v1 then compatible v2, compatible v1 then hostile v2: whole name conflicts, neither row stamped; all
  compatible: all rows stamped, 7 rows); `:stamped_by_other_module`; a tenant `tag` untouched and unreported; a full
  `run/1` sweep with a conflicted tenant and a clean one; no exam (with and without an unrelated `session`) with
  `exam_named_types_present`; `:exception_not_installed` then restore.
* **T-16 race variants**: (1) `after_precheck` creates an incompatible NEW version of `certificate` after the advisory
  pre-pass and before the transaction: the real run reports `:shape_not_compatible`, no `certificate` row stamped, the
  other five are; (2) a second connection holds a row lock, the stamp waits on it while holding the `496_001` name
  locks, a third connection creating an incompatible `certificate` version blocks (two backends observed waiting in
  `pg_stat_activity`), and after the commit that create is refused `:entity_type_managed`.
* **T-18**: dry run writes nothing (row dump, audit count, stamps) and reports `differences` by NAME only; unsupported
  module; the audit entry has `actor_id` nil, `resource_id` = tenant id, exactly the keys `conflicts module rows_stamped
  source types_stamped`, no `definition_json`/`fields`; the ten authoring rows byte-identical.
* **T-19**: a row lock held by a second connection with `lock_timeout_ms: 200` fails THAT tenant (`:lock_timeout`),
  nothing stamped, the other tenant stamped, a re-run after release completes; the release wrapper drops
  `after_precheck` and `lock_timeout_ms` (a raising seam is passed and never runs); Mix task `--dry-run` prints the summary
  and a conflict line and stamps nothing, bad arguments / unsupported module raise the usage. **Not exercised in-VM:**
  the `System.halt(1)` on a failed tenant (it would kill the test VM); the condition (`report.failed_total > 0`) is
  asserted on the report instead.
* **T-20 / T-22 / T-23**: see AC table.
* **T-24..T-27**: see AC7 row.

## Existing tests updated

* `pack_install_test.exs`: `@entity_types` split into `@authoring_types` (10) and `@runtime_types` (6); counts 10 -> 16 at
  the pack-shape test and the `installed_entity_definitions` assertion; the real-install flow still activates and exercises
  only the ten (the six are installed inactive, as the design's OQ-5 decides).
* `managed_types_callers_test.exs`: described above.
* `bilimbaga_solution_e2e_test.exs`: after the real `POST /tenant/solutions` install the six runtime definitions are
  now stamped, so the fixture's `Definitions.create_definition/2` (`:tenant`) of them is refused
  (`:entity_type_managed`, observed: `right: {:error, :entity_type_managed}` at `exam_fixtures.ex:254`). The test now calls
  `ExamFixtures.activate_exam_definitions_after_pack_install!/1`, which creates + activates the authoring versions and
  ACTIVATES the pack's own stamped runtime rows. Also removed one unused alias (`Definitions`) that already failed
  `--warnings-as-errors` on `main`.
* `test/mix/tasks/letflow.seed.exam_fixtures_test.exs` (NOT in the design's 3.4 list; design T-06 expected it to pass
  unchanged): its setup pre-activated tenant-owned `session` etc. and then the task's own `Installs.install("exam")` failed
  with `{:pack_install_failed, {:managed_name_taken, "session"}}` (5 of 5 tests red, observed). The setup now installs the
  exam module first and calls `activate_exam_definitions_after_pack_install!/1`; the task then takes its documented
  `:already_installed` path and the module's own session path runs on stamped definitions. 5/5 pass. This is a
  consequence of the design (a tenant that already defines a managed name cannot install the module), not an
  implementation bug, but any script that pre-creates tenant-owned `session` definitions before installing exam breaks.
* Design 3.4 files checked but needing no edit: `entity_definitions_test.exs` (reads the JSON files, no pack count),
  `solution_packs_module_owned_pack_test.exs`, `solution_pack_bilimbaga_field_restrictions_test.exs`,
  `tenant_solutions_test.exs`, `tenant_auditor_routes_test.exs`, `on_install_test.exs`,
  `install_activation_test.exs`, `ci_backend_path_filter_test.exs` (see the run results in the handoff).

## Mutants for TEST-DESIGN-VALIDATOR

Four mutants, each one edit, with the tests that must fail. **Not applied by TEST-DESIGNER** (instructed not to edit
`lib/` or `priv/`); the failing sets below are derived by reading the assertions against the mutated code, so TDV must
apply and measure them itself.

| Id | Mutant (revert after) | Tests that must go red |
|---|---|---|
| M1 trigger accepts a non-exam value | `priv/repo/migrations/20261016120001_allow_exam_managed_by_stamp.exs` `up`: replace `AND NEW.managed_by = 'exam'` by `AND NEW.managed_by IS NOT NULL` (so NULL -> any module id opens). Variant M1b: delete the `AND NEW.name = ANY (ARRAY[...])` line | M1: `stamp_trigger_test` T-08 "refused for another module id..." (NULL -> 'other' allowed). M1b: T-08 "refused on each of the ten authoring names and on org_unit" and T-10 "function body's literal array holds exactly those six names" |
| M2 stamp skips the in-transaction classification | `stamp.ex` `real_run/6`: use the advisory classification (computed before the transaction) instead of re-classifying the locked rows (e.g. pass `advisory` in and skip `classify(rows, ...)`) | `stamp_test` "RACE (SECURITY F-4): an incompatible NEW version created after the advisory pre-pass..." (the incompatible new version rides into an immutable stamp) |
| M3 owner omitted at an exam call site | `certificate.ex` (or `anti_cheat.ex`, or the `write_record/4` in `session.ex`): drop `exam_owner()` from the `Records.create_record(...)` call. (Also leaves `exam_owner/0` unused: with `--warnings-as-errors` compile itself fails; keep a `_ = exam_owner()` to isolate the behavioural effect) | `exam_stamped_tenant_test` T-04 (the flow returns `{:error, :entity_type_managed}` on the stamped tenant); `managed_types_callers_test` T-17 (R1 file list no longer equals `@authority_callers`), "GH #2596 T-06" (site list), and the R6 real-tree test |
| M4 inventory lists module writes | `tamper_inventory.ex` `suspicious?/5`: make the predicate unconditionally true (drop the key-shape and owner conditions) | `tamper_inventory_test` T-24 (the module's `session`/`session_question` events are listed), T-26 first test (`assert [_] = findings`), T-27 (`report.findings == []`), T-25 count assertions |

Further mutants worth trying if time allows: remove the `Repo.in_transaction?()` guard from `Stamp.run_tenant/2` (T-09
nested test, T-09b is unaffected); add an authoring name to `Stamp`'s `@stamp_names` (T-10, T-11 assertion
consistency); make a dry run write (T-18). **Known unkilled mutant:** deleting the LAST `set_config('letflow.managed_by_stamp',
'', true)` clearing statement in `Stamp.real_run/6` changes nothing observable (the transaction ends right after); it is
defence in depth for a joined outer transaction that the entry guard already makes unreachable. T-09 (ii) pins only the
trigger side (`''` keeps it closed).

## Limits (stated, not hidden)

* Attachment write routes on the six types stay open (#2582): not tested here by ruling.
* The scan is a tripwire, not a boundary; raw SQL as the app DB role can still open the exception.
* The Mix tasks' `System.halt(1)` path is not run in-VM.
* Archived events (`events_archive`) are not scanned by the inventory (OQ-7); the keyless generic write by the session
  owner is the documented blind spot (T-27 characterises it, it is not a guarantee).
* The sweep tests (`Stamp.run/1`) run over every registered tenant of the test database; assertions pick this test's own
  tenants by schema name.
