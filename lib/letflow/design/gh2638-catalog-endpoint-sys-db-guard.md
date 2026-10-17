# GH #2638: database backstop for the catalog `endpoint_url` `_sys` refusal

Author: CODE-DESIGNER, 2026-10-17. Branch `fix/GH-2638-catalog-sys-db-guard`, from `main` `50836162`
(#2637 / GH #2623 merged as `26e6cdbd`). Design only: signatures, SQL patterns, test briefs; no bodies.
Parent design: `lib/letflow/design/gh2623-catalog-endpoint-url-sys-refusal.md` (the changeset refusal).

## Changelog

* Revision 0 (2026-10-17): first design.
* Revision 1 (2026-10-17): CODE-DESIGN-VALIDATOR FAIL, 3 blockers, applied. (1) A THIRD existing test breaks
  (`admin_services_reserved_endpoint_test.exs:134-146`); sections 0, 5, 6 (T5) and R2 corrected and ELIXIR-DEV must
  grep `test/` for every raw write. (2) T1 now specifies the migration-run mechanism (`Ecto.Migrator.run/4`, global,
  explicit migration list), restoration and cleanup. (3) T2 now names the exact pattern extraction
  (`pg_get_constraintdef`) and the bound-parameter verdict. Nits: 2.1 states why the pattern departs from the issue
  text; T6 scoped; pre-flight uses the same quoted pattern attribute. Validator rulings on OQ-1..OQ-6 recorded in
  section 8 as DECIDED.

## 0. Verified facts on `main` `50836162`

| Fact | Where |
|---|---|
| Both tables are GLOBAL (no `prefix:`, not in the tenant-scoped migration manifest). One migration, one copy, no `if prefix() do` guard, no template-tenant-schema replay. | `20260830000001_create_service_catalog.exs` header; `20260921000004_add_service_catalog_versioning.exs` header |
| `service_catalog.endpoint_url` `NOT NULL`, only CHECK on it today `chk_service_catalog_endpoint_url_length` (`char_length <= 2048`). `service_catalog_versions.endpoint_url` `NOT NULL`, NO check at all. | the two migrations |
| Writers of `service_catalog`: `ServiceCatalog.register/1` (`Repo.insert`, `service_catalog.ex:~246-253`, `Entry.insert_changeset/2`); `publish/3` (live-row update through `Entry.publish_changeset/2`); `retire/1` (`retire_changeset/1`, does not touch `endpoint_url`); `update_scope/2` (`update_scope_changeset/2`, casts only scope/owner); `delete/1` (`Repo.delete_all` on versions, delete of the entry). Test-only: `test/support/tenant_schema_reaper.ex` raw `DELETE FROM service_catalog`. | `lib/letflow/service_catalog.ex`; `git grep` over `lib priv test/support config scripts` found no `insert_all`, `update_all`, raw `INSERT/UPDATE`, seed or `priv/modules/**` writer of either table |
| Writer of `service_catalog_versions`: only `archive_current_version/1` inside `publish/3` (`Repo.insert` of `Version.archive_changeset/1`, a verbatim copy of the live row). `Version.archive_changeset/1` does NOT validate `endpoint_url`. | `service_catalog.ex:383-404`; `version.ex:78-83` |
| Elixir predicate: `Entry.check_endpoint_url_references/1` -> `ReservedReferences.reserved_template_names/1` -> `ServiceTask.template_reference_keys/1` filtered by `VariableMerge.reserved_key?/1` (KEY is exactly `"_sys"` or starts `"_sys."`, CASE-SENSITIVE). | `entry.ex` (`check_endpoint_url_references/1`); `reserved_references.ex:148-156`; `service_task.ex:346-405` |
| Placeholder grammar (strict, in source): `\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}`. The refusal grammar is that source with the KEY class widened to `[a-zA-Z0-9_.]+`. The closing `\s*\}\}` is part of the match (a placeholder with trailing garbage, e.g. `{{variables._sys x}}`, is not a placeholder and not refused). Elixir `~r` has no `u` flag, so `\s` is the ASCII set (space, `\t`, `\n`, `\v`, `\f`, `\r`). | `service_task.ex:346-363, 386-405` |
| Changeset error shape for the refusal: `add_error(:endpoint_url, msg, validation: :endpoint_url_reserved_variable)`; router recognises it through a private `reserved_endpoint_url?/1` and answers 422 `{"error": "endpoint_url_reserved_variable", "field": "endpoint_url"}`. | `entry.ex` `validate_endpoint_url/1`; `admin_services.ex:368-374`; `Response.endpoint_url_reserved_variable/1` |
| Migration conventions: `use Ecto.Migration`; `create constraint(..., check: ...)`; DB-level trigger/function only where immutability needs it (6+ migrations, all tenant-scoped); raw SQL via `execute/2` with a down; NO existing `NOT VALID` / `validate: false` / `@disable_ddl_transaction` use in `priv/repo/migrations`. ecto_sql 3.14.0 (supports `validate: false` on `create constraint`). `migration_filenames_test.exs` enforces unique numeric version prefixes. | `priv/repo/migrations/*`; `mix.lock` |
| THREE existing tests write a `_sys` URL into `service_catalog` with `Repo.update_all` as a "raw fixture" and WILL FAIL with `check_violation` once the CHECK exists (see 7, R2): (a) "refuses an INHERITED reserved URL; a clean supplied URL repairs it" (`update_all` at ~line 145); (b) "resolve_pinned_version/3 still returns a stored reserved URL unchanged" (~line 208), both in `test/letflow/service_catalog/endpoint_url_reserved_test.exs`; (c) "POST /:service_id/versions inheriting a reserved live URL -> reserved 422" (`update_all` at line 141) in `test/letflow/routers/admin_services_reserved_endpoint_test.exs:134-146`. Checked and SAFE (not `_sys`): `engine_catalog_service_task_test.exs:370`, `endpoint_url_validation_test.exs:75`. ELIXIR-DEV must nevertheless grep `test/` for EVERY `update_all`/`insert`/`insert!`/`insert_all` of `Entry`/`Version`/`service_catalog` carrying a `_sys` URL (`git grep -n "_sys" -- test` intersected with those writers) before declaring the list complete. | the three files above |

Observation, out of scope (no action): `:string` columns are `varchar(255)` by Ecto default, so the
2048 length CHECK on `endpoint_url` is effectively dominated by the column type. Not touched here.

## 1. Decision: option (a), a CHECK constraint on both tables

Chosen: **(a) DB CHECK, not a trigger, not (b).**

* Why (a) is feasible here: the guard is a pure, immutable predicate over one column of the same row; a
  CHECK states it declaratively, adds no function object to drop/replace, runs for `INSERT` and for any
  `UPDATE` that touches the column, and is visible in `\d`. Triggers in this repo exist for
  immutability and cross-row/OLD-vs-NEW rules (`audit_entries_no_update`, `script_rules_guard`, ...);
  none is needed here. The catalog tables are small (catalog-sized, tens of rows), so lock and scan
  cost is negligible even with the transaction held.
* Why not (b): the writer set is exactly small today, but (b) is a residual that every future code path,
  migration, and operator's SQL silently bypasses (the issue's own threat). (a) removes the residual;
  the writer-enumeration test would only detect a repo-code writer, not an operator. (a) is also cheap.
* Behaviour for valid entries is unchanged: the CHECK refuses only a template the Elixir predicate already
  refuses (parity, section 3). The changeset still runs first, so every ordinary refusal keeps its
  existing code and 422; the DB CHECK is the net underneath.
* A (b)-style writer-enumeration guard test is ALSO added (section 6, T6) as cheap defence in depth: it
  fails if a new writer appears without the review of the refusing changeset. Not a substitute for (a).

## 2. Database change (one migration)

New file `priv/repo/migrations/20261017100001_add_catalog_endpoint_url_reserved_ref_guard.exs`
(module `Letflow.Repo.Migrations.AddCatalogEndpointUrlReservedRefGuard`). Version is strictly after the
current last (`20261016120001`); `migration_filenames_test.exs` stays green. GLOBAL: no `prefix:`, no
`if prefix() do`, NOT registered in `Letflow.TenantProvisioning`'s tenant-scoped manifest (header comment says so,
as the two source migrations do).

### 2.1 The one pattern (PostgreSQL ARE, operator `~`, case-SENSITIVE)

Pattern text, single-sourced in the migration as ONE module attribute, written with a non-interpolating sigil (`~S`) and used by the pre-flight (spliced into the `$$`-quoted `DO` block as a dollar-quoted literal, so no escaping differs from the constraints) and both constraints:

`\{\{[ \t\n\v\f\r]*variables\._sys(\.[a-zA-Z0-9_.]*)?[ \t\n\v\f\r]*\}\}`

Constraint expression on each table: `endpoint_url !~ '<pattern>'` (`standard_conforming_strings` is on by default, so the
backslashes are literal in the SQL literal; the Elixir side writes it with a non-interpolating sigil).

Derivation from the Elixir grammar (the auditable correspondence):

| Elixir grammar piece | DB pattern piece | Note |
|---|---|---|
| `\{\{` | `\{\{` | same |
| `\s*` (ASCII: space, tab, LF, VT, FF, CR) | `[ \t\n\v\f\r]*` | NOT `\s` / `[[:space:]]`: PostgreSQL's `\s` follows the DB locale and may match Unicode spaces (e.g. U+2003) that Elixir's non-`u` `\s` does not. Explicit set keeps parity |
| `variables\.` | `variables\.` | same |
| KEY `[a-zA-Z0-9_.]+` filtered by `reserved_key?/1` (`"_sys"` or prefix `"_sys."`) | `_sys(\.[a-zA-Z0-9_.]*)?` | `_sys` exactly, or `_sys.` followed by any KEY chars (including none: `_sys.`). A longer key such as `_system` / `_sysx` falls through because the next required token is `\s*\}\}` |
| `\s*\}\}` | `[ \t\n\v\f\r]*\}\}` | the closing braces are part of the match on both sides |
| case-sensitive | operator `~` (not `~*`) | see OQ-1 |

Equivalence argument (for REVIEWER): placeholders cannot overlap (they start `{{`, end `}}`, and the interior is
KEY chars and whitespace only, no brace), so `Regex.scan` finds every placeholder that an unanchored DB match could find;
"exists a placeholder with a reserved KEY" is therefore the same predicate as the DB regex matching anywhere in the string.
No anchors, no NUL/newline sensitivity, `.` is only used inside brackets.

Deliberate departure from the issue text. The issue quotes `~* '\{\{\s*variables\.\s*_sys'`. That pattern (a) puts
`\s*` BETWEEN `variables.` and `_sys`, which the renderer grammar does not allow (`{{variables. _sys}}` is not a placeholder and is
inert), (b) lacks the closing `\s*\}\}`, so it would refuse `{{variables._sys x}}` and an unclosed `{{variables._sys`, which the Elixir predicate accepts, and
(c) with `~*` would refuse `_SYS`, which the case-sensitive renderer and `reserved_key?/1` treat as an ordinary key. Any of the three breaks the
AC "DB pattern and Elixir predicate agree on the table" and "no behaviour change for valid entries". The issue called its pattern a
"superset used by the QA inventory"; the guard must be EXACT, not a superset. Ruled correct by CODE-DESIGN-VALIDATOR (OQ-1).

### 2.2 Steps, in order, in `up/0`

1. **Pre-flight, abort on any hit** (`execute` of a PL/pgSQL `DO` block, one statement): count rows in
   `service_catalog` and in `service_catalog_versions` whose `endpoint_url ~ <pattern>`. If either count is
   greater than zero, `RAISE EXCEPTION` with a message that carries ONLY the two counts and a pointer to
   the remediation (publish a corrected version / delete the entry), never a URL or a placeholder (INV-2/INV-5).
   The count query reuses the same quoted pattern attribute as the constraints. Expected 0 (QA inventory `2026-10-15-inv-catalog-sys-refs-001` found 0 on 2026-10-15; the migration, not that
   record, is the authority at apply time).
2. **Add, NOT VALID**, on `service_catalog`: constraint `chk_service_catalog_endpoint_url_no_reserved_ref`
   via `create constraint(..., validate: false)`. Same on `service_catalog_versions`:
   `chk_service_catalog_versions_endpoint_url_no_reserved_ref`. (`NOT VALID` skips the table scan; new writes are checked immediately.)
3. **Validate** each: `execute("ALTER TABLE ... VALIDATE CONSTRAINT ...")` (takes `SHARE UPDATE EXCLUSIVE`, does not block
   reads or writes).
4. The migration stays in Ecto's default DDL transaction (this repo has no `@disable_ddl_transaction` precedent), so
   `ACCESS EXCLUSIVE` from step 2 is held to commit. Accepted: the tables are catalog-sized and the whole migration is
   milliseconds. The NOT VALID + VALIDATE split is kept anyway because it is the form that is correct if the tables grow
   and someone lifts the transaction (OQ-2 asks the supervisor if a non-transactional split is wanted).

`down/0`: drop both constraints (`IF EXISTS`); the pre-flight has no inverse. Reversible. Names are under 63
bytes (48 and 57).

No change to columns, indexes, types, other constraints. No trigger, no function created.

## 3. Elixir/DB agreement mechanism

Two implementations of one predicate (Elixir derived at call time from the grammar source; SQL a fixed pattern) cannot be
unified in code, so agreement is enforced by a **parity table test run against the real database** (section 6, T2):

* One table of `{label, template, refused?}` rows is the single list the test iterates. For each row the test asserts
  (1) `Entry.check_endpoint_url_references/1` result, AND (2) the DB verdict obtained by the bound-parameter query
  `SELECT $1::text ~ $2::text` with the template as `$1` and the extracted pattern as `$2` (bound parameters, so neither value
  is re-escaped or interpolated into SQL), where the pattern is read from the LIVE constraint, not from a copy in the test, so the
  test cannot agree with a stale copy. EXTRACTION (exact): `SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conname = $1`
  with the constraint name bound (run for both constraint names; the two literals must be byte-identical, asserted).
  `pg_constraint.consrc` no longer exists (removed in PostgreSQL 12). The stored definition is normalised by Postgres, e.g.
  `CHECK (((endpoint_url)::text !~ '<pattern>'::text))`; capture the single-quoted literal with a regex anchored on the
  `!~ '` ... `'::text` frame (greedy to the LAST `'::text`), then un-double any `''` (the pattern contains no single quote, so
  the assertion `not String.contains?(pattern, "'")` also pins that). The test fails loudly if the capture does not yield exactly one literal;
  plus (3) for each refused row a direct `Repo.insert_all` fails with the constraint; for each accepted row a direct insert
  succeeds. Rows agree on all three or the test fails.
* A second, StreamData property (same file): for generated templates built from `{{`, whitespace from
  `[ \t\n\v\f\r]`, `variables.`, a KEY from `[a-zA-Z0-9_.]` (biased toward `_sys`, `_sys.`, `_system`, `_SYS`, `a._sys`), and
  `}}` or a truncated closer, the Elixir verdict equals the DB verdict. Bounded: 200 runs, short strings.
* The migration's pattern attribute and the live constraint are one source; the test reads the live one. If the Elixir
  grammar or `reserved_key?/1` ever change, the parity test fails until the migration (a NEW migration replacing the
  constraint) is updated. The `template_placeholder/0` moduledoc already says a grammar change must ship the catalog check;
  extend that sentence (comment only) to name the DB constraints too (section 5).

Parity table (all templates are `https://example.test/<x>`; `refused` = Elixir refuses AND DB rejects):

| Label | `<x>` | Refused |
|---|---|---|
| bare | `{{variables._sys}}` | yes |
| bare, upper | `{{variables._SYS}}` | no (case-sensitive; inert) |
| dotted | `{{variables._sys.x}}` | yes |
| dotted, deep | `{{variables._sys.r.seq}}` | yes |
| dotted, empty tail | `{{variables._sys.}}` | yes |
| whitespace, spaces | `{{ variables._sys }}` | yes |
| whitespace, tab/LF | `{{<TAB>variables._sys.x<LF>}}` | yes |
| whitespace, VT/FF/CR | `{{<VT>variables._sys<FF><CR>}}` | yes |
| whitespace, Unicode (U+2003 before `variables`) | `{{<EM SPACE>variables._sys}}` | no (not an ASCII `\s`) |
| similar name | `{{variables._system}}` | no |
| similar name | `{{variables._sysx}}` | no |
| nested, not reserved | `{{variables.a._sys}}` | no |
| suffix | `{{variables.x_sys}}` | no |
| trailing garbage, not a placeholder | `{{variables._sys x}}` | no |
| unclosed | `{{variables._sys` | no |
| wrong capitalisation of `variables` | `{{Variables._sys}}` | no |
| text outside a placeholder | `_sys/{{variables.a}}` | no |
| ordinary key | `{{variables.order_id}}` | no |
| in host position | `https://{{variables._sys}}.example.test/x` (whole URL) | yes |
| multiple placeholders, one reserved | `{{variables.ok}}/{{variables._sys.b}}` | yes |
| no placeholder | (plain `https://example.test/svc`) | no |

## 4. Where the refusal surfaces (stable 422, never 500)

Normal path is unchanged: the changeset predicate refuses first, with `validation: :endpoint_url_reserved_variable`, and the
router answers 422 `endpoint_url_reserved_variable`. The DB CHECK is reached only if the Elixir predicate and the
pattern ever disagree (a bug) or a path skips the changeset (`insert_all`, SQL: those raise `Postgrex.Error`, which is correct
for a non-changeset writer; the 422 is for the changeset writers).

Changes to make a DB-raised violation map to the same stable 422:

* `Entry.insert_changeset/2` and `Entry.publish_changeset/2`: add `check_constraint(:endpoint_url, name: :chk_service_catalog_endpoint_url_no_reserved_ref, message: "must not reference the reserved engine variable namespace")`
  (same message string as the validator's `@endpoint_url_reserved_message`; reuse the attribute).
* `Version.archive_changeset/1`: add `check_constraint(:endpoint_url, name: :chk_service_catalog_versions_endpoint_url_no_reserved_ref, message: <same>)`. Practically unreachable (the live row already satisfies the identical CHECK) but
  closes the only remaining 500 path; the changeset is returned by `publish/3` as `{:error, %Ecto.Changeset{}}`, already
  handled by the router.
* `check_constraint/3` cannot set `validation:`; its error opts are `constraint: :check, constraint_name: "<name>"`. So the recogniser must accept BOTH forms. New public pure helper:

  `@spec Letflow.ServiceCatalog.Entry.reserved_endpoint_url_error?(Ecto.Changeset.t()) :: boolean()` -- true iff an `:endpoint_url` error has `validation: :endpoint_url_reserved_variable` OR `constraint: :check` with `constraint_name` one of the two names above (strings, as Ecto reports them).

  `Letflow.Routers.AdminServices` replaces its private `reserved_endpoint_url?/1` body with a call to it (both handlers unchanged otherwise). Public so it is unit-testable (the DB branch is not reachable through HTTP with consistent predicates).
* Response body, status, and echo rules unchanged (no URL, no matched name).

## 5. Files touched

New: `priv/repo/migrations/20261017100001_add_catalog_endpoint_url_reserved_ref_guard.exs`.
Edited: `lib/letflow/service_catalog/entry.ex` (two `check_constraint` calls, one public helper, moduledoc line),
`lib/letflow/service_catalog/version.ex` (one `check_constraint`), `lib/letflow/routers/admin_services.ex` (private recogniser delegates),
`lib/letflow/engine/service_task.ex` and `lib/letflow/definitions/reserved_references.ex` (COMMENT/@doc sentence only: a grammar or `reserved_key?/1`
change must also ship a new migration replacing the two CHECKs and the parity table).
Tests: see 6; EDITED existing tests: `test/letflow/service_catalog/endpoint_url_reserved_test.exs` (inherited test rewritten at changeset level, dispatch-resolution test deleted) and
`test/letflow/routers/admin_services_reserved_endpoint_test.exs` (the inherited-live-URL test at 134-146 removed), plus any further hit of the grep required in R2. No change to `service_catalog.ex` bodies, `engine.ex`, the renderer, or any router response shape. No docs/ files
(the 422 code list lives in the router moduledoc, unchanged).

## 6. Acceptance criteria to design to test

| AC | Design | Test |
|---|---|---|
| Choose (a) or (b) with the reason in the PR | 1 | PR body quotes section 1 reasons |
| (a) migration confirms zero matching rows first and aborts otherwise | 2.2 step 1 | **T1** `test/letflow/migrations/add_catalog_endpoint_url_reserved_ref_guard_test.exs`, `use Letflow.DataCase, async: false`, `Sandbox.mode(Repo, :auto)` (`Ecto.Migrator` takes a lock on `schema_migrations`, which a sandboxed pool does not hand out; same reason as `definitions/migrations_test.exs`). MECHANISM: the existing tests replay TENANT-scoped migrations via `TenantProvisioning.replay_migrations/2` or `Ecto.Migrator.run(..., prefix: schema)`; that does not fit a GLOBAL migration, so the test calls `Ecto.Migrator.run(Repo, [{20_261_017_100_001, Letflow.Repo.Migrations.AddCatalogEndpointUrlReservedRefGuard}], direction, all: true, log: false)` with NO `prefix:` (an explicit one-entry migration list, not the directory). SEQUENCE: (1) `:down` run (drops both constraints AND removes the `schema_migrations` row for that version); (2) insert one violating row into `service_catalog` and one into `service_catalog_versions` with raw `Repo.query!` (committed, since `:auto`), using service_ids prefixed `gh2638-mig-` and capturing the archive `version_id`s; (3) `:up` run inside `assert_raise` (the DDL transaction rolls back, so no constraint and no `schema_migrations` row result; assert the message contains the two counts and does NOT contain the URL or `_sys`); (4) delete the two violating rows by `service_id`/`version_id` with raw `DELETE`; (5) `:up` run again; assert both constraints exist with `convalidated = true` (query `pg_constraint`) and that `schema_migrations` has the version row again; (6) reversibility: `:down`, assert the constraints are gone, then `:up`. RESTORATION (`on_exit`, also runs on assertion failure): delete any leftover `gh2638-mig-%` rows from both tables (committed rows cannot be rolled back by the sandbox), then, if `schema_migrations` lacks the version, run `:up` again so the shared test DB ends fully migrated. While the constraints are dropped no other test module may write a `_sys` URL, which holds because every catalog test module is `async: false`. |
| NOT VALID/validate semantics, no long lock | 2.2 steps 2-4 | T1 asserts `convalidated` ends true; the migration source is reviewed for `validate: false` + `VALIDATE CONSTRAINT` (REVIEWER) |
| a direct `Repo.insert_all` of a `_sys` URL fails (both tables) | CHECK | **T3** (in the parity test file): `Repo.insert_all(Entry/"service_catalog", ...)` and `Repo.insert_all(Version/"service_catalog_versions", ...)` with a refused template -> `assert_raise Postgrex.Error` with `postgres.code == :check_violation` and `postgres.constraint` equal to the exact name; plus a raw `UPDATE` that sets the column to a refused value on a clean row -> same error; and the clean-URL insert succeeds. |
| refusal code surfaces as stable changeset error, HTTP 422 not 500 | 4 | **T4** unit: build a valid `Entry.insert_changeset` result, `put_change(:endpoint_url, refused)` AFTER validation, `Repo.insert` -> `{:error, cs}` (not a raise) whose `:endpoint_url` error has `constraint: :check`, the name, and the shared message; `Entry.reserved_endpoint_url_error?/1` true; same for `publish_changeset/2` and `Version.archive_changeset/1`. **T5** router: `admin_services_reserved_endpoint_test.exs` keeps its normal-path cases unedited (supplied reserved URL -> 422 `endpoint_url_reserved_variable`, both routes), BUT its test "POST /:service_id/versions inheriting a reserved live URL -> reserved 422" (lines 134-146) MUST be removed: its `Repo.update_all` at line 141 raises `check_violation` once the CHECK exists, and the inherited case is unreachable over HTTP in a real database. Disposition: REMOVE it; the router branch is covered instead by the injected-changeset unit test of `Entry.reserved_endpoint_url_error?/1` (T4, plus the false-cases here). Add a case that `reserved_endpoint_url_error?/1` is false for a length error, a scheme error and an unrelated check_constraint error (`chk_service_catalog_scope_owner_consistency`). |
| same predicate/pattern as #2623; pinned agreement table | 3 | **T2** (parity table + property) in `test/letflow/service_catalog/endpoint_url_db_guard_parity_test.exs` (`async: false`, `:auto`, rows cleaned in `on_exit`); includes bare `_sys`, `_SYS`, dotted `_sys.x`, whitespace (and Unicode whitespace), `_system`, ordinary key, per the issue. Reads the live constraint pattern from `pg_constraint`. |
| no behaviour change for valid entries | 1, 3 | the existing suites `service_catalog_test.exs`, `endpoint_url_validation_test.exs`, `endpoint_url_reserved_test.exs` (after R2 edits), `admin_services_*` pass; T2 accepted rows insert fine; a register/publish/retire/update_scope/delete smoke with an ordinary templated URL (`{{variables.order_id}}`) passes. |
| (defence in depth, not an AC) writer enumeration | 0, 1 | **T6** `test/letflow/service_catalog/writers_guard_test.exs` (pure, no DB): `git grep`-equivalent over `lib/` and `priv/` (File walk + string match, no shelling out) for `insert_all`, `update_all`, `Repo.insert`, `Ecto.Multi`, and raw `INSERT INTO`/`UPDATE`, restricted to files that alias `Letflow.ServiceCatalog.Entry` / `Letflow.ServiceCatalog.Version` (or `ServiceCatalog.{Entry, Version}`) or name `service_catalog` / `service_catalog_versions` (so `Dlq.Entry`, `Audit.Entry` and other `Entry` modules cause no false hits); asserts the set of (file, writer) equals the two known call sites in `service_catalog.ex` (`register`, `archive_current_version`/`apply_publish`) and that `Repo.delete_all`/`delete` there are the only deletes. A new writer fails the test with a message naming the changeset-and-constraint review this design requires. |

## 7. Risks

* **R1 pattern drift.** Two predicates. Mitigated by T2 reading the live constraint and by the explicit whitespace set. Residual: a
  future grammar change that is not accompanied by a new migration fails T2, which is the intended tripwire.
* **R2 existing tests that write a `_sys` URL raw WILL break (three known, grep for more).** `Repo.update_all(... set: [endpoint_url: "...{{variables._sys.r}}"])` now raises
  `check_violation`. Known: `endpoint_url_reserved_test.exs` ~145 and ~208, and `admin_services_reserved_endpoint_test.exs:141`. ELIXIR-DEV/TEST-DESIGNER must grep
  `test/` for EVERY `update_all`/`insert`/`insert!`/`insert_all` of `Entry`/`Version` carrying a `_sys` URL; `engine_catalog_service_task_test.exs:370` and
  `endpoint_url_validation_test.exs:75` were checked and are safe. Required edits (owned by TEST-DESIGNER):
  (i) the "refuses an INHERITED reserved URL" test cannot create the bad stored row any more; re-express it at changeset level without a DB row:
  `Entry.publish_changeset(%Entry{endpoint_url: bad, ...}, %{timeout_ms: ...})` carries `reserved_endpoint_url_error?/1`, and the "clean supplied
  URL repairs it" half becomes a changeset-level assertion (valid changeset). The inherited case is now unreachable in a real database
  (the CHECK guarantees stored rows are clean), which is a strictly stronger property, asserted by T3.
  (ii) "existing rows are not altered at dispatch resolution" tests a precondition the DB now forbids; remove it and record in the PR that the
  contingency in #2623 section 4 is closed by the migration pre-flight (count must be 0 to apply). DELETE it explicitly (decided, OQ-3); no replacement.
  (iii) the router test "POST /:service_id/versions inheriting a reserved live URL -> reserved 422" is removed (disposition in T5); the router's
  recogniser branches are covered by `reserved_endpoint_url_error?/1` unit tests.
* **R3 migration on an environment that holds a violating row** aborts startup of `mix ecto.migrate` (intended; message names counts only, remediation in text).
  Any deployed DB must be pre-checked with the QA inventory query; the pattern for that query is the migration's pattern with `~`.
* **R4 lock.** `ADD CONSTRAINT` takes `ACCESS EXCLUSIVE` briefly; with NOT VALID there is no scan. Catalog-sized tables, in a transaction: negligible.
* **R5 Postgres escape semantics inside bracket expressions** (`\t`, `\v` inside `[...]` in an ARE). I believe AREs honour character-entry escapes in
  brackets, but ELIXIR-DEV must confirm by running T2 first; fallback if not: the alternation `( |\t|\n|\v|\f|\r)*` (same set, escapes outside brackets).
* **R6 `varchar` + `!~`**: operand is `varchar`/`text`; the operator and the constraint are immutable and valid in a CHECK. No cast needed.
* **R7 test DB sandbox**: a failed statement inside a sandbox transaction aborts it; the new tests use `:auto` mode like the existing catalog tests (`async: false`).
* **R8 INV-2/INV-5**: the pre-flight and any error text never include the URL or the matched name. INV-7: the only interpolation is the constant pattern; no tenant/user data in SQL.
* **Scope fence:** no tenant schema work, no trigger, no dispatch change, no change to what `check_endpoint_url/1` (scheme/host) accepts, no change to the grammar.

## 8. Rulings and open questions

DECIDED (CODE-DESIGN-VALIDATOR, recorded as decisions, not open):

* **OQ-1 DECIDED: case-sensitive `~`.** The renderer regex has no `i` flag and its KEY class has no dot; `_SYS` is an ordinary key. See 2.1 for the departure from the issue text.
* **OQ-2 DECIDED: keep the default DDL transaction** (no `@disable_ddl_transaction`).
* **OQ-3 DECIDED: delete the "dispatch resolution unchanged" test** explicitly (R2 (ii)); no replacement.
* **OQ-4 DECIDED: public `Entry.reserved_endpoint_url_error?/1` is acceptable.**
* **OQ-5 DECIDED: no length CHECK added on `service_catalog_versions`.**
* **OQ-6 DECIDED: infra/supervisor note in the PR body** (repeat the inventory on each real environment before the release carrying this migration); not a design item.

STILL OPEN:

* **OQ-7 Postgres bracket escapes (R5).** Whether `\t \v \f` inside `[...]` of an ARE behave as assumed is confirmed only by running T2; ELIXIR-DEV runs T2 first and uses the alternation fallback in R5 if not. No other open question.
