# 0067 -- After-commit record-event script triggers (Record T) and the outbox that delivers them

Status: PROPOSED by the developer of GH #3183 (REQ-560 slice 0, task T-0506), 2026-10-25. Needs
SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice
is its own requirement (D9).

Date: 2026-10-25

Depends on: [0050](0050-foundation-modules-org-catalog-and-reference-contract.md) (D7, F2);
[0051](0051-org-scoped-role-grants-and-enforcement.md) (T12, T13);
[0053](0053-tenant-scripted-rules.md) (hook 4, D1, D4, D5, D7, D8, D9, deviation 11);
[0054](0054-process-step-writes-entity.md) (D3 lock order, D8);
[0061](0061-engine-lock-order-platform-invariant.md) (item 1, item 5, item 6, rule 5);
[0062](0062-restriction-carrying-variables.md) (R4, R5, R6);
[0065](0065-entity-pre-write-script-hook.md) (the Record E record of REQ-539: D4, D5, D6);
REQ-499 (GH #2587, `Records.command_multi/3`, delivered); GH #2534 (tenant script runtime, merged).

Numbering note: `0066` is already used twice on main (generic saved views; module uninstall). This record
takes the next free number, 0067, as of `origin/main` on 2026-10-25.

## Map of REQ-560 description items

| REQ-560 item | Where |
|---|---|
| (1) the atomicity rule | D1 |
| (2) the outbox: table, states, claim, delivery guarantee, retry, dead letter, relation to existing code | D2, D3 |
| (3) trigger declaration, pinning, loop protection | D4 |
| (4) script principal, what a trigger may do | D5 |
| (5) ordering, concurrency, fairness, backpressure | D6 |
| (6) failure mapping, visibility | D7 |
| INV-1, INV-3 | D8 |
| (7) slice list | D9 |
| consistency, not decided | Consistency, Not decided here |

## Problem

Decision 0053 names "Record T, after-commit entity-event triggers and the outbox" (hook 4) as direction only,
and its deviation 11 says "no outbox exists". A trigger runs a tenant script AFTER a record write has
committed. The script therefore cannot roll the write back; the risks are the gap between the commit and the
trigger (a trigger lost when the node dies after the commit) and a trigger applied twice. This record decides
the outbox that closes that gap, what delivery guarantee a trigger gets, and how a trigger's result is applied.

## D1. The atomicity rule (normative)

**The outbox row for each matching trigger is inserted in the SAME database transaction as the record write,
so that either the write and all its outbox rows commit, or none of them does. No trigger script runs before
that transaction has committed, and none runs inside it.**

- *Rollback.* If the write transaction rolls back for any reason (validation, a version conflict, an
  idempotency replay that finds the original, a lock timeout, a refused fingerprint of Record E, a failed
  insert of the outbox row itself), no outbox row remains and no trigger runs. A duplicate replay of an
  already committed write (idempotency) inserts no new outbox row: the original write's rows are the only ones.
- *Commit, then node death before any worker ran.* The outbox row is durable at commit, in `pending`. After
  the restart the worker (D2) claims it. Nothing needs the dead node's memory: the row is the only carrier.
- *Commit, then node death after a worker claimed the row.* The row is `running` with a lease. After the
  restart it is not claimable until the lease has expired (30 s by default, D2); the lease sweep then returns
  it to `pending` and it is claimed again (D3). A worker of the earlier attempt that somehow lives on cannot
  apply its result (D3, CAS on `attempt`).
- *Never "soon after".* Writing the outbox row in a second transaction after the commit is forbidden: a crash
  between the two would lose the trigger.
- *Where the insert happens.* Inside the existing write Multi of `Records` (the direct create, update, delete
  and upsert paths and `Records.command_multi/3`, which also serves the process-step paths `HandlerWrites` and
  `StepWrites`), after the step that assigns the type's sequence number (so the type's sequence row is held and
  `source_seq` is known) and before the tenant-wide audit chain row (0061 item 6). A process-step write is
  covered, because the insert lives in the shared Multi, not in a caller; there is no step-path refusal as in
  0065 D1, since the trigger runs after the commit and holds no instance lock.
- *Matching.* The matching bindings (D4) are read INSIDE that transaction, after the type's sequence row is
  locked. A bind or unbind takes the same sequence row (D4), so a write sees a binding if and only if the
  binding committed before the write took the lock: no write is half-covered.

**Worked example.** Type `invoice` has a binding on `updated` to script `invoice_notify` v3 (sha256 `h3`). At
10:00:00.000 W1 updates invoice I (record id `r1`). W1's transaction takes the `invoice` sequence row, assigns
`source_seq` 41, writes the record, the history and event rows, reads the binding and inserts outbox row `O1`
(`pending`, `attempt` 0, entity type `invoice`, record `r1`, event `updated`, `source_seq` 41, pinned `invoice_notify`
v3 `h3`), then the audit row. It commits at 10:00:00.040. At 10:00:00.050 the node is killed (power loss); no
worker had run. *Restart* at 10:01:00: the poller's first tick lists the tenant schemas, finds `O1` `pending`,
claims it (`running`, `attempt` 1, lease until 10:01:30), runs the script on the current state of `r1`, and in
one result transaction marks `O1` `done` and applies the declared write with the idempotency key
`record_trigger:O1`. Variant A: the node dies at 10:00:00.2 after the claim (lease until 10:00:30): at 10:01:00
the lease has long expired, the sweep sets `O1` to `pending` (the cause is counted), attempt 2 runs and applies
with the same key; the dead attempt-1 worker cannot apply (CAS on `attempt`). Variant B: W1 fails with a version
conflict before commit: there is no `O1` and no trigger run, and the invoice is unchanged.

## D2. The outbox: table, states, claim, and the existing code

**Table.** `record_trigger_outbox`, a tenant-schema table under the `:prefix` (migration in slice T-2, existing
tenants through the usual tenant-migration path, no `tenant_id` column beyond the project's convention for
tenant tables, 0006 D2). Columns (names working): `id` (uuid, primary key, generated by the write transaction),
`binding_id`, `entity_type`, `record_id`, `event` (`created | updated | deleted`), `source_seq` (bigint, the
type's sequence number of the write), `occurred_at` (the transaction time), `script_key`, `script_version`,
`script_sha256` (copied from the binding at insert: the row carries its own pin), `depth` (int), `chain`
(array of binding ids that caused this row, D4), `actor_id` (attribution only), `status`, `attempt`,
`next_attempt_at`, `claimed_at`, `lease_expires_at`, `last_code` (closed set, D7), `done_at`. The payload holds ids
and the event type only: no record values, no field names, no variable content (D8).

**States.** `pending -> running -> done`; `running -> pending` (retriable cause, D3); `pending | running -> dead`
(terminal, D7). Terminal states: `done`, `dead`. The dead-letter state is `dead`.

**Claim.** Two statements in one transaction, the idiom of `ScriptTaskDispatcher.claim_next/1` and
`lock_and_claim/2`: a candidate read (status `pending`, `next_attempt_at <= now`, ordered by `next_attempt_at`
then `id`, limit 8, with the per-record order rule of D6), then a re-select of the candidate ids
`FOR UPDATE SKIP LOCKED` limit 1, then an update to `running` with `attempt + 1`, `claimed_at` and the lease.
**Lock mode of the claim query: `FOR UPDATE SKIP LOCKED`** on the outbox row only. Two workers cannot claim one
row; a row held by another transaction is skipped, never waited for.

**Lease length.** No owner figure exists. The stated default is the one of `ScriptTaskDispatcher.lease_ms/0`:
platform maximum wall clock 5 s + caller margin 2 s + `lease_margin_ms` 23 s = 30 s (config
`:lease_margin_ms`, clamped to at least 1 s). **Retry cap:** `max_attempts` 10 claims in total per row, over all
retriable causes together (D3); backoff base 500 ms, doubling, cap 30 s (the figures of `busy_backoff_*` in the
script dispatcher). After the tenth claim fails retriably the row is `dead` with `retries_exhausted`.

**Existing code read, and the ruling for each** (files read in full or in the relevant parts on 2026-10-25):

| Existing code | Ruling | Reason |
|---|---|---|
| `lib/letflow/engine/script_task_dispatcher.ex` (+ `script_task_dispatcher/poller.ex`) | **Reuse the pattern and the runtime calls; separate table and module.** | Its table `script_task_dispatches` is keyed on `(instance_id, node_id)` with a join to `InstanceProjection` (`p.status == :active`) and the apply CAS writes instance effects; a record event has no instance and no node. Reused unchanged: the claim idiom, lease formula, round-robin fairness (one row per tenant per pass, global tick budget), `Scripts.Runtime.prepare_run/3`, the runner and watchdog, the output check, the never-raises `try/rescue/catch` per row. |
| `lib/letflow/engine/service_task_dispatcher.ex` (+ `service_task_dispatcher/poller.ex`) | **Separate; nothing reused except the poller shape.** | It dispatches HTTP with `config_snapshot`, SSRF validation and "at-most-once HTTP dispatch" (an external effect that must not repeat); a trigger has no external effect before apply. The poller shape (zero-delay first tick, tenant list from `Registration` where `migrations_applied_at` is set, `Pollers` child gated by a `:start_*` flag, false in `config/test.exs`) is copied for a third poller, so a script run never delays HTTP dispatch nor script-task dispatch. |
| `lib/letflow/dlq.ex` (+ `dlq/entry.ex`) | **Reuse for tenant visibility of a dead row; not as the queue.** | `dlq_entries` has `entry_type` (extensible string), `instance_id` (nullable), `reference_id`, statuses `pending | retrying | resolved | discarded` and a route (REQ-178). A dead outbox row gets one DLQ entry (`entry_type` `record_trigger`, `reference_id` the outbox id, `instance_id` nil, `reason` the closed code) enqueued in the SAME transaction that sets `dead`. `Dlq.retry/2` manages only the entry row and re-dispatches nothing (its own moduledoc); a requeue of the outbox row is an explicit TENANT_ADMIN action of slice T-5. It is not the queue because it has no lease, no claim and no per-record order. |
| `lib/letflow/plugs/api_pipeline.ex` | **No reuse; stated for completeness.** | Its only mention of an outbox is a provenance-table row for the deferred R-Co plug `Letflow.Plugs.OutboxCap` ("S6 (outbox subsystem)"), never built. It is not an outbox implementation and creates no obligation; the per-tenant depth cap of D6 is a new, separate rule. |
| `lib/letflow/webhooks/delivery.ex` | Not reused. | An append-only attempt log, not a queue. |

**Lock position (against 0061).** The outbox row is a NEW row of the class "the instance's own timer / dispatch /
script-CAS rows" in item 1, but with no instance: it is the first lock of its transaction, ahead of everything
else. (a) The **insert** in a record write takes no lock on any existing row (a fresh id, no unique conflict
possible), so it adds no edge to the wait-for graph; it is placed after item 5 / 5a (the sequence row is held and
`source_seq` is known) and before item 6 (the audit chain row), and is called "item 5b" below; nothing waits on
it. (b) The **claim** transaction locks the outbox row only and takes nothing else. (c) The **result
transaction** takes: the outbox row (CAS, first), then item 5 for the types it writes (ascending by entity type,
with 0054 D3 rule 3a where it applies), item 5a, item 6. No path takes an outbox row while holding an item 5
row, because the only path that holds item 5 and touches an outbox row is the insert of (a). Hence no cycle. No
change to the order; 0061 rule 5 still requires, in slice T-4, the forced-overlap test (a barrier row held by a
third connection, FIFO lock queue, deadlock and lock-timeout errors reported through the Repo telemetry event)
for a result transaction racing a record writer of the same type.

## D3. Delivery guarantee

**Ruling: at-least-once RUN, exactly-once APPLICATION, by the outbox row id.** A trigger script is a pure
function (0053 D4) whose only effect is the declared write applied in the result transaction. 0053 D5 forbids
"retry of a non-idempotent hook"; a trigger run has no effect before its result transaction, so re-running it
after a crash is not a retry of an effect. At-most-once was rejected: it would lose a trigger when the worker
dies between claim and apply, which is exactly the loss the outbox exists to prevent; the cost of a second run is
CPU only. This differs from the script-task dispatcher's rule "an expired lease is NEVER re-run" (`ScriptTaskDispatcher`
moduledoc, C6) because that route's run may be followed by external effects through the instance; a trigger's
cannot (see Consistency, 0053 D7).

- **Idempotency key** `record_trigger:<outbox row id>:<line index>`, one per declared write line, passed as the
  `idempotency_key` of the `Records` attrs of that line (`create_attrs`, `update_attrs`, `upsert_attrs`). The key is
  built from the outbox row id and line index only, never from the payload or the script output. The prefix
  `record_trigger:` is not the reserved `sys:step:` prefix (`Records.step_key_prefix/0`, refused by
  `reject_step_key` with `:reserved_idempotency_key`); it is reserved by this record for the worker, and slice T-4
  adds it to the reserved-prefix refusal so that no request or process step can supply one.
- **The write entry points (decided; the code read on 2026-10-25).** `Records.command_multi/3` is NOT used for
  trigger results: it accepts only `kind: :create` (`check_step_command/1` answers `{:command_kind_not_supported,
  kind}` otherwise), it refuses any command that carries its own `idempotency_key` or `line_key`
  (`reject_caller_keys`, `:invalid_step_source`) because it derives `sys:step:<origin id>:<line index>` from a
  mandatory `%StepSource{}` that describes a process-step origin, and a trigger has none; and a duplicate key is
  `:idempotency_conflict`, never the original. Instead each write line goes through the public single-command
  paths with the authority `:tenant`: `Records.create_record/3` (mode `create`), `Records.update_record/3` (mode
  `update_self`) and `Records.upsert_record_by_external_ref/3` (mode `upsert_by_external_ref`), called in order
  INSIDE one outer `Repo.transaction/1` of the worker (each path's own `Repo.transaction` then joins it; an error of
  any line rolls the whole result back). These paths take a caller `idempotency_key` and, for the same request and key,
  return the ORIGINAL record with `is_duplicate: true` and append nothing (`Records` moduledoc, "Replaying the same
  request"); the same key with another request is `{:error, :idempotency_key_reuse}`. No change to `Records` write
  semantics and no new StepSource variant is needed. `Records` changes in exactly two places (slice T-4 for the
  prefix, slice T-2 for the lineage opt): the `record_trigger:` reserved-prefix refusal, and the trigger-lineage
  `opts` channel of D4.
- **The result transaction is one transaction:** the CAS on `(id, attempt, status = running)`, the declared
  write line(s) through the paths above, and the update of the row to `done`. A worker that dies after
  computing the result but before the transaction commits has applied nothing (rollback); a worker that dies
  after the commit has marked the row `done` in that same commit. **There is therefore no state "applied but not
  marked done".** As a second line, a forced duplicate apply (a test bypasses the CAS and re-runs the same lines)
  gets `is_duplicate: true` for every line with the same request and writes nothing; the worker treats that as
  success. If the re-run produced a different request under the same key (a script that is not a pure function),
  the answer is `{:error, :idempotency_key_reuse}`, mapped to `trigger_write_refused` with reason
  `idempotency_conflict` (D7), the row `dead`, and still nothing is written twice.
- **A refused result needs a SECOND transaction.** Any line error (`idempotency_key_reuse`, a 0050 / 0051 / 0062
  refusal, validation) rolls back the whole outer result transaction, so the move to `dead`, `last_code` and the DLQ
  entry cannot be written in it. After the rollback the worker runs a terminal transaction with the same CAS on
  `(id, attempt, status = running)` that sets `dead`, `last_code` and the DLQ entry (D7). If the worker dies between
  the two transactions, nothing was applied and the row is still `running`: the lease expires, the sweep returns it
  to `pending`, the next attempt re-runs the script and meets the same refusal (the refusal is a function of the
  record, the script and the checks), and writes the terminal transaction then. The cost is one extra attempt
  counted toward `max_attempts`; no write is ever applied twice.
- **What a script author may assume.** The script may run more than once for one event, never concurrently for
  one row, and its declared writes take effect at most once per row. It sees the CURRENT state of the record
  (the payload holds no values), plus the event name, `source_seq` and the record's current sequence, so a later
  write may already have changed it: it must be written as "bring the derived data in line with the current
  record", not as "react to this exact change". It may NOT assume delivery within a time bound, delivery in the
  order of different records, or that a `deleted` record still exists (its record input is null for `deleted`).
  `ctx.now` is the row's `occurred_at`; `ctx.uuid()` is a UUIDv5 over `(outbox row id, counter)` (the 0053 F12
  construction with the row id replacing the instance ids), so repeated runs yield identical values.
- **Retriable causes** (the row returns to `pending`, `next_attempt_at` set by the backoff of D2, counted against
  `max_attempts`): admission refused (`script_busy`), a lease that expired (a crash), and contention while
  applying (`entity_write_contention`). Every other outcome is terminal on its first occurrence (D7).
- **CAS on `attempt`.** The result transaction and every status update match `(id, attempt, status = running)`.
  A late worker of an earlier attempt, a swept row or a duplicate finds no row and writes nothing (`:stale`).

## D4. Trigger declaration, pinning, loop protection

- **Declaration.** A tenant-schema table `record_trigger_bindings` (slice T-1): `id`, `entity_type`, `event`
  (`created | updated | deleted`), `script_key`, `script_version`, `script_sha256`, `status` (`active | disabled`),
  `bound_by`, timestamps. Unique on `(entity_type, event)`: at most one trigger per type and event. An `upsert`
  raises `created` or `updated` according to the branch taken; a process-step write raises the same events as
  the direct path. The 0053 D1 `hook_kind` `entity_event` (reserved) becomes accepted; a script of another hook
  kind cannot be bound.
- **Pin kind (reused from 0065 D4, which says):** "The closed pin-kind set (`:catalog_entry | :variable_schema
  | :module | :script` in `pin_resolver.ex`) is NOT extended: those are instance pins frozen in
  `INSTANCE_STARTED` and a record write has no instance." and "The pin is a tenant-schema row binding an entity
  type to `(script key, script version, sha256)`". Record T reuses exactly this: a binding row, not a pin kind.
  The version must be `published` and not `revoked`; the sha256 is stored, copied into each outbox row at insert
  and re-checked at run time; bind, rebind and unbind are `ScriptsPublish` actions, TENANT_ADMIN, audited with
  `Audit.append_multi/4` in the same Multi, OIDC credential only. **Amends 0065 D4 in one place:** 0065 allows
  "One hook per entity type"; Record T allows one trigger per `(type, event)` in its own table, and a type may
  have a Record E hook and Record T triggers at once (they are different hook kinds and different tables).
- **Bind takes the type's sequence row** `FOR UPDATE` (item 5, nothing else), so the in-transaction match of D1
  is ordered against it. Unbinding or rebinding does not touch rows already in the outbox: such a row keeps its
  own pin and runs the pinned version, unless that version was revoked meanwhile (then `script_revoked`, D7).
- **Managed types.** Binding to a type with a `managed_by` stamp is refused at bind (`entity_type_managed`), as in
  0065 D7; relaxing it so that a tenant may observe module-owned data is under "Not decided here".
- **Loop protection (normative).** A write applied by a trigger raises triggers like any write, with
  `depth = parent depth + 1` and `chain = parent chain ++ [parent binding id]`. At insert time (D1) a binding is
  NOT enqueued when (a) its id is already in the parent's `chain` (a trigger never re-raises itself or an
  ancestor), or (b) `depth` would exceed the depth cap (default **3**, config; a tenant cannot raise it).
  The write that would have raised the refused trigger still commits (a loop guard never undoes a write); the
  refusal appends a metadata-only audit entry (`trigger_loop_suppressed`, binding id, depth, no values) in the
  same transaction and increments a counter.
- **How lineage reaches the insert (decided; server-only).** The D1 insert runs inside the Multi of
  `create_record/3`, `update_record/3` and `upsert_record_by_external_ref/3`, which carry no lineage today. Slice
  T-2 adds a keyword `opts` argument (`create_record/4`, `update_record/4`; `upsert_record_by_external_ref/4` has
  one already, but its `upsert_opts!` raises on unknown keys and must be extended) with a single new key `:trigger_lineage` (`%{depth, chain}`). The 2- and 3-arity forms, which the
  HTTP routers call, and `HandlerWrites` and `StepWrites` (which build through `command_multi/3`, whose insert step also writes a root row), pass no opts and so write a ROOT row (`depth` 0, empty
  `chain`). The value is read ONLY from `opts`, never from `attrs`, a request body or a step; an attrs key named
  `trigger_lineage`, `depth` or `chain` is not interpreted. Absence means root, so a caller cannot suppress a
  trigger by omitting anything; only code that calls the 4-arity form can lower or hide lineage, and only the
  trigger worker (slice T-4) does, with the lineage copied from the claimed row. A request or step can therefore
  neither supply nor forge `depth` or `chain`.
- **Tests.** Slice T-2 (no worker yet): lineage injected directly through `opts` expecting suppression at (a)
  (id already in `chain`) and at (b) (depth 3 write raises no row), and a root write raising a row at depth 0; a
  test that an HTTP create / update / upsert and a process-step write whose attrs carry `trigger_lineage`,
  `depth` and `chain` still insert a row with `depth` 0 and an empty `chain`. Slice T-4 (worker exists): a
  binding on type X whose script writes X expecting no second row, and a chain A -> B -> C -> D expecting rows to
  depth 3 and a suppression at the fourth.

## D5. Script principal, and what a trigger may do

- **Principal (reused from 0065 D5, which says):** "Script principal: tenant-wide, no user grants (0053 D5); the
  invoking actor id is recorded for attribution only." A trigger has NO invoking user at run time; `actor_id`
  of the original write is copied to the audit entry only.
- **Input** is built by the host after claim, never stored in the outbox: the current record (restriction
  filtered for the script principal, D8) and the event facts; plus declared tenant-wide master lookups under the
  read contract of 0053 D5 (pre-fetched, no `Repo` call in the sandbox, unknown / redacted / out-of-scope
  indistinguishable from a miss, INV-5). A record the principal cannot see (scope) yields the same input as a
  miss and the script is told only `record: null`.
- **Output** is a closed set of write lines declared in the manifest (`writes`: target entity type, mode
  `update_self | create | upsert_by_external_ref`, declared fields), at most a fixed number of lines (the numeric
  caps are under Not decided here). Anything else is `output_invalid`. The script cannot write scope-bearing
  fields, `managed_by` or system fields; this is refused at bind.
- **Application** is in a SEPARATE transaction after the run (D3), through the single-command paths
  `create_record/3`, `update_record/3` and `upsert_record_by_external_ref/3` (not `command_multi/3`, D3) with the
  authority `:tenant` (set by code, never by request data, 0050 F2), so the existing checks run unchanged: 0050
  managed types refused (`write_not_permitted`), 0051 scope checked on the OLD and NEW value of every written
  field (T12; T13 does not apply, there is no instance), the 0062 R5 "fewer restrictions" predicate at bind and
  at run time with the run taint (R4) carried into the field's restriction provenance, and the lock order of D2.
  The write is never part of the original transaction. A write refused by these checks is a trigger failure
  (D7), not an error of the original write.

## D6. Ordering, concurrency, fairness, backpressure

- **Per record, in commit order.** `source_seq` is the type's sequence number, assigned under the type's sequence
  row lock held to commit (0054 D3), so it is strictly increasing in commit order per type. The candidate query
  skips a row when a row of the same `(entity_type, record_id)` with a lower `source_seq` is `pending` or
  `running`. Rows of different records run in parallel; there is no order across records or types. A `dead`
  earlier row does not block later rows.
- **Fairness.** One row per tenant per pass, round-robin start rotating every tick, under a global wall-time
  budget (as `ScriptTaskDispatcher.run_tick/2`), so one tenant's backlog cannot starve another's.
- **Admission.** Every run goes through `ScriptAdmission` (0053 D8) with caller monitoring; `{:error, :capacity}`
  is `script_busy` and retriable (D3). The trigger poller is a separate process from the HTTP and script-task
  pollers and shares only `ScriptAdmission`.
- **Depth cap per tenant.** The number of outbox rows in `pending` or `running` per tenant is capped (default
  **10 000**, config; the figure is a target to be measured in slice T-2). When the count is at the cap, the
  insert step of D1 FAILS the write with `trigger_backlog_full` (retriable by the caller, nothing committed). The
  check runs ONLY when at least one active binding matches the write's type and event; a write with no matching
  binding never reads the count and can never fail for this reason. Mapping by caller: a direct HTTP write answers
  a refusal with a retry hint (status number under Not decided here); on the process-step path the insert step is a
  `{:line, i, :enqueue_trigger}` step of the shared Multi. **Decided engine-side handling (option a): backlog full
  is treated as contention.** Slice T-2 adds a clause to `Records.line_failure/3` so that `trigger_backlog_full`
  is carried as a new member of `step_refusal_code()` through `StepWrites.interpret_line/4` as `{:refused, i,
  :trigger_backlog_full, :step}`, and adds to `Engine.interpret_service_step_failure/2` a clause that returns
  `:contention` for it (beside the existing `:entity_write_contention` clause). `handle_service_outcome(:contention,
  ...)` then retries with the existing backoff, and on exhaustion lands the step through `land_service_failure/5`
  as `entity_write_contention` (already in `@service_refusal_codes`, 503, retryable, nothing committed). Not added
  to `@service_refusal_codes`; without the engine clause the code would land as `:entity_write_failed` with an
  internal-error log, which this record rejects. This applies to the service-task route and the script-task route
  alike (both land through `land_service_failure/5`). On the user-task completion route (the engine
  `:not_a_line_failure` call site and `Response.entity_write_refused/3`) there is no retry loop: the completion
  answers a retryable refusal `entity_write_refused` with code `trigger_backlog_full` (HTTP status under Not decided
  here), nothing committed, and the caller repeats the completion. `trigger_enqueue_failed` (a database fault of the
  insert) stays internal on every path, `{:entity_write_failed, i, :enqueue_trigger}` landing as `entity_write_failed`
  (an incident as today): a real fault, not a refusal. T-2 tests both mappings through `HandlerWrites`,
  `StepWrites`, the service-task route, the script-task route and the user-task completion route.
  In practice a full backlog rarely drains within the short backoff (100/300 ms), so this route mostly lands a retryable refusal rather than recovering.
  Dropping a trigger silently would break D1, and backpressure to the writer is the fail-closed answer. The count
  is a bounded `count` over a partial index and takes no lock, so concurrent writers may overshoot the cap by the
  number of concurrent transactions; the cap is a bound on growth, not an exact limit.
- **Kill switch.** The per-tenant kill switch of 0053 D7 applies to the worker: while it is on, claimed rows
  become `dead` with `script_rejected`, or, as a stated alternative recorded under Not decided here, stay
  `pending`. Default of this record: `dead` with `script_rejected` (fail closed, as 0053 says).

## D7. Failure mapping (INV-8)

A trigger failure NEVER undoes the original write: the original transaction committed before any trigger ran.
The worker converts every executor outcome, including exit and crash, to a typed `{:error, code}` and never
raises; per row the steps run inside `try/rescue/catch`, a catch is logged as one line with the dispatch id, the
tenant schema and a class tag (`raised | thrown | exited`), no stacktrace and no `Exception.format` or `inspect`
text reaches a tenant, a log or the row (`last_code` holds a closed code only).

| Outcome | Stable code (`last_code`) | Effect on the outbox row |
|---|---|---|
| script `fail(code, details)` | `script_failed` + manifest-declared code | `dead`, DLQ entry |
| script error | `script_error` | `dead`, DLQ entry |
| instruction budget | `budget_exceeded` | `dead` |
| memory limit | `memory_limit_exceeded` | `dead` |
| timeout | `timeout` | `dead` |
| invalid output (schema, undeclared write, widening) | `output_invalid` (widening: `script_output_restriction_widened`) | `dead` |
| admission refused | `script_busy` | back to `pending` with backoff, counts toward `max_attempts` |
| sandbox worker crash / exit (watchdog DOWN) | `script_error` | `dead` |
| kill switch on | `script_rejected` | `dead` (D6) |
| script unavailable, revoked, or hash mismatch with the row's pin | `script_unavailable` / `script_revoked` / `pin_mismatch` | `dead` |
| claim lost (CAS finds no row: swept, duplicate, late) | none | nothing written (`:stale`); the other attempt owns the row |
| lease expired (crash) | `lease_expired` (counted) | `pending` again by the sweep, counts toward `max_attempts`; `dead` with `retries_exhausted` at the cap |
| result refused by the 0050 / 0051 / 0062 checks | `trigger_write_refused` + reason `write_not_permitted | entity_type_managed | validation | output_restriction | idempotency_conflict` | whole result transaction rolled back, then a second terminal transaction (D3): `dead`, DLQ entry |
| contention while applying | `entity_write_contention` | back to `pending` with backoff, counts toward `max_attempts` |
| tenant schema dropped or not provisioned | none to the tenant (no tenant remains) | the tenant is absent from the tick's schema list; the rows go with the schema; a failed query is rescued and counted, never crashes the poller |
| outbox insert fails or backlog full at write time | `trigger_backlog_full` / `trigger_enqueue_failed` | the ORIGINAL WRITE fails and rolls back (D1: nothing committed); the only place where trigger machinery can fail a write, and only before the commit. Step path (D6): backlog full is retried as contention on the service and script-task routes and exhausted as `entity_write_contention`; on user-task completion it is a retryable refusal; an enqueue fault stays internal |

Only `script_busy`, an expired lease and apply contention retry; this amends 0053 D7 for triggers (Consistency).
**Tests required in the implementing slices:** one test per row of this table (slice T-5 for the executor
outcomes and the refusals, slice T-2 for the insert failures), and the loop depth-cap test of D4. A `dead` row
appends a metadata-only audit record (key, version, sha256, HMAC of the canonical input, outcome class,
duration, instructions, heap words, principal; no values, 0053 D9) in its own short transaction. A dead row is an
incident visible to the tenant (D9, slice T-5): the DLQ entry, a list route, a count and an `Alerts` signal.

## D8. INV-1, INV-3

**INV-1.** The outbox and binding tables live in the tenant schema under the `:prefix`. A worker takes the tenant
from the schema of the row it claimed (the tick's `Registration` schema list), NEVER from the payload; no column
or JSON value of a row names a tenant that is used for access. The payload holds ids and the event type only
(no record values, no field names): a leak of the table leaks no tenant data and the input is rebuilt from the
live record under the principal's restrictions. Entity type is validated against the tenant's definitions and is
never used as a table name (INV-7, bound parameters). **INV-10 test, required in the implementing slice:** an
outbox row of tenant A is not claimed, listed or counted for tenant B; a bind, unbind, list, requeue and count
route called with B's token naming A's type or A's row id answers byte-identically to the same call on a tenant
with no rows; the admin listing for tenant B equals, byte for byte, the listing of a tenant with no rows.

**INV-3.** A trigger runs only under the existing sandbox allow-list, the mandatory heap cap and `ScriptAdmission`
with caller monitoring (0053 D7, D8), with limits equal to hook 1 (default wall clock 1 000 ms, maximum 5 000
ms; output cap 64 KiB; instruction budget and heap from the manifest, clamped); nothing is relaxed silently. The
input is built by the host and redacted through the field restrictions of the script principal (0053 D5, 0062
R6): a restricted field is omitted unless it is named in the manifest input schema AND the publisher held
`EntitiesRestrictionsManage`, re-checked at run time; the 0062 R6 opt-in extends to hook 4. Any value above
the D7 maxima (read caps, write-line counts, per-run limits) is NOT decided here and is listed under "Not
decided here".

## D9. Slices

Each slice is its own requirement and one change of a few hundred lines. `[SECURITY-REVIEWER: mandatory]` marks a
slice that touches a tenant-data path. All behaviour is behind a flag that defaults off (`:record_triggers_enabled`,
plus `:start_record_trigger_worker` for the poller, false in `config/test.exs`).

- **T-1 trigger declaration and pin**: `record_trigger_bindings` migration, accept `entity_event` in the
  `Scripts.Runtime` checks, bind / unbind / list routes, bind-time checks (managed type, definition exists,
  declared writes, 0062 R5), sequence-row lock at bind. Depends on 0053 7c merged. `[SECURITY-REVIEWER: mandatory]`
- **T-2 outbox table and same-transaction insert**: `record_trigger_outbox` migration, insert step in the shared
  `Records` Multi (direct paths and `command_multi/3`), the server-only `:trigger_lineage` opt (`create_record/4`,
  `update_record/4`, `upsert_record_by_external_ref/4`, D4), loop suppression and depth cap tested with lineage
  injected through the opt, per-tenant backlog cap, the `Records.line_failure/3` clause, the new `step_refusal_code()`
  member and the `Engine.interpret_service_step_failure/2` contention clause (D6), with tests through `HandlerWrites`,
  `StepWrites`, the service-task, script-task and user-task completion routes,
  tests of the rollback and replay cases of D1 and of the 0061 position. No worker. Depends on T-1.
  `[SECURITY-REVIEWER: mandatory]`
- **T-3 claim worker with lease**: the poller child (flag, off), claim query `FOR UPDATE SKIP LOCKED`, per-record
  order, lease sweep, fairness, retry cap and backoff; the run is a stub that marks `done`. Tests: no double claim
  under concurrency, crash-and-restart of D1's worked example (lease expiry), INV-10 claim test. Depends on T-2.
  `[SECURITY-REVIEWER: mandatory]`
- **T-4 script run and result application**: `Scripts.Runtime.prepare_run/3`, input build with redaction, pre-fetched
  reads, the run, output check, the result transaction with CAS and the per-line key over the single-command
  paths (D3; the `record_trigger:` reserved-prefix refusal in `Records`; the worker passes `:trigger_lineage` from
  the claimed row; the end-to-end loop tests of D4; the second terminal transaction of D3 and the worker-dies-between
  test), the forced-overlap test of
  0061 rule 5, a forced duplicate apply expecting `is_duplicate: true` and no second write, and the
  `idempotency_key_reuse` case. No `command_multi/3` extension is needed, so no extra slice. Depends on T-3.
  `[SECURITY-REVIEWER: mandatory]`
- **T-5 failure handling, dead letter, tenant visibility**: the whole D7 table, one test per row, DLQ entry in
  the dead transaction, list / count / requeue routes (TENANT_ADMIN), `Alerts`, audit records, kill switch. Depends
  on T-4. `[SECURITY-REVIEWER: mandatory]`
- **T-6 dry-run and UAT**: dry-run of an `entity_event` script against a draft record (reads tenant data, writes
  nothing) and `uat_design` scenarios. Depends on T-5. `[SECURITY-REVIEWER: mandatory]` (dry-run reads tenant data)

Not in the list: bulk import volume handling, outbox pruning of `done` rows, a trigger on a managed type.

## Consistency with earlier records

- **0050 F2** (no amendment): result writes use the authority `:tenant` set by code, so managed types are refused
  by the existing check; binding to a managed type is refused (D4).
- **0051 T12** (no amendment): T12 applies to the old and new value of every field a trigger result writes; T13
  does not apply (no instance, as 0065 D7).
- **0053** (AMENDED / clarified):
  - the scope-list line "Record T, 'after-commit entity-event triggers and the outbox' (hook 4, old D6)" and
    deviation 11 "Hook 4 'via an outbox': no outbox exists; direction only (Record T)": this record is the
    binding decision and the outbox it defines is new (D2);
  - D1 `hook_kind` `entity_event` reserved: accepted by this record (D4);
  - **D7** "Only `script_busy` is retriable; the rest are not.": AMENDED for hook 4: also an expired lease
    (a crash) and contention while applying are retriable, bounded by `max_attempts` (D3); every executor
    failure stays non-retriable (D7 table);
  - **D5** "Retry of a non-idempotent hook is forbidden.": clarified, not amended: a trigger re-run precedes any
    effect and its application is exactly-once by the row id (D3);
  - D5 "A dynamic data API would amend it and belongs to Records E/F": not used (D5 pre-fetched reads);
  - D5 "The triggering user id is recorded for attribution, not used for access": a trigger has no user at run
    time; the actor of the original write is recorded for attribution (D5).
- **0054 / REQ-499** (no amendment): the process-step write path (`HandlerWrites`, `StepWrites` over
  `Records.command_multi/3`, `sys:step:` keys, create-only) raises triggers through the shared Multi (D1) and its
  semantics are unchanged; trigger RESULTS do not use `command_multi/3` (D3). D3's lock order is unchanged. Unlike
  0065 D1, no step-path refusal of the write is needed; the only step-path addition is the `trigger_backlog_full`
  refusal code (D6).
- **0061** (CLARIFIED, no change of order): adds the outbox row to the item 1 class and the insert "item 5b"
  between item 5a and item 6 with no lock taken (D2). No cycle; rule 5's forced-overlap test is required in T-4.
- **0062** (no amendment): R5 predicate at bind and run time and R4 taint apply to every result write line; R6
  opt-in extends to hook 4 (the R6 heading "(hook 1 scripts)" now also names hooks 2 and 4).
- **0065 (Record E)** (AMENDED in one place): D4's "One hook per entity type" now reads "one hook per entity type
  for Record E; Record T triggers are separate, one per `(type, event)`". Reused unchanged: the pin by binding row
  (D4), the tenant-wide principal (D5), the closed failure-code style with no raw error text (D6: "Hook 2 converts
  every executor outcome, including exit and crash, to a typed `{:error, code}` and never raises inside the write
  transaction"). Not reused: the F13 read fingerprint (a trigger runs after commit and reads current state).

## Not decided here

- Owner tolerance for a delayed or dead-lettered trigger beyond the defaults chosen (at-least-once run,
  exactly-once application is chosen here with its reason; if the owner prefers at-most-once the record is
  reopened).
- Numeric values above the 0053 D7 maxima: read caps (rows per read, reads per hook), number of write lines per
  result, rows per result, any wall clock above 5 000 ms.
- The per-tenant backlog cap (10 000) and the depth cap (3) as final figures; to be measured in T-2.
- Pruning and retention of `done` and `dead` rows.
- Triggers on managed types (observe-only) and the kill-switch alternative of leaving rows `pending`.
- HTTP status numbers of `trigger_backlog_full`, `trigger_enqueue_failed` and `trigger_write_refused`.
- Bulk-import volume (one outbox row per imported record) and a coalescing rule for repeated updates.

## Threat cases for SECURITY-REVIEWER

1. Cross-tenant claim, list, count or requeue of an outbox row (INV-1, INV-10).
2. A trigger result writing a scope field, `managed_by` or a restricted field (D5).
3. A trigger loop exhausting the worker or the backlog (D4, D6).
4. A worker that dies between run and apply applying twice, or never (D3).
5. Sandbox crash leaking raw error text or raising inside the poller (D7).
6. Deadlock between a result transaction and a record writer or an engine writer (D2, 0061).
7. Payload content leaking record values through the table or the DLQ entry (D8).

## Sign-off

- SECURITY-REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
- REVIEWER: pending (verdict recorded in the PR body `## Gates` block).
