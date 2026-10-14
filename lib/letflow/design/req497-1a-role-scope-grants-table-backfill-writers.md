# REQ-497 PR 1a: `role_scope_grants` table, backfill, binding writers (GH #2533)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-GH2533-SCOPE-GRANTS-20261015`, step 03.
Base: `main` 4a911d40e. Scope: REQ-497 acceptance criteria **[1a] AC1-AC4 and AC17 for 1a only**.
Everything labelled [1b] (`allowed?/3`, AuthPipeline load, flag, shadow, N1 guard, token listing,
`exclude_scoped_holders/2`, the integrity endpoint, the route walk) is out of scope and is not
designed here.

Sources read: REQ-497 (`docs/requirements.yaml:36039-36258`), GH #2533 body incl. "Stage-1 cut"
and its one comment (heartbeat, no AC revision), decision 0051 (D1, D3, D4, D8, D12, Rollout,
"Security review pass 2" N1-N4), 0050 D8, `docs/agents/instructions/security-invariants.md`
(INV-1..INV-10), `docs/anti-patterns.md` (migration-version collisions :574 and :1313,
`@expected_tenant_tables` :2202, pooled fixture :4680), and the code cited per section below.

Design only. No function bodies; signatures are given as `@spec`-shaped text, SQL is described in
prose, not written.

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-14 | Initial design. |
| r1 | 2026-10-14 | ORCH revision 1 after CDV FAIL and SECURITY-REVIEWER FAIL. **B1 (SEC):** the ensure/repair cases (P -> P same group, i.e. W2(b), W4(b), W5(b), and the backfill task) now insert the tenant-wide row ONLY when no row of ANY `tenant_wide` value exists for (`:group`, group, role) (the T9 predicate, serialised by lock A), via the new `repair_group_row!/3`; the unconditional insert stays only for `nil -> P` and `not P -> P`. New T-C1 case "P, P same group with only a scoped row". **B2 (CDV):** the FK `scope_node_id -> scope_node_paths(node_id)` is DEFERRED to stage 2 (#2535); 1a keeps the column, its index and the CHECK (sections 1.3, 1.6, T-M3, T-N1, new section 10). Lock A is the migration's FIRST `execute` (SEC advisory 1). **Advisories:** run_tenant/2 error reasons and dry-run shapes named (CDV A2); precedent citation corrected to `:50-77` (CDV A3); `Backfill.run/1` skips and reports registrations whose schema is missing and continues (SEC); OQ-3 resolved for 1a (no rescue; T-W8 R2 asserts `Postgrex.Error`); OQ-4 handed to letflow-2 via ORCH; 1b carry-overs in new section 10. |

---

## 0. Binding decisions (from the dispatch, not re-decided)

| # | Decision |
|---|---|
| B1 | Principal model: the backfill writes ONE `tenant_wide` GROUP row per `tenant_role` row with `kind = :platform_role`. No user rows. `:process_routing_role` bindings get no row. |
| B2 | Binding writers create, move or remove the group row in the SAME transaction as the binding write: `upsert_role` (new binding, kind change), `rebind_role`, `delete_group`, seeding/provisioning (`seed_default_platform_role_groups`), `RoleBackfill.run`, `TenantAdminMigration.run` (it writes bindings: ensures TENANT_ADMIN, deletes legacy PLATFORM_ADMIN). |
| B3 | Membership writers create no row (`add_group_member`, `remove_group_member`, `sync_role_claims_from_token`, the TenantAdminMigration member copy, `PendingAdminGrants.bind_on_login`). |
| B4 | T9 (bindings without a row) returns 0 after every writer. |
| B5 | No behaviour change: no flag, no `allowed?/3`, no route/response/authorization change; existing tests pass unedited. |

Consequence of B1 recorded explicitly: the `PLATFORM_ADMIN` binding (platform tenant only, and a
legacy one in a not-yet-migrated non-platform tenant) is a `:platform_role` binding and therefore
gets a `tenant_wide` group row. 0051 D1 says PLATFORM_ADMIN is "out of scope for grants"; a
`tenant_wide` row is exactly today's semantics, so it is harmless, and it keeps T9 a single
uniform rule ("every `:platform_role` binding has a row"). 1b's `allowed?/3` must never consult
grants for platform-scope permissions (section 10, item 1b-1).

---

## 1. Migration

### 1.1 File, version, module

- File: `priv/repo/migrations/20261015025331_create_role_scope_grants.exs`
- Module: `Letflow.Repo.Migrations.CreateRoleScopeGrants`
- Version: `20_261_015_025_331`.

Version choice, checked 2026-10-14T19:5xZ after `git fetch origin`:
- latest on `origin/main` and in this checkout: `20261014100002_create_scope_node_paths.exs`;
- open PRs (`gh pr list -R tvolodi-org/letflow --state open`): only #2565
  (`feat/GH-2534-7b2a-script-policy`) adds a migration, `20261014000002_create_script_policy.exs`;
  #2580 is docs only; the rest are stale chore/docs PRs with no migration;
- GH #2552 (letflow-3, `state:in-progress`) has no pushed branch or PR yet; it will add an
  `api_tokens` issuer migration. The `...025331` suffix (embeds "2533") is chosen so a same-day
  `20261015000001`-style pick by another session cannot collide;
- `grep -rn "20261015\|20_261_015" test lib priv config` returns nothing (anti-patterns :1313: no
  test-fixture constant collides).
ELIXIR-DEV re-runs these three checks immediately before committing; on a collision, bump the
last digits and keep the manifest entry equal to the filename prefix.

### 1.2 Structure of the migration module

`use Ecto.Migration`, with `up/0` and `down/0` (not `change/0`: the data steps are not
reversible by Ecto). Both bodies are wrapped in the mandatory `if prefix() do ... end` guard;
on a plain `mix ecto.migrate` (no prefix) the migration is a no-op.

Public functions of the migration module (public so the abort test can drive them, section 6.1
T-M2b; they are not an application API and nothing in `lib/` calls them):

| Function | Spec | Purpose |
|---|---|---|
| `up/0` | `@spec up() :: any()` | r1: in this order, (1) `execute(fn -> lock_tenant_admins_in_migration!(schema) end)` as the FIRST command (lock A before any DDL or read, SEC advisory 1), (2) `create_objects(schema)`, (3) `execute(fn -> run_backfill!(schema) end)`. Zero-arity `execute/1` is supported by ecto_sql 3.14.0 (`deps/ecto_sql/lib/ecto/migration.ex:1096`); queued commands and these functions run in order inside the one migration transaction. |
| `down/0` | `@spec down() :: any()` | Drops the table (indexes and constraints go with it). `tenant_role` is untouched. |
| `lock_tenant_admins_in_migration!/1` | `@spec lock_tenant_admins_in_migration!(schema :: String.t()) :: :ok` | `SELECT pg_advisory_xact_lock($1::bigint)` with `Letflow.Identity.tenant_admin_lock_key(schema)` bound (section 1.4 step 1). Held until the migration transaction ends. |
| `create_objects/1` | `@spec create_objects(schema :: String.t()) :: any()` | The DDL of section 1.3 (table, CHECKs, indexes; no FK in 1a). |
| `run_backfill!/1` | `@spec run_backfill!(schema :: String.t()) :: backfill_counts()` | In order: insert the rows (1.4); `assert_no_gap!/1`; audit (1.5) when applicable. Returns the counts. Lock A is already held (`up/0` step 1). |
| `assert_no_gap!/1` | `@spec assert_no_gap!(schema :: String.t()) :: :ok` | Runs the frozen T9 count (1.4); raises `RuntimeError` with message prefix `"role_scope_grants backfill gap:"` followed by the COUNT only, when it is non-zero. |

`backfill_counts()` is the map `%{platform_role_bindings: non_neg_integer(), group_rows_inserted:
non_neg_integer(), user_rows_inserted: 0, process_routing_bindings_skipped: non_neg_integer(),
bindings_without_row_after: 0}`.

The migration does NOT call `Letflow.Identity.RoleScopeGrants` for the insert or the assert. A
replayed historical migration must keep its semantics when application code evolves (the
precedent `20260926010001_backfill_exam_tenant_modules.exs:32-37` freezes its constant for the
same reason). The insert and the T9 count are therefore frozen SQL in the migration; parity with
the application's T9 function is pinned by test T-C3. The only application functions the
migration calls are pure/stable ones: `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`
(pure string function, used the same way by the precedent), `Letflow.Identity.tenant_admin_lock_key/1`
(pure; its doc guarantees stability across releases, `identity.ex:1063-1072`), and
`Letflow.Audit.insert_entry/3` (section 1.5, with its residual risk stated there).

### 1.3 DDL (tenant schema, `prefix: schema`)

Table `role_scope_grants` (no `tenant_id` column, 0006 D2; the schema is the tenant scope, INV-1):

| Column | Type | Null | Notes |
|---|---|---|---|
| `id` | `binary_id` (uuid) | not null, PK | client-generated in Ecto, `gen_random_uuid()` in the migration's SQL insert |
| `principal_type` | `text` | not null | `'user'` or `'group'` (CHECK below). Ecto: `Ecto.Enum, values: [:user, :group]` |
| `principal_id` | `binary_id` (uuid) | not null | a `users.id` or a `groups.id`; NO FK (polymorphic, see below) |
| `role` | `text` | not null | a `tenant_role.name` of kind `:platform_role` (closed `Authorization.roles/0` set; validated in the changeset, not by a DB CHECK, see below) |
| `scope_node_id` | `text` | null | an `org_unit` node id; type `text` to match `scope_node_paths.node_id` (`20261014100002_create_scope_node_paths.exs:28`). r1: NO FK in 1a, deferred to stage 2 (see FK justification) |
| `tenant_wide` | `boolean` | not null, **no default** | a writer must state it (0051 M3: tenant-wide only by an explicit act) |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | not null | `timestamps(type: :utc_datetime_usec)`, as `scope_node_paths` |

Constraints (names are part of the contract; tests and the changeset map them):

| Name | Kind | Definition (prose) |
|---|---|---|
| `role_scope_grants_tenant_wide_xor_node` | CHECK | `(tenant_wide AND scope_node_id IS NULL) OR (NOT tenant_wide AND scope_node_id IS NOT NULL)`; rejects both-set and neither-set (AC1) |
| `role_scope_grants_principal_type_check` | CHECK | `principal_type IN ('user', 'group')` |
| `role_scope_grants_principal_role_idx` | INDEX (non-unique) | `(principal_type, principal_id, role)`: the 0051 D3 lookup index named in AC1 (pg_indexes assertion) |
| `role_scope_grants_tenant_wide_uniq` | UNIQUE partial index | `(principal_type, principal_id, role) WHERE tenant_wide`: at most one tenant-wide row per (principal, role); the conflict target of every idempotent insert |
| `role_scope_grants_scoped_uniq` | UNIQUE partial index | `(principal_type, principal_id, role, scope_node_id) WHERE NOT tenant_wide`: no duplicate scoped row (stage 2; costs nothing now) |
| `role_scope_grants_scope_node_id_idx` | partial INDEX | `(scope_node_id) WHERE scope_node_id IS NOT NULL`: lookup by node (stage 2 grant listing, and the RESTRICT check of the stage-2 FK) |

FK justification:
- **No FK on `principal_id`.** It is polymorphic (`users.id` or `groups.id`), so one FK cannot
  express it. Dangling rows are prevented by the writers (section 3: `delete_group` removes the
  group's rows in its transaction; the only binding delete, TenantAdminMigration's legacy
  PLATFORM_ADMIN removal, removes the row) and detected by `RoleScopeGrants.orphan_group_rows/1`
  (section 2.2). No user rows exist in stage 1, and no user-delete path exists on main. Two
  nullable columns (`user_id`, `group_id`) with FKs were considered and rejected: REQ-497 and
  0051 D1 fix the column set as `principal_type, principal_id`.
- **No FK to `tenant_role`.** A grant names a role (closed set), not a binding row; D1's cascade
  on "removing the role binding itself" is done by the writer (section 3), because the row is
  keyed by (group, role name) and a rebind must move, not delete, it.
- **r1: NO FK on `scope_node_id` in 1a; DEFERRED to stage 2 (GH #2535), ORCH decision option
  (b).** r0 proposed `REFERENCES scope_node_paths(node_id) ON DELETE RESTRICT`. CDV found it
  breaks the existing `test/letflow/scope_node_paths/migration_test.exs:133`, which migrates
  `CreateScopeNodePaths` `:down` on a tenant schema (Postgres refuses to drop a table another
  table's FK references), and AC4 requires existing tests to pass unedited. No route in stage 1
  creates a scoped row (Stage-1 cut), so nothing can reference a node yet and the FK protects
  nothing in 1a. Stage 2 (#2535), when scoped rows first become writable, adds the FK (the DB half
  of D1 "an `org_unit` cannot be deleted while any grant references it") and resolves the
  `scope_node_paths` `:down` interaction there (section 10, item 1b-4). 1a keeps the column, the
  CHECK and `role_scope_grants_scope_node_id_idx`.
- **No DB CHECK on `role`.** The role set is closed but has changed by migration-less code
  (REQ-448 added `TENANT_AUDITOR`); a DB CHECK would make the next such change a data migration
  in every tenant. The changeset enforces membership in `Authorization.roles/0`, and every
  writer derives `role` from a `:platform_role` binding, which is itself validated against that
  set (`role_registry.ex:171-184`).

### 1.4 Backfill and assert (inside the migration transaction)

`Ecto.Migrator` runs each migration inside `repo.transaction/2` in one `Task`
(`deps/ecto_sql/lib/ecto/migrator.ex:332-353`); `Letflow.Repo` calls from that process (the
zero-arity `execute/1` function) join that transaction. So the DDL, the backfill, the assert and
the audit commit or roll back together; an assert failure aborts the whole migration, the table
included, and the version is not recorded in `schema_migrations`.

`run_backfill!/1`, in order (all statements parameterised; the only interpolation is the
`prefix()` schema name, as in every tenant migration, INV-7):

1. **Lock (r1: taken by `up/0`'s FIRST command, `lock_tenant_admins_in_migration!/1`, before the
   DDL; listed here for the argument).** `SELECT pg_advisory_xact_lock($1::bigint)` with
   `Letflow.Identity.tenant_admin_lock_key(schema)` as the bound parameter: the same key every
   binding writer on main already takes first (`role_registry.ex:296, 469, 675`,
   `identity.ex:766`, `tenant_admin_migration.ex:311`). No binding can be created, converted,
   moved or deleted between the insert and the assert, including by a pre-release node during a
   rolling deploy (it takes the same lock since #2547).
2. **Count inputs.** `platform_role_bindings` = count of `tenant_role` where `kind =
   'platform_role'`; `process_routing_bindings_skipped` = count where `kind =
   'process_routing_role'`.
3. **Insert.** One `INSERT ... SELECT` into `"<schema>".role_scope_grants` of, for every
   `tenant_role` row with `kind = 'platform_role'`: `id = gen_random_uuid()`,
   `principal_type = 'group'`, `principal_id = tenant_role.group_id`, `role = tenant_role.name`,
   `scope_node_id = NULL`, `tenant_wide = true`, both timestamps `now()`; with
   `ON CONFLICT (principal_type, principal_id, role) WHERE tenant_wide DO NOTHING` (idempotent on
   a re-apply after `down`/`up`). `group_rows_inserted` = the statement's row count. Nothing reads
   `group_members` or `users`: no user row can be produced (B1).
4. **Assert (T9, frozen).** `assert_no_gap!(schema)`: count of `tenant_role` rows with
   `kind = 'platform_role'` for which NO `role_scope_grants` row exists with `principal_type =
   'group'`, `principal_id = tenant_role.group_id`, `role = tenant_role.name` (any `tenant_wide`
   value: per D1 "every bound role has at least one row"). Non-zero raises (aborts the
   migration). The message carries the count only (INV-4: no names, ids or record contents in a
   log line that a boot replay prints).
5. **Audit** per 1.5.

### 1.5 Audit `scope.backfill_completed` from inside the migration

How: `Letflow.Audit.insert_entry(Letflow.Repo, attrs, schema)` called from the same zero-arity
`execute/1` function, after the assert. `insert_entry/3` opens `repo.transaction/1`, which nests
into the migration's transaction (`audit.ex:219-229`), takes the tenant's `audit_chain_locks`
row `FOR UPDATE` (that table exists: manifest entry `20261003000001`, earlier than this one) and
appends a hash-chained `audit_entries` row (created by `20260830020001`, earlier). An
`{:error, _}` return is turned into a raise (aborts the migration); the D8 rule "audit writes in
the SAME transaction as the change" therefore holds.

When: only when BOTH (a) `TenantProvisioning.tenant_id_for_schema_name(schema)` returns
`{:ok, _}` (skips `tenant_template` and any non-tenant schema, the precedent's guard,
`20260926010001_backfill_exam_tenant_modules.exs:50-77`), and (b) `platform_role_bindings > 0`.

Why (b): a new tenant replays the whole manifest BEFORE role seeding
(`tenant_onboarding.ex:173-175`), so it has 0 bindings here and nothing was backfilled; its rows
come from the seeding writers (section 5). Skipping the zero case also removes the replay hazard
below for every future new tenant. An existing tenant has bindings and gets exactly one entry,
at the deploy that applies this migration (AC1).

Entry attributes:
- `actor_id: nil` (system act; same as TenantAdminMigration's entries);
- `action: "scope.backfill_completed"` (0051 D8 name; the chain accepts new actions without a
  code change, D8 "VERIFIED");
- `resource_type: "role_scope_grants"`, `resource_id:` the tenant id string;
- `before_state: nil`;
- `after_state:` exactly `%{"source" => "migration", "migration_version" => 20261015025331,
  "platform_role_bindings" => n, "group_rows_inserted" => n, "user_rows_inserted" => 0,
  "process_routing_bindings_skipped" => n, "bindings_without_row_after" => 0}`;
- `trace_id: nil`.

INV-4 implications: the entry carries counts and a version only; no role names, group ids, user
ids, claims or token material. The abort message carries a count only. No secret is resolved or
handled anywhere in this PR. The entry is tenant-scoped (written with `prefix = schema`, INV-1).

Residual risk (accepted, stated for REVIEWER): `insert_entry/3` inserts through
`Letflow.Audit.Entry`'s current schema. If a later migration adds an `audit_entries` column and
the `Entry` schema starts writing it, replaying THIS migration on a schema that still has
bindings but has not applied this migration would fail loudly (insert of an unknown column),
aborting that tenant's replay (fail closed, reported by `replay_all_pending/0`). Condition (b)
makes this unreachable for new tenants; it can only affect an existing tenant that skips this
deploy's replay and a later `audit_entries` change at once. The alternative, writing the entry
from the mix/release task instead, was rejected: AC1 requires the entry from the migration, and
the boot-time replay (`migration_replay_boot.ex:91`) runs no task.

### 1.6 Manifest entry and fixture oracle

- Append to `@tenant_scoped_migration_manifest` (`lib/letflow/tenant_provisioning.ex:491-658`),
  after the `CreateScopeNodePaths` entry, a comment line `# REQ-497 / GH #2533 PR 1a (decision
  0051 D1): role_scope_grants with its backfill and T9 assert.` and
  `{20_261_015_025_331, Letflow.Repo.Migrations.CreateRoleScopeGrants,
  "20261015025331_create_role_scope_grants.exs"}`. Extend the `tenant_scoped_migrations/0` @doc
  prose list ("and REQ-497 one more: `role_scope_grants`").
- Add `"role_scope_grants"` to `@expected_tenant_tables` in `test/support/tenant_fixture.ex:133-186`
  (alphabetical, between `"repository_artifacts"` and `"scope_node_paths"`), and bump the paired
  count assertion `test/letflow/support/tenant_fixture_test.exs:324` from 52 to 53 (anti-patterns
  :2202; same commit as the migration). This is the ONE edit to an existing test file; it is
  outside AC4's unedited set (identity, onboarding, auth pipeline, authorization_enforcement).
- `test/support/tenant_template.ex`: no edit. Its fingerprint follows the manifest; the template
  schema (`"tenant_template"`) applies the migration with 0 bindings and no audit (1.5 (a)).
- Pooled fixture (`TenantFixture.start_pool!/2`): no edit. The digest and the dirty-table reset
  discover tables from the catalog (anti-patterns :4680). r1: the table has NO FK in 1a, so no
  new FK edge (no `role_scope_grants -> scope_node_paths` edge until stage 2).
- r1: `test/letflow/scope_node_paths/migration_test.exs:133` (migrates `CreateScopeNodePaths`
  `:down`) keeps passing unedited, because no table references `scope_node_paths` in 1a
  (section 1.3, FK deferral). It is added to T-N1's run list.

---

## 2. Ecto schema and core module

### 2.1 `Letflow.Identity.RoleScopeGrant` (`lib/letflow/identity/role_scope_grant.ex`)

`schema "role_scope_grants"`, `@primary_key {:id, :binary_id, autogenerate: true}`,
`@timestamps_opts [type: :utc_datetime_usec]`. Fields: `principal_type` (`Ecto.Enum, values:
[:user, :group]`), `principal_id` (`:binary_id`), `role` (`:string`), `scope_node_id`
(`:string`), `tenant_wide` (`:boolean`), `timestamps()`. No associations (polymorphic principal).

- `@type t :: %__MODULE__{}` with the fields above.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()`: casts all five fields; requires
  `principal_type, principal_id, role, tenant_wide`; `validate_inclusion(:role,
  Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1))`; `check_constraint` mapped
  for `role_scope_grants_tenant_wide_xor_node` (field `:scope_node_id`) and
  `role_scope_grants_principal_type_check`; (r1: no `foreign_key_constraint`, there is no FK in
  1a; stage 2 adds it with the FK); `unique_constraint` for both partial unique index names. Writers in 1a never use the changeset
  for the idempotent tenant-wide insert (see 2.2); it exists for tests and stage-2 CRUD.

### 2.2 `Letflow.Identity.RoleScopeGrants` (`lib/letflow/identity/role_scope_grants.ex`) - the stable name

The single core module that writes and checks `role_scope_grants`. 1b's `Letflow.Api.Scope` and
the 1b integrity endpoint READ through it; no other module writes the table (a REVIEWER check
for 1a; a mix check like `check_scope_node_paths_writers` is OQ-4, to be filed by letflow-2). Every function takes an
explicit `prefix` (INV-1) and uses `Ecto.Query`/`Repo.insert_all` with bound parameters (INV-7).

Writer functions (all called from inside the binding writer's own transaction):

| Function | Spec | Contract |
|---|---|---|
| `reconcile_binding!/3` | `@spec reconcile_binding!(before :: TenantRole.t() \| nil, after :: TenantRole.t() \| nil, prefix :: String.t()) :: :ok` | THE entry point every binding writer calls with the binding as it was and as it is after its write, in the same transaction. Raises `ArgumentError` when `Repo.in_transaction?()` is false (same guard style as `lock_tenant_admins!/1`, `identity.ex:1095-1097`): this is how "same transaction" is enforced structurally. Decision table below. Raises on any DB error (the caller's existing rescue/rollback turns that into its error tuple). Writes no audit (the binding writer's own audit, `role_binding.created` / `role_binding.kind_changed` / `role.rebound` / `role_binding.removed`, already records the act; 0051 D8 lists no `grant.*` event for stage 1, since no grant act exists). |
| `ensure_tenant_wide_group_row!/3` | `@spec ensure_tenant_wide_group_row!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) :: :inserted \| :exists` | One `Repo.insert_all` of a single row (`principal_type: :group`, `tenant_wide: true`, `scope_node_id: nil`, generated id, now timestamps) with `on_conflict: :nothing` and `conflict_target: {:unsafe_fragment, "(principal_type, principal_id, role) WHERE tenant_wide"}` (the partial unique index; the fragment is a constant, no input interpolated). Returns by the inserted count. **r1: unconditional create; called ONLY for a binding that becomes `:platform_role` in this write (`nil -> P`, `not P -> P`).** It ignores scoped rows by design (the unique index is tenant-wide only); in stage 2 those two cases are exactly the D1 "binding write creates a tenant-wide row" cases carried to 1b/#2535 (section 10). |
| `repair_group_row!/3` | `@spec repair_group_row!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) :: :inserted \| :covered` | **r1 (SEC B1).** The ensure/repair path for an EXISTING binding. Inserts the tenant-wide row (same insert as `ensure_tenant_wide_group_row!/3`) ONLY when NO row of ANY `tenant_wide` value exists for (`:group`, group_id, role), i.e. exactly when that binding is in T9's result; otherwise writes nothing and returns `:covered`. So a group that holds only scoped rows for the role (stage 2) is never widened to tenant-wide by a repair (0051 D1 fail-closed rule: "a principal that has had scoped rows for a role never becomes tenant-wide by row removal"; the same holds for repair). Check-then-insert is race-free because every caller holds lock A (all binding writers and the backfill take it first), which serialises every write of a group row for that tenant; the caller must hold it (documented precondition; a REVIEWER check). Same transaction guard as `reconcile_binding!/3`. |
| `remove_group_rows!/3` | `@spec remove_group_rows!(group_id :: Ecto.UUID.t(), role :: String.t(), prefix :: String.t()) :: non_neg_integer()` | Deletes every row (tenant-wide and scoped) for (`:group`, group_id, role): D1 "removes the role binding itself (which cascades the rows)". |
| `move_group_rows!/4` | `@spec move_group_rows!(role :: String.t(), from_group_id :: Ecto.UUID.t(), to_group_id :: Ecto.UUID.t(), prefix :: String.t()) :: non_neg_integer()` | Re-points every row of (`:group`, from, role) to `to` (`update_all` of `principal_id`, `updated_at`). Before that it deletes any row already on (`:group`, to, role) (only a stale orphan can be there, since `tenant_role.name` is unique), so the unique index cannot fire. Then calls `repair_group_row!(to, role, prefix)` (r1: repair, not ensure) only when zero rows were moved (repairs a pre-existing gap; with zero rows on `from` and `to` cleared, it inserts). Row-follows-binding is needed for stage 2, where scoped rows must move with the binding rather than be re-created tenant-wide. |
| `delete_group_principal_rows!/2` | `@spec delete_group_principal_rows!(group_id :: Ecto.UUID.t(), prefix :: String.t()) :: non_neg_integer()` | Deletes every row whose principal is that group (any role). Used by `delete_group/2` (section 3, W6). |

`reconcile_binding!/3` decision table (`P` = `kind == :platform_role`; `group(x)` = `x.group_id`;
`name` is unchanged by every writer on main):

| before | after | Effect |
|---|---|---|
| `nil` | P | `ensure_tenant_wide_group_row!(group(after), after.name)` |
| `nil` | not P | none |
| P | P, same group | r1: `repair_group_row!(group(after), after.name)`: inserts a tenant-wide row only when the (group, role) has NO row at all; a group with only scoped rows (or a tenant-wide row) is left unchanged. Callers: W2(b), W4(b), W5(b). |
| P | P, other group | `move_group_rows!(after.name, group(before), group(after))` |
| P | not P (kind change away) | `remove_group_rows!(group(before), before.name)` |
| not P | P | `ensure_tenant_wide_group_row!(group(after), after.name)` |
| not P | not P | none |
| P | `nil` (binding deleted) | `remove_group_rows!(group(before), before.name)` |
| not P | `nil` | none |

Check functions:

| Function | Spec | Contract |
|---|---|---|
| `bindings_without_row/1` | `@spec bindings_without_row(prefix :: String.t()) :: [%{role_id: Ecto.UUID.t(), name: String.t(), group_id: Ecto.UUID.t()}]` | **The T9 query** (reusable; the 1b flip precondition and integrity endpoint call it). Every `tenant_role` row with `kind == :platform_role` with no `role_scope_grants` row of (`:group`, its `group_id`, its `name`), any `tenant_wide` value. Ordered by `name`. One query (`not exists` subquery), read-only, no lock, no transaction; sees a caller's uncommitted writes. |
| `bindings_without_row_count/1` | `@spec bindings_without_row_count(prefix :: String.t()) :: non_neg_integer()` | Same predicate, `count`. Same properties. |
| `orphan_group_rows/1` | `@spec orphan_group_rows(prefix :: String.t()) :: [%{id: Ecto.UUID.t(), principal_id: Ecto.UUID.t(), role: String.t()}]` | Group rows with no `:platform_role` binding of that (group, name): the converse of T9. Used by tests (kind change away, rebind, delete) and as an integrity datum; read-only. |
| `user_row_count/1` | `@spec user_row_count(prefix :: String.t()) :: non_neg_integer()` | Count of `principal_type == :user` rows. Used by tests (B1/B3: "0 user rows"). |

### 2.3 `Letflow.Identity.RoleScopeGrants.Backfill` (`lib/letflow/identity/role_scope_grants/backfill.ex`)

The release-callable repair sweep (section 4). Named here, specified in section 4.

---

## 3. Binding writers: placement, transaction, lock composition

Lock ranks of the #2547 proof (`lib/letflow/design/gh2547-tenant-admin-audit-and-count.md:838-850`):
A (tenant admin advisory lock) < R (`tenant_role` row) < G (`groups` row) < B (business rows) < C
(audit chain lock). `role_scope_grants` rows are rank **B**. Every placement below writes the row
after A, R and G are held and before the audit entry (C) of that writer, except where noted, so
the proof's order A -> R -> G -> B -> C is kept. No new lock is taken: the grant-row writes take
only row locks on `role_scope_grants` (r1: no FK in 1a, so no lock on `scope_node_paths`). No path that does not take A touches `role_scope_grants` in
1a (the only reader in 1a is test/check code, which takes no lock).

| # | Writer (file:line on 4a911d40e) | Where the call goes | Transaction joined | Lock composition |
|---|---|---|---|---|
| W1 | `RoleRegistry.upsert_role/4` new binding: `insert_role/5` (`role_registry.ex:510-535`) | In the `%TenantRole{id: ^inserted_id} = role` branch (:521), BEFORE `audit_binding_write(:created, ...)` (:522): `RoleScopeGrants.reconcile_binding!(nil, role, prefix)`. The lost-race `winner` branch (:525-526) goes to W2 and is covered there. | `do_upsert_role/4`'s `Repo.transaction` (:467), or the caller's outer one when nested (W4, W5). A raise is caught by the existing `rescue` (:479-481) -> `{:error, {:transaction_failed, e}}`, after rollback of the binding. | A (:469) -> R by name (:470, re-taken :498/:520) -> G `FOR UPDATE` (:472) -> **B grant row** -> C audit (:589). Unchanged order; the grant insert sits where the binding insert already is. |
| W2 | `upsert_role/4` existing binding: `converge_existing_role/5` (`role_registry.ex:545-563`) | (a) kind-change branch, after `{:ok, updated}` (:555) and BEFORE `audit_binding_write({:kind_changed, ...})` (:556): `reconcile_binding!(role, updated, prefix)` (inserts on routing -> platform, removes on platform -> routing). (b) unchanged branch `role.kind == kind` (:550-551): `reconcile_binding!(role, role, prefix)` (r1: `repair_group_row!` for a platform binding, inserting only when the binding has no row at all; a no-op for routing; makes every re-run of seeding or POST /roles repair a T9 gap without ever widening a scoped group). (c) `:role_already_bound` branch (:547-548): no call (the transaction rolls back). | Same as W1. | Same as W1 (R and G are already held in this path). |
| W3 | `RoleRegistry.rebind_role/4` -> `move_role/6` (`role_registry.ex:668-727`) | In `move_role/6`, after the successful `Repo.update` (:709) and BEFORE `Audit.insert_entry` of `role.rebound` (:723): `reconcile_binding!(role, updated, prefix)` -> `move_group_rows!` for a platform binding, nothing for a routing one. The same-group branch (:692-693) writes nothing (GH 2524 contract "nothing written"). | `rebind_role/4`'s `Repo.transaction` (:673). A raise from the grant write propagates out of `Repo.transaction` after its rollback. r1 (OQ-3 resolved for 1a): NO rescue is added in 1a; T-W8 R2 asserts `assert_raise Postgrex.Error` and that `group_id` and the row are still on group A. The rescue is carried to 1b's N1 work (section 10). | A (:675) -> R by id `FOR UPDATE` (:676) -> G target `FOR SHARE` (:690) -> tenant_role update -> **B grant rows (update/delete)** -> C (:723). |
| W4 | Seeding / provisioning: `seed_default_platform_role_groups/1` -> `ensure_platform_role_binding/2` (`role_registry.ex:220-317`); callers `TenantOnboarding.provision_and_migrate/1` (`tenant_onboarding.ex:175, 200-205`, used by `mix letflow.seed` and onboarding) and `RoleBackfill.run/0` (`role_backfill.ex:161`) | (a) `nil` branch (:305-312): no new call; the nested `upsert_role/4` (:308) writes the row through W1. (b) existing `:platform_role` branch (:299-300): add `reconcile_binding!(role, role, prefix)` before returning `role` (r1: repair-only via `repair_group_row!`, no insert when any row exists; this is what makes `RoleBackfill.run` and a seeding re-run converge an old gap). (c) routing branch (:302-303): rolls back, no call. | `ensure_platform_role_binding/2`'s per-name `Repo.transaction` (:292); the nested upsert joins it. | A (:296) -> R by name (:298) -> (nil branch) group get-or-create, then W1's own A (re-entrant), R, G -> B -> C. (existing branch) A -> R -> **B** (no G lock needed: the binding row is locked `FOR UPDATE`, so no concurrent rebind/convert can move it, and the group cannot be deleted while bound, FK NO ACTION). |
| W5 | `TenantAdminMigration.run/1` -> `real_tenant/4` -> `apply_plan/5` (`tenant_admin_migration.ex:307-342`) | (a) `ensure_binding(nil, schema)` (:350-368): no new call; the nested `RoleRegistry.upsert_role/4` (:360) writes the TENANT_ADMIN row via W1. (b) `ensure_binding(%TenantRole{} = ta, schema)` (:346): add `reconcile_binding!(ta, ta, schema)` before returning the group id (r1: repair-only via `repair_group_row!`). (c) `remove_legacy_binding(%TenantRole{} = pa, schema)` (:390-394): after the `delete_all` (:391) and BEFORE `audit!(... "role_binding.removed" ...)` (:393): `reconcile_binding!(pa, nil, schema)` -> removes the PLATFORM_ADMIN group row. (d) `copy_members/3` (:373-386): membership only, no call (B3). | `real_tenant/4`'s per-tenant `Repo.transaction` (:309); a raise reaches `process_tenant/3`'s rescue (:221-227) and the tenant is reported `failed` with the binding change rolled back. | A (:311) first. Within A the path already interleaves B and C (ensure_binding's audit, then the member copy, then the binding delete): the grant delete in (c) is B taken after an earlier C in the same transaction. That is safe by the #2547 proof point 2: every other transaction that could touch these rows takes A first and is excluded until this one ends. |
| W6 | `Identity.delete_group/2` (`identity.ex:751-789`) | Inside the transaction, AFTER `Repo.delete_all(query, prefix: prefix)` (:767) has returned `{1, _}`: `RoleScopeGrants.delete_group_principal_rows!(id, prefix)`; the transaction function then returns the original `{1, _}` so the `case` at :771-774 is unchanged. On `{0, _}` no call. A bound group raises the `tenant_role_group_id_fkey` violation at :767, before the call, and the existing rescue (:775-789) maps it to `{:error, :bound_to_role}` with everything rolled back. | `delete_group/2`'s `Repo.transaction` (:764). | A (:766) -> group delete (G, implicit) -> **B**. In 1a a deletable (unbound) group has no legitimate row; this removes orphans so no grant can outlive its principal. |

Membership writers (B3), unchanged and NOT calling `RoleScopeGrants`:
`Identity.add_group_member/3` (`identity.ex:653`), `Identity.remove_group_member/3` (:887),
`Identity.sync_role_claims_from_token/3` (:1146; it inserts `group_members` only, :2587),
TenantAdminMigration `copy_members/3` (`tenant_admin_migration.ex:373`),
`PendingAdminGrants.bind_on_login/5` (`pending_admin_grants.ex:385`; membership via
`add_group_member` at :550). Their AC is tested (section 6.3, T-W10..T-W14): no user row, T9 0.

Paths deliberately NOT changed, with reason:
- `Letflow.IdentityMigration` / `mix letflow.copy_identity_tables` (`identity_migration.ex:195`)
  copy legacy public `tenant_role` rows into tenant schemas (decision 0006). The public tables
  were dropped by `20260819000004_drop_legacy_public_identity_tables.exs`; the path is not live.
  If it were ever run, T9 shows the gap and section 4's task repairs it.
- Test-support code that inserts `TenantRole` directly bypasses writers; 1a has no runtime reader
  of the table, so such fixtures keep passing (AC4). 1b tests that need T9 = 0 must create
  bindings through the writers (OQ-2).

Concurrency note (rolling deploy): a pre-release node writing a binding AFTER this tenant's
migration committed leaves a binding without a row (old code has no `reconcile_binding!`). Every
such gap is visible to T9 and repaired by section 4's task, which the rollout runs after the
deploy completes (section 4.4). A post-release node writing to a tenant whose migration has not
run yet fails closed (`undefined_table` -> W1/W2 `{:error, {:transaction_failed, _}}`; W3/W6
raise), which only happens if that tenant's boot replay failed and is reported by it.

---

## 4. Backfill mix task and release function

### 4.1 `Letflow.Identity.RoleScopeGrants.Backfill`

| Function | Spec |
|---|---|
| `run/1` | `@spec run(opts :: [dry_run: boolean()]) :: {:ok, report()} \| {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: run_tenant_error() \| {:unexpected_exception, module()}}}` |
| `run_tenant/2` | `@spec run_tenant(schema_name :: String.t(), opts :: [dry_run: boolean()]) :: {:ok, tenant_report() \| dry_run_tenant_report()} \| {:error, run_tenant_error()}` |

Types (r1, CDV A2):
- `@type run_tenant_error :: :gap_remains | {:audit_failed, term()}`: the ONLY error reasons
  `run_tenant/2` returns. `:gap_remains` = step 3 found T9 non-zero after the inserts (cannot
  happen under lock A unless a binding names a role the insert refuses; rolled back);
  `{:audit_failed, reason}` = `Audit.insert_entry/3` returned `{:error, reason}` (rolled back).
  A raise (DB error, missing schema) propagates to `run/1`, which classifies it.
- `@type tenant_report :: %{tenant_id: Ecto.UUID.t(), platform_role_bindings: non_neg_integer(),
  group_rows_inserted: non_neg_integer(), bindings_without_row_after: 0}`.
- `@type dry_run_tenant_report :: %{tenant_id: Ecto.UUID.t(), platform_role_bindings:
  non_neg_integer(), bindings_without_row_before: non_neg_integer()}` (no insert/after keys).
- `@type skipped :: %{tenant_id: Ecto.UUID.t(), schema_name: String.t(), reason:
  :tenant_schema_missing}`.
- `@type report :: %{dry_run: boolean(), tenants: [tenant_report()] | [dry_run_tenant_report()],
  skipped: [skipped()], inserted_total: non_neg_integer()}` (`inserted_total` is 0 in a dry run).

- `run/1`: `Letflow.Obs.Logger.with_trace/1` around the sweep (one trace id, as
  `role_backfill.ex:139`); sequential `Enum.reduce_while/3` over
  `TenantProvisioning.list_registrations/0` (REQ-045 rationale, same as RoleBackfill). No
  transaction across tenants. Per registration:
  - r1 (SEC advisory): **a registration whose schema is missing is SKIPPED, reported and the
    sweep CONTINUES.** Detected two ways: (i) before `run_tenant/2`, a read-only existence probe
    of `"<schema>".role_scope_grants` (`to_regclass($1)` with the qualified name as a bound
    parameter, INV-7) returning NULL (schema gone, or this tenant's migration not applied); (ii) a
    `Postgrex.Error` with code `:undefined_table` or `:invalid_schema_name` raised by
    `run_tenant/2` (the schema vanished mid-sweep, the ISS-0343 race; `role_backfill.ex:167-175`
    precedent). Either way the registration is appended to `skipped` with reason
    `:tenant_schema_missing` and `{:cont, ...}`.
  - `{:error, reason}` from `run_tenant/2` halts with `{:backfill_failed, tenant_id, reason}`.
  - Any other exception halts with `{:backfill_failed, tenant_id, {:unexpected_exception,
    exception.__struct__}}` (module only, never the message, INV-4).
- `run_tenant/2` (real run), ONE `Repo.transaction` per tenant:
  1. `Identity.lock_tenant_admins!(schema)` (A, first);
  2. `platform_role_bindings` count; for each row of `RoleScopeGrants.bindings_without_row/1`,
     r1: `RoleScopeGrants.repair_group_row!/3` (so the inserted set is exactly the gap, AC3, and
     a group with only scoped rows is never widened), counting `:inserted`;
  3. `RoleScopeGrants.bindings_without_row_count/1` must be 0, else `Repo.rollback(:gap_remains)`;
  4. only when `group_rows_inserted > 0`: one `scope.backfill_completed` entry via
     `Audit.insert_entry(Repo, attrs, schema)`, attrs as section 1.5 with `"source" =>
     "backfill_task"`, no `"migration_version"` key, `trace_id` = the run's trace id; an
     `{:error, reason}` rolls back with `{:audit_failed, reason}`. A run that inserts nothing
     writes no entry, so an idempotent re-run leaves the audit chain unchanged.
- `run_tenant/2` (dry run): returns `{:ok, dry_run_tenant_report()}`; read-only
  (`bindings_without_row_count/1` plus the binding count), no transaction, no lock, no audit;
  never returns `{:error, _}` (a raise still propagates to `run/1`).
- Idempotent by construction: step 2 inserts only for bindings with no row at all, and the insert
  itself is `on_conflict: :nothing` on the tenant-wide unique index.
- The migration does not call this module (section 1.2).

### 4.2 Mix task `Mix.Tasks.Letflow.BackfillRoleScopeGrants` (`lib/mix/tasks/letflow.backfill_role_scope_grants.ex`)

`mix letflow.backfill_role_scope_grants [--dry-run]`. `@spec run(argv :: [String.t()]) :: :ok`.
Shape copied from `lib/mix/tasks/letflow.backfill_platform_roles.ex`: `Mix.Task.run("app.start")`,
`OptionParser.parse(argv, strict: [dry_run: :boolean])` (an unknown switch prints usage and
exits non-zero), calls `Backfill.run(dry_run: dry?)`, prints one summary line (tenants, total
inserted) and one line per tenant with a non-zero insert or gap (tenant id and counts only),
one line per skipped registration (tenant id and `tenant_schema_missing`; r1, a skip does not
change the exit status), `System.halt(1)` on `{:error, _}` printing tenant id and the reason TAG only. No
`LETFLOW_DEV_DB_CONFIRMED` guard (same precedent).

### 4.3 Release

No Mix in a release: `bin/letflow rpc "Letflow.Identity.RoleScopeGrants.Backfill.run([])"`
(precedent: `tenant_admin_migration.ex:42-43`, `login_directory/key_rotation.ex:8`). The @doc of
`run/1` states this invocation.

### 4.4 Rollout (for the PR body / DOC-UPDATER)

Deploy (boot replay applies the migration per tenant, with backfill and assert) -> when no
pre-release node remains, run the task once (`--dry-run` first is optional) -> T9 is 0 in every
tenant. 1b's flip precondition re-checks T9 server-side anyway.

---

## 5. Tenant provisioning and seeding

New tenants: `TenantOnboarding.provision_and_migrate/1` runs `replay_migrations/2` (creates the
empty table; 0 bindings, so no rows and no audit), then `seed_platform_roles/1` ->
`seed_default_platform_role_groups/1` -> per seedable name `ensure_platform_role_binding/2` ->
`upsert_role/4` -> W1 writes one tenant-wide group row per seeded binding (7 in a non-platform
tenant, 8 in the platform tenant, `RoleRegistry.seedable_role_names/1`). `recover_provisioning/1`
and `mix letflow.seed` use the same path; re-running converges (W4 (b), r1: repair-only, inserts only for a binding with no row). Seed scripts
that call `POST /roles` go through W1/W2. A new tenant therefore ends provisioning with T9 = 0
(test T-W6).

---

## 6. Tests (TEST-DESIGNER writes them; ids are the contract)

New files (all under the AC17 scoped paths):
`test/letflow/identity/role_scope_grants_migration_test.exs`,
`test/letflow/identity/role_scope_grants_test.exs`,
`test/letflow/identity/role_scope_grants_writers_test.exs`,
`test/letflow/identity/role_scope_grants_backfill_test.exs`, and one test-support migration
module `test/support/role_scope_grants_gap_migration.ex` (T-M2b).

Fixtures: tests that install a failure trigger (rollback tests) or migrate down/up use a
dedicated `TenantFixture.provisioned_tenant!/1` tenant, never the pooled tenant (a trigger or a
dropped table is schema drift the pool would have to rebuild, anti-patterns :4680). `async:
false` for files that call `RoleBackfill.run/0`, `TenantAdminMigration.run/1` or `Backfill.run/1`
(they sweep every registration). Helper `assert_t9_zero!(prefix)` =
`RoleScopeGrants.bindings_without_row_count(prefix) == 0 and user_row_count(prefix) == 0`.

### 6.1 AC1: migration (`role_scope_grants_migration_test.exs`)

| Id | Test |
|---|---|
| T-M1 | Populated tenant: run `Ecto.Migrator.run(Repo, [{20_261_015_025_331, CreateRoleScopeGrants}], :down, prefix: schema, all: true)`; seed N = 3 `:platform_role` bindings (`tenant_role` inserted directly, simulating pre-release data), 2 `:process_routing_role` bindings, and members in those groups; run `:up`. Assert: exactly 3 rows; every row `principal_type :group`, `tenant_wide true`, `scope_node_id nil`; the set of `{principal_id, role}` equals the 3 bindings' `{group_id, name}`; `user_row_count == 0`; no row has a routing role name; `bindings_without_row_count == 0`. |
| T-M2a | After T-M1, inside `Repo.transaction`: delete one row, then `CreateRoleScopeGrants.assert_no_gap!(schema)` raises `RuntimeError` whose message starts with `"role_scope_grants backfill gap:"` and contains `1` and no role name or group id; after the transaction the row is back (rolled back). |
| T-M2b | Migration-level abort: with the table dropped (`:down`) and N bindings present, `Ecto.Migrator.run` of the test-support `Letflow.Test.RoleScopeGrantsGapMigration` (version `99_991_015_025_331`, grep-checked unique; its `up/0` calls `CreateRoleScopeGrants.create_objects/1`, then in a zero-arity `execute/1` the real backfill insert, deletes one row, then `assert_no_gap!/1`) raises; afterwards `to_regclass(schema.role_scope_grants)` is NULL, its version is absent from `schema_migrations`, `tenant_role` is unchanged, and no `scope.backfill_completed` entry exists. Ends by re-running the real `:up` so the tenant is whole. |
| T-M3 | CHECK: with a `scope_node_paths` row created through `Letflow.ScopeNodePaths.write/2` (the sole writer), raw inserts of (a) `tenant_wide true` + node set and (b) `tenant_wide false` + NULL node each fail with `check_violation` on `role_scope_grants_tenant_wide_xor_node`; (c) `false` + existing node succeeds (positive control); (d) `principal_type 'token'` fails on `role_scope_grants_principal_type_check`; (e) r1: no FK in 1a, so this case asserts only that `pg_constraint` has no `FOREIGN KEY` on `role_scope_grants` (pins the deferral; stage 2 flips it); (f) a second tenant-wide row for the same (principal, role) fails on `role_scope_grants_tenant_wide_uniq`. |
| T-M4 | `pg_indexes` for the schema: `role_scope_grants_principal_role_idx` exists and its `indexdef` lists `(principal_type, principal_id, role)`; both partial unique indexes exist with their `WHERE` clauses. |
| T-M5 | Audit: after T-M1 exactly one `audit_entries` row with `action "scope.backfill_completed"`; `actor_id nil`; `resource_type "role_scope_grants"`; `after_state` keys exactly the seven of section 1.5 with values `platform_role_bindings 3, group_rows_inserted 3, user_rows_inserted 0, process_routing_bindings_skipped 2, bindings_without_row_after 0`; `Audit.verify_chain(schema)` is `{:ok, :valid}`. A freshly provisioned tenant (0 bindings at replay) has zero such entries. |
| T-M6 | Manifest and reversibility: `TenantProvisioning.tenant_scoped_migrations()` contains `{20_261_015_025_331, CreateRoleScopeGrants}` and is still sorted ascending; on the populated tenant `:down` drops the table and leaves `tenant_role` row count unchanged; a second `:up` restores exactly the T-M1 row set (no duplicates). The existing `test/letflow/migration_filenames_test.exs` guard covers the filename prefix. |

### 6.2 Core module (`role_scope_grants_test.exs`)

| Id | Test |
|---|---|
| T-C1 | `reconcile_binding!/3`: one case per row of the section 2.2 decision table (9 cases), each asserting the resulting row set, run inside `Repo.transaction` after `lock_tenant_admins!/1`; and called outside a transaction it raises `ArgumentError` and writes nothing. r1 (SEC B1) extra cases: (j) "P, P same group with only a scoped row": a `scope_node_paths` node created through `Letflow.ScopeNodePaths.write/2`, a scoped row (`tenant_wide false`, that node) inserted directly for (group, role); `reconcile_binding!(role, role, prefix)` leaves the row set unchanged and there is NO tenant-wide row for (group, role); (k) "P, P same group with no row" inserts exactly one tenant-wide row; (l) `repair_group_row!/3` returns `:covered` for (j) and for an existing tenant-wide row, `:inserted` for (k). |
| T-C2 | `bindings_without_row/1` and `_count/1`: 0 on a clean tenant; a directly inserted `:platform_role` binding is listed with its `role_id`, `name`, `group_id`; a directly inserted routing binding is never listed; a binding covered only by a directly inserted scoped row (`tenant_wide false`) counts as covered. |
| T-C3 | Parity: on the same seeded gap, `bindings_without_row_count/1` and `CreateRoleScopeGrants.assert_no_gap!/1` agree (count 1 vs raise) and both report 0 / `:ok` after repair. |
| T-C4 | `orphan_group_rows/1` lists a group row whose binding is gone or turned routing; `RoleScopeGrant.changeset/2` rejects a role outside `Authorization.roles/0` and maps the CHECK and unique names to changeset errors. |

### 6.3 AC2: writers (`role_scope_grants_writers_test.exs`)

"Rollback test per writer" uses two forms: (R1) a forced rollback around the call, i.e.
`Repo.transaction(fn -> writer; assert binding AND row visible; Repo.rollback(:forced) end)`,
then neither persists (proves both writes are on the one connection/transaction); (R2) an
injected failure of the grant write itself: a test-installed trigger
`BEFORE INSERT/UPDATE/DELETE ON role_scope_grants ... RAISE` in that tenant schema (installed and
dropped by the test, dedicated tenant), after which the writer returns its error and the binding
change did not happen. Every test ends with `assert_t9_zero!` where the scenario is gap-free.

| Id | Writer | Assertions |
|---|---|---|
| T-W1 | `upsert_role` new `:platform_role` binding | one tenant-wide group row for (group, name); R1; R2 (insert trigger) -> `{:error, {:transaction_failed, _}}` and no `tenant_role` row; T9 0. |
| T-W2 | `upsert_role` new `:process_routing_role` binding | no row; T9 0. |
| T-W3 | `upsert_role` kind change routing -> platform (same group) | row inserted; R2 -> error, kind still routing, no row. |
| T-W4 | `upsert_role` kind change platform -> routing | row removed (`orphan_group_rows == []`); R2 (delete trigger) -> error, kind still platform, row present. |
| T-W5 | `upsert_role` repeat of an existing platform binding; and the same with its row deleted beforehand | still exactly one row; the deleted row is re-created (W2 (b)). `{:error, :role_already_bound}` for another group writes no row. |
| T-W6 | Provisioning: `TenantOnboarding.provision_and_migrate/1` on a new tenant (non-platform) | 7 rows, one per `seedable_role_names/1` binding, each on that binding's group; T9 0; 0 user rows; a second `seed_default_platform_role_groups/1` keeps 7 rows; with one row deleted the re-run restores it (W4 (b)); R2 (insert trigger) on a fresh seed -> `{:error, _}` and the failing name has no binding. |
| T-W7 | `RoleBackfill.run/0` | on a tenant missing seeded bindings, after the run every new binding has its row; on a tenant with a binding missing its row, the run restores it; T9 0 for the test tenants. |
| T-W8 | `rebind_role/4` of a platform binding A -> B | the row's `principal_id` is B, none on A; same-group rebind writes nothing (row `updated_at` unchanged, no `role.rebound`); a routing binding rebind leaves zero rows; R1; R2 (update trigger) -> r1: `assert_raise Postgrex.Error` (no rescue in 1a, OQ-3), then `group_id` is still A and the row is still on A. |
| T-W9 | `TenantAdminMigration.run/1` on a non-platform tenant holding a legacy `PLATFORM_ADMIN` binding with members and no `TENANT_ADMIN` binding (platform pin configured as the existing `tenant_admin_migration` tests do) | after: a TENANT_ADMIN group row exists, the PLATFORM_ADMIN group row is gone, `user_row_count 0` (member copy wrote none), T9 0; R2 (insert trigger) -> tenant reported in `failed`, and neither the TENANT_ADMIN binding nor its row exists, the PLATFORM_ADMIN binding and row are intact. |
| T-W10 | `delete_group/2` | an unbound memberless group with a directly inserted orphan row: `:ok` and the orphan is gone; a bound group: `{:error, :bound_to_role}` and its row is still present. |
| T-W11 | `add_group_member/3`, `remove_group_member/3` | grant row set identical before/after; `user_row_count 0`; T9 0. |
| T-W12 | `sync_role_claims_from_token/3` (first sync with claims) | same assertions as T-W11. |
| T-W13 | `PendingAdminGrants.bind_on_login/5` (`test/support/pending_admin_helper.ex` setup) | same assertions as T-W11. |
| T-W14 | TenantAdminMigration member copy | covered by T-W9 (`user_row_count 0`). |

### 6.4 AC3: backfill task (`role_scope_grants_backfill_test.exs`, `async: false`)

| Id | Test |
|---|---|
| T-B1 | Already backfilled tenant: `Backfill.run_tenant/2` -> `group_rows_inserted 0`; no new `scope.backfill_completed` entry. |
| T-B2 | One row deleted directly: `run_tenant/2` inserts exactly that (principal, role) row, reports 1, writes one entry with `"source" => "backfill_task"`. |
| T-B3 | Idempotency: `run/1` twice -> identical row count after each; the second run's `inserted_total` is 0; audit entry count unchanged by the second run. |
| T-B4 | `dry_run: true` with a gap: `run_tenant/2` returns `{:ok, %{tenant_id, platform_role_bindings, bindings_without_row_before: 1}}` (exactly those keys); `run/1` returns `inserted_total 0`; no row and no audit written. |
| T-B6 | r1 (SEC): a registration whose schema is dropped before the sweep: `run/1` returns `{:ok, report}` with that tenant in `skipped` (`reason: :tenant_schema_missing`), and the OTHER test tenant (with a gap) is still repaired in the same run. |
| T-B7 | r1 (CDV A2): `run_tenant/2` returns `{:error, {:audit_failed, _}}` when the audit insert fails (forced by a test trigger on `audit_entries` in a dedicated tenant), and the inserted row is rolled back (T9 still 1). |
| T-B8 | r1 (SEC B1): a group holding only a scoped row for its binding's role (seeded directly, node via `ScopeNodePaths.write/2`): `run_tenant/2` reports `group_rows_inserted 0` and creates no tenant-wide row. |
| T-B5 | Mix task: `Mix.Tasks.Letflow.BackfillRoleScopeGrants.run([])` with `Mix.shell(Mix.Shell.Process)` prints the summary line; output contains no role names. (The `System.halt(1)` path is not executed in-test.) |

### 6.5 AC4: no behaviour change

| Id | Test |
|---|---|
| T-N1 | TEST-RUNNER runs the existing scoped suite (`test/letflow/identity*`, `test/letflow/routers/identity*`, `test/letflow/routers/onboarding*`, `test/letflow/plugs`, `test/letflow/api`, including `authorization_enforcement_test.exs`) and, r1, `test/letflow/scope_node_paths/migration_test.exs` (its `:down` of `CreateScopeNodePaths` at :133 must still pass: no FK references `scope_node_paths` in 1a); `git diff --name-status origin/main -- <those paths>` shows only `A` (added) files. |
| T-N2 | No `lib/letflow/routers/`, `lib/letflow/plugs/` or `lib/letflow/api/` file is in the PR diff (REVIEWER check; 1a adds no route, response field or authorization input). |

### 6.6 AC17 (1a)

ELIXIR-DEV and TEST-RUNNER quote real output of: `mix compile --warnings-as-errors`,
`mix format --check-formatted`, the scoped `mix test` above plus the four new files and
`test/letflow/support/tenant_fixture_test.exs` (count bump), and `mix letflow.check_boundaries`.

### 6.7 AC to design map

| AC | Design elements | Tests |
|---|---|---|
| AC1 | 1.3 table/CHECK/indexes (no FK in 1a); 1.4 backfill and assert; 1.5 audit; 1.6 manifest/oracle | T-M1..T-M6, T-C3 |
| AC2 | 2.2 `reconcile_binding!/3` and helpers; section 3 W1-W6; membership writers unchanged; 2.2 T9 functions | T-W1..T-W14, T-C1, T-C2 |
| AC3 | section 4 | T-B1..T-B8 |
| AC4 | B5; no router/plug/api file touched | T-N1, T-N2 |
| AC17 (1a) | 6.6 | gate output |

---

## 7. Overlap with in-flight work

- **#2565** (open, `feat/GH-2534-7b2a-script-policy`): also appends to
  `@tenant_scoped_migration_manifest`, `@expected_tenant_tables` and the count in
  `tenant_fixture_test.exs:324`, and edits `tenant_fixture.ex`/`tenant_template.ex`. Conflict is
  append-only: whichever PR merges second rebases, keeps both entries in version order and sets
  the count to 54. Distinct migration versions (its `20261014000002` vs `20261015025331`).
- **#2552** (letflow-3, in progress, no branch pushed): token issuer/minting in `identity.ex`
  (`create_token` :1863, `revoke_token` :2047-2091, list) and an `api_tokens` migration. 1a
  touches `identity.ex` only inside `delete_group/2` (:751-789) and adds no token code; it does
  not touch `api_tokens`, `ApiToken`, `count_tenant_wide_admins/1` or `exclude_scoped_holders/2`.
  Only the manifest/oracle append can conflict (as above).
- **#2564** (ready, unclaimed): deactivation, `update_user_status/3` (:403), PATCH /users. 1a does
  not touch these.
- `role_registry.ex` is touched by 1a only at the three insertion points of W1-W4; no open PR
  touches it. #2580 is docs only.

---

## 8. Security (for SECURITY-REVIEWER; INV list per REQ-497 GATES)

- INV-1: new table is tenant-scoped (created with `prefix: schema` under the `if prefix()` guard,
  registered in the manifest); every new query takes an explicit `prefix`; no `tenant_id` column.
- INV-2: no response shape changes (1a adds no route).
- INV-4: audit `after_state` and the abort message carry counts only; the backfill/task logs
  carry tenant ids and counts only; no secret handled.
- INV-5: no lookup-by-id route added.
- INV-6: one new data-access path (the table); its scoping is the above; no route.
- INV-7: migration SQL interpolates only the `prefix()` schema name; the lock key, and every
  value, are bound parameters; the `{:unsafe_fragment, ...}` conflict target is a constant.
- INV-8: writers keep their existing typed results (W1/W2 rescue; W5 per-tenant rescue; W6
  rescue; W3 raises as today, OQ-3); the sweep skips missing schemas and rescues per tenant; the
  migration fails loudly by design (abort).
- INV-10: no platform-scope surface touched.
- 0051 D1 fail-closed (r1, SEC B1): no repair path can turn a group holding scoped rows into a
  tenant-wide one; only a write that makes a binding `:platform_role` creates a tenant-wide row
  unconditionally (section 2.2), and those cases are carried to stage 2 (section 10).

---

## 9. Open questions

- **OQ-1:** moved to section 10 (item 1b-1).
- **OQ-2 (1b test design):** test-support code that inserts `tenant_role` rows directly creates
  T9 gaps. Harmless in 1a; 1b tests whose assertions depend on T9 = 0 (flip precondition, shadow
  counters) must create bindings through the writers.
- **OQ-3: RESOLVED for 1a (ORCH r1).** No rescue in `rebind_role/4` in 1a; T-W8 R2 asserts
  `assert_raise Postgrex.Error` and that `group_id` and the row stay on group A. The rescue is
  carried to 1b (section 10, item 1b-3).
- **OQ-4: handed off.** A mix check that `role_scope_grants` is written only by
  `Letflow.Identity.RoleScopeGrants`: ORCH asks letflow-2 to file it; not in 1a.
- **OQ-5 (rollout):** section 4.4 asks operators to run the backfill task once after a rolling
  deploy finishes. If deploys are always stop-the-world here, the step is a harmless no-op; DOC-
  UPDATER records it in the deploy runbook either way.

---

## 10. For 1b and stage 2 (carried items, r1)

- **1b-1 (was OQ-1; SEC).** The binding principal model gives the `PLATFORM_ADMIN` binding a
  tenant-wide group row (platform tenant; a legacy binding in an unmigrated tenant until W5
  removes it). 0051 D1 puts PLATFORM_ADMIN outside grants (0046 D2). 1b's
  `Letflow.Api.Scope.allowed?/3` must NEVER consult `role_scope_grants` for platform-scope
  permissions, with a test: a platform-scope request by a PLATFORM_ADMIN is decided identically
  whether its row is present, absent, or replaced by a scoped row.
- **1b-2 (SEC).** The three 0051 D1 cases where a binding write creates a `tenant_wide` row, which
  1b (enforced-branch design) and #2535 must handle explicitly, never by the 1a unconditional
  insert: (i) routing -> platform re-creation (`not P -> P` in `reconcile_binding!/3`; a binding
  converted back to platform after its scoped rows were removed with it); (ii) `nil -> P` in an
  ENFORCED tenant (a new binding; D1: "a writer that does not know the intended scope inserts NO
  row and returns a typed error"); (iii) IdP sync into a group whose applicable row is
  tenant-wide (D1/M3 `grant.sync_suppressed` for a user holding scoped rows). In 1a the flag does
  not exist, so (i) and (ii) are the legacy OFF behaviour and (iii) writes no row (B3).
- **1b-3 (OQ-3).** Give `RoleRegistry.rebind_role/4` a rescue mapping a raised DB error to a typed
  `{:error, {:transaction_failed, exception}}` (W1 style) as part of 1b's N1 work on the same
  function (N1 path (c)); update T-W8 R2 accordingly then.
- **S2-1 (stage 2, #2535; CDV B2).** Add the FK `role_scope_grants.scope_node_id ->
  scope_node_paths(node_id) ON DELETE RESTRICT` (constraint name
  `role_scope_grants_scope_node_id_fkey`) in the stage that first makes scoped rows writable, and
  resolve its interaction with `test/letflow/scope_node_paths/migration_test.exs:133`
  (`CreateScopeNodePaths` `:down` would then be refused while `role_scope_grants` exists); add
  `foreign_key_constraint(:scope_node_id)` to `RoleScopeGrant.changeset/2` and flip T-M3 (e).
