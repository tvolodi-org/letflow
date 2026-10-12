# ISS-1042 / Q-1042 / GH #2381 — Module-scoped pooled tenant with dirty-table-only reset (test infrastructure)

- Run: WF03-ISS1042-20261012, step 02 (CODE-DESIGNER). Diagnosis: `docs/issues/ISS-1042.yaml`
  (committed on this branch, measured by ISSUE-FIXER in step 01).
- Scope: `test/support/` plus per-module opt-ins. **No `lib/letflow` production change, no tenant-data
  production path, no CI workflow / required check name change, no paid runners.**
- Design only: signatures, type shapes, algorithms, invariants. No function bodies.

## 0. Decision in one paragraph

Today every test that calls `Letflow.TenantFixture.provisioned_tenant!/1` pays a full
`CREATE SCHEMA` + 50 x `CREATE TABLE (LIKE ... INCLUDING ALL)` + rename/FK/sequence/trigger re-add
clone (mean 839 ms) and a `DROP SCHEMA ... CASCADE` teardown (mean ~42 ms): 74.0 % / 80.4 % of the
measured partition's test-phase wall time. This design adds an **opt-in, module-scoped tenant pool**.
A non-async test module declares, in `setup_all`, the tenant shapes it needs; each is cloned **once**
per module by the existing `do_clone` path. Per test, a call to `provisioned_tenant!/1` is served from
the pool after a **dirty-only reset** (probe all tables for rows in one statement, TRUNCATE only the
dirty ones plus their FK-referencing closure, restore seeds, restart dirty sequences, reset public rows
keyed to the tenant), followed by an independent **verification pass**. If cleanliness cannot be
*proven*, the slot is **rebuilt by a fresh clone**; a dirty tenant is never returned. The default path
(no pool attached) is untouched.

## 1. Facts this design is built on

### 1.1 Measured (ISS-1042 `measurements`, partition 1 of 12, 542 tests, 403 provisionings)

| Fact | Value | Design consequence |
|---|---|---|
| Clone, run B | mean 839 ms, median 711 ms, max 3107 ms; LIKE loop 621 ms of it | A per-test clone is the cost to remove |
| Teardown DROP SCHEMA | mean 41-45 ms (n=384) | Removed per test, paid once per module |
| TRUNCATE of all 57 tables | 932-1055 ms (slower than a clone) | Full truncate **forbidden** as the reset |
| TRUNCATE subset | ~8 ms per table (1: 6 ms, 5: 39 ms, 10: 88 ms, 20: 160 ms) | Reset cost scales with dirty tables only |
| Probe "any row" over 57 tables | 3.6 ms | Probe every table every acquire; it is nearly free |
| Highest-clone modules | IdentityIdHardeningTest 114, PromotionScopeTest 51, StoreTest 39 | First adopters |

### 1.2 Source facts read for this design

- `provisioned_tenant!/1` first line is `Sandbox.mode(Letflow.Repo, :auto)`, unconditional and never
  restored (ISS-0113 / ISS-0423). The pooled path **keeps that line** and does not touch Sandbox mode
  otherwise. Sandbox rollback as an isolation mechanism is not used (ISS-1042 lever b rejected).
- Schema name is a pure function of tenant id (`TenantProvisioning.schema_name_for_tenant/1`); the
  slug is `TenantSlugFixture.unique_slug(prefix)`.
- `do_clone/2` ends by inserting the `Registration` (`tenant_schemas`) row; the tenant row
  (`public.tenants`) is inserted by the fixture before the clone.
- Triggers on `audit_entries`, `repository_artifacts`, `artifact_versions` are `BEFORE UPDATE` /
  `BEFORE DELETE` row triggers only (migrations 20260830020001, 20260830030001). There is **no**
  `BEFORE TRUNCATE` trigger, so TRUNCATE is both permitted and the *only* way to empty those tables
  (DELETE would raise the immutability error). This is a test-only bypass of an immutability rule on
  throwaway test schemas; it must be stated in the moduledoc of the new reset function.
- `Letflow.Support.PlatformTenantFixture.three_tenants!/0` (52 test files use that helper) and the
  local `provisioned_tenant/0` helpers all funnel through `TenantFixture.provisioned_tenant!/1`, so a
  pool attached to the test process serves them with **no change to those helpers**.
- `StoreTest` and others spawn `Task.async` writers that rely on Sandbox `:auto` (committed) writes
  (ISS-0113 mechanism b). The pool must remain correct for writes from any process.

### 1.3 Premises that were NOT verified in this step (Postgres was not reachable here)

The design is written to be correct under **both** answers; the implementer verifies and records the
answer in the new test file's header. See section 14, OQ-1 and OQ-2.

## 2. Public API

All additions are test-only (`test/support/`), plain modules plus one linked helper process per pool
(section 3.2). Nothing is added to `lib/letflow/application.ex` (INV-F-1 of design ISS-0109 holds).

### 2.1 `Letflow.TenantFixture` (additions)

```text
@type slot_spec :: [
        slug_prefix: String.t(),                  # default "tenant-fixture"
        display_name: String.t(),                 # default "Tenant Fixture"
        oidc_mode: :enabled | :disabled,          # default :disabled
        idp_realm_id: String.t() | nil,           # default nil
        expected_tables: [String.t()] | :default  # default :default
      ]

@type pool_opts :: [
        slots: [slot_spec()],                     # required, non-empty
        reset_hooks: [(tenant_fixture() -> :ok)]  # default []; run in the TEST process, after DB reset
      ]

@opaque pool                                      # %{module, worker pid, slot keys}; never inspected by callers

@spec start_pool!(context :: map(), pool_opts()) :: [tenant_pool: pool()]
@spec attach_pool!(context :: map()) :: :ok
@spec pool_dirty_report(tenant_fixture()) :: pool_dirty_report()      # read-only, test-support
@spec recycle_pool!() :: :ok                                           # test-support: simulate a test boundary
@spec pool_stats(pool()) :: pool_stats()

@type pool_dirty_report :: %{
        dirty_tables: [String.t()],            # non-seed tables that hold rows
        dirty_sequences: [String.t()],         # sequences with is_called = true
        seeds_diverged: [String.t()],          # subset of ["event_type_registry", "schema_migrations"]
        structure_diverged: boolean(),         # table/trigger/index/constraint fingerprint != baseline
        public_keyed_rows: [{String.t(), non_neg_integer()}],  # {public table, count} keyed to the tenant
        tenant_row_diverged: boolean(),        # public.tenants or tenant_schemas row != snapshot
        clean?: boolean()
      }

@type pool_stats :: %{
        slots: non_neg_integer(),
        clones: non_neg_integer(),             # initial clones + rebuilds
        acquires: non_neg_integer(),
        resets: non_neg_integer(),
        rebuilds: non_neg_integer(),
        fallback_reasons: [atom()],
        dirty_tables_truncated: non_neg_integer(),
        reset_ms_total: non_neg_integer()
      }
```

Existing `@type opts` for `provisioned_tenant!/1` gains **one** key:

```text
pool: boolean()   # default true. `pool: false` forces the unchanged per-test clone path
                  # even when a pool is attached.
```

`provisioned_tenant!/1`'s `@spec` and return map are unchanged
(`%{tenant_id, schema_name, tenant}`); no `pooled?` key is added, so existing exact-map assertions and
destructuring call sites are unaffected.

### 2.2 `Letflow.Test.TenantTemplate` (additions; it owns the clone knowledge)

```text
@opaque clone_baseline      # fingerprint of one clone captured right after a verified-complete clone

@type clone_state :: %{
        tables: [String.t()],                    # relkind r/p in the clone schema, sorted
        dirty_tables: [String.t()],              # non-seed tables with >= 1 row
        dirty_sequences: [{table :: String.t(), sequence :: String.t()}],
        seed_digests: %{String.t() => {non_neg_integer(), String.t()}},  # {row count, md5}
        structure: %{triggers: [String.t()], indexes: non_neg_integer(), constraints: non_neg_integer(),
                     sequences: [String.t()], functions: [String.t()]}
      }

@type reset_report :: %{
        probe_ms: non_neg_integer(),
        truncated: [String.t()],                 # explicit TRUNCATE set (dirty + FK closure)
        closure_added: [String.t()],             # members added only for FK closure
        sequences_restarted: [String.t()],
        seeds_restored: [String.t()],
        verify_ms: non_neg_integer(),
        total_ms: non_neg_integer()
      }

@spec capture_clone_baseline!(schema_name :: String.t()) :: clone_baseline()
@spec probe_clone_state(schema_name :: String.t()) :: {:ok, clone_state()} | {:error, term()}
@spec reset_clone_schema!(schema_name :: String.t(), clone_baseline()) ::
        {:ok, reset_report()} | {:error, {:unprovable, [String.t()]}}
@spec rebuild_clone_schema!(source_tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_name :: String.t()} | {:error, {:clone_failed, term()}}
```

- `reset_clone_schema!/2` never raises for an unproven result; it returns
  `{:error, {:unprovable, reasons}}` and the caller (the pool worker) rebuilds. It raises only for
  programmer error (schema not present).
- `rebuild_clone_schema!/1` = drop the schema (`DROP SCHEMA IF EXISTS ... CASCADE`), delete the
  tenant's `Registration` row, then the **existing** `clone_tenant_schema!/1` path (same retry and
  error shape, same `assert_schema_complete!` is run by the caller). Reuses `do_clone_with_retry`.
- None of the existing public functions changes signature or behaviour. `clone_tenant_schema!/1` is
  unchanged (the pool calls it).

## 3. Pool lifecycle

### 3.1 How a module opts in

```text
setup_all context  -> Letflow.TenantFixture.start_pool!(context, slots: [...])   (returns [tenant_pool: pool])
setup context      -> Letflow.TenantFixture.attach_pool!(context)                (returns :ok)
```

- Both are called from the adopting module's own `setup_all` / `setup`. `setup` is mandatory:
  per-test setups run in the **test process**, which is where `provisioned_tenant!/1` is called, so
  the attachment is stored in that process's dictionary (key `{Letflow.TenantFixture, :pool}`) and the
  per-test claim counter (key `{Letflow.TenantFixture, :claims}`) is reset to empty. The test process
  is fresh per test, so nothing needs releasing.
- `setup_all` order: `start_pool!` runs once, in the module process, **before** any test and before any
  `DataCase` per-test checkout. It sets `Sandbox.mode(Letflow.Repo, :auto)` itself so its own queries
  and the worker's queries are committed.
- No `use`-macro is added; two explicit one-line calls keep the opt-in greppable.

### 3.2 State shape (lives in one linked helper process per pool)

`start_pool!` spawns **one** `Agent`-style helper (plain process linked to the `setup_all` process,
never supervised, never in the application tree). It exists for one reason: a reset TRUNCATE or a
slot rebuild issued from the *test* process would run on the test's sandbox-owned connection and could
be rolled back with it (OQ-1). The helper has no `$callers` entry and no Sandbox allowance, so under
`:auto` mode its statements run on ordinary pool connections and commit.

Worker state (one map entry per slot):

| Field | Meaning |
|---|---|
| `key` | `{shape, k}`: `shape` = the five `slot_spec` fields with defaults applied, `k` = 0-based occurrence index of that shape within one test |
| `tenant_id`, `schema_name` | fixed for the module's lifetime (rebuild reuses the same id) |
| `baseline` | `clone_baseline()` captured immediately after the completeness assertion |
| `tenant_snapshot` | full-row JSON of `public.tenants` for this id, taken after creation |
| `registration_snapshot` | full-row JSON of this tenant's `tenant_schemas` row |
| `status` | `:clean` (created or verified, not yet handed out) or `:handed_out` |
| `generation` | integer, +1 on every rebuild (used by tests to prove fail-safe) |

Pool-level state: `public_keyed` (list of `{table, column}` discovered once, section 5.1) in
children-before-parents delete order, the FK-referencing graph of the clone schema (computed once from
`pg_constraint` of the first slot), the seed table list `["event_type_registry","schema_migrations"]`,
and `pool_stats`.

### 3.3 Slot creation (once per module, in `start_pool!`)

For each `slot_spec` in declared order, executed **in the worker**:
`Sandbox.mode(:auto)` -> insert the `Tenant` row exactly as the default path does (same
`create_changeset/3`, same slug generator) -> `ensure_template!/0` -> `clone_tenant_schema!/1`
(error -> `report_and_raise` with phase `replay_failed`, as today) -> `assert_schema_complete!/2` with the
spec's `expected_tables` -> `capture_clone_baseline!/1` -> snapshot rows -> `status: :clean`.

Slots are created **only here, never lazily from a test**: a slot created inside a test process would
sit in that test's sandbox transaction and could vanish (OQ-1). A call that names a shape/occurrence
that was not declared **raises** (`ArgumentError`, message names the shape, the declared slots and the
test), it does not silently clone. Cost to the adopter: each declared slot is one ~0.8 s clone per
module; declare the maximum number a single test claims (`three_tenants!` = 3 distinct shapes).

### 3.4 Teardown

`start_pool!` registers `on_exit` (setup_all-level, runs after the module's last test whether tests
passed, failed, timed out, or the module crashed). For each slot, in the worker's still-alive process
or, if it died, in the on_exit process itself: reset public keyed rows (section 5), then the **same
three statements as the per-test `teardown/2`** (DROP SCHEMA IF EXISTS CASCADE, delete `Registration`,
delete `Tenant`), preceded by one marker line `LETFLOW_TENANT_FIXTURE phase=pool_teardown ...`. Then
the worker stops. Anything left behind in a crash is already covered by `TenantSchemaReaper`'s sweep
(same schemas, same naming) exactly as an un-torn-down default tenant is today.

### 3.5 A test fails or times out mid-way

- The test process dies; ExUnit still runs its `on_exit`s. The pool needs nothing from that process.
- Next acquire sees `status: :handed_out` and runs the full reset+verify (it never trusts the previous
  test's exit state, and does not depend on an `on_exit` having run).
- A test that died holding row locks or an open transaction on the slot makes the reset's DDL wait;
  the reset runs with `SET LOCAL lock_timeout = '3s'` and `statement_timeout = '30s'`. A timeout is an
  `unprovable` outcome -> rebuild. If the rebuild itself cannot run (lock still held), the acquire
  raises a loud `ExUnit.AssertionError` carrying `capture_schema_state/1` (same reporting as the default
  path's `report_and_raise`), failing that test rather than handing out a dirty tenant.

## 4. Dirty detection and reset algorithm

Executed by the worker at every acquire of a `:handed_out` slot. The very first acquire after creation
(`status: :clean`) skips straight to hand-out (nothing can have touched it; creation itself ends with
a verified baseline).

### 4.1 Why probe-per-table (and not xmin / pg_stat)

| Candidate | Verdict |
|---|---|
| Probe each table `EXISTS (SELECT 1 ...)` in one statement | **Chosen.** Exact (committed state), 3.6 ms for 57 tables, no dependence on statistics |
| `pg_stat_user_tables.n_tup_ins/upd/del` deltas | Rejected: stats are asynchronous and flushed lazily; a write in the last ms may not be visible; counts cannot distinguish "inserted then deleted" from clean |
| `xmin` / `pg_class.relfilenode` snapshots | Rejected: transaction-id scan needs a read of every row; relfilenode changes only on rewrite and does not see plain inserts |
| `reltuples` | Rejected: estimate, not a proof |

A table is *dirty* iff `EXISTS` is true. Because the pool is fully reset to "all non-seed tables
empty", row presence **is** the correct and complete dirtiness predicate for table data.
UPDATE-in-place of rows can only occur on rows that exist, so it is covered the same way (the rows
disappear when their table is truncated). The only tables that legitimately hold rows when clean are
the seeds (4.4).

### 4.2 Probe (statement set P, one transaction, read-only)

One round trip each, executed twice per acquire (before reset = *detect*, after reset = *verify*):

1. Table set + structure fingerprint: names of relkind `r`/`p` in the clone schema; names of
   non-internal triggers; names of trigger functions in the schema; count of indexes and of
   constraints; names of sequences. Compared to `baseline` for equality.
2. Row presence: `UNION ALL` of one `EXISTS` per table in the **baseline's** table set (not a
   hard-coded list, so a migration adding a table is picked up with no edit here).
3. Sequences: `pg_sequences` rows in the schema with `last_value IS NOT NULL`
   (a never-called sequence has NULL; `RESTART` returns it to NULL).
4. Seed digests for each seed table: `{count(*), md5(string_agg(row::text, '|' ORDER BY row::text))}`
   compared to the baseline's.

### 4.3 Decision order (reset)

1. Probe P. If the **structure fingerprint differs** (extra/missing table, trigger, function,
   index/constraint count, sequence) -> do not attempt to reset; go straight to **rebuild**
   (reason `:structure_diverged`). This catches DDL left by a test (e.g. `identity_id_hardening` T-12b's
   `zz_probe` if it ever commits) and dropped triggers.
2. Compute `D` = dirty non-seed tables; `S` = tables owning a dirty sequence; `V` = diverged seeds.
3. If `D`, `S`, `V` are empty and public state is clean (section 5) -> already clean: no DML at all.
4. Open one transaction with the timeouts of 3.5, then, in this order:
   1. **Truncate set** `T` = `D` closed under "tables whose FK references a member of the set"
      (computed from the pool's FK-referencing graph; the added members are `closure_added`). If a seed
      table is in `T` or in `V`, it is re-seeded in step 3. One statement:
      `TRUNCATE <T...> RESTART IDENTITY` — **no CASCADE** (CASCADE would silently widen the set to
      tables we did not probe; with an explicit closure a missing edge raises instead of hiding).
      `RESTART IDENTITY` restarts the sequences owned by those tables' columns to their start (1).
   2. **Sequences-only dirt** (`S` tables not in `T`: rows were deleted but `nextval` advanced, and
      sequences are not rolled back by sandbox rollback): `ALTER SEQUENCE ... RESTART` per such
      sequence (cheap, no table rewrite).
   3. **Seeds**: for each seed table in `T ∪ V`: `TRUNCATE` (if not already) then
      `INSERT INTO <clone>.<seed> SELECT * FROM tenant_template.<seed>` — the exact two seed
      statements of `do_clone` steps 7-8. Seeds are *restored*, never left empty.
   4. **Public state** (section 5), same transaction.
5. Commit. Run Probe P again (**verify**). The slot is `clean` only if: structure == baseline,
   `D' = S' = V' = ∅`, public keyed counts all 0, tenant/registration rows == snapshots. Anything else
   -> `{:error, {:unprovable, reasons}}` -> rebuild (reason `:verify_failed`).
6. Rebuild failure after one attempt raises (3.5).

### 4.4 Seed tables

| Table | Clean state | Restore |
|---|---|---|
| `event_type_registry` | digest equals the template's rows at the time of the baseline | re-insert `SELECT *` from `tenant_template.event_type_registry` |
| `schema_migrations` | digest equals baseline (the version set copied from the template) | re-insert `SELECT *` from `tenant_template.schema_migrations` |

If the template was **rebuilt mid-module** (ISS-0842 stale fingerprint), seed digests are compared to
the slot's *baseline*, not to the live template, and restore re-inserts from the *baseline's captured
rows* (the baseline stores the seed rows as a term, they are tiny). Resolved here to remove an
ordering dependency on the template; see OQ-6 for the size check the implementer must confirm.

### 4.5 FK ordering, triggers, sequences — summary

- FK: one TRUNCATE statement with an explicit FK closure; no ordering problem (PG permits referencing
  and referenced tables in one TRUNCATE). Public-schema deletes are ordered children-first (5.1).
- Triggers: not dropped, not disabled, not fired (TRUNCATE does not fire row triggers). The structure
  fingerprint proves they are still present with the same function names.
- Sequences: reset by `RESTART IDENTITY` (owned) and `ALTER SEQUENCE RESTART` (4.3.4.2). The mutation
  test M2 proves the class "row deleted, sequence advanced".

## 5. Public-schema state keyed to the tenant (the ISS-0410 class)

### 5.1 Discovery (once per pool, in the worker)

`public_keyed` = every base table in schema `public`, other than `tenants`, `tenant_schemas` and
`schema_migrations`, that has a column which is **either** (a) the referencing column of an FK to
`public.tenants(id)` (`pg_constraint`, contype `f`), **or** (b) a `uuid` column named `tenant_id`,
`owner_tenant_id`, or ending in `_tenant_id` (catches keyed-but-FK-less columns). Discovery is by
catalog, not by a hard-coded list, so a later migration adding such a table is covered. As of this
design the FK set read from migrations is: `solution_pack_installs`, `solution_pack_artefact_bases`,
`pack_update_resolutions`, `onboarding_registry`, `service_catalog` (`owner_tenant_id`),
`entity_column_promotions`, `entity_constraint_activations`, `public_read_handles`,
`platform_migration_rollouts`, `event_history_retirements`, `tenant_memberships`,
`tenant_login_directory`. The implementer re-derives the list from the catalog; this list is
informative.

Delete order: topologically children-before-parents over FKs **among** `public_keyed`. A cycle among
them raises at `start_pool!` (loud, adoption-time) instead of guessing.

### 5.2 Per-acquire public reset (same transaction as 4.3)

1. For each `{table, column}`: probe `EXISTS (... WHERE column = $tenant_id)` (batched in the probe of
   4.2); for tables with rows: `DELETE FROM public.<table> WHERE <column> = $tenant_id`, children first.
   (DELETE, not TRUNCATE: the public tables are shared by other tenants' rows and tests.)
2. `public.tenants` row: compare `to_jsonb(row)` with `tenant_snapshot`; if different, restore every
   column from the snapshot with one `UPDATE ... SET (all columns) = (jsonb_populate_record(NULL::
   public.tenants, $snapshot))` keyed on id (columns enumerated from `information_schema.columns` once
   per pool). This covers a test that changed `status`, `settings`, `display_name`, `idp_realm_id`,
   `oidc_mode`.
3. `public.tenant_schemas` (`Registration`) row: same compare-and-restore against
   `registration_snapshot`. The row is never deleted by a reset.
4. A DELETE or UPDATE that raises (FK violation from a table the discovery did not classify, etc.)
   makes the reset `unprovable`; rebuild also cannot repair public state, so the acquire **raises**
   loudly (the same visible class as today's teardown `delete_all(Tenant)` FK failure). It never
   proceeds.

### 5.3 What is explicitly not reset

Public rows **not keyed to a pooled tenant** (global rows such as an unkeyed `service_catalog` entry,
rows keyed to tenants the test itself created outside the fixture). Their lifecycle is unchanged: the
test's own `on_exit`, exactly as today. A pooled tenant does not make these any more or less leaky
(a fresh tenant id never protected them).

## 6. VM-global (in-memory) state keyed to a tenant

A fresh tenant id per test used to isolate tenant-keyed in-memory state for free; a pooled id reuses
the same key across the module's tests. `lib/` holds exactly these ETS/persistent-term holders:
`Letflow.Api.AuthzDenyLog` (sampler windows, hashed tenant key), `Letflow.Plugs.LoginDiscoveryRateLimit.
Bucket`, `Letflow.Plugs.PublicReadRateLimit.Bucket`, `Letflow.Engine.PluginRegistry`,
`Letflow.Metrics.Registry`.

Rule: **before a module adopts the pool, ELIXIR-DEV greps the module (and the helpers it calls) for
those five and for `Application.put_env`, and records the result in a comment above the module's
`setup_all`.** The mechanism for a hit is `reset_hooks:` (2.1), which runs a caller-supplied function
in the test process after the DB reset. Audit result for the three first adopters, from this
step's grep: `IdentityIdHardeningTest`, `PromotionScopeTest` and `StoreTest` reference none of
`RateLimit`, `Bucket`, `AuthzDenyLog`, `PluginRegistry`, `Metrics`, `:ets`, `persistent_term` and none
asserts on captured log output; `Application.put_env` appears only through
`PlatformTenantFixture.pin!/1`, which already registers its own restore `on_exit` per test.
(Requests through the Identity/PromotionScope routers can emit `AuthzDenyLog` lines on 403 paths; no
assertion consumes them. ELIXIR-DEV re-confirms by reading the module, not by trusting this sentence.)

## 7. Which tests keep a fresh per-test clone, and how the default path stays unchanged

A call is served from the pool **only when all of**: a pool is attached to the calling test process;
`opts[:template]` is `:clone` (default); `opts[:teardown]` is `true` (default); `opts[:pool]` is not
`false`. Everything else takes the unchanged code path.

| Test class | Why it keeps the fresh clone | Mechanism |
|---|---|---|
| No `start_pool!` / `attach_pool!` in the module (every module today, 179+ of the 182 files) | default behaviour | the pdict key is absent -> the new branch returns "not pooled" before any other work |
| The 22+ `template: :replay` sites (29 files with the literal) | they need a genuinely migrated schema | `:replay` is excluded by the rule above |
| DDL/drop tests: `RegistryTenantSchemaMissingTest`, `TenantProvisioningTest`, `tenant_fixture_test.exs` C1-C3 (drops tables/schema), `tenant_template_test.exs`, migration tests (`*migrations_test.exs`), any test with `teardown: false` | they destroy or alter the tenant | not adopting the pool; `teardown: false` is also excluded |
| A pooled module's one-off test that wants isolation | per-call escape | `pool: false` |

Byte-for-byte guarantee: the implementation inserts **one** dispatch point in `provisioned_tenant!/1`
immediately after the existing `Sandbox.mode(Letflow.Repo, :auto)` line. No existing statement of the
default path (tenant insert, `on_exit` registration, `provision_schema!/2`, `assert_schema_complete!/2`,
`teardown/2`, `capture_schema_state/1`, log phases `teardown` / `provision_failed` / `replay_failed` /
`incomplete_schema`) is edited, reordered or re-indented. A reviewer can verify with `git diff` that the
existing function body lines are only *surrounded* by the new branch. New log phases are distinct
(`pool_clone`, `pool_acquire`, `pool_reset`, `pool_fallback`, `pool_teardown`) so the "a
`phase=teardown` line is by construction a post-test teardown" invariant and the C5 tests are not
disturbed; the closed-vocabulary comment is extended, not rewritten.

## 8. Async safety

The pooled tenant is **for non-async modules only**. The reasoning: one slot is one mutable schema; two
concurrent tests would share and corrupt it, and the reset (TRUNCATE takes ACCESS EXCLUSIVE locks)
would block or kill a concurrent reader.

Rejection is loud and fail-closed:

1. `start_pool!/2` raises `ArgumentError` if `context[:async]` is `true` **or missing** (it requires an
   explicit `false`; OQ-3 records the check that the key is present in the `setup_all` context).
2. `attach_pool!/1` raises under the same condition on the per-test context (`tags[:async]` is what
   `DataCase` itself reads).
3. `start_pool!/2` raises if a pool for the same module is already registered in this VM (one pool per
   module; ETS-free check via the worker's registered name `Letflow.TenantFixture.Pool.<Module>`).
4. `provisioned_tenant!/1` called from a process whose dictionary has no pool attached never reaches
   the pool (section 7); a *spawned* process (a `Task`) never has the attachment, so it takes the
   default path — it cannot accidentally mutate a slot through the pool API.

No claim is made that any async module can use it; none may.

## 9. Isolation proof (mutation test) and fail-safe

New file: `test/letflow/support/tenant_fixture_pool_test.exs`, `use Letflow.DataCase, async: false`,
adopting the pool itself with **two** `slot_spec`s of different shapes. Two complementary proofs:

### 9.1 Cross-test proof (no ordering assumption)

Every test in a describe block follows the same shape, so it does not matter which runs first:
(i) `assert_pristine!` — all of classes M1-M7 below are clean (`pool_dirty_report/1` `clean?: true`
AND direct reads); (ii) `mutate_everything!` — write every class; (iii) leave. With >= 3 tests, each
test other than the first proves that the previous test's leftovers are gone. Each test also asserts
that `pool_dirty_report/1` taken **after** `mutate_everything!` lists exactly the classes written
(the "teeth" check: proves the proof is not vacuous because detection *sees* the mutation).

### 9.2 Boundary proof (deterministic, in one test)

`recycle_pool!/0` simulates the test boundary (clears the per-test claim counter so the same slot is
re-acquired in-process, marking the slot `:handed_out`). Shape: acquire -> mutate -> report is dirty ->
`recycle_pool!` -> acquire again -> assert pristine.

### 9.3 Mutation classes (each is written from **the test process** and, separately, from a `Task`
in `:auto` mode, so both a sandbox-owned and a committed write are covered)

| ID | Class | Mutation | Must be pristine next |
|---|---|---|---|
| M1 | tenant table rows, FK chain | insert `groups`, `group_members`, `users`, `tenant_role` (FK to groups), `process_definitions` rows | all tables empty (except seeds) |
| M2 | sequence advanced, row gone | insert then `DELETE` a row of a table with an owned sequence (e.g. `definition_sequence`/events global seq) so the table is empty but the sequence `is_called` | `dirty_sequences == []`, next insert's id restarts at 1 |
| M3 | seeded table UPDATE | `UPDATE event_type_registry SET ...`, `DELETE` one row, `INSERT` an extra row | digest equals baseline; row set equals `tenant_template`'s |
| M4 | seeded `schema_migrations` | delete a version row | version set equals baseline |
| M5 | public row keyed to tenant | insert a `tenant_login_directory` row and a `tenant_memberships` row for the pooled tenant id (children first) | `public_keyed_rows == []` |
| M6 | tenant row | `UPDATE tenants SET status/settings/display_name` | row equals snapshot |
| M7 | registration row | update `tenant_schemas.migrations_applied_at` | row equals snapshot |
| M8 | **fail-safe: structure** | `CREATE TABLE <schema>.zz_probe` committed (via the Task), and in a second test `DROP TRIGGER audit_entries_no_update` | `generation` incremented, `fallback_reasons` contains `:structure_diverged`, table set and trigger set equal baseline again, `assert_clone_parity!(template, slot_schema)` raises nothing |
| M9 | **fail-safe: verify cannot pass** | a held lock from a second connection on a slot table makes the reset time out (lock_timeout) | `generation` incremented via rebuild OR a loud raise; **never** a returned dirty tenant |
| M10 | late writer | a spawned process inserts a row *after* the test returned (simulated by a write between `recycle_pool!` and the next acquire) | detected by the next probe; row absent |
| M11 | no cross-slot bleed | mutate slot A of shape X; slot B of shape Y and the second occurrence of X are untouched | B and X#1 report clean without having been reset |
| M12 | default path untouched | in the same module, `provisioned_tenant!(pool: false)` returns a tenant whose `schema_name` differs from every slot and is dropped at the test's end | existing teardown phase line is emitted once |

After every successful reset, the test also calls
`Letflow.Test.TenantTemplate.assert_clone_parity!(template_schema_name(), slot_schema)` (all 13
dimensions) — the same oracle ISS-0427 uses for freshly cloned schemas — so a reset schema is proven
structurally equal to a clone, not only empty.

### 9.4 Fail-safe rule (normative)

`provisioned_tenant!/1` on the pooled path returns a map **only if** the verify pass (4.3.5) returned
clean. Every other outcome is one of: rebuild-then-verify-clean, or raise. There is no code path that
returns a slot whose cleanliness was not proven in that acquire.

## 10. Failure modes

| Situation | Outcome |
|---|---|
| Probe query itself errors | `unprovable` -> rebuild |
| Structure fingerprint differs | rebuild (`:structure_diverged`) |
| Reset DML raises (lock timeout, FK) | `unprovable` -> rebuild; if public-state delete is the cause -> raise |
| Verify finds residue | rebuild (`:verify_failed`) |
| Rebuild fails | raise with `capture_schema_state/1` report + `Logger.error` under the marker (as today) |
| Worker process dies | `GenServer.call`-style exit is caught and re-raised as `ExUnit.AssertionError`; pool stats lost; `on_exit` still sweeps by deterministic schema names |
| Module declares fewer slots than it claims | `ArgumentError` naming shape and declared slots |
| Template rebuilt mid-module (stale fingerprint) | pool unaffected: baselines and seeds are held by the pool |
| Test changes `Sandbox` mode itself | out of contract (same as today); pool queries run in the worker and are unaffected |

## 11. Measurement plan, rollout, out of scope

### 11.1 Instrumentation (permanent, tiny, marker-based)

Reuse the existing greppable marker. New lines, `Logger.info`, closed phase vocabulary extended:
`LETFLOW_TENANT_FIXTURE phase=pool_clone schema=... ms=...`,
`phase=pool_acquire slot=... outcome=clean|reset|rebuilt ms=...`,
`phase=pool_reset dirty_tables=N closure_added=N sequences=N probe_ms=.. total_ms=..`,
`phase=pool_fallback reason=...`, `phase=pool_teardown ...`. The default path already logs
`phase=teardown` per test. These are the "clone time per test / tables per clone / share" numbers for
acceptance criterion 1 going forward; the diagnosis numbers stay in `docs/issues/ISS-1042.yaml`.

### 11.2 Before/after, 5 runs each (acceptance criterion 2)

- Unit: partition 1 of the 12-slice space, exactly the diagnosis command **without** `--slowest`
  (which forces `--trace`/`max_cases: 1` and would distort): `MIX_TEST_PARTITION=1 mix test
  --partitions 12`, same host, same Docker Postgres (`letflow_test1`), Logger level default.
- BEFORE = base commit `b9d5fa015` (this branch before the implementation commit) in worktree W0;
  AFTER = the implementation commit in worktree W1. Interleave to cancel host drift:
  `B1 A1 B2 A2 B3 A3 B4 A4 B5 A5`. Each run waits for a quiet DB (no other letflow test run) and uses
  a fresh `mix test` process so `tenant_template` is already built (13.6 ms cost, not a variable).
- Record per run: label (`B1..B5`, `A1..A5`), commit sha, UTC start, the `Finished in X seconds
  (Y s async, Z s sync)` line, `N tests, M failures`, count of `phase=pool_clone|pool_reset|
  pool_fallback` lines (AFTER) and of `provisioned_tenant!` clones (BEFORE, from the existing log),
  sum of `pool_reset total_ms`. Write the table to `docs/issues/ISS-1042.yaml` under
  `implementation_measurements` (and quote the medians in the PR body).
- CI: record the GitHub Actions **run ids** of the 5 most recent successful `main` runs of the workflow
  owning required check `Backend gate (mix letflow.check)` before the PR (BEFORE) and of 5 reruns
  of the PR head (AFTER: `gh run rerun`, ids from `gh run list --branch <branch>`), plus the shard
  job durations containing the three adopting modules (`gh run view <id> --json jobs`).
- Pass criteria: (a) no test outcome change (same passed/excluded counts); (b) median AFTER wall <=
  0.6 x median BEFORE on partition 1 (estimate in the issue: -63 %; the three first adopters hold
  204 of the 403 provisionings = 51 %, so the achieved figure is expected below the all-module estimate
  and the report states it per-module); (c) if the reduction is < 25 %, the implementer records the
  per-phase breakdown and files a follow-up instead of widening adoption in this PR.

### 11.3 Rollout in this PR

Adopt in exactly three modules, from the measured top of the list: `Letflow.Api.IdentityIdHardeningTest`
(114 clones: 3 declared slots), `Letflow.Routers.PromotionScopeTest` (51: 3 slots), `Letflow.Definitions.
StoreTest` (39: 2 slots, same shape twice -> `{shape,0}`, `{shape,1}`). Justification for not going wider
here: each adopter needs the section-6 audit and its own green proof; the next candidates
(`ServiceTaskWiringTest` 32, `EngineRequiredOutputsTest` 25) also touch DDL/engine concurrency and
need their own audit, and adopting them unaudited would trade measured speed for the ISS-0410 risk
class. They are listed as follow-ups, not done here.

### 11.4 Explicitly out of scope

Levers (a) clone-only-needed-tables, (b) shared read-only tenant / sandbox rollback, (d) CREATE DATABASE
TEMPLATE, speeding the LIKE loop itself, DELETE-instead-of-TRUNCATE for tiny tables (OQ-4), changing
async modules, changing `lib/`, changing CI workflows or check names, adopting any module beyond the
three, `SandboxPool` (design ISS-0427 section 6 still holds).

## 12. Ownership and tests that must stay green

### 12.1 `owned_modules` for ELIXIR-DEV

- `test/support/tenant_fixture.ex` (API 2.1, dispatch point, pool worker, public discovery, marker phases)
- `test/support/tenant_template.ex` (2.2: baseline, probe, reset, rebuild)
- `test/letflow/support/tenant_fixture_pool_test.exs` (**new**, section 9)
- `test/support/tenant_fixture_dispatch_test.exs` (add: default path unchanged with no pool; `pool: false`
  and `template: :replay` bypass an attached pool)
- `test/letflow/support/tenant_fixture_test.exs` (only if the closed log-phase vocabulary assertion needs
  the new phase names; C1-C6 must pass unchanged)
- `test/letflow/api/identity_id_hardening_test.exs`, `test/letflow/routers/promotion_scope_test.exs`,
  `test/letflow/definitions/store_test.exs` (add the two lines + audit comment only; no test body edits)
- `docs/issues/ISS-1042.yaml` (measurement table, status), `docs/anti-patterns.md` (append: pooled
  fixtures must prove cleanliness or rebuild; TRUNCATE-all is slower than clone)

Not owned / must not change: `lib/**`, `.github/**`, `test/support/platform_tenant_fixture.ex`,
`test/test_helper.exs`, `Letflow.DataCase`.

### 12.2 Existing tests that must stay green (run before and after)

- `test/support/tenant_fixture_dispatch_test.exs`, `test/support/tenant_template_test.exs`,
  `test/letflow/support/tenant_fixture_test.exs` (C1-C6, idp_realm_id opt, teardown logging)
- The three adopting modules (every test, same count as before)
- `RegistryTenantSchemaMissingTest`, `TenantProvisioningTest`, the `template: :replay` files
  (`event_store/registry_test.exs`, `public_read_test.exs`, `routers/public_read_test.exs`,
  `tenant_provisioning/backfill_test.exs`, ...) — they must not be affected at all
- One file that uses `PlatformTenantFixture.three_tenants!` and does **not** adopt (e.g. a sibling
  platform-scope test) to prove the helper is untouched on the default path
- `mix compile --warnings-as-errors` and `mix format --check-formatted` on the touched files

## 13. Invariants

- INV-P1: a pooled `provisioned_tenant!/1` returns only after a verify pass proved the slot clean in
  that acquire; otherwise it rebuilds or raises.
- INV-P2: pools are created only in `setup_all`, never from a test process.
- INV-P3: pooled reset executes on a connection that is not owned by the test's sandbox checkout.
- INV-P4: TRUNCATE sets are explicit and CASCADE is never used; a seed table is never left empty.
- INV-P5: no change to the default path's statements, return shape, log phases or order.
- INV-P6: async modules cannot create or attach a pool.
- INV-P7: no `lib/` change; the immutability triggers are never dropped, disabled, or modified.
- INV-P8: baselines are captured only after `assert_schema_complete!/2` passed for the slot.
- INV-P9: a pool leaves no schema, `Registration` or `Tenant` row behind at module end.

## 14. Open questions (not silently resolved)

| ID | Question | Why it matters | Decision made in this design / what the implementer must do |
|---|---|---|---|
| OQ-1 | After `DataCase`'s per-test `Sandbox.checkout` + the fixture's `Sandbox.mode(:auto)`, does the test process's own writes (and the existing in-test clone) live in a sandbox transaction that rolls back, or commit? The code comments conflict (`identity_id_hardening` T-12b says "DDL rolls back"; `StoreTest` relies on committed writes visible to a `Task`). Postgres was not reachable in this step. | Decides whether test-process writes need a reset at all | Design is correct for **both**: slots are created and reset in a no-`$callers` worker (committed), probes read committed state, and every mutation class is tested from both the test process and a `Task`. Implementer runs a 2-test probe first and records the answer in the new test file's header; it does not change the design. |
| OQ-2 | Is a worker with no `$callers`/allowance really routed to a non-sandbox connection under `:auto` in this repo's `Repo` pool config? | INV-P3 depends on it | Verify with the M-tests (a committed TRUNCATE visible from a `Task`). If false, the fallback is `Repo.checkout`-free `DBConnection` use via a dedicated non-sandbox repo config — which would be a `config/test.exs` change and must be raised to ORCH, not done silently. |
| OQ-3 | Is `:async` present in the `setup_all` context of the installed ExUnit? | The async rejection requires it | Design requires explicit `false`; if the key is absent the implementer must derive it from `ExUnit` module attributes, never default to "ok". |
| OQ-4 | DELETE vs TRUNCATE for tables with a handful of rows (DELETE would avoid per-table file work) | Possible further reset speed-up | Not measured; **TRUNCATE is specified** because it is the only mechanism that works on the immutability-trigger tables and the only one with measured numbers. Revisit only with measurements, out of scope here. |
| OQ-5 | `TRUNCATE ... RESTART IDENTITY` and sequences created via `CREATE SEQUENCE` + `OWNED BY` + `nextval` default (not identity columns) | Reset correctness for the clone's recreated sequences | `OWNED BY` sequences are restarted by `RESTART IDENTITY`; M2 proves it and the 4.3.4.2 `ALTER SEQUENCE RESTART` covers the table-empty case. If M2 fails the implementer must report it as a design defect, not patch around it silently. |
| OQ-6 | Baseline-held seed rows (4.4): `event_type_registry` row count/size | Must stay tiny for the baseline term to be sensible | Implementer confirms the count at implementation time (expected tens of rows); if large, restore from the live template instead and document the ISS-0842 ordering assumption. |
| OQ-7 | Whether indirect public dependents (a public table with an FK to a keyed table but no tenant column of its own) exist | Would be missed by 5.1 | Discovery as specified plus the 5.2.4 loud-raise rule: such a table surfaces as a loud failure at adoption, not a silent leak. |

## 15. Acceptance-criteria mapping

| Source criterion | Element |
|---|---|
| 1. Instrumented measurement: clone time per test, tables per clone, share of test time (numbers quoted) | Quoted from the diagnosis in section 1.1 (done in step 01); permanent marker lines in 11.1 keep it measurable |
| 2. One lever implemented with before/after wall time of the test phase (5 runs each, run ids) | Lever (c) refined, sections 2-5; measurement protocol 11.2 (5 + 5 interleaved local runs, CI run ids) |
| 3. Isolation proof: a test leaving data behind does not leak into the next (mutation test) | Section 9 (M1-M12 classes, cross-test and boundary proofs, teeth check, fail-safe 9.4) |
| 4. No change to required check names; no paid runners | Section 0 and 11.4 (no `.github/**` change, no new job, no new runner); owned modules 12.1 exclude workflows |
| Task items 1-8 (API, algorithm, public state, fresh-clone classes, async, proof, measurement, ownership) | Sections 2-3, 4, 5, 7, 8, 9, 11, 12 respectively |
