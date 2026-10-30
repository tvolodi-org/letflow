# 0065 -- Entity pre-write script hook (Record E): derived fields, and the F13 atomicity rule

Status: PROPOSED by the developer of GH #3155 (REQ-539 slice 0, task T-0477), 2026-10-25. Needs
SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice
is its own requirement (D8).

Date: 2026-10-25

Depends on: [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) (D7, F2);
[0051](0051-org-scoped-role-grants-and-enforcement.md) (T12, T13);
[0053](0053-tenant-scripted-rules.md) (hook 2, D1, D3, D5, D7, F13);
[0054](0054-process-step-writes-entity.md) (D3 lock order, D8);
[0061](0061-engine-lock-order-platform-invariant.md) (item 5, item 6);
[0062](0062-restriction-carrying-variables.md) (R4, R5, R6);
REQ-499 (GH #2587, `Records.command_multi/3`, delivered); GH #2534 (tenant script runtime, merged).

## Map of REQ-539 description items

| REQ-539 item | Where |
|---|---|
| (1) where hook 2 runs, which transaction | D1 |
| (2) the F13 atomicity rule | D2 |
| (3) time, pool, pinning (0053 deviation 8) | D3, D4 |
| (4) principal, restrictions | D5 |
| (5) failure mapping, INV-8 | D6 |
| (6) INV-1, INV-3 | D7 |
| (7) managed types, scope | D7 |
| slice list, consistency, not decided | D8, Consistency, Not decided here |

## Problem

Decision 0053 names hook 2 ("Record E") as non-binding direction that "needs REQ-484 and a dynamic data
API", and its note F13 says derived fields computed from reads are not atomic with the write. REQ-484 was
replaced by REQ-499 (`Records.command_multi/3`) and the tenant script runtime of GH #2534 is merged. This
record is the binding decision: where hook 2 runs, the F13 rule, pinning, principal and restrictions,
failure codes, managed types and scope, and the slice list.

## D1. Where hook 2 runs, and in which transaction

Hook 2 runs BEFORE the write transaction, outside every lock and every pool connection. One hooked write
(create, update, or the created/updated branch of upsert on the `Records` direct paths) is:

1. the existing build phase (validation, active definition, authority check), unchanged;
2. **read phase**: a short READ COMMITTED read-only transaction on its own connection, released before the
   script runs. It reads the sequence counter of every read type FIRST, then the rows (D2), under the read
   contract of 0053 D5, and keeps the **read fingerprint**;
3. **run phase**: the script runs in the sandbox under `ScriptAdmission` with no connection. Input is the
   restriction-filtered record candidate plus the pre-fetched reads; the output is validated;
4. **write phase**: the existing write transaction (the `Repo.transaction()` at the end of the build chain
   in `Records`) opens, takes the lock set (D2), re-validates the fingerprint, then runs the existing
   steps. A mismatch aborts the transaction before the first write.

The sandbox never opens a connection (0053 D5; a host function that calls `Repo` is the pool-exhaustion and
deadlock shape, so `fetch_instance_state` is not a precedent to copy).

**No dynamic data API.** 0053 D5 reserved a dynamic data API for Records E/F. Record E keeps pre-fetched,
declared reads (same read contract as hook 1) because the F13 fingerprint needs the read set known before
the lock step. A later record may add the API and needs its own ruling.

**Process-step path: not supported, fail closed.** `Records.command_multi/3` (callers `HandlerWrites` and
`StepWrites`) runs under the engine's instance row lock and its `lock_timeout`; a sandbox run up to the D7
wall clock would hold the instance mutex. A type with a bound hook therefore cannot be the target of an
`entity_writes` or handler line: binding is refused while an ACTIVE definition has such a line on the type,
and activation of a definition with such a line is refused while the type is bound (stable code
`entity_type_hooked`). Step-path support is a later record.

## D2. The F13 rule (normative)

**Mechanism: version check under the entity-type sequence locks, retry the whole hook, then a typed failure.**

- **Fingerprint.** Per read type, the value of that type's sequence counter (the `instance_sequences` row of
  the type's synthetic instance, the row 0054 D3 step 4a locks) at read time. It changes on every committed
  write of the type, so it covers single-row reads and filtered reads (phantoms) alike.
- **Read order.** The read phase is READ COMMITTED, where each statement takes its own snapshot, so the order
  matters: for every read type its counter is read BEFORE any of that type's rows (all counters first, then
  all rows, in one read-only transaction). A commit between the counter read and the row read can then only
  make the rows newer than the fingerprint: the write phase sees counter > fingerprint, mismatches and
  retries (a spurious retry at worst), never a stale accept. The reverse order (rows, then counter) is
  forbidden: a commit between the reads would be in the counter but not in the rows, the compare would
  match, and a stale derived value would be stored. REPEATABLE READ would also be correct but is not
  required and not relied on; the rule is the order.
- **Absent counter = the column default.** A type with no `instance_sequences` row (never written) has, as
  fingerprint, the default of `Letflow.EventStore.InstanceSequence`'s `next_seq` field (the schema default
  and the `create_instance_sequence` migration column default agree). The write-phase lock step inserts the
  row if absent (`EventStore.lock_instance_sequence/3`, which creates it with that default) and then locks
  it, so a first-ever write compares default with default and passes. A concurrent first write that
  committed first has incremented the counter above the default, so it mismatches and retries. The read
  phase never inserts the row; if the write transaction rolls back the inserted row goes with it and the
  next read phase again reads "absent" = the default.
- **Lock set and order (against 0061).** Before any write, the write transaction locks `FOR UPDATE` the
  sequence row of every type in `S = {written type} U {read types}`, ascending by entity type (byte order),
  preceded by the `scope_node_paths` table lock only where 0054 D3 rule 3a applies. This is exactly 0061
  Decision item 5; no new lock class and no new position (read types that are not written use the same row
  class). It then compares each locked counter with the fingerprint. A hooked write is a record write, not
  an engine path: it holds no instance lock and takes nothing of items 1-4; the audit chain row (item 6)
  comes after. Two hooked writers with sets {A,B} and {B,A} both lock A then B: no cycle. Every writer of a
  type takes that type's sequence row first and holds it to commit (0054 D3), so once the set is held and
  the compare matches, the rows read cannot change before this transaction commits: the stored value has a
  serial order.
- **Retry count, then typed failure.** On mismatch: roll back (nothing written, no idempotency claim, no
  write audit row) and re-run the hook from the read phase. At most **3 attempts in total** (1 run + 2
  retries; `script_busy` retries of D6 count in the same total). After the third mismatch the write fails
  with the typed code `derived_value_conflict` (retryable by the caller with the same idempotency key;
  HTTP status chosen in the router slice within the existing contention mapping). The write is never
  committed with a stale derived value and never without the derived value (fail closed).
- **Why retrying is safe.** Hook 2 is a pure function whose only effect is the single commit (0053 D4, D5:
  the ban on retrying a non-idempotent hook concerns effects, and hook 2 has none before commit); the
  idempotency claim is taken only inside the committing transaction.
- **Worked example.** Type `invoice` has a derived `total`; its hook reads type `invoice_line`, so
  `S = {invoice, invoice_line}` and the lock order is `invoice`, `invoice_line`. The `invoice_line` counter
  is 10 when W1 (update invoice I) runs its read phase: W1 reads the counter (10) first, then the rows (L1,
  L2, total 30). If W2 commits a new line L3 (amount 5) between those two reads, the rows may already hold
  L3 (total 35) while the fingerprint says 10 and the counter is 11: mismatch, retry, never a stale accept.
  *Case A:* W2 commits first (counter 11); W1 locks both rows, sees 11 != 10, rolls back, retries, reads
  L1..L3, stores 35; serial order W2, W1. *Case B:* W1 locks both and matches 10 == 10 first; W2 waits on the
  `invoice_line` sequence row until W1 commits (direct `Records` paths set no lock timeout by default; slice
  E-3 sets the 0054 D3 bound on hooked writes and a timeout maps to the existing `entity_write_contention`);
  W1 stores 30 and commits, then W2 commits L3; serial order W1, W2. No interleaving stores 30 with L3
  already committed. (If `invoice_line` had never been written, W1's fingerprint is the `next_seq` default
  and the row W1 inserts in the write phase matches it.)
- **Cost, stated honestly.** A write to `invoice` blocks writers of `invoice_line` for the write phase. The
  script run is outside that window (D3), which is why this is acceptable. A row-level fingerprint is an
  optimisation that needs its own ruling.

## D3. Time and pool

- Hook wall clock per attempt: the 0053 D7 values (default 1000 ms, maximum 5000 ms from the manifest,
  clamped). Any larger value needs a new ruling.
- The "50 ms rule" of 0053 ("it binds hooks 3 (and 2 after REQ-484)") is read here as binding the **locked
  window**: from the first lock of the write phase to commit (compare plus the existing write steps). The
  script run is outside every lock. 50 ms is the target for that window, measured in slice E-3 (as D7's
  figures stay targets); the exact budget is listed under Not decided here. `lock_timeout` 2 s and
  `statement_timeout` 5 s of 0054 D3 are unchanged.
- Pool: the read-phase connection is released before the script starts, the script task holds none, the
  write phase checks one out. At most one connection is held at any time per hooked write.

## D4. Entity-type pinning (0053 deviation 8)

- The closed pin-kind set (`:catalog_entry | :variable_schema | :module | :script` in `pin_resolver.ex`) is
  NOT extended: those are instance pins frozen in `INSTANCE_STARTED` and a record write has no instance.
- The pin is a tenant-schema row binding an entity type to `(script key, script version, sha256)`; working
  name `entity_type_hook_bindings` (migration in slice E-1). One hook per entity type. The `hook_kind` value
  `entity_write` (reserved in 0053 D1) becomes accepted; a script published for another hook kind cannot be
  bound. The version must be `published` and not `revoked`; the sha256 is stored and re-checked at run
  time; `retired` stops new bindings but an existing binding keeps running; retiring a script referenced by a
  binding is blocked (as 0053 D3).
- Bind, rebind to a new version, and unbind are `ScriptsPublish` actions, TENANT_ADMIN, audited with
  `Audit.append_multi/4` in the same Multi, OIDC credential only (`api_token_not_allowed`). Entity record
  rows do not carry the pin. The entity type is validated against the tenant's definitions at bind and again
  at run time (`recheck_definition` re-resolves the active definition under the type lock).

## D5. Principal and restrictions

- Script principal: tenant-wide, no user grants (0053 D5); the invoking actor id is recorded for attribution
  only. Hook reads are limited to declared tenant-wide master lookups and the record candidate itself; other
  scoped records are denied, indistinguishable from not found (INV-5).
- Input redaction as 0053 D5: restricted fields are omitted unless named in the manifest input schema and the
  publisher held `EntitiesRestrictionsManage`, re-checked at run time. The 0062 R6 opt-in extends to hook 2.
- Output: values for **declared derived fields only** (manifest `derived_fields`, each a field of the bound
  type). A derived field is system-owned: a caller payload that sets it is refused with the existing
  validation error shape. The hook cannot write scope-bearing fields, `managed_by` or system fields;
  refused at bind.
- The 0062 R5 predicate ("fewer restrictions" refusal) applies at bind and at run time to every derived-field
  target; output carries the run taint (0062 R4) into the field's restriction provenance as for step
  writes. A violation is `script_output_restriction_widened` (existing code).

## D6. Failure mapping and INV-8

Hook 2 converts every executor outcome, including exit and crash, to a typed `{:error, code}` and never
raises inside the write transaction. No `Exception.format` or `inspect` text reaches a tenant (the
`executor.ex` crash-string sites stay unreachable; slice E-2 converts).

| Executor outcome | Tenant-visible code | Effect on the pending write |
|---|---|---|
| script `fail(code, details)` | `script_failed` + manifest-declared code | rejected, nothing commits |
| script error | `script_error` | rejected |
| instruction budget | `budget_exceeded` | rejected |
| memory limit | `memory_limit_exceeded` | rejected |
| wall clock | `timeout` | rejected |
| invalid output (schema, undeclared field, widening) | `output_invalid` | rejected |
| admission refused (`{:error, :capacity}`) | `script_busy` | retried inside the 3-attempt total with a short backoff, then rejected as `script_busy` |
| caller or worker crash/exit (watchdog DOWN) | `script_error` | rejected |
| kill switch on | `script_rejected` | rejected |
| fingerprint mismatch after 3 attempts | `derived_value_conflict` | rejected |

Only `script_busy` and the fingerprint mismatch retry. A test per row is required in slice E-4. Every
outcome appends an audit record (key, version, sha256, HMAC input, outcome class, duration, instructions,
heap words, principal and actor id; no values): the accepted one inside the write Multi after item 5 of 0061
and at/before item 6, the rejected one in its own short transaction.

## D7. INV-1, INV-3, managed types and scope

**INV-1.** The hook's reads and writes use only the `:prefix` of the run context. The entity type is
validated against the tenant's definitions and never used as a table name (INV-7: bound parameters through
the query compiler). The INV-10 test is required: a hook bound on a type of tenant A, and a caller of tenant
B naming that type on every bind, unbind and read route with B's token, gets a byte-identical not-found.

**INV-3.** Hook 2 runs only under the existing allow-list sandbox, the mandatory heap cap and `ScriptAdmission`
caller monitoring. Limits equal hook 1 (0053 D7, D8); the output cap stays 64 KiB. The read caps (rows per
read, reads per hook) are not above D7 but are not numbered here (Not decided here). Nothing is relaxed
silently.

**Managed types.** The authority is the positional `authority` argument of `Records` (`:tenant | %Owner{}`),
set by code, never by request data (0050 F2). Binding a tenant script to a managed type is refused at bind
(`entity_type_managed` to the admin). At run time `check_write_authority/3` is repeated and a non-owner gets
`write_not_permitted` (INV-5; 0054 D8 `classify_step_error(:entity_type_managed)`). Tests: bind to a managed
type refused (E-1); a managed-type write by a non-owning caller refused with `write_not_permitted` (E-3).

**Scope (0051 T12/T13).** Scope is checked on BOTH the old stored value and the new value (payload merged
with the hook output) of every field the hook writes and of the type's scope field, for create, update and
upsert; out of scope gives `write_not_permitted`. Tests: out-of-scope old value and out-of-scope new value
(E-3). T13 is moot (no instance); a hook-2 write takes the scope of the record being written and the script
never widens it.

## D8. Slices

Each slice is its own requirement and change.

- **E-1 pin and registry**: accept the `entity_write` hook kind in the `Scripts.Runtime` checks, binding
  table migration (existing tenants through the usual tenant-migration path), bind/unbind/list routes,
  bind-time checks (managed, definition exists, step-line conflict `entity_type_hooked`). Depends on 0053
  7c merged. `[SECURITY-REVIEWER: mandatory]` (tenant-data path)
- **E-2 runtime and read path**: runner entry for hook 2, manifest `reads`/`derived_fields`, read phase with
  fingerprint and the D2 order, redaction, R5 predicate, executor-outcome conversion. No write integration.
  Depends on E-1. `[SECURITY-REVIEWER: mandatory]`
- **E-3 write-path integration with F13**: `Records` create/update/upsert call the hook, lock set, compare,
  retry, `derived_value_conflict`; tests: the worked example under concurrency, the forced-overlap test of
  0061 rule 5 (barrier row held by a third connection, FIFO lock queue, deadlock and lock-timeout errors
  seen through Repo telemetry), a commit forced between counter read and row read expecting a retry, a
  never-written read type committing on attempt 1 and the variant with a concurrent first write expecting
  one retry, the managed and scope refusals of D7. Depends on E-2. `[SECURITY-REVIEWER: mandatory]`
- **E-4 failure mapping and audit**: one test per D6 row, audit records, kill switch honoured, no raw error
  text. Depends on E-3. `[SECURITY-REVIEWER: mandatory]`
- **E-5 dry-run and UAT**: dry-run of an `entity_write` script against a draft record (no write, reads tenant
  data) and `uat_design` scenarios. Depends on E-4. `[SECURITY-REVIEWER: mandatory]` (dry-run reads tenant
  data). The dry-run part is delivered by REQ-633 (GH #3530); the `uat_design` scenarios remain a later task.

Not in the list: step-path support and bulk-import budgeting (separate later records).

## Consistency with earlier records

- **0050 F2** (no amendment; Record E implements it): "hook 2 (scripted rules) are engine / module-side write
  paths and must also refuse managed types, with the owning module path identified by caller, not by
  request data".
- **0051 T12** (AMENDED): "The same applies to a process step that writes an entity (REQ-484, planned, NOT
  VERIFIED in code) and to 0053 hook 2: T12 and T13 apply to that engine write path inside `complete_task`."
  Hook 2 does not run inside `complete_task` and REQ-484 is replaced by REQ-499; T12 applies on the `Records`
  path to old and new value, T13 does not apply (D7).
- **0053** (AMENDED / clarified):
  - scope-list line "(hook 2; needs REQ-484 and a dynamic data API)": now needs REQ-499 (delivered) and no
    dynamic data API (D1);
  - D5 "A dynamic data API would amend it and belongs to Records E/F": not used by Record E (D1);
  - D3 "Entity-type references and pack handling: Records E and P": for entity types, a binding row, not a pin
    kind (D4);
  - "Row-lock answer": "it binds hooks 3 (and 2 after REQ-484)": the 50 ms rule binds the locked window (D3);
  - D1 `hook_kind` `entity_write` is activated;
  - **D7** clarified: "Only `script_busy` is retriable; the rest are not." concerns executor outcomes. Record E
    adds one more retry, the whole-hook re-run on a read-fingerprint mismatch (3 attempts in total, shared with
    `script_busy` retries), safe because the hook is pure before commit (D2). All executor failures stay
    non-retriable.
- **0054** (AMENDED): "Record E (hook 2) is the same path and depends on this record": it is not the same
  path; hook 2 runs on the `Records` direct paths and step lines on a hooked type are refused (D1).
- **0061** (no amendment; clarification): item 5 applies also to read types the write does not touch (D2).
- **0062** (AMENDED): the R6 heading "(hook 1 scripts)" now includes hook 2; the R5 predicate is reused
  unchanged (D5).

## Not decided here

- The exact millisecond budget of the locked window (target 50 ms).
- Numeric read caps (rows per read, reads per hook).
- HTTP status numbers of the new codes `derived_value_conflict` and `entity_type_hooked`.
- A row-level fingerprint refinement.
- Step-path support and bulk-import budgeting.
- Derived fields of managed types (tenant extension layer, REQ-464 area).

## Threat cases for SECURITY-REVIEWER

1. Cross-tenant bind/unbind/read of a hooked type (INV-1, INV-10).
2. Hook output writing a scope field, `managed_by` or a restricted field (D5, D7).
3. Stale derived value through the read order (D2): counter after rows.
4. Deadlock between two hooked writers or a hooked and an engine writer (0061).
5. Crash or exit of the sandbox leaking raw error text or raising in the write transaction (D6).
6. Bypass of the hook through a process-step line (`entity_type_hooked`, D1).

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
