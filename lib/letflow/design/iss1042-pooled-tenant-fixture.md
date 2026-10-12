# ISS-1042 / Q-1042 / GH #2381 — Module-scoped pooled tenant with dirty-table-only reset (test infrastructure)

- Run: WF03-ISS1042-20261012, step 02 (CODE-DESIGNER), **rework iteration 1** (findings F1-F6, M-a..M-e of
  `handoffs/WF03-ISS1042-20261012/step-02b-code-design-validator.json`). Diagnosis: `docs/issues/ISS-1042.yaml`
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
the pool after (1) a **quiescence fence**, (2) a **detect pass** (row-presence probe of every table plus a
**definitional digest** of the whole clone schema), (3) a **dirty-only reset** (TRUNCATE only the dirty
tables plus their FK-referencing closure, restore seeds, restart dirty sequences, reset public rows keyed
to the tenant), (4) a **verify pass** (the same probe and digest again) and (5) a **final guard** (one more
row-presence probe immediately before return). Row data is reset in place; **any definitional drift
(DDL, DISABLE TRIGGER, ALTER ...) is never repaired in place: the slot is rebuilt by a fresh clone.**
If cleanliness cannot be *proven*, the slot is rebuilt; a slot that fails proof twice raises. The default
path (no pool attached) is untouched.

What is proven and what is not is stated once, precisely, in section 9.4 / INV-P1. In short: the
returned tenant was proven clean **at the instant of the final guard**, by the pool worker's own session;
the design does **not** claim that no foreign process writes afterwards, it **detects and mitigates** that
class (section 6.2, 3.6, M13-M14) and **bounds the damage to the owning test** (RR-1).

## 1. Facts this design is built on

### 1.1 Measured

ISS-1042 `measurements` (partition 1 of 12, 542 tests, 403 provisionings), plus one measurement made in
this rework:

| Fact | Value | Design consequence |
|---|---|---|
| Clone, run B | mean 839 ms, median 711 ms, max 3107 ms; LIKE loop 621 ms of it | A per-test clone is the cost to remove |
| Teardown DROP SCHEMA | mean 41-45 ms (n=384) | Removed per test, paid once per module |
| TRUNCATE of all 57 tables | 932-1055 ms (slower than a clone) | Full truncate **forbidden** as the reset |
| TRUNCATE subset | ~8 ms per table (1: 6 ms, 5: 39 ms, 10: 88 ms, 20: 160 ms) | Reset cost scales with dirty tables only |
| Probe "any row" over 57 tables | 3.6 ms | Probe every table every pass; it is nearly free |
| **Definitional digest of one schema (this rework)**: single statement over `pg_class`, `pg_attribute`/`pg_attrdef`, `pg_constraint`, `pg_index`, `pg_trigger`, `pg_proc`, `pg_sequence`, `pg_policy`, `pg_rewrite`, `pg_type`, `pg_statistic_ext`, `pg_inherits`, comments, ACL/owner; run against `tenant_template` in `letflow_test` (57 tables, 995 definition rows) | 4 runs: 17.2 / 12.8 / 13.8 / 12.4 ms (first run of a fresh session 53 ms) | A full digest per pass is affordable: detect + verify = ~26 ms against ~880 ms saved. **No "cheap-always / full-on-recycle" split is needed or allowed** (a split would reopen F1). The implementer re-measures on a real clone and records `digest_ms` (OQ-8) |
| Highest-clone modules | IdentityIdHardeningTest 114, PromotionScopeTest 51, StoreTest 39 | First adopters |

### 1.2 Source facts read for this design

- `provisioned_tenant!/1` first line is `Sandbox.mode(Letflow.Repo, :auto)` (`tenant_fixture.ex:237`),
  unconditional and never restored (ISS-0113 / ISS-0423). The pooled path **keeps that line** and does not
  touch Sandbox mode otherwise. Sandbox rollback as an isolation mechanism is not used (ISS-1042 lever b
  rejected).
- Schema name is a pure function of tenant id (`TenantProvisioning.schema_name_for_tenant/1`); the
  slug is `TenantSlugFixture.unique_slug(prefix)`.
- `do_clone/2` (`tenant_template.ex`) ends by inserting a **new** `Registration` (`tenant_schemas`) row
  (new id, new `provisioned_at`/`migrations_applied_at`) via `Registration.changeset`; the tenant row
  (`public.tenants`) is inserted by the fixture before the clone. Its seed steps are
  `INSERT INTO <clone>.event_type_registry SELECT * FROM tenant_template.event_type_registry` and the same
  for `schema_migrations` (after `CREATE TABLE ... (LIKE ...)` for the latter).
- `expected_tenant_tables/0` has **49** entries; `schema_migrations` is created separately, so a clone
  issues 50 `CREATE TABLE (LIKE ...)` statements and the clone schema holds 50 base tables plus the
  partitions of `events`/`events_archive` (57 relations of kind r/p in `tenant_template`). The diagnosis
  label "50 expected_tenant_tables" is wrong; the statement count of 50 is right.
- Triggers on `audit_entries` (`audit_entries_no_update`, `audit_entries_no_delete`),
  `repository_artifacts` (`repository_artifacts_no_update`, `..._no_delete`) and `artifact_versions`
  (`artifact_versions_no_update`) are `BEFORE UPDATE` / `BEFORE DELETE` row triggers only (migrations
  20260830020001, 20260830030001; confirmed in the live `tenant_template` catalog). There is **no**
  `BEFORE TRUNCATE` trigger, so TRUNCATE is both permitted and the *only* way to empty those tables
  (DELETE would raise the immutability error). This is a test-only bypass of an immutability rule on
  throwaway test schemas; it must be stated in the moduledoc of the new reset function.
- `Letflow.Support.PlatformTenantFixture.two_tenants!/0` and `three_tenants!/0` call
  `TenantFixture.provisioned_tenant!(slug_prefix: "scope-a" | "scope-b" | "scope-p")` — three **distinct
  shapes**. 52 test files reference `PlatformTenantFixture`; 27 of them call `three_tenants!`. They all
  funnel through `provisioned_tenant!/1`, so a pool attached to the test process serves them with **no
  change to those helpers**.
- `StoreTest` runs its `Task.async` writers (`store_test.exs:338-339`, `:1151`, `:1162`) under Sandbox
  `:auto`; every one is awaited (`Task.await_many`). The pool must remain correct for writes from any
  process.
- Sandbox semantics, from `deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex`: only an explicit
  `Sandbox.checkout/2` wraps the connection in `post_checkout` `handle_begin` (lines 544-551, 658);
  `Sandbox.mode(repo, :auto)` checks in every existing checkout (including `DataCase`'s
  `{:shared, self()}` connection) and thereafter every process, including the test process, takes an
  ordinary auto-checkout whose statements **commit**.
- `DataCase` (`test/support/data_case.ex`) does `Sandbox.checkout` then, for non-async tests,
  `Sandbox.mode({:shared, self()})`; it reads `tags[:async]`.
- Spawned writers reachable from `lib/` (audited in 6.2): `Letflow.Obs.Alerts` (`obs/alerts.ex:484`,
  `Task.Supervisor.start_child(Letflow.Obs.Alerts.TaskSupervisor, ...)`, reachable only from
  `Scheduler.Poller` via `Alerts.build_context_and_detect/3`, and `start_scheduler` is `false` in
  `config/test.exs`), `Letflow.LoginDiscovery.Dispatch` (`login_discovery/dispatch.ex:56`
  `start_child`, `:126` `async_nolink`; reachable only from `routers/login_discovery.ex:97`).

### 1.3 Resolved and still-open premises

- **OQ-1 is resolved: answer B.** After `DataCase`'s checkout and the fixture's `Sandbox.mode(:auto)`,
  test-process writes (and the in-test clone's DDL) **commit**; they do not roll back. Evidence: the
  Sandbox source above, plus the measured 41-45 ms mean `DROP SCHEMA` teardown (a no-op drop of a rolled-back
  schema would be ~1 ms). The comment "DDL rolls back" at `identity_id_hardening_test.exs:454` is stale.
  Consequence: schemas, rows and DDL written by any process (test process, `Task`, helper process) are
  committed and visible to the pool worker's probes, and **must** be reset by the pool; the pool's
  correctness does not rely on sandbox rollback at all. The design is written for answer B only; the
  "correct under both answers" claim of the first draft is withdrawn.
- **OQ-2 remains open** (a no-`$callers` worker really runs on a non-sandbox connection under `:auto`).
  It is verified by the M-tests (a committed TRUNCATE is visible from a `Task`), see section 14.

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
        reset_hooks: [(tenant_fixture() -> :ok)], # default []; run in the TEST process, after DB reset
        hooks: [after_verify: (schema_name :: String.t() -> any()),   # TEST-ONLY seams, default none,
                after_guard: (schema_name :: String.t() -> any())]    # run in the worker (section 9.3 M13)
      ]

@opaque pool                                      # %{module, worker pid, slot keys}; never inspected by callers

@spec start_pool!(context :: map(), pool_opts()) :: [tenant_pool: pool()]
@spec attach_pool!(context :: map()) :: :ok
@spec pool_dirty_report(tenant_fixture()) :: pool_dirty_report()      # read-only, test-support
@spec recycle_pool!() :: :ok                                           # test-support: simulate a test boundary
@spec pool_end_fence!() :: :ok                                         # raises on a straggler; see 3.6
@spec pool_stats(pool()) :: pool_stats()

@type pool_dirty_report :: %{
        dirty_tables: [String.t()],            # non-seed tables that hold rows
        dirty_sequences: [String.t()],         # sequences with last_value not null
        seeds_diverged: [String.t()],          # subset of ["event_type_registry", "schema_migrations"]
        definition_drift: [String.t()],        # one entry per definition row whose digest differs
                                               # (classes T C K I G F Q P R Y X H, section 4.2), [] if equal
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
        final_guard_resets: non_neg_integer(),
        fallback_reasons: [atom()],
        dirty_tables_truncated: non_neg_integer(),
        digest_ms_total: non_neg_integer(),
        reset_ms_total: non_neg_integer()
      }
```

Where each function executes (M-e): `start_pool!/2` and `attach_pool!/1` run in the module process /
test process respectively. `pool_dirty_report/1`, `recycle_pool!/0`, `pool_end_fence!/0` and
`pool_stats/1` are called from the **test process** but **execute their database work in the pool worker**
(a call to the worker); each first calls `Sandbox.mode(Letflow.Repo, :auto)` in the caller, the same
unconditional line `provisioned_tenant!/1` has, so the worker is never routed onto a `{:shared, pid}`
checkout (INV-P3).

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
@opaque clone_baseline      # captured right after a verified-complete clone, held by the pool worker

@type clone_state :: %{
        tables: [String.t()],                    # relkind r/p in the clone schema, sorted
        dirty_tables: [String.t()],              # non-seed tables with >= 1 row
        dirty_sequences: [{table :: String.t(), sequence :: String.t()}],
        seed_digests: %{String.t() => {non_neg_integer(), String.t()}},  # {row count, md5}
        definition_digest: String.t(),           # md5 over the sorted definition rows of 4.2 (this schema's own
                                                 # name left in place: baseline and probe are the SAME schema)
        definition_rows: non_neg_integer()       # number of definition rows digested (995 for a clone today)
      }

@type reset_report :: %{
        probe_ms: non_neg_integer(),
        digest_ms: non_neg_integer(),
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
  programmer error (schema not present). **It never attempts to repair definitional drift**: if
  `definition_digest` differs it returns `{:error, {:unprovable, ["definition_drift" | _]}}` immediately,
  before any DML.
- `rebuild_clone_schema!/1` does exactly two things: `DROP SCHEMA IF EXISTS ... CASCADE` plus delete the
  tenant's `Registration` row, then the **existing** `clone_tenant_schema!/1` (same retry and error
  shape; it inserts a *new* `Registration` row). It does **not** assert completeness, capture a baseline
  or snapshot anything: those are the pool worker's job (4.6), because `assert_schema_complete!/2` is the
  fixture's private function and the snapshots live in the worker.
- None of the existing public functions changes signature or behaviour. `clone_tenant_schema!/1` is
  unchanged (the pool calls it).

## 3. Pool lifecycle

### 3.1 How a module opts in, and ordering (M-e)

```text
setup_all context  -> Letflow.TenantFixture.start_pool!(context, slots: [...])   (returns [tenant_pool: pool])
setup context      -> Letflow.TenantFixture.attach_pool!(context)                (returns :ok)
```

- Both are called from the adopting module's own `setup_all` / `setup`. `setup` is mandatory:
  per-test setups run in the **test process**, which is where `provisioned_tenant!/1` is called, so
  the attachment is stored in that process's dictionary (key `{Letflow.TenantFixture, :pool}`) together
  with an empty per-test claim map (key `{Letflow.TenantFixture, :claims}`). The test process is fresh per
  test, so nothing needs releasing.
- **Ordering rule: the module's `attach_pool!` setup must be declared before every setup that calls
  `provisioned_tenant!/1` or a helper that does (e.g. `three_tenants!`).** `DataCase`'s own `setup`
  (checkout) runs first because `use Letflow.DataCase` precedes the module's setups; `attach_pool!`
  must be the module's **first** `setup`.
- **Misordering fails loudly, never silently falls back or double-hands a slot:**
  1. `attach_pool!/1` raises `ArgumentError` if the test process already has an attachment (second call)
     or already holds any claim.
  2. `provisioned_tenant!/1`, on a process with **no** attachment, first asks whether the owning test's
     module (already derived by the existing `owning_test/0`) has a registered pool worker
     (`Letflow.TenantFixture.Pool.<Module>`, 8.3). If it has and the process is the test process, it raises
     `ArgumentError` naming the module and stating "attach_pool!/1 must be the first setup". A process with
     no pool registered for its module takes the default path as today; a spawned `Task` of a pooled
     module also reaches the default path (8.4) and that is by design (it has no `owning_test` ancestry
     problem because it is not the test process: the check applies only when `self()` is the test process).
- `setup_all` order: `start_pool!` runs once, in the module process, **before** any test and before any
  `DataCase` per-test checkout. It sets `Sandbox.mode(Letflow.Repo, :auto)` itself so its own queries
  and the worker's queries are committed.
- No `use`-macro is added; two explicit one-line calls keep the opt-in greppable.

### 3.2 State shape (lives in one linked helper process per pool)

`start_pool!` spawns **one** plain helper process (linked to the `setup_all` process, never supervised,
never in the application tree). It exists for one reason: a reset TRUNCATE or a slot rebuild issued from
the *test* process would run on the test's connection and could contend with the test's own locks and
open statements (OQ-2). The helper has no `$callers` entry and no Sandbox allowance, so under `:auto`
mode its statements run on ordinary pool connections and commit.

Worker state (one map entry per slot):

| Field | Meaning |
|---|---|
| `key` | `{shape, k}`: `shape` = the five `slot_spec` fields with defaults applied, `k` = 0-based occurrence index of that shape within one test |
| `tenant_id`, `schema_name` | fixed for the module's lifetime (rebuild reuses the same id; the schema name is a pure function of it) |
| `baseline` | `clone_baseline()` captured immediately after the completeness assertion; **replaced on every rebuild** |
| `tenant_snapshot` | full-row JSON of `public.tenants` for this id; re-taken on every rebuild |
| `registration_snapshot` | full-row JSON of this tenant's `tenant_schemas` row; **re-taken on every rebuild** (a rebuild inserts a new row with a new id and timestamps) |
| `status` | `:clean` (created or rebuilt, not yet handed out) or `:handed_out`. **Informational only (stats, logging); it never skips a proof** (F5, 4.0) |
| `generation` | integer, +1 on every rebuild (used by tests to prove fail-safe) |

Pool-level state: `public_keyed` (list of `{table, column}` discovered once, section 5.1) in
children-before-parents delete order, the FK-referencing graph of the clone schema (computed once from
`pg_constraint` of the first slot, recomputed on rebuild), the seed table list
`["event_type_registry","schema_migrations"]`, the registered `hooks`, and `pool_stats`.

### 3.3 Slot creation (once per module, in `start_pool!`)

For each `slot_spec` in declared order, executed **in the worker**:
`Sandbox.mode(:auto)` -> insert the `Tenant` row exactly as the default path does (same
`create_changeset/3`, same slug generator) -> `ensure_template!/0` -> `clone_tenant_schema!/1`
(error -> `report_and_raise` with phase `replay_failed`, as today) -> `assert_schema_complete!/2` with the
spec's `expected_tables` -> `capture_clone_baseline!/1` -> snapshot tenant and registration rows ->
`status: :clean`. Slot creation additionally runs
`Letflow.Test.TenantTemplate.assert_clone_parity!(template_schema_name(), slot_schema)` (all 13
dimensions) **only when the pool was started by `tenant_fixture_pool_test.exs`** (cost is a test of the
pool, not a per-module tax).

Slots are created **only here, never lazily from a test**. A call that names a shape/occurrence that was
not declared **raises** (`ArgumentError`, message names the shape, the declared slots and the test), it
does not silently clone. Cost to the adopter: each declared slot is one ~0.8 s clone per module; declare
the maximum number a single test claims (`three_tenants!` = 3 distinct shapes; StoreTest = 1 shape x 2
occurrences).

### 3.4 Teardown (F6)

`start_pool!` registers `on_exit` (setup_all-level, runs after the module's last test whether tests
passed, failed, timed out, or the module crashed). **Its first action is
`Sandbox.mode(Letflow.Repo, :auto)`**, and the same call precedes every statement the worker issues in
teardown. Reason: `DataCase` leaves the mode at `{:shared, dead_test_pid}` after the last test; if that
test never called `provisioned_tenant!/1` (which is what flips to `:auto`), teardown statements would
raise `DBConnection.OwnershipError` and leave the schema to the reaper. Note the side effect, which is
harmless at this point: `Sandbox.mode/2` checks in **every** existing checkout repo-wide (ISS-0113 9.1);
module-end teardown runs when no test of this module is executing, and ExUnit runs sync modules serially
after all async modules, so no other test's checkout is live.

Then, for each slot, in the worker's still-alive process or, if it died, in the on_exit process itself:
reset public keyed rows (section 5), then the **same three statements as the per-test `teardown/2`**
(DROP SCHEMA IF EXISTS CASCADE, delete `Registration`, delete `Tenant`), preceded by one marker line
`LETFLOW_TENANT_FIXTURE phase=pool_teardown ...`. Then the worker stops. Anything left behind in a crash
is already covered by `TenantSchemaReaper`'s sweep (same schemas, same naming) exactly as an un-torn-down
default tenant is today.

### 3.5 A test fails or times out mid-way

- The test process dies; ExUnit still runs its `on_exit`s. The pool needs nothing from that process
  except the end fence of 3.6 (which is allowed to fail).
- Next acquire runs the full fence + detect + reset + verify (4.0); it never trusts the previous test's
  exit state and does not depend on an `on_exit` having run.
- A test that died holding row locks or an open transaction on the slot makes the reset's DDL wait;
  the reset runs with `SET LOCAL lock_timeout = '3s'` and `statement_timeout = '30s'`. A timeout is an
  `unprovable` outcome -> rebuild. If the rebuild itself cannot run (lock still held), the acquire
  raises a loud `ExUnit.AssertionError` carrying `capture_schema_state/1` (same reporting as the default
  path's `report_and_raise`), failing that test rather than handing out a dirty tenant.

### 3.6 End-of-test fence (F2 detection; per test, registered at first claim)

The **first** claim in a test registers one `on_exit` callback that calls `pool_end_fence!/0`, in the test process
(ExUnit runs `on_exit` callbacks in reverse registration order, so the fence runs after any `on_exit`
the test registered later, and the pooled path registers *no* per-test `teardown/2`). The fence runs in the
worker and does:

1. Wait for **quiescence**: poll (10 ms step, 500 ms budget) `pg_stat_activity` for this database, excluding
   the worker's own backend, for any backend whose `state` is `active` or `idle in transaction` /
   `idle in transaction (aborted)` **and** whose current/last `query` text mentions a pooled slot's schema
   name or tenant id. The test process itself is dead by now (on_exit runs after it exits) and its
   connection is idle.
2. If a matching backend is still not quiescent after the budget: **raise `ExUnit.AssertionError`** in the
   `on_exit`, which fails the *owning* test with a message naming the schema, the backend pid, its state
   and its query text ("a process was still using the pooled tenant after the test finished"). It also
   sets every slot to `:handed_out` and records `fallback_reasons: :straggler_at_end`.
3. Otherwise `:ok`. The fence changes no data and never resets anything; reset happens only at acquire.

Honest limit: the fence sees only a straggler that is *mid-statement or mid-transaction* at that moment and
whose SQL text contains the schema name or tenant id (all `prefix:`-scoped Ecto queries do). A straggler
that is sleeping and writes later is covered by the audit rule (6.2), the next acquire's fence A, and the
final guard (4.3), and is otherwise the residual risk RR-1.

## 4. Dirty detection and reset algorithm

### 4.0 One rule for every acquire (F5)

**Every acquire of a pooled slot runs the full sequence below, including the first acquire after slot
creation and after a rebuild.** `status` never skips a step. The sequence is:

```text
fence A  ->  detect (probe P + digest D)  ->  [ reset  ->  verify (probe P + digest D) ]  ->  final guard  ->  return
```

- If detect finds nothing dirty and no drift, **no DML is issued and the verify pass is the detect pass**
  (no second probe); the final guard still runs. A clean acquire costs about fence 1 ms + P 4 ms + D 13 ms
  + guard 4 ms = ~22 ms, not 0.
- If detect finds dirt, the reset runs and a **second** full probe + digest is the verify pass.
- Definitional drift in detect skips straight to rebuild (4.3 step 2), whose result is then run through the
  same detect/verify (4.6).

### 4.1 Why probe-per-table plus a definitional digest (and not xmin / pg_stat)

| Candidate | Verdict |
|---|---|
| Probe each table `EXISTS (SELECT 1 ...)` in one statement | **Chosen for row data.** Exact (committed state), 3.6 ms for 57 tables, no dependence on statistics |
| Definitional digest of catalog rows (4.2 item 1) | **Chosen for structure.** Exact, one statement, ~13 ms; sees everything `assert_clone_parity!` dimensions 1-6, 8-13 compare, at runtime |
| Names + counts of indexes/constraints/triggers | **Rejected (the first draft).** Blind to DISABLE TRIGGER, ALTER COLUMN, same-name index/constraint recreate, ALTER SEQUENCE, comments (F1) |
| `pg_stat_user_tables.n_tup_ins/upd/del` deltas | Rejected: stats are asynchronous and flushed lazily; counts cannot distinguish "inserted then deleted" from clean |
| `xmin` / `pg_class.relfilenode` snapshots | Rejected: transaction-id scan needs a read of every row; relfilenode changes only on rewrite and does not see plain inserts |
| `reltuples` | Rejected: estimate, not a proof |
| Running `assert_clone_parity!` against the live template per acquire | Rejected as the runtime check: it needs the template (ISS-0842 rebuild hazard) and is a per-table Elixir loop of many round trips; used instead in the pool's own test (section 9, after every reset) as an *independent oracle* of the digest |

A table is *dirty* iff `EXISTS` is true. Because the pool is fully reset to "all non-seed tables
empty", row presence **is** the correct and complete dirtiness predicate for table data.
UPDATE-in-place can only occur on rows that exist, so it is covered the same way. The only tables that
legitimately hold rows when clean are the seeds (4.4).

### 4.2 Probe P and digest D (read-only; run in the worker; each is one round trip)

1. **Definition digest D** (F1). One statement over the clone schema (named `$sch`) that produces a set of
   *definition rows*, sorts them, and returns `{count, md5(string_agg)}`. The definition-row classes
   (each row is a `|`-joined text of the listed fields; **the schema's own name is left in place**,
   because baseline and every later probe read the same schema):
   - `T` every relation in the schema (all relkinds): relname, relkind, `reloptions`, RLS flags,
     persistence, owner, ACL, tablespace, `relispartition`, table comment.
   - `C` every column of every table: ordinal, name, `format_type(atttypid, atttypmod)`, NOT NULL,
     identity, generated, `attstattarget`, collation, `pg_get_expr(adbin)` default, column comment.
   - `K` every constraint: name, validated, deferrable, deferred, `pg_get_constraintdef`.
   - `I` every index: `indisvalid`, `indisready`, `indisclustered`, `pg_get_indexdef`.
   - `G` every non-internal trigger: **`tgenabled`**, `pg_get_triggerdef`.
   - `F` every function in the schema: name + md5 of `pg_get_functiondef` (trigger functions included).
   - `Q` every sequence: type, start, increment, max, min, cache, cycle (`pg_sequence`).
   - `P` policies, `R` rewrite rules, `Y` domains/enums/ranges, `X` extended statistics, `H` inheritance
     parents.
   Measured: 995 rows and ~13 ms for a clone-shaped schema (1.1). This is a superset of what
   `assert_clone_parity!` dimensions 2-6 and 8-13 compare (columns, constraints, indexes, sequences,
   identity, triggers + trigger functions + comments, reloptions, attstattarget, extended stats, RLS /
   ownership / partitioning, type and collation), expressed as one digest instead of a diff.
   Dimension 1 (table set) is class `T`; dimension 7 (seed row counts) is probe item 4 below.
2. **Row presence**: `UNION ALL` of one `EXISTS` per table in the **baseline's** table set (not a
   hard-coded list, so a migration adding a table is picked up with no edit here).
3. **Sequences**: `pg_sequences` rows in the schema with `last_value IS NOT NULL`
   (a never-called sequence has NULL; `RESTART` returns it to NULL).
4. **Seed digests** for each seed table: `{count(*), md5(string_agg(row::text, '|' ORDER BY row::text))}`
   compared to the baseline's.

Probe P = items 2-4 (~4 ms). `D` = item 1 (~13 ms). The final guard (4.3 step 6) runs P only.

### 4.3 Decision order (reset)

1. **Fence A** (quiescence, same predicate as 3.6 step 1 but budget 250 ms): wait until no non-worker
   backend is active / idle-in-transaction against the slot. If it is still not quiescent, continue (the
   proof below is what protects the test) and record `fallback_reasons: :straggler_at_acquire`; do not
   raise here, the straggler's writes will be visible to detect and reset like any other dirt.
2. Run **D** and **P** (detect). If `definition_digest` differs from `baseline` -> do not attempt any
   reset; go straight to **rebuild** (4.6, reason `:definition_drift`, with the differing row classes in
   `definition_drift`). This catches `CREATE TABLE`, `DROP`/`DISABLE TRIGGER`, `ALTER COLUMN`,
   same-name index/constraint recreate, `ALTER SEQUENCE`, `COMMENT ON`, replaced trigger function bodies.
3. Compute `D` = dirty non-seed tables; `S` = tables owning a dirty sequence; `V` = diverged seeds.
4. If `D`, `S`, `V` are empty and public state is clean (section 5) -> already clean: no DML at all;
   this detect pass is the verify pass (4.0). Go to step 7.
5. Open one transaction with the timeouts of 3.5, then, in this order:
   1. **Truncate set** `T` = `D` closed under "tables whose FK references a member of the set"
      (computed from the pool's FK-referencing graph; the added members are `closure_added`). If a seed
      table is in `T` or in `V`, it is re-seeded in step 3. One statement:
      `TRUNCATE <T...> RESTART IDENTITY` — **no CASCADE** (CASCADE would silently widen the set to
      tables we did not probe; with an explicit closure a missing edge raises instead of hiding).
      `RESTART IDENTITY` restarts the sequences owned by those tables' columns to their start.
   2. **Sequences-only dirt** (`S` tables not in `T`: rows were deleted but `nextval` advanced, and
      sequences are never rolled back): `ALTER SEQUENCE ... RESTART` per such sequence.
   3. **Seeds**: for each seed table in `T ∪ V`: `TRUNCATE` (if not already) then
      `INSERT INTO <clone>.<seed> SELECT * FROM tenant_template.<seed>` — the exact two seed
      statements of `do_clone` steps 7-8 (one mechanism, 4.4). Seeds are *restored*, never left empty.
   4. **Public state** (section 5), same transaction.
6. Commit. Run **D** and **P** again (**verify**). The slot is `clean` only if: `definition_digest ==
   baseline`, `D' = S' = V' = ∅`, public keyed counts all 0, tenant/registration rows == snapshots.
   Anything else -> `{:error, {:unprovable, reasons}}` -> rebuild (4.6, reason `:verify_failed`). A seed
   digest mismatch caused by a template rebuilt mid-module is such a case and is self-healing (4.4).
7. **Final guard**: run **P** once more immediately before returning the tenant to the caller (the
   `after_verify` test hook, if any, runs *before* it). If the guard finds any dirt (a writer slipped in
   after verify), repeat steps 5-6 **once** (`final_guard_resets` + 1, `fallback_reasons:
   :final_guard`), then run the guard again; if it is still dirty, **raise** `ExUnit.AssertionError`
   (`pool_straggler`, naming the tables and the quiescence-probe result) rather than return the slot.
   The `after_guard` test hook runs after this step and exists only to prove RR-1 (M13c).
8. Return the tenant map. Mark `status: :handed_out`; register the end fence (3.6) on the first claim.
9. Rebuild failure after one attempt raises (3.5).

### 4.4 Seed tables — one restore mechanism (F3)

| Table | Clean state | Restore |
|---|---|---|
| `event_type_registry` | `{count, md5}` equals the slot baseline | `INSERT ... SELECT * FROM tenant_template.event_type_registry` after TRUNCATE |
| `schema_migrations` | `{count, md5}` equals the slot baseline | `INSERT ... SELECT * FROM tenant_template.schema_migrations` after TRUNCATE |

**There is exactly one restore mechanism: re-copy from the live `tenant_template`, using the same two
statements `do_clone` uses.** The baseline stores only `{count, md5}` per seed table, never rows (the
`@opaque clone_baseline` and `clone_state.seed_digests` shape above is complete; no row term is held).

ISS-0842 ordering assumption, stated: **`tenant_template` content is stable for the lifetime of a module's
pool**. `ensure_template!/0` rebuilds the template only when its migration fingerprint is stale (a code
or migration change between runs), never mid-run of one VM. If that assumption is ever violated, the
re-copy produces a digest different from the slot baseline, the verify pass fails, and the slot is
**rebuilt by a fresh clone** (which copies the new template and recaptures the baseline); the failure
mode is therefore a rebuild, never a silent wrong seed. OQ-6 of the first draft is withdrawn.

### 4.5 FK ordering, triggers, sequences — summary

- FK: one TRUNCATE statement with an explicit FK closure; no ordering problem (PG permits referencing
  and referenced tables in one TRUNCATE). Public-schema deletes are ordered children-first (5.1).
- Triggers: not dropped, not disabled, not fired (TRUNCATE does not fire row triggers). The digest
  (class `G`, including `tgenabled`) and class `F` prove they are present, enabled and unchanged.
- Sequences: reset by `RESTART IDENTITY` (owned) and `ALTER SEQUENCE RESTART` (4.3 step 5.2). Their
  *parameters* are in the digest (class `Q`); a changed `INCREMENT`/`START` is drift -> rebuild.
  Mutation test M2 proves the class "row deleted, sequence advanced".

### 4.6 Rebuild (F4) — who does what

Executed **in the pool worker process** (never the test process), for one slot, in this order:

1. `Sandbox.mode(Letflow.Repo, :auto)`.
2. `TenantTemplate.rebuild_clone_schema!(tenant_id)` (drop schema, delete the old `Registration` row,
   `clone_tenant_schema!/1` which inserts a **new** `Registration` row).
3. `assert_schema_complete!(schema_name, expected_tables)` (fixture-private, so this step lives in
   `TenantFixture`, not `TenantTemplate`); failure -> `report_and_raise` phase `incomplete_schema`.
4. `capture_clone_baseline!/1` -> **replace** `slot.baseline` (a rebuilt schema is the new truth).
5. Re-snapshot `tenant_snapshot` and **`registration_snapshot`** (new row id and timestamps).
6. Recompute the FK graph if the schema's table set changed; `generation` + 1; `rebuilds` + 1;
   `status: :clean`; log `phase=pool_acquire outcome=rebuilt`.
7. Then run the normal 4.3 steps 2-7 on the rebuilt slot (detect finds it clean; no DML; final guard).
   A rebuilt slot is never handed out on the strength of the rebuild alone.

Rebuild cost: one clone (~0.8 s) + one drop (~42 ms): the same as a default-path test, i.e. the worst case
equals today's cost (+ ~26 ms of proof). A rebuild that itself fails raises (INV-P1 holds by exception).

## 5. Public-schema state keyed to the tenant (the ISS-0410 class)

### 5.1 Discovery (once per pool, in the worker)

`public_keyed` = every base table in schema `public`, other than `tenants`, `tenant_schemas` and
`schema_migrations`, that has a column which is **either** (a) the referencing column of an FK to
`public.tenants(id)` (`pg_constraint`, contype `f`), **or** (b) a `uuid` column named `tenant_id`,
`owner_tenant_id`, or ending in `_tenant_id` (catches keyed-but-FK-less columns). Discovery is by
catalog, not by a hard-coded list, so a later migration adding such a table is covered. As of this
design the set read from migrations is: FK-based `solution_pack_installs`, `solution_pack_artefact_bases`,
`pack_update_resolutions`, `onboarding_registry`, `service_catalog` (`owner_tenant_id`),
`entity_column_promotions`, `entity_constraint_activations`, `public_read_handles`,
`platform_migration_rollouts`, `event_history_retirements`,
**`event_history_retirement_outcomes`** (`tenant_id` FK, `on_delete: :nothing`), `tenant_memberships`,
`tenant_login_directory`; and FK-less, caught by rule (b) only: **`secrets`**
(`add :tenant_id, :binary_id, null: false`, migration 20260830000003). The implementer re-derives the list
from the catalog; this list is informative.

Delete order: topologically children-before-parents over FKs **among** `public_keyed`. A cycle among
them raises at `start_pool!` (loud, adoption-time) instead of guessing.

### 5.2 Per-acquire public reset (same transaction as 4.3 step 5)

1. For each `{table, column}`: probe `EXISTS (... WHERE column = $tenant_id)` (batched in the probe of
   4.2); for tables with rows: `DELETE FROM public.<table> WHERE <column> = $tenant_id`, children first.
   (DELETE, not TRUNCATE: the public tables are shared by other tenants' rows and tests.)
2. `public.tenants` row: compare `to_jsonb(row)` with `tenant_snapshot`; if different, restore every
   column from the snapshot with one `UPDATE ... SET (all columns) = (jsonb_populate_record(NULL::
   public.tenants, $snapshot))` keyed on id (columns enumerated from `information_schema.columns` once
   per pool). This covers a test that changed `status`, `settings`, `display_name`, `idp_realm_id`,
   `oidc_mode`.
3. `public.tenant_schemas` (`Registration`) row: same compare-and-restore against
   `registration_snapshot` (the snapshot current for this generation, 3.2). The row is never deleted by a
   reset (only by a rebuild, which re-snapshots).
4. A DELETE or UPDATE that raises (FK violation from a table the discovery did not classify, etc.)
   makes the reset `unprovable`; rebuild also cannot repair public state, so the acquire **raises**
   loudly (the same visible class as today's teardown `delete_all(Tenant)` FK failure). It never
   proceeds.

### 5.3 What is explicitly not reset

Public rows **not keyed to a pooled tenant** (global rows such as an unkeyed `service_catalog` entry,
rows keyed to tenants the test itself created outside the fixture). Their lifecycle is unchanged: the
test's own `on_exit`, exactly as today. A pooled tenant does not make these any more or less leaky
(a fresh tenant id never protected them).

## 6. VM-global state and spawned processes keyed to a tenant

A fresh tenant id per test used to isolate tenant-keyed in-memory state **and** made any straggler process
harmless (it hit a dropped schema or a different id). A pooled id reuses the same key across the
module's tests, so both classes need an audit before adoption.

### 6.1 In-memory (ETS / persistent_term / env) holders

`lib/` holds exactly these ETS/persistent-term holders: `Letflow.Api.AuthzDenyLog` (sampler windows,
hashed tenant key), `Letflow.Plugs.LoginDiscoveryRateLimit.Bucket`,
`Letflow.Plugs.PublicReadRateLimit.Bucket`, `Letflow.Engine.PluginRegistry`, `Letflow.Metrics.Registry`.
The mechanism for a hit is `reset_hooks:` (2.1), which runs a caller-supplied function in the test
process after the DB reset.

### 6.2 Adopter audit rule for spawned / supervised / un-awaited processes (F2)

**Rule.** Before a module adopts the pool, ELIXIR-DEV audits the module **and** every helper and `lib/`
entry point it calls for any process that can outlive the test process and touch the tenant schema, and
records the result in a comment above the module's `setup_all` (one line per item). Items:

1. `Task.async` / `Task.start` / `Task.Supervisor.*` / `spawn*` / `start_supervised` / `GenServer.cast` in
   the module and its test-support helpers: every such process must be provably **awaited or stopped
   before the test body returns** (`Task.await*`, `Process.monitor` + `assert_receive :DOWN`, or
   `on_exit` stop).
2. `lib/` fire-and-forget workers reachable from the calls the module makes. Known set (grep of `lib/`):
   `Letflow.Obs.Alerts.fire_hooks/4` -> `Task.Supervisor.start_child(Letflow.Obs.Alerts.TaskSupervisor)`
   (`obs/alerts.ex:484`; reached only through `Scheduler.Poller` -> `Alerts.build_context_and_detect/3`,
   i.e. only with the scheduler running; `start_scheduler: false` in test); `Letflow.LoginDiscovery.
   Dispatch.submit/3` (`login_discovery/dispatch.ex:56`, `async_nolink` at `:126`; reached only from
   `routers/login_discovery.ex:97`); the retention fan-out (`RetirementTaskSupervisor`,
   `event_store/retention_operations.ex:176`) and the Lua / Wasm / plugin `async_nolink` executors, all
   awaited in-process by their callers; `Letflow.Engine.ServiceTaskDispatcher.Poller` and
   `Letflow.Scheduler` (disabled by `start_service_task_dispatcher: false` / `start_scheduler: false`).
3. Telemetry handlers, `Application.put_env`, ETS holders (6.1).

**A module for which an item cannot be shown straggler-free MUST NOT be adopted** (it keeps the default
fresh clone). This is not an implementer judgement call: a module is adopted only with an all-clear audit
comment.

**Audit results for the three first adopters** (from this step's greps; ELIXIR-DEV re-confirms by reading
the module, and a changed result removes that module from the PR):

| Module | Spawns in module / helpers | Reachable `lib/` spawners | Result |
|---|---|---|---|
| `IdentityIdHardeningTest` | none (no `Task`, `spawn`, `start_supervised`, `GenServer`) | calls `Letflow.Routers.Identity` and `Letflow.Identity.*` only; `Identity.RoleBackfill` uses `Task.async_stream` synchronously inside its caller and is not on any path the module calls; none of Alerts / LoginDiscovery.Dispatch / retention is called | **Straggler-free. Adopt.** Note: T-12b commits `CREATE TABLE zz_probe` into slot P; the digest sees it and the next acquire **rebuilds slot P** once (expected, M8a). T-12c (`information_schema ... zz_probe` empty) runs after that acquire in `setup` and passes because the rebuild dropped the schema |
| `PromotionScopeTest` | none | calls `Letflow.Routers.Promotions`, `Definitions`, `Tenants` (promote) only; no spawner on those paths; pins platform tenant via `PlatformTenantFixture.pin!/1` whose `Application.put_env` restore `on_exit` is per test | **Straggler-free. Adopt** |
| `Letflow.Definitions.StoreTest` | `Task.async` at `store_test.exs:338-339`, `:1151`, `:1162`; every one is `Task.await_many`-ed in the same test | `Definitions.create/activate` only; no fire-and-forget; telemetry handler at `:1110` is detached by `on_exit` | **Straggler-free (all awaited). Adopt** |

### 6.3 Mitigations that back the audit (not a substitute for it)

Fence A (4.3 step 1), the final guard (4.3 step 7) and the end-of-test fence (3.6) together convert the
most likely straggler outcomes into a loud failure of the **owning** test instead of silent corruption of
the next one. The residual class is RR-1 in 9.4.

## 7. Which tests keep a fresh per-test clone, and how the default path stays unchanged

A call is served from the pool **only when all of**: a pool is attached to the calling test process;
`opts[:template]` is `:clone` (default); `opts[:teardown]` is `true` (default); `opts[:pool]` is not
`false`. Everything else takes the unchanged code path.

| Test class | Why it keeps the fresh clone | Mechanism |
|---|---|---|
| No `start_pool!` / `attach_pool!` in the module (every module today: all but the 3 adopters of the 455 `*_test.exs` files) | default behaviour | the pdict key is absent and no pool is registered for the module -> the new branch returns "not pooled" before any other work |
| The `template: :replay` sites (29 occurrences in 14 files: 9 test files under `test/letflow/`, `test/support/tenant_fixture_dispatch_test.exs`, `test/support/public_read_fixture_support.ex`, `test/support/tenant_fixture.ex`, and 2 spec `.md` files) | they need a genuinely migrated schema | `:replay` is excluded by the rule above |
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
   module; the check is the worker's registered name `Letflow.TenantFixture.Pool.<Module>`).
4. `provisioned_tenant!/1` called from a process whose dictionary has no pool attached never reaches
   the pool (section 7); a *spawned* process (a `Task`) never has the attachment, so it takes the
   default path — it cannot accidentally mutate a slot through the pool API.

No claim is made that any async module can use it; none may.

## 9. Isolation proof (mutation test), fail-safe and what is claimed

New file: `test/letflow/support/tenant_fixture_pool_test.exs`, `use Letflow.DataCase, async: false`,
adopting the pool itself with **two** `slot_spec`s of different shapes (plus a second occurrence of one
shape for M11). Its header records the OQ-2 probe result.

### 9.1 Cross-test proof (no ordering assumption)

Every test in a describe block follows the same shape, so it does not matter which runs first:
(i) `assert_pristine!` — all of classes M1-M7 below are clean (`pool_dirty_report/1` `clean?: true`
AND direct reads); (ii) `mutate_everything!` — write every row-level class; (iii) leave. With >= 3 tests,
each test other than the first proves that the previous test's leftovers are gone. Each test also asserts
that `pool_dirty_report/1` taken **after** `mutate_everything!` lists exactly the classes written
(the "teeth" check: proves the proof is not vacuous because detection *sees* the mutation).

### 9.2 Boundary proof (deterministic, in one test)

`recycle_pool!/0` simulates the test boundary (clears the per-test claim map so the same slot is
re-acquired in-process, marks the slot `:handed_out`, and runs the end fence of 3.6). Shape: acquire ->
mutate -> report is dirty -> `recycle_pool!` -> acquire again -> assert pristine.

### 9.3 Mutation classes

Row-level classes are each written from **the test process** and, separately, from a `Task` in `:auto`
mode (answer B: both commit). Definition-level classes are written from the test process.

| ID | Class | Mutation | Must be pristine next |
|---|---|---|---|
| M1 | tenant table rows, FK chain | insert `groups`, `group_members`, `users`, `tenant_role` (FK to groups), `process_definitions` rows | all tables empty (except seeds) |
| M2 | sequence advanced, row gone | in the slot schema, with `events` empty, run `SELECT nextval('<schema>.events_global_seq_seq')` (the sequence owned by `events.global_seq`; `tenant_template` has it and `events_pre_partition_20260922_global_seq_seq`) so the table is empty but the sequence `last_value` is not null | `dirty_sequences == []`; next `events` insert gets `global_seq = 1` |
| M3 | seeded table UPDATE | `UPDATE event_type_registry SET ...`, `DELETE` one row, `INSERT` an extra row | digest equals baseline; row set equals `tenant_template`'s |
| M4 | seeded `schema_migrations` | delete a version row | version set equals baseline |
| M5 | public row keyed to tenant | insert a `tenant_login_directory` row and a `tenant_memberships` row for the pooled tenant id (children first), and a `secrets` row (`tenant_id`, no FK) | `public_keyed_rows == []` |
| M6 | tenant row | `UPDATE tenants SET status/settings/display_name` | row equals snapshot |
| M7 | registration row | update `tenant_schemas.migrations_applied_at` | row equals snapshot |
| M8a | **definition: new table (F1)** | `CREATE TABLE <schema>.zz_probe (...)` committed (via a `Task`) | `generation` +1, `fallback_reasons` has `:definition_drift`, table set equals baseline |
| M8b | **definition: dropped trigger** | `DROP TRIGGER audit_entries_no_update ON <schema>.audit_entries` | rebuild; the trigger exists and is enabled; an `UPDATE` of an `audit_entries` row raises the immutability error |
| M15 | **definition: DISABLE TRIGGER, counts unchanged (F1)** | `ALTER TABLE <schema>.audit_entries DISABLE TRIGGER audit_entries_no_update` (name, count, function unchanged; only `tgenabled` flips) | digest differs -> rebuild; `tgenabled = 'O'` again; the immutability error is raised again. Teeth: a **names+counts** fingerprint (the rejected first-draft design) would report equal here, and the test asserts the digest is **not** equal before the reset |
| M16 | **definition: column alteration, counts unchanged** | on `groups`: `ALTER COLUMN <a text col> SET DEFAULT 'x'`, then separately `ALTER COLUMN <a NOT NULL col> DROP NOT NULL`, then `ALTER COLUMN <varchar> TYPE text` (each its own test; column count and names unchanged) | rebuild; `information_schema.columns` equals baseline for `groups` |
| M17 | **definition: index recreate, same name** | `DROP INDEX <schema>.<a non-unique index on groups>`; `CREATE UNIQUE INDEX <same name> ...` (index count unchanged, name unchanged, definition different) | rebuild; `pg_get_indexdef` equals baseline |
| M18 | **definition: constraint recreate, same name** | `ALTER TABLE <schema>.tenant_role DROP CONSTRAINT tenant_role_group_id_fkey`, `ADD CONSTRAINT tenant_role_group_id_fkey FOREIGN KEY ... ON DELETE CASCADE` (constraint count and name unchanged) | rebuild; `pg_get_constraintdef` equals baseline (the FK is `NO ACTION`/`RESTRICT` again; T-12 of IdentityIdHardeningTest depends on it) |
| M19 | **definition: sequence parameters** | `ALTER SEQUENCE <schema>.events_global_seq_seq INCREMENT BY 7` | rebuild; `pg_sequence.seqincrement == 1` |
| M20 | **definition: comments** | `COMMENT ON TABLE <schema>.groups IS 'x'`, `COMMENT ON COLUMN <schema>.groups.id IS 'x'` | rebuild; `obj_description` / `col_description` are NULL again |
| M21 | **definition: trigger function body** | `CREATE OR REPLACE FUNCTION <schema>.audit_entries_immutable() ...` with a no-op body | rebuild; the function's `pg_get_functiondef` equals baseline |
| M9 | **fail-safe: verify cannot pass** | a held lock from a second connection on a slot table makes the reset time out (`lock_timeout`) | `generation` incremented via rebuild OR a loud raise; **never** a returned dirty tenant |
| M10 | late writer between tests | a spawned process inserts a row *after* the test returned (simulated by a write between `recycle_pool!` and the next acquire) | detected by the next detect pass; row absent |
| M13a | **post-verify writer, caught by the final guard (F2)** | the `after_verify` hook inserts a committed row into a tenant table *between verify and the final guard* | `final_guard_resets` +1; the returned tenant is empty; `fallback_reasons` has `:final_guard` |
| M13b | **persistent writer** | the `after_verify` hook writes on **both** passes | `provisioned_tenant!/1` **raises** `pool_straggler`; no map is returned |
| M13c | **write after the guard: containment (RR-1)** | the `after_guard` hook inserts a row after the final guard (not detectable by construction) | that row is visible to the owning test (documented, asserted); `pool_dirty_report/1` lists it; **the next acquire is pristine** (damage bounded to one test) |
| M14 | **straggler at end of test (F2)** | a process opened with `Repo.transaction` on a non-sandbox connection, `INSERT` into a slot table, then blocked in `receive` (state `idle in transaction`), is started and not awaited; the test calls `pool_end_fence!/0` directly | `pool_end_fence!/0` raises `ExUnit.AssertionError` naming the schema, backend pid, state and query; after the process is released and the test ends, the next acquire is pristine |
| M11 | no cross-slot bleed | mutate slot A of shape X; slot B of shape Y and the second occurrence of X are untouched | B and X#1 report clean without having been reset |
| M12 | default path untouched | in the same module, `provisioned_tenant!(pool: false)` returns a tenant whose `schema_name` differs from every slot and is dropped at the test's end | existing teardown phase line is emitted once |
| M22 | misordering is loud (M-e) | a nested test module (or direct call with no attachment) invoking `provisioned_tenant!/1` before `attach_pool!/1`; `attach_pool!/1` called twice | `ArgumentError` in both cases; no slot is handed out |

After every successful reset or rebuild the test also calls
`Letflow.Test.TenantTemplate.assert_clone_parity!(template_schema_name(), slot_schema)` (all 13
dimensions) — the same oracle ISS-0427 uses for freshly cloned schemas — so a reset schema is proven
structurally equal to a clone **by the independent per-dimension implementation**, not only by the
pool's own digest.

### 9.4 What is claimed (INV-P1 restated precisely; F2)

`provisioned_tenant!/1` on the pooled path returns a map only after, **in that acquire**:

- a detect or verify pass in which `definition_digest == baseline`, all non-seed tables are empty, no
  sequence of the schema has been called, seed digests equal the baseline, public keyed rows for this
  tenant are zero and the `tenants` / `tenant_schemas` rows equal their snapshots; **and**
- a final guard (row-presence + sequence + seed probe) executed by the **pool worker's own session**
  immediately before return, and passing on the same or the second attempt.

Every other outcome is one of: rebuild-then-prove-clean, or raise. There is no path that returns a slot
whose cleanliness was not proven in that acquire.

**Not claimed (RR-1, residual risk):** that no *other* process writes to the slot after the final guard
instant. A foreign writer that fires in the microsecond window between the final guard and the test's own
first statement, or during the test, is indistinguishable from the test's own write. This is bounded:
(a) adopters must pass the 6.2 audit (all three do), (b) the end-of-test fence (3.6) fails the owning test
if a writer is mid-flight at the end, (c) the damage is confined to the one test (M13c proves the next
acquire is pristine). It is strictly no worse than the default path for a process that writes to a
tenant id, because the default path's protection (a dropped schema) only existed because the id was fresh.

## 10. Failure modes

| Situation | Outcome |
|---|---|
| Probe or digest query itself errors | `unprovable` -> rebuild |
| Definition digest differs (any class T..H) | rebuild (`:definition_drift`), no in-place repair |
| Reset DML raises (lock timeout, FK) | `unprovable` -> rebuild; if public-state delete is the cause -> raise |
| Verify finds residue | rebuild (`:verify_failed`) |
| Final guard finds dirt twice | raise `pool_straggler` |
| Backend mid-flight at test end | the owning test fails in `on_exit` (`pool_end_fence!`), slot marked `:handed_out` |
| Rebuild fails | raise with `capture_schema_state/1` report + `Logger.error` under the marker (as today) |
| Worker process dies | the call exit is caught and re-raised as `ExUnit.AssertionError`; pool stats lost; `on_exit` still sweeps by deterministic schema names (after `Sandbox.mode(:auto)`) |
| Module declares fewer slots than it claims | `ArgumentError` naming shape and declared slots |
| `attach_pool!/1` missing or misordered | `ArgumentError` (3.1) |
| Template rebuilt mid-module (stale fingerprint) | seed re-copy digest differs from baseline -> verify fails -> rebuild (4.4); never a silent wrong seed |
| Test changes `Sandbox` mode itself | out of contract (same as today); worker queries are unaffected because every worker-routed API sets `:auto` first |

## 11. Measurement plan, rollout, out of scope

### 11.1 Instrumentation (permanent, tiny, marker-based)

Reuse the existing greppable marker. New lines, `Logger.info`, closed phase vocabulary extended:
`LETFLOW_TENANT_FIXTURE phase=pool_clone schema=... ms=...`,
`phase=pool_acquire slot=... outcome=clean|reset|rebuilt digest_ms=.. probe_ms=.. ms=...`,
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
  sum of `pool_acquire digest_ms` and `pool_reset total_ms`. Write the table to
  `docs/issues/ISS-1042.yaml` under `implementation_measurements` (and quote the medians in the PR body).
- CI: record the GitHub Actions **run ids** of the 5 most recent successful `main` runs of the workflow
  owning required check `Backend gate (mix letflow.check)` before the PR (BEFORE) and of 5 reruns
  of the PR head (AFTER: `gh run rerun`, ids from `gh run list --branch <branch>`), plus the shard
  job durations containing the three adopting modules (`gh run view <id> --json jobs`).
- Pass criteria: (a) no test outcome change (same passed/excluded counts); (b) median AFTER wall <=
  0.6 x median BEFORE on partition 1 (estimate in the issue: -63 %; the three first adopters hold
  204 of the 403 provisionings = 51 %, so the achieved figure is expected below the all-module estimate
  and the report states it per-module; the ~26 ms proof overhead per acquire is already inside that
  expectation); (c) if the reduction is < 25 %, the implementer records the per-phase breakdown and
  files a follow-up instead of widening adoption in this PR.

### 11.3 Rollout in this PR

Adopt in exactly three modules, from the measured top of the list, **each conditional on its all-clear
audit comment (6.2)**: `Letflow.Api.IdentityIdHardeningTest` (114 clones: 3 declared slots),
`Letflow.Routers.PromotionScopeTest` (51: 3 slots), `Letflow.Definitions.StoreTest`
(`test/letflow/definitions/store_test.exs`, 39: 2 slots, same shape twice -> `{shape,0}`, `{shape,1}`).
A module whose audit cannot be completed is **dropped from this PR**, not adopted with a caveat. The next
candidates (`ServiceTaskWiringTest` 32, `EngineRequiredOutputsTest` 25) also touch DDL/engine concurrency
and need their own audit; they are follow-ups, not done here.

### 11.4 Explicitly out of scope

Levers (a) clone-only-needed-tables, (b) shared read-only tenant / sandbox rollback, (d) CREATE DATABASE
TEMPLATE, speeding the LIKE loop itself, DELETE-instead-of-TRUNCATE for tiny tables (OQ-4), changing
async modules, changing `lib/`, changing CI workflows or check names, adopting any module beyond the
three, `SandboxPool` (design ISS-0427 section 6 still holds), any weakening of the digest (a
cheap/full split) to buy speed.

## 12. Ownership and tests that must stay green

### 12.1 `owned_modules` for ELIXIR-DEV

- `test/support/tenant_fixture.ex` (API 2.1, dispatch point, pool worker, rebuild orchestration 4.6,
  public discovery, end fence, marker phases)
- `test/support/tenant_template.ex` (2.2: baseline, probe, digest, reset, rebuild)
- `test/letflow/support/tenant_fixture_pool_test.exs` (**new**, section 9)
- `test/support/tenant_fixture_dispatch_test.exs` (add: default path unchanged with no pool; `pool: false`
  and `template: :replay` bypass an attached pool)
- `test/letflow/support/tenant_fixture_test.exs` (**conditional**: only if the closed log-phase vocabulary
  assertion needs the new phase names; C1-C6 must pass unchanged)
- `test/letflow/api/identity_id_hardening_test.exs`, `test/letflow/routers/promotion_scope_test.exs`,
  **`test/letflow/definitions/store_test.exs`** (add the two lines + audit comment only; no test body
  edits). NOTE for ORCH: the dispatched `owned_modules` lists `test/letflow/store_test.exs`, which does
  not exist; the real path is `test/letflow/definitions/store_test.exs`.
- `docs/issues/ISS-1042.yaml` (measurement table, status), `docs/anti-patterns.md` (append: pooled
  fixtures must prove cleanliness by definition digest, not by names/counts; TRUNCATE-all is slower than
  clone; a pooled id makes stragglers harmful)

Not owned / must not change: `lib/**`, `.github/**`, `test/support/platform_tenant_fixture.ex`,
`test/test_helper.exs`, `Letflow.DataCase`, `config/test.exs`.

### 12.2 Existing tests that must stay green (run before and after)

- `test/support/tenant_fixture_dispatch_test.exs`, `test/support/tenant_template_test.exs`,
  `test/letflow/support/tenant_fixture_test.exs` (C1-C6, idp_realm_id opt, teardown logging)
- The three adopting modules (every test, same count as before; IdentityIdHardeningTest T-12b/T-12c
  explicitly, see 6.2)
- `RegistryTenantSchemaMissingTest`, `TenantProvisioningTest`, the `template: :replay` files
  (`event_store/registry_test.exs`, `public_read_test.exs`, `routers/public_read_test.exs`,
  `tenant_provisioning/backfill_test.exs`, ...) — they must not be affected at all
- One file that uses `PlatformTenantFixture.three_tenants!` and does **not** adopt (e.g. a sibling
  platform-scope test) to prove the helper is untouched on the default path
- `mix compile --warnings-as-errors` and `mix format --check-formatted` on the touched files

## 13. Invariants

- INV-P1: a pooled `provisioned_tenant!/1` returns only after a detect-or-verify pass **and** a final
  guard, both by the pool worker's session in that acquire, proved the slot's definitions equal its
  baseline and its data and public state clean; otherwise it rebuilds or raises. It does **not** claim
  that no foreign process writes after the final guard (RR-1, 9.4).
- INV-P2: pools are created only in `setup_all`, never from a test process.
- INV-P3: pooled reset executes on a connection that is not owned by the test's sandbox checkout, and
  every worker-routed entry point sets `Sandbox.mode(:auto)` first.
- INV-P4: TRUNCATE sets are explicit and CASCADE is never used; a seed table is never left empty.
- INV-P5: no change to the default path's statements, return shape, log phases or order.
- INV-P6: async modules cannot create or attach a pool.
- INV-P7: no `lib/` change; the immutability triggers are never dropped, disabled, or modified by the
  pool, and a test that does so is detected and the schema rebuilt.
- INV-P8: baselines are captured only after `assert_schema_complete!/2` passed for the slot, and are
  replaced (with the registration snapshot) on every rebuild.
- INV-P9: a pool leaves no schema, `Registration` or `Tenant` row behind at module end.
- INV-P10: definitional drift is never repaired in place; it always causes a rebuild.
- INV-P11: a module is adopted only with an all-clear spawned-process audit comment (6.2).
- INV-P12: no acquire skips fence, detect, final guard on account of slot `status`.

## 14. Open questions (not silently resolved)

| ID | Question | Why it matters | Decision made in this design / what the implementer must do |
|---|---|---|---|
| OQ-1 | **Resolved (answer B)**, see 1.3: test-process writes commit under `:auto`. | — | Recorded with the sandbox-source evidence; the stale comment at `identity_id_hardening_test.exs:454` is not edited (module body edits are out of scope). The implementer records the probe result in the pool test header as a confirmation, not as a branch in the design |
| OQ-2 | Is a worker with no `$callers`/allowance really routed to a non-sandbox connection under `:auto` in this repo's `Repo` pool config? | INV-P3 depends on it | Verify with the M-tests (a committed TRUNCATE visible from a `Task`). If false, the fallback is `DBConnection` use via a dedicated non-sandbox repo config — which would be a `config/test.exs` change and must be raised to ORCH, not done silently |
| OQ-3 | Is `:async` present in the `setup_all` context of the installed ExUnit? | The async rejection requires it | Design requires explicit `false`; if the key is absent the implementer must derive it from `ExUnit` module attributes, never default to "ok" |
| OQ-4 | DELETE vs TRUNCATE for tables with a handful of rows | Possible further reset speed-up | Not measured; **TRUNCATE is specified** (only mechanism that works on the immutability-trigger tables, only one with measured numbers). Revisit only with measurements, out of scope here |
| OQ-5 | `TRUNCATE ... RESTART IDENTITY` and sequences created via `CREATE SEQUENCE` + `OWNED BY` + `nextval` default (not identity columns) | Reset correctness for the clone's recreated sequences | `OWNED BY` sequences are restarted by `RESTART IDENTITY`; M2 proves it and the 4.3 step 5.2 `ALTER SEQUENCE RESTART` covers the table-empty case. If M2 fails the implementer must report it as a design defect, not patch around it silently |
| OQ-6 | **Withdrawn.** Seeds are re-copied from the live template (4.4); no baseline rows are held | — | — |
| OQ-7 | Whether indirect public dependents (a public table with an FK to a keyed table but no tenant column of its own) exist | Would be missed by 5.1 | Discovery as specified plus the 5.2.4 loud-raise rule: such a table surfaces as a loud failure at adoption, not a silent leak |
| OQ-8 | Digest cost on a real *clone* (measured here on `tenant_template`: 12.4-17.2 ms, 995 rows) and the end-fence `pg_stat_activity` false-positive rate (background backends whose query text mentions the schema) | Gain survives only if `digest_ms` stays small; a noisy fence would fail good tests | Implementer records median `digest_ms` and fence outcomes in `implementation_measurements`. If median digest > 40 ms or the fence ever fires on a clean module, **raise to ORCH**; do not weaken the digest or disable the fence silently |
| OQ-9 | `events` / `events_archive` partitions: leaf partitions are probed and truncated through the partitioned parent (relkind `p`); whether any FK closure edge targets a leaf directly | A missed edge surfaces as a loud TRUNCATE error (no CASCADE), never a silent leak | Implementer confirms with M1/M2 on `events`; a raised edge is added to the closure computation and reported as a design note |

## 15. Acceptance-criteria mapping

| Source criterion | Element |
|---|---|
| 1. Instrumented measurement: clone time per test, tables per clone, share of test time (numbers quoted) | Quoted from the diagnosis in section 1.1 (done in step 01); digest cost measured in this rework (1.1); permanent marker lines in 11.1 keep it measurable |
| 2. One lever implemented with before/after wall time of the test phase (5 runs each, run ids) | Lever (c) refined, sections 2-5; measurement protocol 11.2 (5 + 5 interleaved local runs, CI run ids) |
| 3. Isolation proof: a test leaving data behind does not leak into the next (mutation test) | Section 9 (M1-M22: row classes, definition classes M8-M21, late/post-verify writers M10/M13/M14, cross-test and boundary proofs, teeth check, fail-safe and precise claim 9.4) |
| 4. No change to required check names; no paid runners | Section 0 and 11.4 (no `.github/**` change, no new job, no new runner); owned modules 12.1 exclude workflows |
| Task items 1-8 (API, algorithm, public state, fresh-clone classes, async, proof, measurement, ownership) | Sections 2-3, 4, 5, 7, 8, 9, 11, 12 respectively |
| Rework findings F1-F6, M-a..M-e | F1: 4.1, 4.2, M8-M21; F2: 6.2, 6.3, 3.6, 4.3 steps 1 and 7, 9.4, M13, M14; F3: 4.4; F4: 4.6, 3.2; F5: 4.0, INV-P12; F6: 3.4; M-a: 1.3, OQ-1; M-b: 1.2, 7; M-c: 1.2, 5.1; M-d: 12.1; M-e: 3.1, 2.1, M2, M22 |
