defmodule Letflow.Engine do
  @moduledoc """
  Context module for EE-01 (`create/2`) — starting a new process instance.
  See `lib/letflow/design/req045-instance-start-engine-shell.md` for the full
  design this module implements; this moduledoc restates the points that
  design's §2 requires to be stated here verbatim in substance.

  ## Process-vs-row decision (AC5, AC6)

  Whether a running instance is a supervised `:gen_statem` process or a
  plain transactional context module was this stage's largest open design
  question (`docs/migration/stage-3-instance-engine.md`'s second Early
  finding). This module resolves it for EE-01's own scope only: `create/2`
  is a plain function, no process — see the design doc §1 for the full
  reasoning (every write EE-01 performs is already transactional; there is
  no multi-step conversation a caller has across several calls the way
  `submitted -> approve` in `Letflow.ProcessInstance` does; no timer, no
  backpressure, no external-plugin call). The answer may legitimately differ
  for later engine subsystems (REQ-056 service task dispatch, REQ-057 plugin
  registry), which the same finding names as the strong case for a process;
  this module does not pre-empt those requirements' own decisions.

  Concretely, for the two existing modules this decision bears on:

    * `lib/letflow/process_instance.ex` is **superseded, not extended**. Its
      hardcoded four-atom state graph becomes REQ-027 definition data,
      snapshotted per instance by REQ-033. `Letflow.ProcessInstance` itself
      is not deleted by this requirement — REQ-046 owns physically removing
      it; this requirement only stops adding to its pattern and builds the
      real replacement alongside it.
    * `lib/letflow/instance_supervisor.ex` is **generalized, not
      superseded** — but not by this requirement, since this requirement
      introduces no process for it to supervise. Its `DynamicSupervisor`
      shape is confirmed still correct in principle for whichever later S3
      requirement (REQ-056/REQ-057) does need a supervised process.
      `Letflow.Engine` does not modify `instance_supervisor.ex` at all.
    * `Letflow.Events.TransitionEvent` (and its migration) is **deliberately
      kept in place, not retired by this requirement.** REQ-023's `events`
      table is the durable event log for the new engine (this module
      appends `INSTANCE_STARTED` there); `TransitionEvent` is
      `Letflow.ProcessInstance`'s own private log with no reader or writer
      outside that module. Retiring it is REQ-046's job, bundled with
      `Letflow.ProcessInstance`'s own removal.

  ## HTTP is out of scope (AC7 / scope boundary)

  `POST /api/v1/instances` and every other HTTP route belong to S4
  (api-surface) — this module builds a context-module function only,
  returning tagged tuples, matching the boundary every other S2-S3 context
  module already established.

  ## Activation loops to a stable resting state (AC7, updated post-REQ-050/051)

  `create/2` drives `Letflow.Engine.Transition.transition/3` from a worklist
  loop (`advance_until_stable/4`), one hop per call — matching
  `Transition`'s own "single hop per call" contract (its moduledoc) —
  rather than assuming any fixed hop count. After each hop it diffs the
  token list against what it was immediately before that hop
  (`tokens_needing_dispatch/3`) to decide which token_ids still need a
  dispatch call: a token needs another hop exactly when it just arrived
  somewhere its own node's dispatch hasn't run yet (whether via a plain
  :START/gateway advance, or as one of several fresh tokens produced by a
  `:PARALLEL_GATEWAY` split or join) — never when it stayed at the same
  `node_id` (`:HUMAN_TASK`'s genuine "no automatic outgoing traversal"
  stop) or was removed outright (`:END`, or a join's `:wait` outcome). The
  loop ends the instant the worklist is empty: either no token remains
  (the instance reached `:END` and completed) or every remaining token
  sits on a genuine waiting state or a node type this engine doesn't
  dispatch yet (`:SERVICE_TASK`/`:TIMER`/`:SUB_PROCESS`, surfaced as
  `{:error, {:activation_failed, {:node_type_not_yet_implemented, ...}}}`).
  A defensive, generously-sized hop bound
  (`length(graph.nodes) * 4 + 10`) guards against ever looping forever
  should a malformed/cyclic graph somehow reach this code despite
  REQ-028's structural validators rejecting true cycles — see design doc
  §9 OQ-1a (updated) for the full history of this limitation.

  ## `tenant_id` is validated, never persisted

  `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key.
  `opts[:prefix]` is resolved via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` purely to prove it
  names a well-formed tenant schema before any I/O — the derived value is
  not stored anywhere by this module, since none of
  `instance_projections`/`tokens`/`tasks` carries a `tenant_id` column
  (Decision 0006 D2).

  ## REQ-059 (PIN-01..PIN-04) — pin resolution runs before any write

  `start_instance/5`'s call order is, in this exact sequence: build the
  graph once (`build_graph/1`, reused by both this step and `activate/3`
  below rather than built twice); `Letflow.Engine.PinResolver.resolve/4`
  (enumerates and resolves every `SERVICE_TASK`/`SUB_PROCESS` catalog/module
  reference plus exactly one `variable_schema` entry, against an injectable
  `PinResolver.Lookup.t()` — see `pin_lookup/2`/`pin_overrides/1` below);
  `PinResolver.validate_initial_variables/2` (rejects initial variables
  violating the resolved `variable_schema`, reusing REQ-024's
  `Letflow.EventStore.Registry.JsonSchema.validate/2`); `parent_pins/2` +
  `PinResolver.apply_inheritance/2` (child pin inheritance when
  `attrs[:parent_instance_id]` is given, `{:ok, own_pins, []}` unchanged
  otherwise); **only then** `create_snapshot/3` — the first step in the
  whole sequence that performs any `Repo` write. A failed resolution,
  validation, or parent-pin lookup therefore writes zero rows anywhere
  (`instance_definition_snapshots` included) by construction, never by a
  rollback — see `lib/letflow/design/req059-pin-resolver.md` §3 for the full
  call-order specification this implements verbatim. The resolved
  `pins`/`conflicts` are threaded through `activate/3` (its own signature
  changed to `activate(instance_id, graph, initial_variables)`, taking the
  already-built graph instead of rebuilding it) into `persist/10`, which
  embeds them into the `INSTANCE_STARTED` event payload
  (`append_instance_started_event/8`) — see
  `Letflow.Engine.PinResolver`'s own moduledoc for the full PIN-01..PIN-04
  algorithm and its named SCOPE GAPs.

  ## `complete_task/3` (EE-04, REQ-048) — HTTP and assignee authorization are
  ## out of scope

  `POST /api/v1/tasks/:id/complete`'s HTTP status-code mapping (404/409/422
  for `:task_not_found`/`{:task_not_pending, _}`/`:invalid_output_variables`
  respectively) is S4 (api-surface) scope — `complete_task/3` returns tagged
  tuples only, exactly as `Letflow.EventStore.append/2`'s `is_duplicate`
  boolean already left the 200-vs-201 choice to S4. Whether the calling
  `TASK_WORKER` is the task's own `assignee_ref` (HTTP 403 otherwise, per
  IDN-03's role matrix) is **not checked anywhere in this module** —
  `complete_task/3` performs no assignee comparison and accepts
  `attrs.actor_id` as already-authorized by the caller. See
  `lib/letflow/design/req048-task-completion.md` for the full design.

  (ISS-0942 update: the sentence above used to say this check was "the S4
  auth plug's job, per REQ-021's precedent" without it actually having been
  built — it was a documented, explicit deferral (§12, `INV-EE48-10`) that
  never landed once S4 shipped, leaving `POST /tasks/:id/complete` gated
  only by the coarse tenant-wide `:TasksComplete` RBAC permission. ISS-0942
  closed that gap by adding the check as `Letflow.Tasks.authorize_completion/3`,
  called from `Letflow.Routers.Tasks.handle_complete/3` *before*
  `complete_task/3` is ever invoked — not as an S4 `Plug`, but as a
  `Letflow.Tasks` context function, consistent with how `claim_task/3`'s own
  authorization resolution already lives there. The module boundary this
  section asserts — this check is not this module's job — remains true and
  unchanged; only the implication that it was never built is corrected. See
  `lib/letflow/design/iss0942-task-complete-authorization-gap.md`.)

  ## Output-variable schema validation at the merge call site (REQ-109)

  `merge_output_variables/7` builds a real `variable_validations` map via
  `Letflow.Engine.VariableSchema.variable_validations/5` and passes it to
  `Letflow.Engine.VariableMerge.merge/3`, which made REQ-061's
  `{:rejected, …}` → `Letflow.Engine.ExecutionError.append_multi/3` branch
  reachable through the real completion path for the first time (ISS-0063 /
  GH#212).

  > **Amended by REQ-459 / REQ-460 (2026-10):** that branch is NO LONGER reachable
  > from a HUMAN_TASK completion. `merge_output_variables/8` checks the very same
  > validations first and refuses the completion with a retryable 422
  > (`{:error, {:output_refused, %{missing_keys: _, rejected_keys: _}}}`) before
  > anything is written: the instance is not put into ERROR and no
  > `EXECUTION_ERROR` event is raised. Rule C of the same change adds the HUMAN_TASK
  > attribute `required_outputs` (`Letflow.Engine.RequiredOutputs`), checked in the
  > `:completion_guards` Multi step against the SUBMITTED output only. The
  > `{:rejected, …}` → ERROR path survives for the SUB_PROCESS completion merge
  > (REQ-062, `Letflow.Engine.SubProcess`) and the other engine-internal
  > `EXECUTION_ERROR` callers; form-expression re-evaluation errors are unchanged
  > (still `EXECUTION_ERROR`). See
  > `lib/letflow/design/req459-required-outputs-and-distinct-person.md`.

  Storage-side rationale — the table, the three R-Co "schema"
  concepts, the deferred registration path — lives in
  `Letflow.Engine.VariableSchema`'s own moduledoc; what follows is the
  engine-side half.

  ### The former hardcoded `nil` was design-sanctioned, not a defect

  Before REQ-109 this call site passed `variable_validations: nil` literally.
  That conformed to its own gate-approved design contract:
  `lib/letflow/design/req049-variable-merge.md` §7.3 states outright that
  "until that requirement exists, every real caller of `merge/3` legitimately
  passes `variable_validations: nil`." **REQ-109 is that requirement.** The
  `nil` was the documented placeholder for a lookup that had not been built,
  not a regression — it had already been re-filed as one twice, and this
  paragraph exists to stop a third time.

  ### Why `JsonSchema.validate/2` rather than REQ-024's `validate_payload/3`

  `Letflow.EventStore.Registry.JsonSchema.validate/2` is called directly, and
  no JSON Schema dependency is added to `mix.exs`. This is a deliberate,
  stated deviation from REQ-049 AC4's *wording* whose *substance* it still
  satisfies: `JsonSchema.validate/2` **is** `validate_payload/3`'s own
  internal pure delegate (`lib/letflow/event_store/registry.ex:147` is
  literally `case JsonSchema.validate(decoded, schema) do`), so no second JSON
  Schema implementation is introduced. `validate_payload/3` itself is bypassed
  because it is bound to `get_type/2` → `event_type_registry`
  (`registry.ex:165-175`), and REQ-109 resolved variable-schema storage as a
  *dedicated* table rather than an `event_type_registry` reuse — calling it
  would force exactly the variable-key-to-event-type name mangling that
  resolution rejected.

  Three consequences for `req049-variable-merge.md`:

    * **§7.1 is superseded.** Its `{"value" => raw}` wrapper convention is
      replaced by `%{key => value}` against
      `%{"type" => "object", "properties" => %{key => schema}, "required" =>
      [key]}` — the shape already proven at
      `lib/letflow/engine/sub_process.ex:179-185`. Using the variable's own key
      as the wrapper key makes each `ValidationFailure.field_path` name the
      real variable (`/amount`, not `/value`).
    * **§7.2's `{:error, :unknown_event_type} -> :ok` row is superseded.** "Not
      registered" is now "no row for that `variable_key`", and such a key is
      **omitted** from the map rather than mapped to an outcome; `merge/3`'s
      own `Map.get(validations, key, :ok)` default already covers it.
    * **`req049-variable-merge.md` §13.2's open question is CLOSED, not merely
      re-mapped.** It asked how
      `validate_payload/3`'s `{:error, :tenant_not_provisioned}` and
      `{:error, term()}` cases should map into a `validation_outcome()`.
      `JsonSchema.validate/2` is pure — it performs no `get_type/2` lookup and
      no tenant resolution — so neither error surface exists at all and there
      is nothing left to map.

  A lookup *scoping* failure is a different kind of thing from a rejected
  value and is never folded into "no schemas registered": it returns
  `{:error, {:variable_schema_lookup_failed, reason}}`, which aborts the
  `Ecto.Multi`, writes nothing, and leaves the task `pending` and the instance
  `active`. A missing prefix has no tenant to commit an ERROR tail into, so
  aborting is the only fail-closed answer available.

  ### OPEN QUESTION for REVIEWER — REQ-059's pin vs. this live read

  PROVENANCE (historical, not current decision authority):
  REQ-059 (PIN-01/PIN-03) freezes exactly one `:variable_schema` pin per
  instance at start and forbids substituting a current version for a pinned
  one, so that "a newer catalog version published mid-flight does not affect
  an in-flight instance." The merge-time read above is **live**, so in
  principle it can expose an in-flight instance to a schema edited after that
  instance started. R-Co does both — the live read at merge
  (`instance.zig:2318`) and a digest pinned at start
  (`pin_resolver.zig:428`/`:490`) — and REQ-109 ports the live read.

  **The conflict is latent, not live**, for three independent reasons:

    1. `pin_resolver.ex:262-263`'s `default_lookup/0` returns
       `{:ok, %{version: "unversioned", json_schema: nil}}` — a populated tuple
       whose `json_schema` is nil — so the one `:variable_schema` pin every
       instance records today carries **no schema content**. Nothing meaningful
       is pinned, so nothing can be contradicted.
    2. REQ-059 AC5's no-fallback guarantee is scoped to
       `Letflow.Engine.PinResolver`, which REQ-109 does not touch.
    3. The conflict activates only once `pin_resolver.ex`'s lookup is wired to
       the real table, which REQ-109 explicitly defers.

  No `docs/migration/decisions/` record is being re-decided — none of the six
  covers variable schemas. If REVIEWER judges this a live conflict with
  REQ-059, it belongs in a decision record, not in this requirement's code.

  ## `cancel_instance/3` (EE-08, REQ-052) — SUPERSESSION and scope boundary

  `lib/letflow/parallel_approval.ex` (`Letflow.ParallelApproval`) and
  `lib/letflow/approval_supervisor.ex` (`Letflow.ApprovalSupervisor`) are
  **deleted** by this requirement, together with REQ-051's `PARALLEL_GATEWAY`
  split/join — the hand-written two-approver `:gen_statem` and its dedicated
  `DynamicSupervisor` are both fully superseded, with no retained/generalized
  half (unlike `Letflow.ProcessInstance`'s own retirement, REQ-046, which kept
  `Letflow.InstanceSupervisor` for a distinct, still-open future need —
  REQ-052 introduces no new process and therefore has no equivalent
  supervisor to keep).

  R-Co's EE-08 additionally (a) cancels pending timers atomically via
  SCH-03 (`src/scheduler/`, S6 — not yet built in Letflow) and (b) abandons
  any in-flight `SERVICE_TASK` HTTP call best-effort (REQ-056's own future
  transport, out of S3 scope). **Neither exists in Letflow yet, and
  `cancel_instance/3` performs neither.** This function cancels what already
  exists today — `tasks`, `tokens`, and `instance_projections` rows, plus the
  one `INSTANCE_CANCELLED` event — and leaves both as named, documented gaps:
  a future S6 timer-scheduling requirement is expected to add its own
  timer-cancellation call alongside this function's own transaction (or a
  follow-up hook this function exposes for it to call), and REQ-056 is
  expected to add its own best-effort HTTP-abort call the same way. Neither
  is a silent omission — `cancel_instance/3` does not claim to fully
  implement EE-08's R-Co scope, only its S3-buildable subset.

  `POST /api/v1/instances/:id/cancel` is S4 (api-surface) scope — this
  function returns tagged tuples only, matching the boundary `create/2`/
  `complete_task/3` already established.

  See `lib/letflow/design/req052-instance-cancellation.md` for the full
  design this section implements.

  ## EE-12 (REQ-055) — lock inventory and cross-instance isolation

  Every `lock("FOR UPDATE")` the engine itself acquires in `create/2`,
  `complete_task/3`, and `cancel_instance/3` (this module) plus
  `Letflow.EventStore.append/2`'s own transitive lock on the instance's stream
  is scoped to a single `instance_id`, never wider. A completion whose node
  declares `entity_writes` (decision 0054) additionally takes, through
  `Letflow.Engine.EntityPort`, each written entity type's `instance_sequences`
  row and its synthetic per-type `instance_projections` row (PER TYPE,
  therefore shared with every writer of that type in the tenant, across
  instances), the record rows it reads `FOR UPDATE`, and, for org-tree and
  scoped types only, the `scope_node_paths` table lock:

    * `fetch_and_lock_task/3` (`complete_task/3`) — locks `tasks`, filtered
      `where t.id == ^task_id`. **Single-row**: exactly the one `tasks` row
      named by `task_id`, which FK-scopes to exactly one `instance_id`.
    * `fetch_and_lock_instance_projection/3` (`complete_task/3`) — locks
      `instance_projections`, filtered `where p.instance_id == ^instance_id`.
      **Single-row**: exactly this instance's own projection row.
    * `fetch_and_lock_open_tasks/3` (`cancel_instance/3`) — locks `tasks`,
      filtered `where t.instance_id == ^instance_id and t.status == :pending`,
      `order_by asc: t.id`. **Row-set, single-instance**: every row locked
      carries this same `instance_id`; the deterministic `order_by` avoids a
      lock-ordering deadlock against a concurrent multi-row locker on the same
      instance, and never touches another instance's rows.
    * `fetch_and_lock_instance_projection_for_cancel/3` (`cancel_instance/3`) —
      locks `instance_projections`, filtered `where p.instance_id ==
      ^instance_id`. **Single-row**, same shape as the `complete_task/3`
      projection lock above, scoped to this instance only.
    * `fetch_and_lock_live_tokens/3` (`cancel_instance/3`) — locks `tokens`
      (`TokenRecord`), filtered `where t.instance_id == ^instance_id and
      t.status in [:active, :waiting]`, `order_by asc: t.id`. **Row-set,
      single-instance**, same shape as the open-tasks lock above, scoped to
      this instance's own tokens only.
    * `lock_and_increment_sequence/3` (`Letflow.EventStore`, reached from
      every `create/2`/`complete_task/3`/`cancel_instance/3` event append via
      `EventStore.append/2`) — locks `instance_sequences`
      (`InstanceSequence`), filtered `where s.instance_id == ^instance_id`.
      **Single-row, single-instance**: the row is keyed 1:1 by `instance_id`
      (`on_conflict: :nothing, conflict_target: :instance_id` on the
      preceding insert-if-absent step); a concurrent `EventStore.append/2`
      call for a *different* `instance_id` locks a disjoint row and is never
      blocked by this one. `create/2` itself acquires no `lock("FOR UPDATE")`
      of its own — its `Multi.run(:instance_projection, ...)` step only
      inserts fresh rows, so L6 above is its only shared contention point.

  **No global or table-level lock is held anywhere in these write paths,
  except the `scope_node_paths` table lock (`Letflow.ScopeNodePaths.lock!/1`,
  decision 0054 D3 rule 3a), taken only by a completion whose `entity_writes`
  lines write an org-tree type or a scoped type.**
  Every lock above is acquired via a `where` clause keyed on `instance_id`
  (directly, or transitively via `task_id`/`token_id` FK-scoped to one
  `instance_id`) — Postgres's `SELECT ... FOR UPDATE` locks exactly the
  row(s) the query's `WHERE` clause matches, never the table. No
  `Repo.transaction/1` call in `lib/letflow/engine.ex`,
  `lib/letflow/engine/task_activation.ex`, or `lib/letflow/event_store.ex`
  locks any row outside the `instance_id` it was given, and none of those
  three modules holds a `:global`/`Registry`-backed singleton, a
  `Mutex`/`:mutex` dependency, a `LOCK TABLE` (other than
  `ScopeNodePaths.lock!/1` reached through `entity_writes`, see above), or any
  `GenServer`/`:gen_statem`/`DynamicSupervisor.start_child` call.
  **This finding does not extend to every file under `lib/letflow/engine/*.ex`
  as a blanket claim**: `lib/letflow/engine/plugin_registry.ex`
  (`Letflow.Engine.PluginRegistry`, REQ-057) is `use GenServer` — a real
  singleton process — but it is out of scope here on purpose, not by
  oversight: it holds no `instance_id`-scoped row lock at all (it is a
  registry lookup process, not a `Repo.transaction/1` participant), and it is
  not one of REQ-045/047/048/052's per-instance write paths, which is
  REQ-055's own named scope. `lib/letflow/engine/task_activation.ex` acquires
  no lock of its own anywhere — every step it contributes runs as an
  `Ecto.Multi.run/3` step inside the caller's already-open transaction,
  operating only on rows the caller already locks or fresh rows it is itself
  inserting.

  Lock ordering (decision 0061, GH #2704: one global order for every write path and both child
  kinds). A path takes a SUBSEQUENCE of these row classes, in this order, per instance X:
  (1) X's service-dispatch / script-CAS rows and (2) X's `tasks` rows (decision 0061 rule 1
  numbers 1-2 as one class; `complete_task/3`, `cancel_instance/3` and an ESCALATION timer fire take
  `tasks` first, an apply the dispatch row; GH #2707: X's `timers` rows are NOT in this class, see
  (7)); (3) X's projection (always before X's tokens and before
  everything below); (4) the ANCESTOR GROUP of a sub-process child, nearest first: parent projection,
  then the parent's waiting token, then the grandparent's (`lock_parent_group/4`); (5) X's live
  `tokens`; (6) the ENTITY-TYPE rows, ascending by entity type (decision 0054 D3: the type's
  `instance_sequences` row, then its synthetic projection row; no record row is locked, writes are
  create-only; the `scope_node_paths` table lock of rule 3a is not taken yet, no scoped type
  exists); (7) X's `timers` rows (GH #2707: P-protected like the tokens, touched only while X's
  projection is held, their order among themselves and against the tokens unconstrained);
  (8) the tenant-wide AUDIT CHAIN row (the first audit write of the transaction, held to
  commit); (9) the sequence rows: X's own, then the ancestors' (`EventStore.append/2`, the cascade);
  (10) the projection UPDATEs. Across instances a child's rows come strictly before its
  ancestors' and nothing goes child-ward.

  The ancestor group's mode is decided from the pure transition BEFORE its first lock
  (`lock_intent/1`) and is never upgraded: `FOR UPDATE` on the whole chain when the instance
  completes in this transaction (its cascade follows), `FOR KEY SHARE` on the immediate parent
  otherwise (compatible between siblings, still queued ahead of a parent cancel's `FOR UPDATE`).

  What this means per path:

    * `complete_task/3` (HUMAN): `tasks`, projection, then the pure steps (`:snapshot_and_state`
      ... `:transition`, no lock), THEN `:lock_ancestors` (the group; GH #2704 moved it here from the
      first tail step, so it precedes the entity-type rows), then the entity-type rows
      (`maybe_entity_writes/4`: per line in `(entity_type, declared index)` order, that type's
      sequence row and synthetic projection row), then the tail (timer cancels, token reconcile,
      task activation, audit rows, events, projection, cascade). A completion whose node declares
      `entity_writes` runs under `SET LOCAL lock_timeout` 2 s / `statement_timeout` 5 s as the FIRST
      statements, which bound the whole transaction including these waits; a deadlock or timeout is
      reported as `entity_write_contention` (503, retryable, nothing committed). A completion
      without lines still has no `SET LOCAL` timeout, but since GH #2823 a deadlock, lock timeout
      or statement cancel raised from its `Repo.transaction` is reported the same way
      (`entity_write_contention`, 503, retryable, nothing committed). Post-commit failures stay
      `{:transaction_failed, _}`.
    * GH #2590 / REQ-501 R4b: a node that also declares `module_writes` takes, after
      `:entity_writes_started` and before any write, one `{:type_lock, type}` per type in the
      ascending union of the line types and the handlers' registered targets
      (`HandlerWrites.lock_types/4`), so a handler can neither reorder nor skip them; a handler
      receives no `repo` and can take no other lock.
    * SERVICE_TASK / script apply (`do_persist_service_task_advance/10`, GH #2587 PR C2, GH #2590 R5,
      GH #2648): the dispatch (or CAS) row and the projection before the Multi, then in it
      `:lock_ancestors` (the group; GH #2695), then, with an entity plan, the `{:pre_type_lock, type}`
      group (GH #2704, through the entity port's optional `lock_types/4`: the same ascending union
      of line and handler-target types, BEFORE the token inserts and the task activation, whose
      `task.create` audit takes the audit chain row), then tokens, task activation, timers, dispatch
      arms and sub-process children, the entity writes (their own type locks are now no-op re-locks),
      the events, the projection, the completion cascade (the ancestors' sequence rows and projection
      UPDATEs, with the group already held) and the entity audits last. The pre-lock is lock-only (its one write: the empty counter row of a type bound to a number sequence, REQ-541): no
      event, audit or sequence number changes position or content. A deadlock or timeout here is
      classified as contention and re-applied (bounded) for HTTP applies and for planned script
      applies; an UNPLANNED script apply goes straight to `apply_script_task_result_once/4`, whose
      blanket rescue turns a deadlock into `:raised` (a terminal `script_rejected`/`apply_failed`;
      accepted, a script task in a sub-process child is not reachable end to end until GH #2694).
    * `Scheduler.fire_timer/2` (GH #2707, through `lock_for_timer_fire/3`): for an escalation timer the
      pending `tasks` rows of its token, then the projection (any status), then, for an active
      child, the parent group (GH #2829: `FOR KEY SHARE` on the immediate parent when the pure hop
      chain leaves the child running, `FOR UPDATE` on the ancestor chain when it completes the child
      and the fire runs the completion cascade), then the timer row, then the TIMER_FIRED append and
      the advance. A timer
      whose instance is not active is settled: all pending timers of that instance are cancelled
      with reason `instance_<status>` and the transaction commits.
    * `cancel_instance/3`: `tasks`, dispatch rows, the projection, `:lock_ancestors` (the
      group of a sub-process child, `FOR KEY SHARE` on the immediate parent: GH #2708; a cancel
      never completes the child), then (GH #2706) a SECOND read of the open `tasks`, `FOR UPDATE
      SKIP LOCKED`, which is complete because no task of the instance can be inserted while its
      projection is held (the `tasks.instance_id` foreign key needs `KEY SHARE` on it) and never
      waits (a pending task held by another transaction, usually a completer queued behind the
      projection, aborts the attempt: rolled back and retried, at most 3 attempts within one
      contention-timeout constant of the first attempt's start, never when nested in a caller's
      transaction; exhaustion is `{:error, :cancel_contention}`), then (GH #2707) the instance's
      timers, live tokens, the INSTANCE_CANCELLED append, the audit row last. Every wait of the
      transaction is bounded by a transaction-local `lock_timeout` (GH #2706, 5 s, set first as
      a bound parameter, skipped when nested; `Letflow.Engine.Contention`): a lock timeout or
      deadlock victim rolls back and is `{:error, :cancel_contention}` too.
      It never goes child-ward. On the parent side every writer follows projection, token, sequence row,
      audit row: `complete_task/3`, `Scheduler.fire_timer` (escalation: the task rows first), `ExecutionError`, and the cascade
      (`SubProcess.lock_waiting_parent/3`: parent projection, then the token re-selected
      `FOR UPDATE`; GH #2695).

  Why the group is taken before the entity-type rows and not after: a parent's own completion takes
  `tasks` and its projection (steps 1 and 2 of decision 0054 D3) before the entity-type rows, so a
  child that took the type rows first and the parent's projection second could never agree with it;
  the service apply already took the group first (GH #2695). Why the type rows precede the audit
  chain row: the type's `instance_sequences` row is the same row class as the "sequence row" half
  of an audit-versus-sequence cycle, and the HUMAN path always took it before the audit chain row
  (decision 0054 D3 rules 4 and 5); the service apply used to activate its next task, an audit
  write, before its entity writes (GH #2705, "I4").

  Foreign-key locks (GH #2695, mechanism measured by GH #2709's probe): Postgres runs the FK check
  of an UPDATE of a referencing row when the OLD row version was written by the current transaction
  (a row updated earlier in the transaction, or inserted in it), even if no key column changed; it
  skips the check otherwise. So the SECOND UPDATE of a sub-process child's projection row within one
  transaction queues `KEY SHARE` on the parent token and the parent projection, in an order fixed per
  tenant schema, while the first UPDATE of a previously committed row takes none. A parent cancel
  queued on the parent projection could therefore form a cycle with the child's own UPDATE. The
  group must be held before that second UPDATE; every event append is an UPDATE and a landing's
  append is its first, so it is taken before the first write. The ExecutionError landing does this
  for all its callers in `ExecutionError.append_multi/3` (`:execution_error_lock_ancestors`,
  `FOR KEY SHARE`, after its eligibility check; GH #2709). The group is found through
  `tokens.waiting_child_instance_id = child AND status = :waiting`, so the guarantee covers a
  WAITING parent only. A direct `cancel_instance/3` of a child (GH #2708) updates the child's
  projection twice (the INSTANCE_CANCELLED append, then the status), so it takes the group in
  `:lock_ancestors` right after its eligibility check. A child created in the same transaction
  is the exception: its first UPDATE already takes the FK locks (the row was inserted by this
  transaction).

  Cold appenders (GH #2707 PR-2): `EventStore.append/2` locks the instance projection `FOR NO KEY
  UPDATE` in its first step, before the sequence row, so the attachment events and a Lua
  `emit_event` take the same order as the engine writers (invariant I-S, decision 0061). The
  streams of entity-type synthetic instances and `append_platform_event/2` are outside I-S.

  Known gap, tracked and NOT closed so far: dispatch and script-CAS rows armed during a cancel's wait
  for the projection. The no-cycle argument covers the paths named in
  `lib/letflow/design/gh2704-lock-order-family.md` and nothing else.

  The cascade recurses ancestor-ward (child to parent to grandparent), never downward. The
  activator-active check runs pre-transaction (P0, design 7.3; 0054 D4a.4): a deactivation between
  that read and the commit is honoured one completion late.

  REQ-045 resolved this engine to row-based state (`create/2` is a plain
  function under `Ecto.Multi`, not a supervised `:gen_statem`/
  `DynamicSupervisor`-per-instance process — see this moduledoc's own
  "Process-vs-row decision" section above), so there is no per-instance
  process for a supervised-isolation/process-kill scenario to apply to.
  Isolation instead rests entirely on the row-locking discipline documented
  above. Instance isolation is verified under real concurrency by
  `test/letflow/engine_concurrency_test.exs` (REQ-055), which covers
  completions without `entity_writes` only; cross-instance entity-type
  contention is covered by the decision 0054 lock-order tests (AC 6). A
  completion with org-type lines serialises other org writers by design. See
  `lib/letflow/design/req-055-concurrent-instance-isolation.md` for the full
  design this section implements.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine.Contention
  alias Letflow.Engine.EntityPort
  alias Letflow.Engine.ExecutionError
  alias Letflow.Engine.FormExpressionReevaluation
  alias Letflow.Engine.IdempotentReplay
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.RequiredOutputs
  alias Letflow.Engine.SeparationOfDuties
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.ServiceTask
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Engine.ScriptTaskDispatcher.RunRecord
  alias Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch
  alias Letflow.Engine.SubProcess
  alias Letflow.Engine.Task
  alias Letflow.Engine.TaskActivation
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.Transition
  alias Letflow.Engine.VariableLabels
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.VariableSchema
  alias Letflow.Dlq
  alias Letflow.EventStore
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceVisibility
  alias Letflow.EventStore.Registry, as: EventRegistry
  alias Letflow.Identity
  alias Letflow.Modules.StartGate
  alias Letflow.Repo
  alias Letflow.Repository.Attachments
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Scheduler.TimerTypes
  alias Letflow.ScopeNodePaths

  require Letflow.Scheduler.TimerTypes
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.PinLookup
  alias Letflow.TenantProvisioning

  @type create_attrs :: %{
          optional(:definition_id) => Ecto.UUID.t(),
          optional(:definition_name) => String.t(),
          optional(:correlation_key) => String.t() | nil,
          optional(:scope_node_id) => String.t() | nil,
          required(:initial_variables) => map(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type opts :: [prefix: String.t()]

  @type create_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :idempotency_key_reuse}
          | {:error, :invalid_schema_name}
          | {:error, :missing_definition_reference}
          | {:error, :both_definition_id_and_name}
          | {:error, :invalid_initial_variables}
          | {:error, :definition_not_found}
          | {:error, :definition_not_active}
          | {:error, :definition_needs_reactivation}
          | {:error, :duplicate_correlation_key}
          | {:error, :invalid_scope_node}
          | {:error, {:snapshot_failed, term()}}
          | {:error, {:graph_structure_invalid, term()}}
          | {:error, {:activation_failed, term()}}
          | {:error, {:event_append_failed, term()}}
          | {:error, {:unresolved_catalog_ref, ref :: String.t()}}
          | {:error, {:unresolved_module_ref, ref :: String.t()}}
          | {:error, {:unresolved_pin_override, ref :: String.t()}}
          | {:error,
             {:variable_schema_violation, [Letflow.EventStore.Registry.ValidationFailure.t()]}}
          | {:error, {:parent_pin_lookup_failed, reason :: term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  # `replayed: true` (GH #2577) marks the answer to a same-key replay: the original instance, with
  # the CURRENT projection status (so any of the four) and current nodes.
  @type create_result :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:definition_id) => Ecto.UUID.t(),
          required(:status) => :active | :completed | :cancelled | :error,
          required(:current_nodes) => [String.t()],
          required(:variables) => map(),
          required(:started_at) => DateTime.t(),
          optional(:replayed) => true
        }

  @doc """
  Starts a new process instance (EE-01) from an ACTIVE definition: resolves
  and validates the definition, snapshots it (`Letflow.Definitions.SnapshotStore`,
  before any event exists), advances the root token off `:START` via
  `Letflow.Engine.Transition`, and atomically inserts the
  `instance_projections` row, the root `tokens` row, and the
  `INSTANCE_STARTED` event (one `Ecto.Multi`) — see this module's moduledoc
  and the design doc for the full algorithm and error taxonomy.

  Exactly one of `attrs[:definition_id]`/`attrs[:definition_name]` must be
  given (`:definition_name` resolves via
  `Letflow.Definitions.get_active_by_name/2` — *the* single ACTIVE row for
  that name). `attrs[:initial_variables]` must be a plain map (`%{}` is
  valid); `attrs[:correlation_key]` is optional and may be `nil`.
  `attrs[:actor_id]`/`attrs[:idempotency_key]` are required — plumbed
  straight through to `Letflow.EventStore.append/2`'s own identical
  requirement.

  ## Scope node (REQ-531, decision 0051 T13/T14)

  `attrs[:scope_node_id]` is the optional scope node the instance is started under: set once here,
  never changed (`instance_projections.scope_node_id`, carried in `INSTANCE_STARTED` and
  `InstanceState`). It must name an existing, non-retired `scope_node_paths` node of the tenant;
  anything else (unknown, retired, malformed, another tenant's) is `{:error, :invalid_scope_node}`
  before anything is written, and the node is re-checked under a `FOR SHARE` lock inside the
  transaction. The three start paths:

    * `POST /instances` accepts the optional field; `Letflow.Routers.Instances` additionally checks
      that a scoped caller names a node inside its `InstancesStart` grants (same refusal as unknown);
    * a sub-process child never takes a value from a caller: it inherits its parent's stored value
      (`Letflow.Engine.SubProcess.append_start_multi/7`, both the `create/2` and `complete_task/3` paths);
    * webhook and trigger starts: none exist today. Any future one must supply a node or the instance
      stays unscoped (T14): an unscoped instance is visible to tenant-wide holders only.

  The idempotent-replay comparison includes the node: the same key with a different node (or with
  none) is `:idempotency_key_reuse`.

  ## Module uninstall (decision 0066 D4, REQ-627)

  A definition stamped with an `:uninstalled` module (`owner_module`) answers `{:error, :definition_not_found}`,
  the answer for an unknown definition, by id and by name, whatever its status. An advisory read in the
  lookup and a `FOR SHARE` read of the module's `tenant_modules` row in the start transaction
  (`Letflow.Modules.StartGate`) make start and uninstall serialize. Decision 0061: the start takes
  `scope_node FOR SHARE`, then `tenant_modules FOR SHARE`, then the new `P_x` insert and its rows, and the
  audit chain last; the uninstall takes `tenant_modules FOR UPDATE`, plain count reads, then the audit chain.
  Both take `tenant_modules` before the audit chain and the uninstall holds no `P_x`, scope-node or task
  lock, so no wait-for cycle exists and 0061 needs no amendment. Scheduled jobs of the module's definitions
  stop and may be auto-disabled; re-enable them by hand after reactivation. Sub-process children are NOT
  blocked yet (known hole): `modules_uninstall_enabled` may be turned on only after that is settled.
  """
  @spec create(attrs :: create_attrs(), opts :: opts()) ::
          {:ok, create_result()} | create_error()
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_tenant_id(attrs),
         :ok <- check_definition_reference(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, initial_variables} <- fetch_initial_variables(attrs),
         :continue <- start_replay_check(attrs, initial_variables, prefix),
         :ok <- start_race_gate(attrs),
         :ok <- validate_scope_node(attrs, prefix),
         {:ok, definition} <- resolve_definition(attrs, opts) do
      correlation_key = Map.get(attrs, :correlation_key)
      start_instance(definition, initial_variables, correlation_key, attrs, tenant_id, prefix)
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §4) -- zero DB writes attempted.
  # ---------------------------------------------------------------------

  defp reject_tenant_id(attrs) do
    if Map.has_key?(attrs, :tenant_id) or Map.has_key?(attrs, "tenant_id") do
      {:error, :tenant_id_not_accepted}
    else
      :ok
    end
  end

  defp check_definition_reference(attrs) do
    has_id = Map.has_key?(attrs, :definition_id)
    has_name = Map.has_key?(attrs, :definition_name)

    cond do
      has_id and has_name -> {:error, :both_definition_id_and_name}
      not has_id and not has_name -> {:error, :missing_definition_reference}
      true -> :ok
    end
  end

  # REQ-531 -- the optional start scope node. Advisory pre-check (a refusal here happens before
  # `create_snapshot/3` writes anything); `persist/14` re-checks the node under a FOR SHARE lock.
  # Absent or nil is an unscoped start. Unknown, retired, malformed and non-string all answer one
  # code (INV-5): the caller learns nothing about which nodes exist.
  defp validate_scope_node(attrs, prefix) do
    case Map.get(attrs, :scope_node_id) do
      nil ->
        :ok

      node_id when is_binary(node_id) and node_id != "" ->
        case ScopeNodePaths.resolve(node_id, prefix) do
          {:ok, %{node: %{retired_at: nil}}} -> :ok
          _unknown_or_retired -> {:error, :invalid_scope_node}
        end

      _other ->
        {:error, :invalid_scope_node}
    end
  end

  defp fetch_initial_variables(attrs) do
    case Map.get(attrs, :initial_variables) do
      variables when is_map(variables) and not is_struct(variables) -> {:ok, variables}
      _other -> {:error, :invalid_initial_variables}
    end
  end

  # GH #2577 -- a key already claimed by an INSTANCE_STARTED of this request answers the
  # original result; a key claimed by anything else answers `:idempotency_key_reuse`.
  # Runs before `resolve_definition/2` (a replay must survive the definition being archived)
  # and before any write, so a replay leaves no snapshot behind. A non-binary key keeps
  # today's typed errors from `EventStore.append/2`.
  defp start_replay_check(%{idempotency_key: key} = attrs, initial_variables, prefix)
       when is_binary(key) do
    case IdempotentReplay.lookup(key, prefix) do
      :none -> :continue
      {:ok, original} -> start_replay(original, attrs, initial_variables, prefix)
      {:error, _reason} = error -> error
    end
  end

  defp start_replay_check(_attrs, _initial_variables, _prefix), do: :continue

  # Test seam (GH #2577, T-start-race), compiled ONLY when `:engine_test_seams` is true. A start
  # whose key the test armed in `:persistent_term` waits here, after `start_replay_check/3` has
  # answered `:continue` and before any insert, until the test releases it. Two armed starts
  # therefore both pass the replay check before either inserts: the race `resolve_start_race/5`
  # answers. The wait is bounded, so a test that never releases the gate cannot hang.
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    defp start_race_gate(%{idempotency_key: key}) when is_binary(key) do
      case :persistent_term.get({__MODULE__, :start_race_gate}, nil) do
        {test_pid, ^key} ->
          send(test_pid, {:start_race_arrived, self()})

          receive do
            :start_race_go -> :ok
          after
            10_000 -> :ok
          end

        _not_armed ->
          :ok
      end
    end

    defp start_race_gate(_attrs), do: :ok
  else
    defp start_race_gate(_attrs), do: :ok
  end

  defp start_replay(%EventStore.Event{} = original, attrs, initial_variables, prefix) do
    if same_start_request?(original, attrs, initial_variables, prefix) do
      replay_start_result(original, prefix)
    else
      {:error, :idempotency_key_reuse}
    end
  end

  defp same_start_request?(%EventStore.Event{payload: payload} = original, attrs, vars, prefix)
       when is_map(payload) do
    original.event_type == "INSTANCE_STARTED" and
      IdempotentReplay.same_uuid?(original.actor_id, Map.get(attrs, :actor_id)) and
      Map.get(payload, "initial_variables") == IdempotentReplay.canonical_json(vars) and
      Map.get(payload, "correlation_key") == Map.get(attrs, :correlation_key) and
      Map.get(payload, "scope_node_id") == Map.get(attrs, :scope_node_id) and
      same_start_definition?(payload, attrs, prefix)
  end

  defp same_start_request?(_original, _attrs, _vars, _prefix), do: false

  defp same_start_definition?(payload, %{definition_id: definition_id}, _prefix),
    do: IdempotentReplay.same_uuid?(Map.get(payload, "definition_id"), definition_id)

  defp same_start_definition?(payload, %{definition_name: name}, prefix) do
    case Definitions.get_by_id(Map.get(payload, "definition_id"), prefix: prefix) do
      {:ok, definition} -> definition.name == name
      _other -> false
    end
  end

  defp replay_start_result(%EventStore.Event{} = original, prefix) do
    query =
      from(p in InstanceProjection, where: p.instance_id == ^original.instance_id)

    case Repo.one(query, prefix: prefix) do
      %InstanceProjection{} = projection ->
        {:ok,
         %{
           instance_id: projection.instance_id,
           definition_id: projection.definition_id,
           status: projection.status,
           current_nodes: projection.current_nodes,
           variables: Map.get(original.payload, "initial_variables"),
           started_at: projection.started_at,
           replayed: true
         }}

      nil ->
        {:error, {:idempotency_lookup_failed, :projection_missing}}
    end
  end

  # GH #2577 -- two same-key starts that both passed `start_replay_check/3`: the loser's
  # INSTANCE_STARTED append finds the key claimed, its Multi rolls back (projection, tokens,
  # timers, audit), and it answers the winner's result. The loser's snapshot row was written
  # outside the Multi (design OQ-4), so it is deleted here.
  defp resolve_start_race(
         {:error, {:idempotent_replay, %EventStore.Event{}}},
         instance_id,
         attrs,
         initial_variables,
         prefix
       ) do
    Repo.delete_all(
      from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^instance_id),
      prefix: prefix
    )

    case IdempotentReplay.lookup(Map.fetch!(attrs, :idempotency_key), prefix) do
      {:ok, original} -> start_replay(original, attrs, initial_variables, prefix)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_start_race(result, _instance_id, _attrs, _initial_variables, _prefix), do: result

  defp resolve_definition(%{definition_id: definition_id}, opts) do
    definition_id
    |> Definitions.get_by_id(opts)
    |> gate_uninstalled_owner(opts)
    |> interpret_definition_lookup()
  end

  defp resolve_definition(%{definition_name: definition_name}, opts) do
    definition_name
    |> Definitions.get_active_by_name(opts)
    |> gate_uninstalled_owner(opts)
    |> interpret_definition_lookup()
  end

  # REQ-627: a definition stamped with an UNINSTALLED module is unknown to a new start, whatever its
  # status (uniform 404, INV-5). Runs before the status case so a draft answers 404, not 409. The cause
  # goes to the server log only. Advisory; `persist/14` re-checks under a FOR SHARE lock.
  defp gate_uninstalled_owner({:ok, %{owner_module: module_id} = definition} = found, opts)
       when is_binary(module_id) do
    if StartGate.uninstalled?(module_id, Keyword.get(opts, :prefix)) do
      Logger.info(
        "start refused: owner module uninstalled module_id=#{module_id} definition_id=#{definition.id}"
      )

      {:error, :not_found}
    else
      found
    end
  end

  defp gate_uninstalled_owner(lookup, _opts), do: lookup

  defp interpret_definition_lookup({:ok, definition}) do
    case definition do
      # GH #2692 (REQ-515): the recorded activator lost its authority; refuse a NEW start
      # before any token exists, so a SERVICE task cannot make its external call first.
      %{status: :active, needs_reactivation_at: %DateTime{}} ->
        {:error, :definition_needs_reactivation}

      %{status: :active} ->
        {:ok, definition}

      _other ->
        {:error, :definition_not_active}
    end
  end

  defp interpret_definition_lookup({:error, :not_found}), do: {:error, :definition_not_found}
  defp interpret_definition_lookup({:error, _reason} = error), do: error

  # ---------------------------------------------------------------------
  # Snapshot phase (design doc §5) -- must precede the event append; opens
  # and commits its own transaction, deliberately not folded into the
  # Ecto.Multi below (design doc §9 OQ-4).
  # ---------------------------------------------------------------------

  # REQ-059 (design doc §3) -- pin resolution (PinResolver.resolve/4),
  # initial-variable validation against the resolved variable_schema, and
  # child-instance pin inheritance all run BEFORE create_snapshot/3's first
  # Repo write, so a failed resolution/validation/parent-pin-lookup writes
  # zero rows anywhere (PIN-01 AC1/AC4, PIN-02 AC2) -- satisfied by
  # construction (a failure returns before create_snapshot/3 ever runs), not
  # by a rollback. The graph is built once, up front, and threaded into both
  # PinResolver.resolve/4 and activate/3 (its own signature changed from
  # activate(instance_id, definition, initial_variables) to
  # activate(instance_id, graph, initial_variables) -- mechanical, avoids
  # building the same graph twice).
  defp start_instance(definition, initial_variables, correlation_key, attrs, tenant_id, prefix) do
    instance_id = Ecto.UUID.generate()
    # REQ-187 design doc §3.1 -- "the arrival timestamp" (AC1) is one fixed
    # instant per hop-chain, read once here, before prepare_timer_arms/4
    # runs -- not a fresh clock read per timer.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, graph} <- build_graph(definition.graph),
         {:ok, own_pins, variable_json_schema} <-
           PinResolver.resolve(
             graph,
             definition,
             pin_lookup(attrs, tenant_id, prefix),
             pin_overrides(attrs)
           ),
         :ok <- PinResolver.validate_initial_variables(initial_variables, variable_json_schema),
         {:ok, parent_pins} <- parent_pins(attrs, prefix),
         {:ok, pins, conflicts} <- PinResolver.apply_inheritance(own_pins, parent_pins),
         {:ok, _snapshot} <- create_snapshot(instance_id, definition, prefix),
         {:ok, activated_state, pending_events} <-
           activate(instance_id, graph, initial_variables),
         # REQ-531: the start scope node rides on the state so snapshots and rebuilds keep it.
         new_instance_state = %{activated_state | scope_node_id: Map.get(attrs, :scope_node_id)},
         {:ok, prepared_children} <-
           prepare_sub_process_children(
             instance_id,
             new_instance_state,
             graph,
             pending_events,
             prefix
           ),
         {:ok, prepared_timers} <-
           prepare_timer_arms(pending_events, graph, instance_id, now),
         {:ok, prepared_service_task_dispatches} <-
           prepare_service_task_dispatch_for_create(
             pending_events,
             graph,
             instance_id,
             new_instance_state.variables,
             now,
             %{
               pin_source: {:pins, pins},
               tenant_id: tenant_id,
               variable_labels: new_instance_state.variable_labels,
               actor_id: Map.get(attrs, :actor_id)
             }
           ) do
      persist(
        instance_id,
        definition,
        initial_variables,
        correlation_key,
        graph,
        new_instance_state,
        prepared_children,
        prepared_timers,
        prepared_service_task_dispatches,
        tenant_id,
        pins,
        conflicts,
        attrs,
        prefix
      )
    end
  end

  # create/2's own call site has no already-persisted parent instance to
  # route an :empty_url_error into Letflow.Engine.ExecutionError against
  # (design doc §2.1 point 3, mirroring prepare_sub_process_children/5's own
  # "must write nothing on failure" contract) -- folds it into create/2's
  # own {:activation_failed, _} error shape instead, aborting activation
  # entirely.
  defp prepare_service_task_dispatch_for_create(
         pending_events,
         graph,
         instance_id,
         variables,
         now,
         catalog_ctx
       ) do
    case prepare_service_task_dispatch(
           pending_events,
           graph,
           instance_id,
           variables,
           now,
           catalog_ctx
         ) do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, reason} ->
        {:error, {:activation_failed, reason}}

      {:empty_url_error, node_id, _variables} ->
        {:error, {:activation_failed, {:service_task_url_rendered_empty, node_id}}}

      {:catalog_resolution_error, node_id, reason, _variables} ->
        {:error, {:activation_failed, {:service_task_catalog_unresolved, node_id, reason}}}

      # GH 2534 PR 7c-1 (design 4.4): a script SERVICE_TASK without a usable :script pin.
      {:script_binding_error, node_id, reason, _variables} ->
        {:error, {:activation_failed, {:script_binding_unresolved, node_id, reason}}}

      # GH #2616 part 2 (decision 0062 R12): a labelled variable would render into an outbound URL or body.
      {:restricted_outbound_error, node_id, keys, _variables} ->
        {:error,
         {:activation_failed, {:service_task_restricted_variable_outbound, node_id, keys}}}
    end
  end

  # req062 design doc §3.3 -- resolves every {:sub_process_start, token_id,
  # node_id} pending_event() surfaced by this instance's own root activation
  # (before any Multi step for create/2 itself has been appended, matching
  # SubProcess.prepare_child_activation/4's own "must write nothing on
  # failure" contract). A failure here aborts create/2 entirely, exactly
  # like every other activation failure this function already surfaces
  # (hop-limit, unimplemented node type) -- there is no already-persisted
  # parent instance for a failure at this specific call site to route into
  # Letflow.Engine.ExecutionError against (the parent itself does not exist
  # in the DB yet), unlike the dispatch_task_completion_hop_chain/5 call
  # site (§3.3), where the parent instance already exists and is already
  # locked.
  defp prepare_sub_process_children(
         instance_id,
         new_instance_state,
         graph,
         pending_events,
         prefix
       ) do
    pending_events
    |> Enum.filter(&match?({:sub_process_start, _token_id, _node_id}, &1))
    |> Enum.reduce_while({:ok, []}, fn {:sub_process_start, token_id, node_id}, {:ok, acc} ->
      case Enum.find(graph.nodes, &(&1.id == node_id)) do
        nil ->
          {:halt, {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}}

        node ->
          case SubProcess.prepare_child_activation(
                 instance_id,
                 new_instance_state.variables,
                 node,
                 parent_variable_labels: new_instance_state.variable_labels,
                 prefix: prefix
               ) do
            {:ok, prepared} ->
              {:cont, {:ok, [{token_id, prepared} | acc]}}

            {:error, reason} ->
              {:halt, {:error, {:activation_failed, {:subprocess_interface_violation, reason}}}}
          end
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # REQ-187 design doc §3.1 -- resolves every {:timer_armed, token_id,
  # node_id} pending_event() surfaced by this hop-chain (matching
  # prepare_sub_process_children/5's own Enum.filter precedent exactly)
  # into arm_attrs ready for Letflow.Scheduler.create/2, shared unchanged by
  # both start_instance/5's and complete_task/3's own call sites, and by
  # advance_after_timer_fired/3 (§8.4) for a :TIMER->:TIMER outgoing edge.
  # `token_id` is deliberately left out of arm_attrs -- filled in once the
  # real TokenRecord id is known (build_timer_arms_multi/4, below).
  @spec prepare_timer_arms(
          [Transition.pending_event()],
          Graph.t(),
          instance_id :: Ecto.UUID.t(),
          now :: DateTime.t()
        ) ::
          {:ok, [{token_id :: String.t(), arm_attrs :: map()}]}
          | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}}
          | {:error, {:invalid_timer_duration, node_id :: String.t(), value :: term()}}
          | {:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids :: [String.t()]}}
  defp prepare_timer_arms(pending_events, graph, instance_id, now) do
    timer_arms = Enum.filter(pending_events, &match?({:timer_armed, _token_id, _node_id}, &1))

    escalation_arms =
      Enum.filter(pending_events, &match?({:escalation_timer_armed, _token_id, _node_id}, &1))

    # REQ-494 design §2.2: reminder arms ride beside escalation arms, with their
    # own compound step name ({:scheduler_reminder_timer, token_record_id}), so
    # they are exempt from the single-deadline guard below as well.
    reminder_arms =
      Enum.filter(pending_events, &match?({:reminder_timer_armed, _token_id, _node_id}, &1))

    # CODE-DESIGN-VALIDATOR's own resolution of design doc §13 OQ-3
    # (handoff task description item "REQUIRED ADDITION"): Letflow.Scheduler.create/2's
    # Multi branch hardcodes the literal step name :scheduler_timer
    # (scheduler.ex:94) -- arming more than one :TIMER node in the same
    # hop-chain (reachable today via :PARALLEL_GATEWAY, transition.ex's own
    # real dispatch clause) would collide inside one Ecto.Multi and RAISE a
    # bare RuntimeError, which this codebase's totality discipline does not
    # tolerate. Turned into a graceful, typed failure here instead of
    # widening Scheduler.create/2's Multi API to accept a caller-supplied
    # step name (explicitly out of scope for this requirement).
    if length(timer_arms) > 1 do
      node_ids = Enum.map(timer_arms, fn {:timer_armed, _token_id, node_id} -> node_id end)
      {:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}}
    else
      # Escalation timer arms use compound step names ({:scheduler_escalation_timer, token_record_id})
      # in build_timer_arms_multi/4, so multiple escalation arms in the same hop chain are safe.
      escalation_result =
        escalation_arms
        |> Enum.reduce_while({:ok, []}, fn {:escalation_timer_armed, token_id, node_id},
                                           {:ok, acc} ->
          case Enum.find(graph.nodes, &(&1.id == node_id)) do
            nil ->
              {:halt, {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}}

            node ->
              case resolve_escalation_timer_arm_attrs(node, node_id, instance_id, now) do
                {:ok, arm_attrs} -> {:cont, {:ok, [{token_id, arm_attrs} | acc]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          {:error, reason} -> {:error, reason}
        end

      reminder_result =
        reminder_arms
        |> Enum.reduce_while({:ok, []}, fn {:reminder_timer_armed, token_id, node_id},
                                           {:ok, acc} ->
          case Enum.find(graph.nodes, &(&1.id == node_id)) do
            nil ->
              {:halt, {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}}

            node ->
              case resolve_reminder_timer_arm_attrs(node, node_id, instance_id, now) do
                {:ok, arm_attrs} -> {:cont, {:ok, [{token_id, arm_attrs} | acc]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          {:error, reason} -> {:error, reason}
        end

      with {:ok, escalation_prepared} <- escalation_result,
           {:ok, reminder_prepared} <- reminder_result do
        timer_arms
        |> Enum.reduce_while({:ok, []}, fn {:timer_armed, token_id, node_id}, {:ok, acc} ->
          case Enum.find(graph.nodes, &(&1.id == node_id)) do
            nil ->
              {:halt, {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}}

            node ->
              case resolve_timer_arm_attrs(node, node_id, instance_id, now) do
                {:ok, arm_attrs} -> {:cont, {:ok, [{token_id, arm_attrs} | acc]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, escalation_prepared ++ reminder_prepared ++ Enum.reverse(acc)}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # `:invalid_timer_duration` is defensive-only -- CHK-12 already rejects an
  # invalid duration_iso8601 at definition-approval time, so a :TIMER node
  # reaching here with one should be unreachable (design doc §3.1).
  defp resolve_timer_arm_attrs(%Graph.Node{attributes: attributes}, node_id, instance_id, now) do
    case Map.get(attributes || %{}, "duration_iso8601") do
      value when is_binary(value) ->
        case Graph.parse_iso8601_duration(value) do
          {:ok, seconds} ->
            {:ok,
             %{
               instance_id: instance_id,
               timer_type: TimerTypes.deadline(),
               node_id: node_id,
               fire_at: DateTime.add(now, seconds, :second)
             }}

          :error ->
            {:error, {:invalid_timer_duration, node_id, value}}
        end

      other ->
        {:error, {:invalid_timer_duration, node_id, other}}
    end
  end

  # REQ-396: mirrors resolve_timer_arm_attrs/4 but reads escalation_timer_duration
  # and sets the escalation timer type. CHK-21 already validates the duration at
  # definition-approval time, so an invalid value here is defensive-only.
  defp resolve_escalation_timer_arm_attrs(
         %Graph.Node{attributes: attributes},
         node_id,
         instance_id,
         now
       ) do
    case Map.get(attributes || %{}, "escalation_timer_duration") do
      value when is_binary(value) ->
        case Graph.parse_iso8601_duration(value) do
          {:ok, seconds} ->
            {:ok,
             %{
               instance_id: instance_id,
               timer_type: TimerTypes.escalation(),
               node_id: node_id,
               fire_at: DateTime.add(now, seconds, :second)
             }}

          :error ->
            {:error, {:invalid_timer_duration, node_id, value}}
        end

      other ->
        {:error, {:invalid_timer_duration, node_id, other}}
    end
  end

  # REQ-494 design §2.3: mirrors resolve_escalation_timer_arm_attrs/4 for
  # timer_type "reminder", plus the optional recurrence quartet. Interval
  # absent -> all four recurrence keys omitted (NULL); present ->
  # repeat_total = 1 + reminder_repeat_count, or 51 (50-repeat cap) when the
  # count is absent. Every error is defensive-only after CHK-28.
  @spec resolve_reminder_timer_arm_attrs(
          Graph.Node.t(),
          node_id :: String.t(),
          instance_id :: Ecto.UUID.t(),
          now :: DateTime.t()
        ) ::
          {:ok, Scheduler.arm_attrs()}
          | {:error, {:invalid_timer_duration, node_id :: String.t(), value :: term()}}
  defp resolve_reminder_timer_arm_attrs(
         %Graph.Node{attributes: attributes},
         node_id,
         instance_id,
         now
       ) do
    attributes = attributes || %{}
    duration = Map.get(attributes, "reminder_timer_duration")

    with {:ok, seconds} <- parse_reminder_duration(duration, node_id),
         {:ok, recurrence} <-
           resolve_reminder_recurrence(
             Map.get(attributes, "reminder_repeat_interval"),
             Map.get(attributes, "reminder_repeat_count"),
             node_id
           ) do
      {:ok,
       Map.merge(
         %{
           instance_id: instance_id,
           timer_type: TimerTypes.reminder(),
           node_id: node_id,
           fire_at: DateTime.add(now, seconds, :second)
         },
         recurrence
       )}
    end
  end

  defp parse_reminder_duration(value, node_id) when is_binary(value) do
    case Graph.parse_iso8601_duration(value) do
      {:ok, seconds} -> {:ok, seconds}
      :error -> {:error, {:invalid_timer_duration, node_id, value}}
    end
  end

  defp parse_reminder_duration(other, node_id),
    do: {:error, {:invalid_timer_duration, node_id, other}}

  defp resolve_reminder_recurrence(nil, nil, _node_id), do: {:ok, %{}}

  defp resolve_reminder_recurrence(nil, count, node_id),
    do: {:error, {:invalid_timer_duration, node_id, count}}

  defp resolve_reminder_recurrence(interval, count, node_id) do
    case Graph.parse_reminder_repeat_interval(interval) do
      :error ->
        {:error, {:invalid_timer_duration, node_id, interval}}

      {:ok, interval_seconds} when is_nil(count) ->
        {:ok, reminder_recurrence(interval, interval_seconds, 51)}

      {:ok, interval_seconds} when is_integer(count) and count in 1..50 ->
        {:ok, reminder_recurrence(interval, interval_seconds, 1 + count)}

      {:ok, _interval_seconds} ->
        {:error, {:invalid_timer_duration, node_id, count}}
    end
  end

  # `repeat_total` is the total number of fires (Scheduler.maybe_rearm_timer/3).
  defp reminder_recurrence(interval, interval_seconds, repeat_total) do
    %{
      repeat_expression: interval,
      repeat_interval_us: interval_seconds * 1_000_000,
      fired_count: 0,
      repeat_total: repeat_total
    }
  end

  # REQ-187 design doc §3.2 -- wires prepare_timer_arms/4's own output into
  # the caller's already-open Multi, reusing Letflow.Scheduler.create/2's
  # own documented Multi.t()-accepting branch (one Multi.insert/4 step per
  # timer, named :scheduler_timer -- prepare_timer_arms/4's own defensive
  # guard above ensures this is called with at most one deadline-timer entry
  # per Multi). REQ-396: escalation timers pass step_name: to Scheduler.create/2
  # so each gets a unique compound step name, preventing collisions when
  # multiple :HUMAN_TASK nodes with escalation are armed in one hop chain.
  @spec build_timer_arms_multi(
          Multi.t(),
          [{token_id :: String.t(), arm_attrs :: map()}],
          id_map :: %{String.t() => String.t()},
          prefix :: String.t()
        ) :: Multi.t()
  defp build_timer_arms_multi(multi, prepared_timers, id_map, prefix) do
    Enum.reduce(prepared_timers, multi, fn {token_id, arm_attrs}, acc_multi ->
      token_record_id = Map.fetch!(id_map, token_id)
      complete_attrs = Map.put(arm_attrs, :token_id, token_record_id)

      opts =
        case arm_attrs.timer_type do
          TimerTypes.escalation() ->
            [prefix: prefix, step_name: {:scheduler_escalation_timer, token_record_id}]

          # REQ-494 design §2.4: without its own step name a reminder would
          # collide with a deadline timer's :scheduler_timer in the same chain.
          TimerTypes.reminder() ->
            [prefix: prefix, step_name: {:scheduler_reminder_timer, token_record_id}]

          _ ->
            [prefix: prefix]
        end

      Scheduler.create(acc_multi, complete_attrs, opts)
    end)
  end

  # REQ-215 design doc §2.2 -- resolves every {:service_task_dispatch_requested,
  # token_id, node_id} pending_event() surfaced by this hop-chain (matching
  # prepare_timer_arms/4's own Enum.filter/reduce_while idiom exactly) into
  # arm_attrs ready for ServiceTaskDispatch.arm_changeset/2, shared unchanged
  # by create/2's, complete_task/3's, and advance_after_timer_fired/3's own
  # hop chains (§2.1) -- a SERVICE_TASK's outgoing edge can lead into another
  # SERVICE_TASK node just as readily as a :START or :TIMER edge can lead
  # into one. `token_id` is deliberately left out of arm_attrs -- filled in
  # once the real TokenRecord id is known (build_service_task_dispatch_multi/5,
  # below), mirroring prepare_timer_arms/4's own deferred-token_id pattern.
  #
  # Unlike prepare_timer_arms/4, no "at most one per hop chain" guard is
  # needed here (§2.5) -- build_service_task_dispatch_multi/5 keys each
  # Multi.insert/4 step by a compound {:service_task_dispatch, token_record_id}
  # tuple, not a bare atom, so more than one SERVICE_TASK dispatch prepared
  # in the same hop chain (e.g. a PARALLEL_GATEWAY split reaching two
  # SERVICE_TASK nodes) cannot collide.
  @spec prepare_service_task_dispatch(
          [Transition.pending_event()],
          Graph.t(),
          instance_id :: Ecto.UUID.t(),
          variables :: map(),
          now :: DateTime.t(),
          catalog_dispatch_ctx()
        ) ::
          {:ok, [prepared_service_task_dispatch()]}
          | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}}
          | {:error,
             {:config_parse_failed, node_id :: String.t(), ServiceTask.config_parse_error()}}
          | {:empty_url_error, node_id :: String.t(), variables :: map()}
          | {:catalog_resolution_error, node_id :: String.t(), catalog_resolution_reason(),
             variables :: map()}
          | {:script_binding_error, node_id :: String.t(), :pin_missing | :pin_mismatch,
             variables :: map()}
          | {:restricted_outbound_error, node_id :: String.t(), keys :: [String.t()],
             variables :: map()}
  # GH 2534 PR 7c-1 (design 4.4): `kind` says which table the row goes to -- `:http`
  # (`service_task_dispatches`, every pre-7c row) or `:script` (`script_task_dispatches`).
  @type prepared_service_task_dispatch :: %{
          required(:token_id) => String.t(),
          required(:node_id) => String.t(),
          required(:arm_attrs) => map(),
          optional(:kind) => :http | :script
        }
  # ISS-0917 (design D2) -- where the instance's effective pins come from and
  # which tenant's visibility applies when a `route_kind: :catalog_service`
  # node is activated. `{:pins, list}` (create/2: already in hand) or
  # `{:reconstruct, instance_id, prefix}` (every other site: read lazily from
  # the instance's event log, at most once per call). `tenant_id` is either
  # the resolved id or `{:schema_prefix, prefix}` (completion hop: derived
  # lazily, only if a catalog node is actually activated). Never caller input.
  @typep catalog_pin_source ::
           {:pins, [PinResolver.pinned_version() | PinResolver.effective_pin()]}
           | {:reconstruct, instance_id :: Ecto.UUID.t(), prefix :: String.t() | nil}
  # GH 2534 PR 7c-1 (design 4.4): optional `actor_id`, the hop chain's command actor (create/2:
  # the starting actor; complete_task/3: the completing user), stored on a script dispatch row
  # as `triggering_user_id`; timer, HTTP-advance, script-advance and sub-process hops pass none.
  # GH #2616 part 2 (decision 0062 R12): `variable_labels` are the labels of the `variables` the
  # dispatch renders, read from the same in-memory state (a labelled key may not reach an endpoint).
  @typep catalog_dispatch_ctx :: %{
           required(:pin_source) => catalog_pin_source(),
           required(:tenant_id) => Ecto.UUID.t() | {:schema_prefix, String.t()},
           required(:variable_labels) => %{optional(String.t()) => [String.t()]},
           optional(:actor_id) => Ecto.UUID.t() | nil
         }
  @typep catalog_resolution_reason ::
           {:pin_missing, :catalog_entry, String.t()}
           | :pin_has_no_identity
           | :pins_unavailable
           | :version_not_found
           | {:required_auth_unsupported, :API_KEY | :OAUTH2 | :MUTUAL_TLS}
  defp prepare_service_task_dispatch(
         pending_events,
         graph,
         instance_id,
         variables,
         now,
         catalog_ctx
       ) do
    dispatch_requests =
      Enum.filter(
        pending_events,
        &match?({:service_task_dispatch_requested, _token_id, _node_id}, &1)
      )

    dispatch_requests
    |> Enum.reduce_while({:ok, [], catalog_ctx}, fn {:service_task_dispatch_requested, token_id,
                                                     node_id},
                                                    {:ok, acc, ctx} ->
      case Enum.find(graph.nodes, &(&1.id == node_id)) do
        nil ->
          {:halt, {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}}

        node ->
          case resolve_service_task_arm_attrs(node, node_id, instance_id, variables, now, ctx) do
            {:ok, arm_attrs, ctx} ->
              {:cont,
               {:ok, [%{token_id: token_id, node_id: node_id, arm_attrs: arm_attrs} | acc], ctx}}

            {:ok_script, arm_attrs, ctx} ->
              prepared = %{
                token_id: token_id,
                node_id: node_id,
                arm_attrs: arm_attrs,
                kind: :script
              }

              {:cont, {:ok, [prepared | acc], ctx}}

            {:error, reason} ->
              {:halt, {:error, reason}}

            {:empty_url_error, ^node_id} ->
              {:halt, {:empty_url_error, node_id, variables}}

            {:catalog_resolution_error, ^node_id, reason} ->
              {:halt, {:catalog_resolution_error, node_id, reason, variables}}

            {:script_binding_error, ^node_id, reason} ->
              {:halt, {:script_binding_error, node_id, reason, variables}}

            {:restricted_outbound_error, ^node_id, keys} ->
              {:halt, {:restricted_outbound_error, node_id, keys, variables}}
          end
      end
    end)
    |> case do
      {:ok, acc, _ctx} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
      {:empty_url_error, node_id, variables} -> {:empty_url_error, node_id, variables}
      {:catalog_resolution_error, _node_id, _reason, _variables} = error -> error
      {:script_binding_error, _node_id, _reason, _variables} = error -> error
      {:restricted_outbound_error, _node_id, _keys, _variables} = error -> error
    end
  end

  # design doc §2.2 steps 2-5. A ServiceTask.parse_config_from_node_attributes/1
  # failure is a graph-authoring-time defect REQ-029's CHK-11-family
  # validators are expected to have already caught -- folds into
  # {:error, {:config_parse_failed, node_id, reason}}, aborting the whole
  # hop-chain's Multi (same "abort, don't half-commit" contract
  # prepare_timer_arms/4's own errors already have).
  #
  # ISS-0917 (design D2): a route_kind: :catalog_service node is resolved HERE,
  # at activation, from the instance's OWN effective pin for config.service_id
  # (never from the live current catalog row -- INV-PD-1):
  #   1. obtain the pins (create/2: in hand; elsewhere: reconstructed lazily),
  #   2. PinResolver.pin_for/3 -> the pin, else {:pin_missing, ...},
  #   3. resolve the pinned version by version_id, or by (service_id, version)
  #      for a rebound pin (ServiceCatalog.resolve_pinned_version/3),
  #   4. required_auth != :NONE fails closed (no request is built),
  #   5. render the pinned endpoint_url with the same {{variables.KEY}}
  #      renderer an inline url_template uses and freeze it (plus audit keys)
  #      in config_snapshot, so ServiceTaskDispatcher only ever sees a frozen
  #      rendered_url and never calls the catalog.
  # Every failure is a typed tuple; none falls back to the live row.
  defp resolve_service_task_arm_attrs(node, node_id, instance_id, variables, now, ctx) do
    case ServiceTask.parse_config_from_node_attributes(node) do
      {:error, reason} ->
        {:error, {:config_parse_failed, node_id, reason}}

      {:ok, %ServiceTask.Config{route_kind: :inline_url} = config} ->
        with [] <- restricted_outbound_keys([config.url_template, config.body_template], ctx) do
          rendered_url = render_service_task_template(config.url_template, variables)
          rendered_body = render_service_task_body_template(config.body_template, variables)

          with {:ok, arm_attrs} <-
                 finish_service_task_arm_attrs(
                   config,
                   node_id,
                   instance_id,
                   rendered_url,
                   rendered_body,
                   now
                 ) do
            {:ok, arm_attrs, ctx}
          end
        else
          keys -> {:restricted_outbound_error, node_id, keys}
        end

      {:ok, %ServiceTask.Config{route_kind: :catalog_service} = config} ->
        case resolve_catalog_version(config, ctx) do
          {:ok, resolved, ctx} ->
            with [] <-
                   restricted_outbound_keys([resolved.endpoint_url, config.body_template], ctx) do
              rendered_url = render_service_task_template(resolved.endpoint_url, variables)
              rendered_body = render_service_task_body_template(config.body_template, variables)

              with {:ok, arm_attrs} <-
                     finish_service_task_arm_attrs(
                       config,
                       node_id,
                       instance_id,
                       rendered_url,
                       rendered_body,
                       now,
                       resolved
                     ) do
                {:ok, arm_attrs, ctx}
              end
            else
              keys -> {:restricted_outbound_error, node_id, keys}
            end

          {:error, reason} ->
            {:catalog_resolution_error, node_id, reason}
        end

      # GH 2534 PR 7c-1 (design 4.4): the instance's OWN frozen :script pin for the node's
      # key (from the same pin source the catalog route uses). A missing pin, a pin whose
      # version differs from the node's, or a pin without sha256 is a typed binding error.
      {:ok, %ServiceTask.Config{route_kind: :script} = config} ->
        case resolve_script_pin(config, ctx) do
          {:ok, sha256, ctx} ->
            arm_attrs = %{
              instance_id: instance_id,
              node_id: node_id,
              script_key: config.script_key,
              script_version: config.script_version,
              script_sha256: sha256,
              event_time: now,
              next_attempt_at: now,
              triggering_user_id: triggering_user_id(ctx)
            }

            {:ok_script, arm_attrs, ctx}

          {:error, reason} ->
            {:script_binding_error, node_id, reason}
        end
    end
  end

  # GH #2616 part 2 (decision 0062 R12): a labelled variable never renders into a URL or body that
  # leaves the process. Returns the sorted key names of the templates' placeholders that carry a
  # label in the dispatch's own labels (names only; `[]` when none). An unlabelled key renders as today.
  defp restricted_outbound_keys(templates, ctx) do
    templates
    |> Enum.flat_map(&ServiceTask.template_variable_keys/1)
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(ctx.variable_labels, &1, []) != []))
    |> Enum.sort()
  end

  defp resolve_script_pin(%ServiceTask.Config{script_key: key, script_version: version}, ctx) do
    case catalog_pins(ctx.pin_source) do
      {:ok, pins, pin_source} ->
        ctx = %{ctx | pin_source: pin_source}
        expected_version = Integer.to_string(version)

        case PinResolver.pin_for(pins, :script, key) do
          {:ok, %{version: ^expected_version, sha256: sha256}}
          when is_binary(sha256) and byte_size(sha256) == 64 ->
            {:ok, sha256, ctx}

          {:ok, _mismatched_or_unhashed} ->
            {:error, :pin_mismatch}

          {:error, _missing} ->
            {:error, :pin_missing}
        end

      {:error, _pins_unavailable} ->
        {:error, :pin_missing}
    end
  end

  # The platform actor (and anything not a UUID) is stored as NULL (design 4.4, R8).
  defp triggering_user_id(ctx) do
    with actor when is_binary(actor) <- Map.get(ctx, :actor_id),
         true <- actor != EventStore.platform_actor_id(),
         {:ok, uuid} <- Ecto.UUID.cast(actor) do
      uuid
    else
      _ -> nil
    end
  end

  # ISS-0917 -- steps 1-4 of the pipeline above. Returns the (possibly
  # memoised) ctx so a hop chain reconstructs pins / derives the tenant id at
  # most once.
  @spec resolve_catalog_version(ServiceTask.Config.t(), catalog_dispatch_ctx()) ::
          {:ok, ServiceCatalog.resolved_service_version(), catalog_dispatch_ctx()}
          | {:error, catalog_resolution_reason()}
  defp resolve_catalog_version(%ServiceTask.Config{service_id: service_id}, ctx) do
    with {:ok, pins, tenant_id, ctx} <- catalog_pins_and_tenant(ctx),
         {:ok, pin} <- PinResolver.pin_for(pins, :catalog_entry, service_id),
         {:ok, identity} <- catalog_pin_identity(pin),
         {:ok, resolved} <- fetch_pinned_version(service_id, identity, tenant_id),
         :ok <- check_catalog_auth_supported(resolved) do
      {:ok, resolved, ctx}
    end
  end

  defp catalog_pins_and_tenant(%{pin_source: pin_source, tenant_id: tenant_id} = ctx) do
    with {:ok, pins, pin_source} <- catalog_pins(pin_source),
         {:ok, tenant_id} <- catalog_tenant_id(tenant_id) do
      {:ok, pins, tenant_id, %{ctx | pin_source: pin_source, tenant_id: tenant_id}}
    end
  end

  defp catalog_pins({:pins, pins} = source) when is_list(pins), do: {:ok, pins, source}

  defp catalog_pins({:reconstruct, instance_id, prefix}) do
    case PinResolver.reconstruct_effective_pins(instance_id, prefix: prefix) do
      {:ok, pins} -> {:ok, pins, {:pins, pins}}
      _error -> {:error, :pins_unavailable}
    end
  end

  defp catalog_tenant_id({:schema_prefix, prefix}) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      _error -> {:error, :pins_unavailable}
    end
  end

  defp catalog_tenant_id(tenant_id) when is_binary(tenant_id), do: {:ok, tenant_id}

  defp catalog_pin_identity(%{resolved_id: id}) when is_binary(id) and id != "",
    do: {:ok, {:version_id, id}}

  defp catalog_pin_identity(%{version: version}) when is_binary(version) and version != "",
    do: {:ok, {:version, version}}

  defp catalog_pin_identity(_pin), do: {:error, :pin_has_no_identity}

  defp fetch_pinned_version(service_id, identity, tenant_id) do
    case ServiceCatalog.resolve_pinned_version(service_id, identity, tenant_id) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :not_found} -> {:error, :version_not_found}
    end
  end

  # http_transport/3 implements no authentication and no per-tenant secret
  # reference is wired into the dispatcher (INV-4), so a service declaring
  # required_auth != :NONE fails closed rather than receiving an
  # unauthenticated request.
  defp check_catalog_auth_supported(%{required_auth: :NONE}), do: :ok

  defp check_catalog_auth_supported(%{required_auth: auth}),
    do: {:error, {:required_auth_unsupported, auth}}

  defp finish_service_task_arm_attrs(
         config,
         node_id,
         instance_id,
         rendered_url,
         rendered_body,
         now,
         catalog_version \\ nil
       ) do
    case ServiceTask.validate_rendered_url(rendered_url) do
      {:error, :empty_rendered_url} ->
        {:empty_url_error, node_id}

      :ok ->
        arm_attrs = %{
          instance_id: instance_id,
          node_id: node_id,
          config_snapshot:
            config_snapshot_map(config, rendered_url, rendered_body, catalog_version),
          attempt_index: 0,
          next_attempt_at: now,
          created_at: now
        }

        {:ok, arm_attrs}
    end
  end

  # design doc §2.2 -- plain map projection of ServiceTask.Config.t() plus
  # the derived keys "rendered_url" and "rendered_body" (ISS-0926 added the
  # latter, mirroring the former), matching exactly the field set
  # ServiceTaskDispatcher's own config_from_snapshot/1 reads back
  # (service_task_dispatcher.ex:630-648). String-keyed, matching
  # ServiceTaskDispatch.config_snapshot()'s own @type.
  #
  # ISS-0917 -- for a catalog row (`catalog_version` non-nil) "rendered_url"
  # is the rendered PINNED endpoint_url, "timeout_ms" is min(node, catalog)
  # (the service's declared bound can only tighten the author's), and three
  # audit keys are added. `catalog_retry_policy` is audit-only, deliberately
  # not interpreted (retry stays the node's retry_limit). The inline path
  # (`catalog_version` nil) gets no extra keys at all.
  @spec config_snapshot_map(
          ServiceTask.Config.t(),
          rendered_url :: String.t() | nil,
          rendered_body :: String.t() | nil,
          ServiceCatalog.resolved_service_version() | nil
        ) :: map()
  defp config_snapshot_map(
         %ServiceTask.Config{} = config,
         rendered_url,
         rendered_body,
         catalog_version
       ) do
    base = %{
      "route_kind" => to_string(config.route_kind),
      "url_template" => config.url_template,
      "service_id" => config.service_id,
      "method" => to_string(config.method),
      "body_template" => config.body_template,
      "headers" => config.headers,
      "timeout_ms" => config.timeout_ms,
      "retry_limit" => config.retry_limit,
      "rendered_url" => rendered_url,
      "rendered_body" => rendered_body
    }

    case catalog_version do
      nil ->
        base

      %{} = resolved ->
        Map.merge(base, %{
          "timeout_ms" => min(config.timeout_ms, resolved.timeout_ms),
          "catalog_version_id" => resolved.version_id,
          "catalog_version" => resolved.version,
          "catalog_retry_policy" => resolved.retry_policy
        })
    end
  end

  # REQ-215 design doc §2.3 -- the minimal inline {{variables.KEY}} template
  # renderer. Scoped to exactly the {{variables.KEY}} syntax the R-Co design
  # doc names (src/design/ext-01-service-task-node.md:20, {{variables.order_id}}).
  # Used for url_template only -- a URL has no JSON-string-literal quoting to
  # protect, so substitution stays plain (this IS the pre-ISS-0926 behavior;
  # it is a separate, lower-severity risk class and intentionally untouched
  # by the SECURITY-REVIEWER fix below). No existing rendering mechanism was
  # found anywhere in this codebase to reuse (§0.1) -- this function is
  # deliberately new, deliberately minimal, and is NOT the intended long-term
  # shape for template rendering in this codebase: a future requirement
  # needing richer syntax (nested paths, escaping, conditionals) should
  # replace this function with a real one.
  @spec render_service_task_template(template :: String.t() | nil, variables :: map()) ::
          String.t() | nil
  defp render_service_task_template(nil, _variables), do: nil

  defp render_service_task_template(template, variables) when is_binary(template) do
    Regex.replace(ServiceTask.template_placeholder(), template, fn _match, key ->
      variables |> Map.get(key) |> render_service_task_value()
    end)
  end

  # SECURITY-REVIEWER fail on PR #2113 (ISS-0926 follow-up) -- body_template
  # splices its substituted values into a JSON-string-literal position inside
  # the fixture's raw JSON text (e.g. `"review_id":"{{variables.review_id}}"`).
  # Unlike url_template above, an unescaped substitution here lets a `"` in
  # the variable's value close the surrounding JSON string early and inject
  # sibling keys, or forge a duplicate key that shadows a legitimate field
  # (proof: a `review_id` of `x","reviewer_override":"approved_by_attacker",
  # "notes":"n` renders a `"reviewer_override"` key that was never in the
  # template; a value like `x","reason":"all_clear` produces a duplicate
  # `"reason"` key whose resolution is parser-dependent). This sibling
  # function is identical to render_service_task_template/2 except every
  # substituted value is JSON-string-escaped (json_string_escape/1) before
  # splicing, so a `"` or control character in the value can never terminate
  # the enclosing JSON string. variables.body_template stays a plain string
  # (ServiceTask.parse_config_from_node_attributes/1 reads it as-is off node
  # attributes, matching §0.1's existing "no new syntax" scope) -- escaping
  # individual substituted values, not switching to map-then-Jason.encode!/1,
  # is the natural fix for that representation.
  @spec render_service_task_body_template(template :: String.t() | nil, variables :: map()) ::
          String.t() | nil
  defp render_service_task_body_template(nil, _variables), do: nil

  defp render_service_task_body_template(template, variables) when is_binary(template) do
    Regex.replace(ServiceTask.template_placeholder(), template, fn _match, key ->
      variables |> Map.get(key) |> render_service_task_value() |> json_string_escape()
    end)
  end

  # JSON-string-content escaping (quotes, backslashes, control characters)
  # for a value about to be spliced between a JSON template's own existing
  # quotes -- equivalent to Jason.encode!/1'ing the raw string and stripping
  # the outer quote pair it adds, so the result is safe to place INSIDE an
  # already-quoted JSON string literal (not a standalone JSON string itself).
  @spec json_string_escape(String.t()) :: String.t()
  defp json_string_escape(value) when is_binary(value) do
    encoded = Jason.encode!(value)
    String.slice(encoded, 1, String.length(encoded) - 2)
  end

  defp render_service_task_value(nil), do: ""
  defp render_service_task_value(value) when is_binary(value), do: value

  defp render_service_task_value(value) when is_number(value) or is_atom(value),
    do: to_string(value)

  defp render_service_task_value(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value)

  # design doc §2.4 -- thin wrapper building ServiceTask.empty_url_context()
  # from the hop-chain's already-in-scope values and calling
  # ServiceTask.build_empty_url_error_attrs/1 unmodified. idempotency_key
  # uses ServiceTask.build_idempotency_key/4 with attempt_index: 0 (no
  # dispatch row exists yet at this failure point).
  @spec build_service_task_empty_url_error(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          variables :: map(),
          variable_labels :: map(),
          actor_id :: Ecto.UUID.t() | nil,
          idempotency_key :: String.t()
        ) :: standalone_error_attrs()
  defp build_service_task_empty_url_error(
         instance_id,
         node_id,
         variables,
         variable_labels,
         actor_id,
         idempotency_key
       ) do
    context = %{
      instance_id: instance_id,
      node_id: node_id,
      actor_id: actor_id,
      idempotency_key: idempotency_key,
      variables: variables
    }

    context
    |> ServiceTask.build_empty_url_error_attrs()
    |> Map.put(:labels, variable_labels)
  end

  # ISS-0917 -- sibling of build_service_task_empty_url_error/5 for a catalog
  # SERVICE_TASK whose pinned version could not be resolved at activation.
  @spec build_service_task_catalog_unresolved_error(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          reason :: term(),
          variables :: map(),
          variable_labels :: map(),
          actor_id :: Ecto.UUID.t() | nil,
          idempotency_key :: String.t()
        ) :: standalone_error_attrs()
  defp build_service_task_catalog_unresolved_error(
         instance_id,
         node_id,
         reason,
         variables,
         variable_labels,
         actor_id,
         idempotency_key
       ) do
    %{
      instance_id: instance_id,
      node_id: node_id,
      reason: reason,
      actor_id: actor_id,
      idempotency_key: idempotency_key,
      variables: variables
    }
    |> ServiceTask.build_catalog_unresolved_error_attrs()
    |> Map.put(:labels, variable_labels)
  end

  # REQ-215 design doc §2.5 -- wires prepare_service_task_dispatch/5's own
  # output into the caller's already-open Multi, mirroring
  # build_timer_arms_multi/4's own shape but calling
  # ServiceTaskDispatch.arm_changeset/2 directly (no intermediary "create"
  # function exists or is needed -- REQ-214's own moduledoc already
  # documents arm_changeset/2 as "called only by REQ-215's future
  # activation-time caller," i.e. this module). Named step key
  # {:service_task_dispatch, token_record_id} (a compound tuple key,
  # mirroring {:hop_chain_token_records, instance_id}'s own compound-key
  # precedent) rather than a bare atom -- more than one SERVICE_TASK
  # dispatch can be prepared in the same hop chain (§2.5's own note above).
  @spec build_service_task_dispatch_multi(
          Multi.t(),
          [prepared_service_task_dispatch()],
          id_map :: %{String.t() => String.t()},
          tenant_id :: Ecto.UUID.t(),
          prefix :: String.t()
        ) :: Multi.t()
  defp build_service_task_dispatch_multi(multi, prepared_dispatches, id_map, tenant_id, prefix) do
    Enum.reduce(prepared_dispatches, multi, fn %{token_id: token_id, arm_attrs: arm_attrs} =
                                                 prepared,
                                               acc_multi ->
      token_record_id = Map.fetch!(id_map, token_id)
      row_id = Ecto.UUID.generate()

      case Map.get(prepared, :kind, :http) do
        :http ->
          attrs =
            arm_attrs
            |> Map.put(:id, row_id)
            |> Map.put(:token_id, token_record_id)
            |> Map.put(:tenant_id, tenant_id)

          Multi.insert(
            acc_multi,
            {:service_task_dispatch, token_record_id},
            ServiceTaskDispatch.arm_changeset(%ServiceTaskDispatch{}, attrs),
            prefix: prefix
          )

        # GH 2534 PR 7c-1 (design 4.4): a script binding's row (no tenant_id column, 0006 D2).
        :script ->
          attrs =
            arm_attrs
            |> Map.put(:id, row_id)
            |> Map.put(:token_id, token_record_id)

          Multi.insert(
            acc_multi,
            {:script_task_dispatch, token_record_id},
            ScriptTaskDispatch.arm_changeset(%ScriptTaskDispatch{}, attrs),
            prefix: prefix
          )
      end
    end)
  end

  # design doc §8 -- attrs[:pin_lookup] surface: a caller-supplied
  # PinResolver.Lookup.t(), or (REQ-373 design §6) Letflow.ServiceCatalog.PinLookup.build/1
  # -- the real, catalog-backed Lookup -- when none is given. Only this
  # second Map.get/3 argument changed (was PinResolver.default_lookup/0);
  # attrs[:pin_lookup], when a caller supplies one, is still returned
  # verbatim and untouched. PinLookup.build/1 itself copies
  # module_lookup/variable_schema_lookup verbatim from
  # PinResolver.default_lookup/0 (see that module's own @doc), so every
  # existing variable_schema/module_ref resolution path is byte-unchanged by
  # this wiring -- only a catalog_entry (SERVICE_TASK service_id) reference's
  # resolution outcome can differ. tenant_id (ISS-0922) scopes the catalog
  # lookup to services visible to the starting tenant.
  #
  # GH 2534 PR 7c-1 (design 4.3): the default lookup also carries the script registry's
  # `script_lookup` closure for `prefix`; a caller-supplied `attrs[:pin_lookup]` is still
  # returned unchanged (its nil `script_lookup` resolves no script binding).
  @spec pin_lookup(attrs :: map(), tenant_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          PinResolver.Lookup.t()
  defp pin_lookup(attrs, tenant_id, prefix) do
    Map.get_lazy(attrs, :pin_lookup, fn ->
      PinLookup.build(tenant_id, prefix)
    end)
  end

  # design doc §8 -- attrs[:pin_overrides] surface, [] when absent.
  @spec pin_overrides(attrs :: map()) :: [PinResolver.override_entry()]
  defp pin_overrides(attrs) do
    Map.get(attrs, :pin_overrides, [])
  end

  # design doc §8 -- attrs[:parent_instance_id] surface: nil (root instance,
  # no parent) when absent; otherwise reconstructs the parent's effective pin
  # set via PinResolver.reconstruct_effective_pins/2. The design's own §8
  # spec shows a bare `[PinResolver.effective_pin()] | nil` return type, but
  # its own prose requires a reconstruct_effective_pins/2 failure to
  # propagate as create/2's own {:error, {:parent_pin_lookup_failed, reason}}
  # -- a bare, untagged return cannot carry that error, so this
  # implementation returns {:ok, pins_or_nil} | {:error, _} to fit the
  # `with` chain above, the smallest change consistent with the design's own
  # stated error-propagation requirement. Flagged for REVIEWER (also design
  # doc §9 OQ-4: the :parent_instance_id key name itself is a forward guess
  # against not-yet-built REQ-062, unconfirmed against that requirement's
  # own eventual code).
  @spec parent_pins(attrs :: map(), prefix :: String.t() | nil) ::
          {:ok, [PinResolver.effective_pin()] | nil}
          | {:error, {:parent_pin_lookup_failed, reason :: term()}}
  defp parent_pins(attrs, prefix) do
    case Map.get(attrs, :parent_instance_id) do
      nil ->
        {:ok, nil}

      parent_instance_id ->
        case PinResolver.reconstruct_effective_pins(parent_instance_id, prefix: prefix) do
          {:ok, pins} -> {:ok, pins}
          {:error, reason} -> {:error, {:parent_pin_lookup_failed, reason}}
        end
    end
  end

  defp create_snapshot(instance_id, definition, prefix) do
    case SnapshotStore.create(instance_id, definition.id, prefix: prefix) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :definition_not_found} -> {:error, :definition_not_found}
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------
  # Pure dispatch off :START (design doc §6 steps 8-9) -- runs entirely
  # before the Multi opens, so a dispatch failure never needs a rollback.
  # ---------------------------------------------------------------------

  defp activate(instance_id, graph, initial_variables) do
    with {:ok, start_node} <- find_start_node(graph) do
      token_id = Ecto.UUID.generate()
      root_token = %Token{token_id: token_id, node_id: start_node.id, branch_id: instance_id}

      instance_state = %InstanceState{
        instance_id: instance_id,
        status: :active,
        tokens: [root_token],
        variables: initial_variables,
        pending_task_nodes: []
      }

      # Defensive-only bound (see moduledoc): REQ-028's structural validators
      # are expected to reject any true graph cycle before a definition ever
      # reaches create/2, so this is never expected to actually trigger --
      # it exists purely so a malformed graph that somehow slips past those
      # validators fails with a typed error instead of looping forever
      # (this codebase's "never raise, never hang" totality discipline,
      # transition.ex's own moduledoc). Scaled by a small multiple of the
      # node count, not just `length(graph.nodes) + 1`: a PARALLEL_GATEWAY
      # split (REQ-051) can put several tokens in flight at once, each
      # independently walking its own branch toward the matching join, so
      # the total hop budget for one activation can legitimately exceed the
      # raw node count without any cycle being involved.
      hop_limit = length(graph.nodes) * 4 + 10

      case advance_until_stable(graph, instance_state, [token_id], hop_limit) do
        {:ok, new_instance_state, pending_events} ->
          {:ok, new_instance_state, pending_events}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Worklist-driven activation loop: `pending_token_ids` holds every token_id
  # still known to need a dispatch attempt at its *current* position.
  # Advances a single hop with the head of the worklist, then re-derives
  # which token_ids need dispatching next by diffing the token list before
  # and after that hop (`tokens_needing_dispatch/3`) -- this is what lets a
  # single uniform rule handle every REQ-044/050/051 dispatch clause without
  # this module hardcoding which node types "auto-advance": a token needs
  # another dispatch call exactly when it just arrived somewhere its own
  # node's dispatch hasn't run yet (a fresh `node_id`, whether reached via
  # :START/gateway advance, a PARALLEL_GATEWAY split's newly-derived
  # branches, or a join firing's newly-derived merged token) -- never when
  # it stayed put (:HUMAN_TASK's "no automatic outgoing traversal" contract,
  # or a join's :wait outcome consuming the arriving branch token without
  # producing a new one).
  # Made public (still `@doc false`, not part of this module's documented API)
  # rather than duplicated, per req053 design doc §9 OQ-2's own two named
  # options ("exported from Engine with @doc false, or extracted into a
  # small shared helper module") — Letflow.Engine.Reconstruction
  # (REQ-053, EE-11) drives this exact worklist loop over a replayed
  # InstanceState the same way create/2's own activate/2 and complete_task/3's
  # own dispatch_task_completion_hop_chain/5 already do. Duplicating this
  # function's body risked the two copies silently diverging over time
  # (design doc §9 OQ-2's own stated risk for that alternative) — exporting
  # the existing, already-tested implementation unchanged avoids that at the
  # cost of a slightly wider module surface, which @doc false keeps out of
  # generated docs. Flagged for REVIEWER per the design doc's own request.
  # req062 design doc §3.1 -- widened to accumulate every hop's own
  # pending_event() list (order preserved, hop order) and return it as a
  # third tuple element, rather than silently dropping it one hop at a time.
  # Every caller now binds and uses this third element; for now only
  # {:sub_process_start, ...} entries are actually consumed by this
  # requirement's own new code (Letflow.Engine.SubProcess) -- every other
  # variant continues to be structurally received but not acted on,
  # identical to today's behavior.
  @doc false
  @spec advance_until_stable(Graph.t(), InstanceState.t(), [String.t()], integer()) ::
          {:ok, InstanceState.t(), [Transition.pending_event()]}
          | {:error, {:activation_failed, term()}}
  def advance_until_stable(_graph, instance_state, [], _hops_remaining) do
    {:ok, instance_state, []}
  end

  def advance_until_stable(_graph, _instance_state, [token_id | _rest], hops_remaining)
      when hops_remaining <= 0 do
    {:error, {:activation_failed, {:hop_limit_exceeded, token_id}}}
  end

  def advance_until_stable(graph, instance_state, [token_id | rest], hops_remaining) do
    previous_tokens = instance_state.tokens

    case Transition.transition(graph, instance_state, {:advance_token, token_id}) do
      {:ok, new_instance_state, pending_events} ->
        newly_pending =
          tokens_needing_dispatch(previous_tokens, new_instance_state.tokens, token_id)

        case advance_until_stable(
               graph,
               new_instance_state,
               rest ++ newly_pending,
               hops_remaining - 1
             ) do
          {:ok, final_state, more_pending_events} ->
            {:ok, final_state, pending_events ++ more_pending_events}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:activation_failed, reason}}
    end
  end

  # Diffs the token list from just before/after one dispatch call to decide
  # which token_ids still need their own dispatch attempt: any token_id that
  # didn't exist before this hop (a PARALLEL_GATEWAY split's derived
  # branches, or a join's newly-fired merged token) is always fresh and
  # needs one; the just-dispatched token_id itself needs another pass only
  # if its node_id actually changed (it moved somewhere new) -- if it's
  # gone entirely (:END removed it, or a join consumed it) or stayed at the
  # same node_id (:HUMAN_TASK's genuine stop) it does not. Every other
  # existing token is untouched by this hop and was already resolved (either
  # still correctly queued from an earlier hop, or already stable) -- this
  # function never re-adds it.
  # Public/`@doc false` for the same req053 design doc §9 OQ-2 reason as
  # advance_until_stable/4 above.
  @doc false
  @spec tokens_needing_dispatch([Token.t()], [Token.t()], String.t()) :: [String.t()]
  def tokens_needing_dispatch(previous_tokens, new_tokens, dispatched_token_id) do
    previous_by_id = Map.new(previous_tokens, &{&1.token_id, &1})

    new_tokens
    |> Enum.filter(fn token ->
      case Map.fetch(previous_by_id, token.token_id) do
        :error ->
          true

        {:ok, %Token{node_id: previous_node_id}} ->
          token.token_id == dispatched_token_id and token.node_id != previous_node_id
      end
    end)
    |> Enum.map(& &1.token_id)
  end

  # Public/`@doc false` for the same req053 design doc §9 OQ-2 reason as
  # advance_until_stable/4 above -- Letflow.Engine.Reconstruction (REQ-053)
  # resolves an event log's snapshot graph through this exact function
  # rather than re-deriving graph-load error mapping independently.
  @doc false
  @spec build_graph(map()) ::
          {:ok, Graph.t()} | {:error, {:graph_structure_invalid, term()}}
  def build_graph(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, graph} -> {:ok, graph}
      :error -> {:error, {:graph_structure_invalid, :invalid_graph_map}}
    end
  end

  # A structurally-valid graph (CHK-01, REQ-028) guarantees exactly one
  # START node -- defensive, never-raising fallback only, not a literal AC
  # case (design doc §6 step 8). Public/`@doc false` for the same req053
  # design doc §9 OQ-2 reason as advance_until_stable/4 above.
  @doc false
  @spec find_start_node(Graph.t()) ::
          {:ok, Node.t()} | {:error, {:graph_structure_invalid, :no_start_node}}
  def find_start_node(%Graph{nodes: nodes}) do
    case Enum.find(nodes, &(&1.node_type == :START)) do
      nil -> {:error, {:graph_structure_invalid, :no_start_node}}
      start_node -> {:ok, start_node}
    end
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §6 steps 10-11) -- one Ecto.Multi: the
  # instance_projections row, the root tokens row, the INSTANCE_STARTED
  # event, all together or none at all.
  # ---------------------------------------------------------------------

  defp persist(
         instance_id,
         definition,
         initial_variables,
         correlation_key,
         graph,
         new_instance_state,
         prepared_children,
         prepared_timers,
         prepared_service_task_dispatches,
         tenant_id,
         pins,
         conflicts,
         attrs,
         prefix
       ) do
    current_node_ids = Enum.map(new_instance_state.tokens, & &1.node_id)

    try do
      Multi.new()
      |> lock_scope_node(Map.get(attrs, :scope_node_id), prefix)
      |> lock_owner_module(definition, prefix)
      |> Multi.run(:instance_projection, fn repo, _changes ->
        # M1 always inserts :active, even when the landing-node dispatch above
        # already completed the instance (design doc §9 OQ-1a's :END success
        # case): Letflow.EventStore.append/2's own active_instance_guard (its
        # M1, run as part of M3 below) requires the instance_projections row
        # to be non-terminal at INSTANCE_STARTED append time -- the same
        # ordering EventStore.append/2 already enforces for every other
        # event. M4 (:finalize) below flips the row to its true final status
        # immediately after the event append succeeds, still inside this same
        # Multi.
        #
        # Bugfix discovered while implementing ISS-0396 (see
        # lib/letflow/design/iss0396-task-records-multi-sibling-fix.md's own
        # test scenario, §5 -- the first test in the codebase where a ROOT
        # instance's own SUB_PROCESS children complete synchronously enough,
        # within THIS SAME create/2 transaction, to advance the ROOT itself
        # all the way to :completed via a PARALLEL_GATEWAY join): M3 (:event,
        # this root instance's own INSTANCE_STARTED append) used to sit AFTER
        # the `build_sub_process_children_multi/6` merge below, on the
        # (previously untested) assumption that nothing before M3 could ever
        # change this row's status away from the :active this step just wrote.
        # That assumption is false once a synchronously-completing SUB_PROCESS
        # cascade is in the mix: `Letflow.Engine.SubProcess.
        # reconcile_parent_projection/5` (sub_process.ex) writes this SAME
        # row's status directly (not through `EventStore.append/2`, so not
        # gated by its own active_instance_guard) from *inside* that merge,
        # ahead of M3 -- flipping the row to :completed before M3 ever runs.
        # M3 then hits `active_instance_guard`'s own terminal check and fails
        # with `{:instance_terminated, :completed}`, rejecting the ROOT
        # instance's own founding INSTANCE_STARTED event. M3 is moved here,
        # immediately after M1 and before :token_record/the children merge, so
        # it always runs while the row is still the :active this step just
        # inserted -- nothing between M1 and M3 reads `changes[:token_record]`
        # or `changes[:event]`, so this reordering is safe. Flagged for
        # REVIEWER: this is a `persist/8`-wide Multi-step-ordering change,
        # outside iss0396-task-records-multi-sibling-fix.md's own stated
        # file-touch list (§6), and the largest of the three bugs surfaced by
        # that design's own regression test -- worth its own extra scrutiny,
        # and a candidate for being split into its own follow-up issue if
        # REVIEWER judges it too large for this branch.
        insert_instance_projection(
          repo,
          instance_id,
          definition,
          correlation_key,
          :active,
          current_node_ids,
          initial_variables,
          new_instance_state.join_counters,
          new_instance_state.scope_node_id,
          prefix
        )
      end)
      |> Multi.run(:event, fn _repo, _changes ->
        append_instance_started_event(
          instance_id,
          definition,
          correlation_key,
          initial_variables,
          pins,
          conflicts,
          attrs,
          prefix
        )
      end)
      |> Multi.run(:token_record, fn repo, _changes ->
        insert_token_records(repo, instance_id, new_instance_state.tokens, prefix)
      end)
      |> Multi.merge(fn changes ->
        # req062 design doc §3.3 -- appends each prepared sub-process child's
        # own creation steps, keyed off the just-inserted parent :token_record
        # rows (must run after M2 above -- the parent token row referenced by
        # each child's own parent_token_id FK must already exist in this same
        # transaction).
        build_sub_process_children_multi(
          changes,
          instance_id,
          new_instance_state,
          prepared_children,
          attrs,
          prefix
        )
      end)
      |> Multi.merge(fn changes ->
        # REQ-187 design doc §3.2 -- positioned immediately after :token_record
        # (the step that resolves real TokenRecord ids) and before :finalize,
        # matching exactly where build_sub_process_children_multi/5 sits.
        id_map =
          TaskActivation.token_id_to_record_id(
            new_instance_state.tokens,
            Map.fetch!(changes, :token_record)
          )

        build_timer_arms_multi(Multi.new(), prepared_timers, id_map, prefix)
      end)
      |> Multi.merge(fn changes ->
        # REQ-215 design doc §2.1/§2.5 -- positioned alongside the timer-arms
        # merge above (same "resolves real TokenRecord ids" precondition).
        id_map =
          TaskActivation.token_id_to_record_id(
            new_instance_state.tokens,
            Map.fetch!(changes, :token_record)
          )

        build_service_task_dispatch_multi(
          Multi.new(),
          prepared_service_task_dispatches,
          id_map,
          tenant_id,
          prefix
        )
      end)
      |> TaskActivation.append_multi(
        instance_id,
        graph,
        # create/2's own call site always starts from a freshly-constructed
        # InstanceState (pending_task_nodes: []), so every entry in
        # new_instance_state.pending_task_nodes is "newly pending" by
        # construction (req047 design §5.1) -- a future EE-04 caller is
        # expected to pass that instance's own pending_task_nodes value, read
        # at the start of its own call, instead of [].
        [],
        new_instance_state,
        prefix
      )
      |> Multi.run(:finalize, fn repo, %{instance_projection: projection} ->
        finalize_instance_projection(
          repo,
          projection,
          new_instance_state.status,
          prefix,
          instance_id
        )
      end)
      |> Multi.merge(fn changes ->
        record_instance_create_audit(changes, instance_id, attrs, prefix)
      end)
      |> Repo.transaction()
      |> maybe_snapshot_after_create(instance_id, new_instance_state, prefix)
      |> interpret_create_result(
        instance_id,
        definition,
        new_instance_state.status,
        current_node_ids,
        initial_variables,
        Map.get(attrs, :actor_id),
        prefix
      )
      |> resolve_start_race(instance_id, attrs, initial_variables, prefix)
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # REQ-195 -- create/2's own actor_id (attrs[:actor_id], already an
  # explicit, required argument -- Letflow.Routers.Instances.handle_create/1
  # sources it from conn.assigns.auth_context.user_id) is a real, non-nil
  # value, unlike Definitions' lifecycle functions. after_state is the
  # :finalize step's own resulting InstanceProjection row -- reusing that
  # already-fetched struct rather than a second independent read.
  defp record_instance_create_audit(changes, instance_id, attrs, prefix) do
    finalized = Map.fetch!(changes, :finalize)

    Audit.append_multi(
      Multi.new(),
      :audit,
      %{
        actor_id: Map.get(attrs, :actor_id),
        action: "instance.create",
        resource_type: "instance",
        resource_id: instance_id,
        before_state: nil,
        after_state: Audit.struct_state(finalized),
        trace_id: nil
      },
      prefix
    )
  end

  # req062 design doc §3.3 -- resolves each prepared child's own parent
  # TokenRecord.id (from M2's own just-inserted list, positionally zipped
  # against new_instance_state.tokens the same way
  # TaskActivation.token_id_to_record_id/2 already does) and appends
  # SubProcess.append_start_multi/7 for it, one child at a time.
  defp build_sub_process_children_multi(
         changes,
         instance_id,
         new_instance_state,
         prepared_children,
         attrs,
         prefix
       ) do
    token_records = Map.fetch!(changes, :token_record)
    id_map = TaskActivation.token_id_to_record_id(new_instance_state.tokens, token_records)

    Enum.reduce(prepared_children, Multi.new(), fn {token_id, prepared}, acc_multi ->
      parent_token_record_id = Map.fetch!(id_map, token_id)

      SubProcess.append_start_multi(
        acc_multi,
        instance_id,
        parent_token_record_id,
        prepared.node_id,
        prepared,
        %{actor_id: Map.get(attrs, :actor_id), idempotency_key: Map.get(attrs, :idempotency_key)},
        prefix: prefix
      )
    end)
  end

  # REQ-054 (design doc §4.2) -- SnapshotWriter's first named call site:
  # after create/2's own INSTANCE_STARTED event append. Best-effort: a
  # SnapshotWriter failure here must never turn a successfully-committed
  # create/2 call into an error return to the caller (the event log is
  # already durable; the snapshot is a read-side cache over it, per
  # SnapshotWriter's own moduledoc/INV-ISS-2), so any {:error, _} is logged
  # and swallowed, not propagated. Runs after Repo.transaction/1 commits
  # (not folded into the Multi itself) -- instance_state_snapshots is a
  # separate table this Multi has no atomicity obligation toward.
  defp maybe_snapshot_after_create(
         {:ok, %{event: %{sequence_number: sequence_number}}} = result,
         instance_id,
         %InstanceState{} = new_instance_state,
         prefix
       ) do
    snapshot_instance(instance_id, new_instance_state, sequence_number, prefix)
    result
  end

  defp maybe_snapshot_after_create(result, _instance_id, _new_instance_state, _prefix), do: result

  # Shared by every REQ-054 call site below: delegates to
  # SnapshotWriter.maybe_take_snapshot/4, logs and swallows a write failure
  # rather than raising or propagating it into the caller's own result --
  # see maybe_snapshot_after_create/4's comment for why.
  defp snapshot_instance(instance_id, %InstanceState{} = instance_state, sequence_number, prefix) do
    case SnapshotWriter.maybe_take_snapshot(instance_id, instance_state, sequence_number,
           prefix: prefix
         ) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Letflow.Engine.SnapshotWriter.maybe_take_snapshot/4 failed for instance " <>
            "#{instance_id} at sequence_number #{sequence_number}: #{inspect(reason)}"
        )
    end
  end

  # M1 -- insert instance_projections. A uq_instance_correlation collision
  # surfaces as an Ecto.Changeset unique-constraint error, mapped here to
  # :duplicate_correlation_key (AC4); any other changeset failure is passed
  # through raw (create_error()'s Ecto.Changeset.t() catch-all clause).
  #
  # join_counters (ISS-0397 fix, extending the design's own §2.4 write-site
  # fix to this Multi's own M1 insert, not only reconcile_projection/5):
  # create/2's own initial hop-chain (activate/3, still pure/in-memory) can
  # itself run a PARALLEL_GATEWAY split -- the exact shape both this file's
  # own regression tests and the design doc's §5.1/§5.3 fixtures use (split
  # immediately after START) -- leaving new_instance_state.join_counters
  # non-empty at insert time. Persisting it here too (not just on later
  # reconcile_projection/5 calls) closes the same INV-EE48-7 gap for a
  # cohort opened during create/2 itself, which reconcile_projection/5 alone
  # cannot cover since it is never called from create/2's own Multi.
  defp insert_instance_projection(
         repo,
         instance_id,
         definition,
         correlation_key,
         status,
         current_node_ids,
         initial_variables,
         join_counters,
         scope_node_id,
         prefix
       ) do
    attrs = %{
      instance_id: instance_id,
      status: status,
      definition_id: definition.id,
      correlation_key: correlation_key,
      current_nodes: current_node_ids,
      variables: initial_variables,
      join_counters: SnapshotWriter.serialize_join_counters(join_counters),
      scope_node_id: scope_node_id
    }

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, %InstanceProjection{} = projection} ->
        {:ok, projection}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_violation?(changeset, :correlation_key) do
          {:error, :duplicate_correlation_key}
        else
          {:error, changeset}
        end
    end
  end

  # M2 -- insert the root/branch tokens row(s), post-landing-dispatch node_id,
  # branch_id == instance_id for the root branch (req043 §3.2's root-branch
  # convention) or the branch's own id for each PARALLEL_GATEWAY split branch.
  # Must run after M1 (tokens.instance_id's FK target must already exist in
  # the same transaction). An empty token list means the root token already
  # reached :END and was removed by dispatch_end/3 (design doc §9 OQ-1a's
  # :END success case) -- no tokens row at all for this instance, matching
  # the test's own explicit assertion that a same-call :END completion
  # leaves zero rows in `tokens`, not one stranded at "end". A
  # PARALLEL_GATEWAY split can legitimately leave two or more live tokens
  # (one per branch, each parked at its own node) -- inserted here one at a
  # time, in order, so the first failure short-circuits the rest.
  defp insert_token_records(_repo, _instance_id, [], _prefix), do: {:ok, []}

  defp insert_token_records(repo, instance_id, [%Token{} | _] = tokens, prefix) do
    Enum.reduce_while(tokens, {:ok, []}, fn %Token{} = token, {:ok, acc} ->
      case insert_token_record(repo, instance_id, token, prefix) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_token_record(repo, instance_id, %Token{} = token, prefix) do
    attrs = %{
      instance_id: instance_id,
      node_id: token.node_id,
      branch_id: token.branch_id,
      status: :active
    }

    %TokenRecord{}
    |> TokenRecord.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, %TokenRecord{} = record} -> {:ok, record}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:activation_failed, changeset}}
    end
  end

  # M3 -- append the INSTANCE_STARTED event. Must run after M1:
  # EventStore.append/2's own active_instance_guard requires the
  # instance_projections row to already exist. Letflow.EventStore.append/2
  # opens its own Repo.transaction/1 internally, which Ecto runs reentrantly
  # inside this Multi's already-open transaction (same connection, no second
  # real transaction) -- see the design doc §6 step 10 for the full citation.
  #
  # actor_id/idempotency_key are read with Map.get/2, never Map.fetch!/2: a
  # caller omitting either is exactly the kind of externally-reachable input
  # this module must not raise on (INV-8) -- a missing value is passed
  # through unchanged to EventStore.append/2, which already returns the
  # typed :missing_actor_id / :missing_idempotency_key errors for it.
  # REQ-059 (design doc §3) -- pins is embedded as pinned_versions (PIN-02
  # AC3/AC4). pin_conflicts (design doc §7) is embedded, even when [],
  # whenever this instance has a parent (attrs[:parent_instance_id] present)
  # -- omitted entirely, not even as an empty list, when it has none, so a
  # reader can distinguish "root instance" from "child instance with zero
  # conflicts" from the payload shape alone.
  defp append_instance_started_event(
         instance_id,
         definition,
         correlation_key,
         initial_variables,
         pins,
         conflicts,
         attrs,
         prefix
       ) do
    base_payload = %{
      definition_id: definition.id,
      correlation_key: correlation_key,
      initial_variables: initial_variables,
      pinned_versions: pins
    }

    payload_map =
      if Map.has_key?(attrs, :parent_instance_id) do
        Map.put(base_payload, :pin_conflicts, conflicts)
      else
        base_payload
      end
      |> put_scope_node(Map.get(attrs, :scope_node_id))

    payload = Jason.encode!(payload_map)

    event_attrs = %{
      instance_id: instance_id,
      event_type: "INSTANCE_STARTED",
      payload: payload,
      actor_id: Map.get(attrs, :actor_id),
      idempotency_key: Map.get(attrs, :idempotency_key)
    }

    # GH #2577 -- must stay the last expression of the Multi step (see IdempotentReplay).
    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} = replay -> replay
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # REQ-531 -- authoritative scope-node check: the node row is share-locked to commit (the same
  # rank-N lock `ScopedGrants` takes), so a concurrent retire either waits for this start or is seen
  # here. No node, no step.
  defp lock_scope_node(multi, nil, _prefix), do: multi

  defp lock_scope_node(multi, node_id, prefix) do
    Multi.run(multi, :scope_node, fn _repo, _changes ->
      case ScopeNodePaths.lock_active_node_for_share!(node_id, prefix) do
        {:ok, _node} -> {:ok, node_id}
        {:error, _reason} -> {:error, :invalid_scope_node}
      end
    end)
  end

  # REQ-627 -- authoritative uninstall check: a stamped definition share-locks its module row to commit.
  # An uninstall holds it FOR UPDATE, so one of the two waits for the other. Unstamped: no step.
  defp lock_owner_module(multi, %{owner_module: module_id}, prefix) when is_binary(module_id) do
    Multi.run(multi, :owner_module, fn repo, _changes ->
      StartGate.lock_live_for_share(repo, module_id, prefix)
    end)
  end

  defp lock_owner_module(multi, _definition, _prefix), do: multi

  # The key is present only when the instance has a node (REQ-531: "absent or null").
  defp put_scope_node(payload_map, nil), do: payload_map
  defp put_scope_node(payload_map, node_id), do: Map.put(payload_map, :scope_node_id, node_id)

  # M4 -- flips the instance_projections row to its true final status once
  # the INSTANCE_STARTED event (M3) has been appended while the row was
  # still :active (see M1's comment above). A no-op when the landing-node
  # dispatch left the instance :active (the common HUMAN_TASK case) --
  # avoids an unconditional extra UPDATE for the overwhelmingly common path.
  # `completed_at` is set here (not at M1) since this is the one place the
  # row's terminal status actually becomes true, matching
  # `InstanceProjection.terminal?/1`'s own :completed/:cancelled framing.
  defp finalize_instance_projection(
         _repo,
         %InstanceProjection{} = projection,
         :active,
         _prefix,
         _instance_id
       ) do
    {:ok, projection}
  end

  defp finalize_instance_projection(
         repo,
         %InstanceProjection{} = projection,
         :completed,
         prefix,
         instance_id
       ) do
    attrs = %{status: :completed, completed_at: DateTime.utc_now()}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
    |> case do
      {:ok, %InstanceProjection{} = updated} ->
        # req047 design §8 / REQ-187 design doc §5.2 -- the SCH-03
        # timer-cancellation hook, called here (still inside this open
        # transaction) immediately after the instance_projections row's
        # status is confirmed flipped to :completed, so this real DB write
        # participates in this same atomic commit/rollback. Reuses the same
        # `completed_at` this clause already computed above (`attrs`) for
        # `cancelled_at` too -- no second clock read. Call site position
        # deliberately unmoved (AC4).
        {:ok, _count} =
          TaskActivation.cancel_pending_timers(
            repo,
            instance_id,
            attrs.completed_at,
            "instance_completed",
            prefix
          )

        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §6 step 11).
  # ---------------------------------------------------------------------

  defp interpret_create_result(
         {:ok, %{instance_projection: %InstanceProjection{} = projection}},
         instance_id,
         definition,
         status,
         current_node_ids,
         initial_variables,
         _actor_id,
         _prefix
       ) do
    {:ok,
     %{
       instance_id: instance_id,
       definition_id: definition.id,
       status: status,
       current_nodes: current_node_ids,
       variables: initial_variables,
       started_at: projection.started_at
     }}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape create_error() promises (or passes a
  # raw changeset/term() through, matching those catch-all clauses); this
  # just unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  #
  # ISS-0784 -- additionally, when `reason` is the `{:invalid_form_schema,
  # node_id, form_schema_reason}` rejection surfacing from
  # `TaskActivation.append_multi/6`, records a best-effort audit entry in a
  # second, independent transaction, opened only now that `Repo.transaction/1`
  # has already returned this `{:error, ...}` and rolled back (design §3).
  # Any other `reason` shape is byte-identical to before this issue.
  defp interpret_create_result(
         {:error, _failed_step, reason, _changes},
         instance_id,
         _definition,
         _status,
         _current_node_ids,
         _initial_variables,
         actor_id,
         prefix
       ) do
    case reason do
      {:invalid_form_schema, node_id, form_schema_reason} ->
        record_task_activation_rejection_audit(
          instance_id,
          node_id,
          form_schema_reason,
          actor_id,
          prefix
        )

      _other ->
        :ok
    end

    {:error, reason}
  end

  # =========================================================================
  # complete_task/3 (EE-04, REQ-048) -- see
  # lib/letflow/design/req048-task-completion.md for the full design this
  # section implements.
  # =========================================================================

  @type complete_attrs :: %{
          required(:output_variables) => map(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type complete_opts :: [prefix: String.t(), f1: Letflow.Tasks.f1()]

  # `{:error, {:variable_schema_lookup_failed, VariableSchema.error_reason()}}` was
  # removed from this union (GH#310 / ISS-0091): neither member of
  # `VariableSchema.error_reason/0` is reachable on this call path --
  # `:missing_prefix` is foreclosed by the tenant resolution above (before
  # `run_complete_task/6` is even entered), and `:invalid_definition_id` by
  # `InstanceProjection.definition_id`'s column being `NOT NULL` (now reflected in
  # that struct's own `@type t`, see its moduledoc). `merge_output_variables/7`
  # still maps that lookup failure into the same tuple internally -- deliberately
  # not removed, see its own comment -- but a value no caller of this function can
  # ever observe has no business in this *public* @spec, where it would only
  # obligate every exhaustive `case` to handle a clause that can't match. The
  # trailing `{:error, term()}` member already covers it structurally, so nothing
  # about the runtime contract narrows.
  @type complete_error ::
          {:error, :invalid_output_variables}
          | {:error, :invalid_task_id}
          | {:error, :invalid_schema_name}
          | {:error, :task_not_found}
          | {:error, {:task_not_pending, status :: :completed | :cancelled}}
          | {:error, :instance_not_found}
          | {:error, {:instance_not_active, status :: :completed | :cancelled | :error}}
          | {:error, :snapshot_not_found}
          | {:error, {:graph_structure_invalid, term()}}
          | {:error, {:missing_token_record, token_id :: Ecto.UUID.t()}}
          | {:error, {:transition_failed, Transition.transition_error()}}
          | {:error, {:new_token_during_resume_not_supported, token_id :: String.t()}}
          | {:error, {:task_activation_failed, term()}}
          | {:error, {:event_append_failed, term()}}
          # GH #2577 (D-1, D-2): the key is claimed by another request (not a same-task retry).
          | {:error, :idempotency_key_reuse}
          | {:error, :missing_actor_id}
          | {:error, :missing_idempotency_key}
          | {:error,
             {:instance_execution_error, error_type :: ExecutionError.error_type(),
              affected :: ExecutionError.affected()}}
          | {:error,
             {:output_refused, %{missing_keys: [String.t()], rejected_keys: [String.t()]}}}
          | {:error, :separation_of_duties}
          # GH #3409 (F-3): the node's form validation hook refused (the manifest's code and field
          # entries only), or gave no verdict (a closed `Letflow.Scripts.FormValidation` code).
          | {:error,
             {:form_hook_refused,
              %{code: String.t(), fields: [%{field: String.t(), code: String.t()}]}}}
          | {:error, {:form_hook_failed, code :: atom()}}
          # GH #2587 PR B2 (design section 5.4): a declarative entity write refused (a stable
          # code and the declared line index, or `:contention` for a lock/timeout/deadlock
          # or the 10 s guard), failed internally (a step atom only), or the activator is
          # deactivated (the refusal stub, 409).
          | {:error,
             {:entity_write_refused, index :: non_neg_integer() | :contention, code :: atom()}}
          | {:error, {:entity_write_failed, index :: non_neg_integer(), step :: atom()}}
          | {:error, :entity_write_needs_reactivation}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  # REQ-460 (design req459 §2.4): the INTERNAL refusal a completion guard returns
  # from its Multi step as {:error, {:completion_refused, refusal}}. It never leaves
  # this module: interpret_complete_result/3 audits it and maps it to the public
  # {:error, {:output_refused, %{...}}} member of complete_error/0. REQ-463 adds the
  # {:separation_of_duties, blocking_node_ids} member, which maps to the
  # detail-free public {:error, :separation_of_duties}.
  @typep completion_refusal ::
           {:separation_of_duties, blocking_node_ids :: [String.t()]}
           | {:output_refused, missing_keys :: [String.t()], rejected_keys :: [String.t()]}
           | :entity_writes_not_planned

  @typep refusal_context :: %{required: [String.t()], allowed: [String.t()]}

  # GH #3409 (F-3 part B, criterion 8): fixed, not a setting. The sandbox cap is
  # `FormValidation.max_timeout_ms/0` (50 ms), so a busy slot frees within about one script run.
  @form_hook_busy_attempts 3
  @form_hook_busy_backoff_ms 25

  @type complete_result :: %{
          task_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          instance_status: :active | :completed,
          current_nodes: [String.t()],
          variables: map(),
          variable_labels: VariableLabels.labels(),
          completed_at: DateTime.t()
        }

  @doc """
  Completes a `PENDING` `Letflow.Engine.Task` (EE-04): merges
  `attrs[:output_variables]` into the instance's live variables (REQ-049's
  `Letflow.Engine.VariableMerge.merge/3`), evaluates the completed
  `:HUMAN_TASK` node's own outgoing edges via
  `Letflow.Engine.Transition`'s new `{:complete_task, token_id}` dispatch,
  activates any newly-reached `:HUMAN_TASK` node(s)
  (`Letflow.Engine.TaskActivation.append_multi_from_existing_records/6`),
  flips the task row to `COMPLETED`, and appends exactly one
  `TASK_COMPLETED` event (REQ-025) -- all inside one `Ecto.Multi`/
  `Repo.transaction/1`. Row-level `SELECT ... FOR UPDATE` locking on the
  `tasks` row (and, for the same reason `instance_projections` writes need
  it, on the owning `instance_projections` row) serializes two concurrent
  `complete_task/3` calls on the same `task_id`: exactly one commits
  `:completed`, the other observes `{:error, {:task_not_pending,
  :completed}}`.

  `attrs[:output_variables]` must be present and a plain map (`%{}` is
  valid); `nil`, a missing key, or a non-map/struct value are all rejected
  with `{:error, :invalid_output_variables}` before any I/O is attempted.
  `attrs[:actor_id]`/`attrs[:idempotency_key]` are not independently
  pre-validated here -- they are plumbed straight through to
  `Letflow.EventStore.append/2`'s own identical requirement, matching
  `create/2`'s own `append_instance_started_event/6` pattern (design doc
  §10).

  See this module's moduledoc for the S4 (HTTP status mapping, IDN-03
  assignee authorization) scope boundary this function does not implement
  -- the IDN-03 assignee check is implemented as
  `Letflow.Tasks.authorize_completion/3`, called from
  `Letflow.Routers.Tasks.handle_complete/3` *before* this function, per
  ISS-0942 (moduledoc's "`complete_task/3` (EE-04, REQ-048)" section has
  the full update).

  GH #3409 (F-3 part B): when the node's form validation hook finds the script sandbox busy
  (`{:error, {:form_hook_failed, :script_busy}}`), the transaction is rolled back, a fixed 25 ms
  backoff runs outside any transaction, and the whole completion re-runs, at most 3 attempts in
  total; then that error is returned and the task stays pending. No other code retries.
  """
  @spec complete_task(
          task_id :: Ecto.UUID.t(),
          attrs :: complete_attrs(),
          opts :: complete_opts()
        ) :: {:ok, complete_result()} | complete_error()
  def complete_task(task_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id),
         {:ok, output_variables} <- fetch_output_variables(attrs),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      actor_id = Map.get(attrs, :actor_id)
      idempotency_key = Map.get(attrs, :idempotency_key)
      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      run_complete_task(
        task_id,
        output_variables,
        actor_id,
        idempotency_key,
        completed_at,
        prefix,
        Keyword.get(opts, :f1, :off),
        hidden_check(opts)
      )
    end
  end

  # GH #2616 part 2 (decision 0062 R8, R9): the router passes the caller's hidden label set under
  # `:hidden_labels`, and the sentinel refusal runs for it (`nil` hides every labelled key). Other
  # callers (scripts, timers, tests) pass no such option and the check is skipped for them.
  defp hidden_check(opts) do
    case Keyword.fetch(opts, :hidden_labels) do
      {:ok, hidden} -> {:check, hidden}
      :error -> :skip
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §4) -- zero DB writes attempted.
  # ---------------------------------------------------------------------

  # Defensive INV-8 guard, not literally named by the design's own §3/§4
  # text: task_id flows straight into a `where t.id == ^task_id` query
  # (M1, below) -- a malformed, non-UUID-shaped value there raises
  # Ecto.Query.CastError rather than returning a typed error, the same
  # class of bug lib/letflow/event_store.ex's fetch_uuid/3 and
  # lib/letflow/definitions/snapshot_store.ex's cast_uuid/2 already guard
  # against for their own externally-reachable id arguments. Flagged for
  # REVIEWER as a deliberate addition beyond the design's literal text.
  defp cast_task_id(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_task_id}
    end
  end

  defp fetch_output_variables(attrs) do
    case Map.get(attrs, :output_variables) do
      variables when is_map(variables) and not is_struct(variables) -> {:ok, variables}
      _other -> {:error, :invalid_output_variables}
    end
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §8) -- one Ecto.Multi.
  # ---------------------------------------------------------------------

  # GH #3409 (F-3 part B, REQ-605 criterion 8): a busy script sandbox rolls the whole completion
  # back (the failed Multi step releases the tasks and projection locks before this loop sees the
  # result), the backoff runs here with no transaction open, and the whole completion re-runs.
  # At most `@form_hook_busy_attempts` attempts in total; only `:script_busy` retries.
  defp run_complete_task(
         task_id,
         output_variables,
         actor_id,
         idempotency_key,
         completed_at,
         prefix,
         f1,
         hidden_check,
         attempt \\ 1
       ) do
    result =
      attempt_complete_task(
        task_id,
        output_variables,
        actor_id,
        idempotency_key,
        completed_at,
        prefix,
        f1,
        hidden_check
      )

    case result do
      {:error, {:form_hook_failed, :script_busy}} when attempt < @form_hook_busy_attempts ->
        Process.sleep(@form_hook_busy_backoff_ms)

        run_complete_task(
          task_id,
          output_variables,
          actor_id,
          idempotency_key,
          completed_at,
          prefix,
          f1,
          hidden_check,
          attempt + 1
        )

      other ->
        other
    end
  end

  defp attempt_complete_task(
         task_id,
         output_variables,
         actor_id,
         idempotency_key,
         completed_at,
         prefix,
         f1,
         hidden_check
       ) do
    try do
      # GH #2587 PR B2 (design 7.3, P0/P1): the read-only plan phase and `prepare/2` run
      # BEFORE the transaction. `nil` plan = no lines = today's Multi, step for step.
      case plan_entity_writes(task_id, actor_id, prefix) do
        {:ok, plan, hook} ->
          run_complete_task_transaction(
            {plan, hook},
            task_id,
            output_variables,
            actor_id,
            idempotency_key,
            completed_at,
            prefix,
            f1,
            hidden_check
          )

        {:error, _reason} = error ->
          error
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  defp run_complete_task_transaction(
         {plan, hook},
         task_id,
         output_variables,
         actor_id,
         idempotency_key,
         completed_at,
         prefix,
         f1,
         hidden_check
       ) do
    plan
    |> build_complete_task_multi(
      task_id,
      output_variables,
      actor_id,
      idempotency_key,
      completed_at,
      prefix,
      f1,
      hidden_check,
      hook
    )
    |> run_transaction(plan)
    |> fold_sys_into_transition()
    |> maybe_snapshot_after_complete_task(prefix)
    |> emit_task_completed_telemetry(prefix)
    |> interpret_complete_result(actor_id, prefix)
  end

  # Test seam (design B-15), compiled ONLY when `config :letflow, :engine_test_seams` is true
  # (set in `config/test.exs`; absent from every other build). It takes a prefix and runs
  # `prepare/2` through the real plan, so it must not exist in a production build.
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    @doc false
    @spec __complete_task_multi_step_names__(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
            {:ok, [term()]} | {:error, term()}
    def __complete_task_multi_step_names__(task_id, actor_id, prefix),
      do: __complete_task_multi_step_names__(task_id, actor_id, prefix, :skip)

    # `hidden_check` is `:skip` or `{:check, hidden}` (as `hidden_check/1` builds it): with a check
    # the `:redacted_sentinel` step exists, so the position of the hook step after it can be read.
    @doc false
    @spec __complete_task_multi_step_names__(
            Ecto.UUID.t(),
            Ecto.UUID.t(),
            String.t(),
            :skip | {:check, term()}
          ) :: {:ok, [term()]} | {:error, term()}
    def __complete_task_multi_step_names__(task_id, actor_id, prefix, hidden_check) do
      with {:ok, plan, hook} <- plan_entity_writes(task_id, actor_id, prefix) do
        names =
          plan
          |> build_complete_task_multi(
            task_id,
            %{},
            actor_id,
            "step-names-probe",
            DateTime.utc_now(),
            prefix,
            :off,
            hidden_check,
            hook
          )
          |> Multi.to_list()
          |> Enum.map(fn
            {:merge, {:merge, _fun}} -> :__merge__
            {name, _op} -> name
          end)

        {:ok, names}
      end
    end
  end

  # GH #2616 part 2 (decision 0062 R8, R9): a completion may not write the redaction placeholder over a
  # restricted value the caller cannot read; that would destroy the stored value and erase its label.
  # Checked under the instance row lock and before any write (the reevaluation and the merge come
  # after it). The labels are the locked projection's. Refused keys are names only.
  defp maybe_redacted_sentinel_check(multi, :skip, _output_variables), do: multi

  defp maybe_redacted_sentinel_check(multi, {:check, hidden}, output_variables) do
    Multi.run(multi, :redacted_sentinel, fn _repo, %{instance_projection: projection} ->
      case redacted_sentinel_keys(output_variables, projection.variable_labels, hidden) do
        [] -> {:ok, :accepted}
        keys -> {:error, {:redacted_value_submitted, keys}}
      end
    end)
  end

  # GH #3409 (decision 0067 D1/D9, F-3 part A): hook 3, the node's `form_validation` script, runs
  # after the guards and the sentinel check (a refused completion never starts the sandbox) and
  # before the reevaluation and the merge. It only reads; a refusal rolls the transaction back and
  # writes no audit row (F-4). A node without a hook gets no step.
  defp maybe_form_validation_hook(multi, nil, _output_variables, _completed_at, _prefix),
    do: multi

  defp maybe_form_validation_hook(multi, hook, output_variables, completed_at, prefix) do
    Multi.run(multi, :form_validation_hook, fn _repo,
                                               %{
                                                 task: task,
                                                 instance_projection: projection,
                                                 snapshot_and_state: snapshot_and_state
                                               } ->
      run_form_hook(
        hook,
        task,
        projection,
        snapshot_and_state,
        output_variables,
        completed_at,
        prefix
      )
    end)
  end

  defp run_form_hook(%{pin: :unresolved}, _task, _projection, _snap, _vars, _at, _prefix),
    do: {:error, {:completion_refused, {:form_hook_failed, :script_rejected}}}

  defp run_form_hook(
         hook,
         %Task{} = task,
         projection,
         snap,
         output_variables,
         completed_at,
         prefix
       ) do
    {:ok, sha256} = hook.pin

    # Facts come only from the three step results and the submitted output (the SUBMITTED values,
    # not the re-evaluated ones). Restricted values are dropped by `publisher_may_restricted?: false`.
    facts = %{
      variables: output_variables,
      variable_labels: projection.variable_labels,
      instance_id: task.instance_id,
      token_id: task.token_id,
      form: %{
        definition_id: projection.definition_id,
        definition_version: snap.definition_version,
        node_id: task.node_id,
        schema_version_hash:
          :sha256
          |> :crypto.hash(Letflow.Scripts.Hash.canon(task.form_schema || %{}))
          |> Base.encode16(case: :lower)
      },
      task: %{
        id: task.id,
        node_id: task.node_id,
        assignee_kind: task.assignee_type || "none",
        now: completed_at
      }
    }

    pin = %{script_key: hook.key, script_version: hook.version, script_sha256: sha256}

    case Letflow.Scripts.FormValidation.run(prefix, pin, facts, publisher_may_restricted?: false) do
      {:ok, :accepted} ->
        {:ok, :accepted}

      {:ok, {:refused, %{code: _, fields: _} = verdict}} ->
        {:error, {:completion_refused, {:form_hook_refused, verdict}}}

      {:error, code, _stats} ->
        {:error, {:completion_refused, {:form_hook_failed, code}}}
    end
  end

  defp redacted_sentinel_keys(output_variables, labels, hidden) do
    placeholder = Atom.to_string(VariableLabels.representation())

    output_variables
    |> Enum.filter(fn {key, value} ->
      value == placeholder and VariableLabels.hidden?(labels, key, hidden)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp build_complete_task_multi(
         plan,
         task_id,
         output_variables,
         actor_id,
         idempotency_key,
         completed_at,
         prefix,
         f1,
         hidden_check,
         hook
       ) do
    Multi.new()
    |> maybe_entity_write_timeouts(plan)
    |> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
    # REQ-518 PR 2d (design C.4, AC 15): the approver rule F1, re-checked INSIDE the transaction
    # right after the task row lock (a grant revoked since the request began is seen). `f1` is
    # :off unless the tenant is `on`, and then this step does not exist (steps unchanged). A plain
    # read, no lock of its own (Letflow.Tasks.f1_recheck/3), so the lock orders are untouched.
    |> maybe_f1_scope(f1, prefix)
    |> Multi.run(:instance_projection, fn repo, %{task: task} ->
      fetch_and_lock_instance_projection(repo, task.instance_id, prefix)
    end)
    |> Multi.run(:snapshot_and_state, fn repo, %{task: task, instance_projection: projection} ->
      build_snapshot_and_state(repo, task, projection, prefix)
    end)
    # REQ-460 (design req459 §2.2 step 4): caller-error guards, after BOTH row
    # locks and the snapshot read, before any step that can commit. Pure.
    # GH #2587 PR B2 (D-B.3): the fail-closed "node has lines but no plan" check is a
    # pure branch of this same step, evaluated AFTER separation of duties and required
    # outputs (so those refusals are unchanged), receiving the plan through the closure.
    |> Multi.run(:completion_guards, fn repo,
                                        %{
                                          task: task,
                                          snapshot_and_state: %{graph: graph}
                                        } ->
      check_completion_guards(repo, graph, task, output_variables, actor_id, prefix, plan)
    end)
    |> maybe_redacted_sentinel_check(hidden_check, output_variables)
    |> maybe_form_validation_hook(hook, output_variables, completed_at, prefix)
    |> Multi.run(:form_expression_reevaluation, fn _repo,
                                                   %{
                                                     task: task,
                                                     snapshot_and_state: %{
                                                       seed_instance_state: seed_state
                                                     }
                                                   } ->
      # Multi.run/3's own contract: the callback itself must always succeed
      # structurally -- reevaluate/4's domain result (which can itself be an
      # {:error, reevaluation_error()} rejection) is carried INSIDE this
      # {:ok, _} payload and inspected explicitly by the :merge step below,
      # the same discipline merge_output_variables/7's own
      # {:execution_error, _} tagging already uses (design doc §2).
      {:ok,
       FormExpressionReevaluation.reevaluate(
         task.form_schema,
         seed_state.variables,
         seed_state.variable_labels,
         output_variables
       )}
    end)
    |> Multi.run(:merge, fn repo,
                            %{
                              task: task,
                              snapshot_and_state: %{
                                graph: graph,
                                seed_instance_state: seed_state
                              },
                              instance_projection: projection,
                              form_expression_reevaluation: reevaluation_result
                            } ->
      case reevaluation_result do
        {:error, reevaluation_error} ->
          error_args =
            build_reevaluation_execution_error_args(
              reevaluation_error,
              projection,
              actor_id,
              idempotency_key,
              seed_state.variables
            )

          {:ok, {:execution_error, error_args}}

        {:ok,
         %{
           output_variables: corrected_output_variables,
           output_labels: output_labels,
           events: form_events
         }} ->
          projection
          |> merge_output_variables(
            actor_id,
            idempotency_key,
            seed_state.variables,
            corrected_output_variables,
            output_labels,
            repo,
            prefix,
            refusal_context(graph, task)
          )
          |> prepend_form_expression_events(form_events)
      end
    end)
    |> Multi.run(:transition, fn _repo,
                                 %{
                                   snapshot_and_state: snapshot_and_state,
                                   merge: merge_outcome,
                                   instance_projection: projection
                                 } ->
      dispatch_task_completion_hop_chain(
        snapshot_and_state,
        projection,
        actor_id,
        idempotency_key,
        merge_outcome,
        completed_at,
        prefix
      )
    end)
    # GH #2704 (decision 0061, change C-P): the ancestor group of a sub-process child is taken
    # HERE -- right after the pure :transition (which fixes the lock mode) and BEFORE the entity-
    # type rows and every tail write -- so a child takes parent projection, parent token, then
    # entity-type rows, the order a parent's own completion has (P_p then E) and the service
    # apply's. Only the final STATUS matters (the entity-write `_sys` folding does not change
    # it); an execution error takes no group (its landing is a continuing-shaped step with no
    # ancestor lock, see GH #2709).
    |> Multi.run(:lock_ancestors, fn repo, %{task: task, transition: transition} ->
      case transition do
        {:advanced, state, _children, _timers, _dispatches} ->
          lock_parent_group(repo, task.instance_id, lock_intent(state), prefix)

        _execution_error ->
          {:ok, []}
      end
    end)
    # GH #2587 PR B2 (D-B.2): AFTER :transition (which only computes) and before the tail,
    # skipped on either execution error, so a failed completion writes no record.
    |> maybe_entity_writes(plan, actor_id, prefix)
    |> Multi.merge(fn changes ->
      build_complete_task_tail_multi(
        changes,
        actor_id,
        output_variables,
        completed_at,
        idempotency_key,
        plan,
        prefix
      )
    end)
  end

  # ---------------------------------------------------------------------
  # GH #2587 PR B2: process-step entity writes on a HUMAN_TASK completion
  # (design lib/letflow/design/gh2587-req499-pr-b-human-task-writes.md).
  # ---------------------------------------------------------------------

  @typep entity_plan :: %{
           lines: [EntityPort.line()],
           module_writes: [EntityPort.module_write_line()],
           owner: EntityPort.owner_stamp() | nil,
           node_id: String.t(),
           task_id: Ecto.UUID.t(),
           instance_id: Ecto.UUID.t(),
           definition_id: Ecto.UUID.t(),
           definition_version: String.t(),
           activator_id: Ecto.UUID.t(),
           authorized: [{String.t(), String.t()}]
         }

  # Compile-time constants (INV-7): bounds every wait of a completion WITH lines, the tail's
  # included. A completion without a plan issues neither statement.
  @entity_write_set_lock_timeout "SET LOCAL lock_timeout = '2s'"
  @entity_write_set_statement_timeout "SET LOCAL statement_timeout = '5s'"

  @max_entity_write_lines 20

  @contention_error_codes [:lock_not_available, :query_canceled, :deadlock_detected]

  # D-C.9: total wall-clock budget of one apply (HTTP; the script route takes
  # min(this, lease remaining - margin)), the attempt-START gate (a re-apply starts only with at
  # least this much budget left), the pre-guard bound subtracted from the budget the 10 s guard
  # gets (P1 `prepare/2` <= 4 s + the two row-lock waits <= 4 s), the lease margin, the number of
  # attempts and the constant backoffs.
  @service_apply_total_ms 20_000
  @service_attempt_gate_ms 15_000
  @service_pre_guard_bound_ms 8_000
  @service_lease_margin_ms 2_000
  @service_apply_attempts 3
  @service_backoffs_ms [100, 300]

  @service_refusal_codes [
    :write_not_permitted,
    :validation_failed,
    :entity_append_only,
    :entity_type_inactive,
    :entity_write_contention,
    :entity_write_failed,
    :entity_write_needs_reactivation
  ]

  # P0 + P1 (design 7.3). Read-only except `prepare/2`'s own short transaction. Never fails the
  # completion by itself for a read problem (`{:ok, nil}`: the in-transaction steps return
  # today's canonical errors, and the fail-closed guard refuses "lines but no plan").
  #
  # GH #3409 (F-3): the same reads also give the node's form validation hook binding and its
  # script pin (`read_form_hook/3`), independent of whether the node has entity lines. An
  # unreadable task or snapshot gives no hook, which is safe: the transaction re-reads the same
  # rows and answers `task_not_pending` / `snapshot_not_found` before any step runs (a
  # non-pending task never becomes pending again; the snapshot is write-once).
  @spec plan_entity_writes(Ecto.UUID.t(), term(), String.t()) ::
          {:ok, entity_plan() | nil, form_hook() | nil} | {:error, term()}
  defp plan_entity_writes(task_id, actor_id, prefix) do
    with %Task{status: :pending} = task <- Repo.get(Task, task_id, prefix: prefix),
         {:ok, graph, raw_graph} <- fetch_graph_with_raw(task.instance_id, prefix),
         %{attributes: %{} = attributes} <- find_node(graph, task.node_id) do
      hook = read_form_hook(task, attributes, prefix)

      case declared_writes(attributes) do
        {:ok, [], []} ->
          {:ok, nil, hook}

        declared ->
          with {:ok, plan} <- resolve_entity_plan(task, declared, raw_graph, actor_id, prefix),
               do: {:ok, plan, hook}
      end
    else
      _no_lines_or_unreadable -> {:ok, nil, nil}
    end
  end

  @typep form_hook :: %{
           key: String.t(),
           version: pos_integer() | nil,
           pin: {:ok, String.t()} | :unresolved
         }

  # GH #3409 (decision 0067 D1, F-3): a node naming `validation_script_key` has a hook. A key with
  # no usable version, or no matching pin, is still a hook with `pin: :unresolved` (fail closed,
  # never "no hook"). Script pins are never rebound or inherited, so reading them here, before
  # the transaction, is exact and keeps the whole-log read out of the locked section.
  defp read_form_hook(%Task{} = task, attributes, prefix) do
    case Map.get(attributes, "validation_script_key") do
      key when is_binary(key) and key != "" ->
        version = Map.get(attributes, "validation_script_version")
        version = if is_integer(version) and version >= 1, do: version

        %{key: key, version: version, pin: form_hook_pin(task, key, version, prefix)}

      _no_hook ->
        nil
    end
  end

  defp form_hook_pin(_task, _key, nil, _prefix), do: :unresolved

  defp form_hook_pin(%Task{} = task, key, version, prefix) do
    expected_version = Integer.to_string(version)

    with {:ok, pins} <- PinResolver.reconstruct_effective_pins(task.instance_id, prefix: prefix),
         {:ok, %{version: ^expected_version, sha256: sha256}}
         when is_binary(sha256) and byte_size(sha256) == 64 <-
           PinResolver.pin_for(pins, :script, key) do
      {:ok, sha256}
    else
      _missing_or_mismatched -> :unresolved
    end
  end

  # The node's declarative lines and, GH #2590 R4b, its `module_writes` lines, as a tagged result.
  # An `entity_writes` or `module_writes` value that is neither absent, `[]` nor a list (a
  # hand-edited snapshot) is `{:malformed, index}` and refused fail-closed by the plan, never
  # coerced to "no lines" (SECURITY S1: a malformed `entity_writes` must not let the rest of the
  # node run).
  @spec declared_writes(map()) ::
          {:ok, [term()], [term()]} | {:malformed, non_neg_integer()}
  defp declared_writes(attributes) do
    with {:ok, lines} <- list_attribute(Map.get(attributes, "entity_writes"), 0),
         {:ok, module_lines} <-
           list_attribute(Map.get(attributes, "module_writes"), length(lines)) do
      {:ok, lines, module_lines}
    end
  end

  # GH #2688 / REQ-513 D5: is the dispatch's node in the entity-write class, by the SAME predicate
  # the plan uses (`plan_entity_writes/3`: `declared_writes/1 != {:ok, [], []}`, a malformed
  # attribute included). A missing snapshot or node is `:unreadable`: no write without a
  # proven class.
  @doc false
  @spec stuck_entity_write_class?(Ecto.UUID.t(), String.t(), String.t()) ::
          :in_class | :other_class | :unreadable
  def stuck_entity_write_class?(instance_id, node_id, prefix) do
    with {:ok, graph, _raw_graph} <- fetch_graph_with_raw(instance_id, prefix),
         %{} = node <- find_node(graph, node_id) do
      case node do
        %{attributes: %{} = attributes} ->
          if declared_writes(attributes) != {:ok, [], []}, do: :in_class, else: :other_class

        _no_attributes ->
          :other_class
      end
    else
      _unreadable -> :unreadable
    end
  end

  defp list_attribute(none, _index) when none in [nil, []], do: {:ok, []}
  defp list_attribute([_ | _] = lines, _index), do: {:ok, lines}
  defp list_attribute(_malformed, index), do: {:malformed, index}

  defp resolve_entity_plan(%Task{} = task, {:malformed, index}, _raw_graph, actor_id, prefix) do
    record_entity_write_refusal_audit(
      task,
      actor_id,
      index,
      :write_not_permitted,
      :line_malformed,
      prefix
    )

    {:error, {:entity_write_refused, index, :write_not_permitted}}
  end

  defp resolve_entity_plan(
         %Task{} = task,
         {:ok, lines, module_lines},
         raw_graph,
         actor_id,
         prefix
       ) do
    with {:actor, true} <- {:actor, is_binary(actor_id)},
         # I-B6 / 0054 D4: the 20-line cap is enforced AT RUN TIME on the pinned snapshot, so a
         # hand-edited snapshot cannot bypass the activation check. GH #2590 R4b: the cap is on
         # the COMBINED declarative and `module_writes` count.
         {:cap, true} <- {:cap, length(lines) + length(module_lines) <= @max_entity_write_lines},
         %InstanceProjection{definition_id: definition_id} <-
           Repo.get_by(InstanceProjection, [instance_id: task.instance_id], prefix: prefix),
         {:ok, definition} <- Definitions.get_by_id(definition_id, prefix: prefix),
         {:ok, activator_id, authorized} <- recorded_activator(definition, prefix),
         :ok <- check_activator_active(activator_id, prefix),
         # INV-3 (design 6.1 P0b): stamp, install state, hashes, handler and arguments are
         # authorized against the tenant's CURRENT state BEFORE `prepare/2` and every lock.
         owner = owner_stamp(definition),
         :ok <-
           authorize_module_writes(task, module_lines, owner, raw_graph, lines, actor_id, prefix),
         :ok <- check_applied_event_schema(task, module_lines, lines, actor_id, prefix) do
      plan = %{
        lines: lines,
        module_writes: module_lines,
        owner: owner,
        node_id: task.node_id,
        task_id: task.id,
        instance_id: task.instance_id,
        definition_id: definition_id,
        definition_version: definition.version,
        activator_id: activator_id,
        authorized: authorized
      }

      case EntityPort.impl().prepare(lines, prepare_ctx(prefix, module_lines)) do
        :ok ->
          {:ok, plan}

        {:error, :entity_write_contention} ->
          {:error, {:entity_write_refused, :contention, :entity_write_contention}}

        {:error, _prepare_failure} ->
          {:error, {:entity_write_failed, 0, :prepare}}
      end
    else
      {:actor, false} ->
        {:error, :missing_actor_id}

      {:cap, false} ->
        record_entity_write_refusal_audit(
          task,
          actor_id,
          @max_entity_write_lines,
          :validation_failed,
          :too_many_lines,
          prefix
        )

        {:error, {:entity_write_refused, @max_entity_write_lines, :validation_failed}}

      {:error, :entity_write_needs_reactivation} = refusal ->
        refusal

      {:error, {:entity_write_refused, _index, _code}} = refusal ->
        refusal

      _unreadable ->
        {:ok, nil}
    end
  end

  defp prepare_ctx(prefix, []), do: %{prefix: prefix}
  defp prepare_ctx(prefix, module_lines), do: %{prefix: prefix, module_writes: module_lines}

  # The ownership stamp the definition row carries, as opaque strings (the engine names no
  # module). `nil` for an unstamped row: a node with `module_writes` then fails authorization.
  defp owner_stamp(%{
         owner_module: module_id,
         owner_module_version: version,
         owner_manifest_hash: manifest_hash,
         owner_body_hash: body_hash
       })
       when is_binary(module_id) and is_binary(version) and is_binary(manifest_hash) and
              is_binary(body_hash) do
    %{
      module_id: module_id,
      module_version: version,
      manifest_hash: manifest_hash,
      body_hash: body_hash
    }
  end

  defp owner_stamp(_definition), do: nil

  defp authorize_module_writes(_task, [], _owner, _raw_graph, _lines, _actor_id, _prefix), do: :ok

  defp authorize_module_writes(task, module_lines, owner, raw_graph, lines, actor_id, prefix) do
    case EntityPort.impl().authorize_module_writes(module_lines, %{
           prefix: prefix,
           owner: owner,
           snapshot_graph: raw_graph,
           entity_write_count: length(lines)
         }) do
      :ok ->
        :ok

      {:error, {index, detail}} ->
        # One public code for every cause (INV-5); the closed detail goes to the tenant audit.
        record_entity_write_refusal_audit(
          task,
          actor_id,
          index,
          :write_not_permitted,
          detail,
          prefix
        )

        {:error, {:entity_write_refused, index, :write_not_permitted}}
    end
  end

  # Rollout backstop (decision 0054 R4a amendment, design 4.11): a handler line adds keys that
  # only `TASK_ENTITY_WRITES_APPLIED` schema v3 accepts, and a tenant gains v3 only when
  # `TenantProvisioning.replay_all_pending/0` has run for it. Without v3 the APPLIED event would
  # be refused at append INSIDE the transaction; refuse before it, fail closed.
  defp check_applied_event_schema(_task, [], _lines, _actor_id, _prefix), do: :ok

  defp check_applied_event_schema(task, _module_lines, lines, actor_id, prefix) do
    case EventRegistry.max_schema_version(EntityPort.applied_event_type(), prefix) do
      version when is_integer(version) and version >= 3 ->
        :ok

      _outdated ->
        index = length(lines)

        record_entity_write_refusal_audit(
          task,
          actor_id,
          index,
          :write_not_permitted,
          :event_schema_outdated,
          prefix
        )

        {:error, {:entity_write_refused, index, :write_not_permitted}}
    end
  end

  # SEC INFO-1: `activated_by` is UNTRUSTED data at run time (a stored jsonb document). It is
  # re-validated here: the structure (below), then the signature (T-0250, GH #2644:
  # `Letflow.Definitions.ActivatedBy.verify/3`, bound to this row's id, version and graph).
  # Anything unsigned, forged, copied or unverifiable is the re-activation refusal (fail closed).
  # GH #2692 (REQ-515): a definition flagged `needs_reactivation` is refused first, with the
  # same error as a bad document, so both write paths keep their 409 / ERROR + DLQ shapes.
  defp recorded_activator(%{needs_reactivation_at: %DateTime{}}, _prefix),
    do: {:error, :entity_write_needs_reactivation}

  defp recorded_activator(%{activated_by: activated_by} = definition, prefix) do
    with {:ok, uuid, pairs} <- recorded_activator_document(activated_by),
         {:ok, :verified} <- ActivatedBy.verify(activated_by, definition, prefix) do
      {:ok, uuid, pairs}
    else
      _invalid -> {:error, :entity_write_needs_reactivation}
    end
  end

  # `DefinitionsActivate` is NOT assumed (a rollback or promotion may record a different
  # permission set).
  defp recorded_activator_document(%{
         "user_id" => user_id,
         "permissions" => permissions,
         "authorized" => authorized
       })
       when is_binary(user_id) and is_list(permissions) and is_list(authorized) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_id),
         true <- "EntitiesRecordsWrite" in permissions,
         {:ok, pairs} <- authorized_pairs(authorized) do
      {:ok, uuid, pairs}
    else
      _invalid -> {:error, :entity_write_needs_reactivation}
    end
  end

  defp recorded_activator_document(_activated_by),
    do: {:error, :entity_write_needs_reactivation}

  defp authorized_pairs(authorized) do
    Enum.reduce_while(authorized, {:ok, []}, fn
      %{"entity_type" => type, "op" => op}, {:ok, acc} when is_binary(type) and is_binary(op) ->
        {:cont, {:ok, [{type, op} | acc]}}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  # An absent user row is treated as deactivated (fail closed).
  defp check_activator_active(activator_id, prefix) do
    case Identity.get_user(activator_id, prefix: prefix) do
      {:ok, %{status: :active}} -> :ok
      _inactive_or_absent -> {:error, :entity_write_needs_reactivation}
    end
  end

  defp maybe_entity_write_timeouts(multi, nil), do: multi

  defp maybe_entity_write_timeouts(multi, _plan) do
    Multi.run(multi, :entity_write_timeouts, fn repo, _changes ->
      repo.query!(@entity_write_set_lock_timeout)
      repo.query!(@entity_write_set_statement_timeout)
      {:ok, nil}
    end)
  end

  defp maybe_entity_writes(multi, nil, _actor_id, _prefix), do: multi

  defp maybe_entity_writes(multi, plan, actor_id, prefix) do
    ctx = %{
      prefix: prefix,
      origin: {:task, plan.task_id},
      instance_id: plan.instance_id,
      node_id: plan.node_id,
      definition_id: plan.definition_id,
      definition_version: plan.definition_version,
      actor_id: actor_id,
      activator_id: plan.activator_id,
      authorized: plan.authorized,
      variables: &entity_write_variables/1,
      variable_labels: &entity_write_variable_labels/1,
      skip?: &entity_write_skip?/1,
      module_writes: plan.module_writes,
      owner: plan.owner,
      entity_write_count: length(plan.lines)
    }

    EntityPort.impl().multi(multi, plan.lines, ctx)
  end

  defp entity_write_variables(%{merge: {:merged, %{new_variables: variables}}}), do: variables
  defp entity_write_variables(_changes), do: %{}

  # Decision 0062 R5: the labels of the merged variables the lines read.
  defp entity_write_variable_labels(%{merge: {:merged, %{new_labels: labels}}}), do: labels
  defp entity_write_variable_labels(_changes), do: %{}

  # Redundant TODAY (defence in depth): `:transition` passes a merge execution error through
  # (`dispatch_task_completion_hop_chain/7`), so the transition clause below also matches.
  defp entity_write_skip?(%{merge: {:execution_error, _}}), do: true
  defp entity_write_skip?(%{transition: {:execution_error, _}}), do: true
  defp entity_write_skip?(_changes), do: false

  # A completion with a plan maps every contention class (and a connection error); a plan-less
  # completion (GH #2823) maps only a Postgres lock timeout or deadlock to the same result, so
  # `complete_task/3` answers 503 instead of a generic 500. The post-commit stages and any
  # other error stay under the function-level blanket rescue (design 7.6, B-4).
  defp run_transaction(multi, nil) do
    Repo.transaction(multi)
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}} when code in @contention_error_codes ->
          {:error, {:entity_write_refused, :contention, :entity_write_contention}}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp run_transaction(multi, _plan) do
    Repo.transaction(multi)
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}} when code in @contention_error_codes ->
          {:error, {:entity_write_refused, :contention, :entity_write_contention}}

        _other ->
          reraise error, __STACKTRACE__
      end

    _error in DBConnection.ConnectionError ->
      {:error, {:entity_write_refused, :contention, :entity_write_contention}}
  end

  # F-3: the snapshot, the telemetry and the result read the final state from
  # `changes.transition`; the tail folded the same `_sys` values into the projection write.
  # Strict `put_sys/3`, engine-minted ids only. A fold failure cannot occur here (the
  # transaction already validated the same pairs); the state is then left unfolded.
  defp fold_sys_into_transition(
         {:ok,
          %{
            entity_writes: %{sys_values: values},
            transition: {:advanced, %InstanceState{} = state, children, timers, dispatches}
          } = changes}
       )
       when map_size(values) > 0 do
    case fold_sys_values(state, values) do
      {:ok, folded} ->
        {:ok, %{changes | transition: {:advanced, folded, children, timers, dispatches}}}

      {:error, _reason} ->
        {:ok, changes}
    end
  end

  defp fold_sys_into_transition(result), do: result

  defp fold_sys_values(%InstanceState{} = state, values) do
    with {:ok, variables} <- fold_sys_map(state.variables, values) do
      {:ok, %InstanceState{state | variables: variables}}
    end
  end

  defp fold_sys_map(variables, values) do
    values
    |> Enum.sort()
    |> Enum.reduce_while({:ok, variables}, fn {key, value}, {:ok, acc} ->
      case VariableMerge.put_sys(acc, key, value) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Tail additions (design 7.5): per-line audit beside the task audit, then the SYS event
  # (BEFORE TASK_COMPLETED so replay folds the values first), then the APPLIED event. No
  # instance-event `metadata` is set (B3 SEC F3: nothing `_sys`-derived in metadata).
  defp append_entity_write_tail(
         multi,
         %{applied: applied, lines_hash: lines_hash, sys_values: sys_values},
         plan,
         %Task{} = task,
         actor_id,
         idempotency_key,
         prefix
       )
       when is_map(plan) do
    multi
    |> append_entity_write_audits(applied, lines_hash, plan, task, actor_id, prefix)
    |> append_sys_variables_event(sys_values, task, actor_id, idempotency_key, prefix)
    |> append_entity_writes_applied_event(
      applied,
      lines_hash,
      task,
      actor_id,
      idempotency_key,
      prefix
    )
  end

  defp append_entity_write_tail(
         multi,
         _not_applied,
         _plan,
         _task,
         _actor_id,
         _idempotency_key,
         _prefix
       ),
       do: multi

  defp append_entity_write_audits(multi, applied, lines_hash, plan, task, actor_id, prefix) do
    Enum.reduce(applied, multi, fn line, acc ->
      attrs = %{
        actor_id: actor_id,
        action: "entity_write.process_step",
        resource_type: "entity_record",
        resource_id: line.record_id,
        before_state: nil,
        after_state:
          Map.merge(
            %{
              "entity_type" => line.entity_type,
              "record_id" => line.record_id,
              "task_id" => task.id,
              "instance_id" => task.instance_id,
              "node_id" => task.node_id,
              "definition_id" => plan.definition_id,
              "definition_version" => plan.definition_version,
              "line_index" => line.line_index,
              "lines_hash" => lines_hash
            },
            handler_keys(line)
          ),
        trace_id: nil
      }

      Multi.run(acc, audit_step_name(line), fn repo, _changes ->
        Audit.insert_entry(repo, attrs, prefix)
      end)
    end)
  end

  # GH #2590 R4b: a handler write carries the registering module id, the handler name and its
  # per-call ordinal (opaque strings and an integer; the engine names no module). A declarative
  # line has none of the three, so its audit and event bytes are unchanged.
  defp handler_keys(%{write_ordinal: ordinal} = line) when is_integer(ordinal) do
    %{
      "handler_module" => line.handler_module,
      "handler_name" => line.handler_name,
      "write_ordinal" => ordinal
    }
  end

  defp handler_keys(_declarative_line), do: %{}

  # Several writes of one handler call share a declared `line_index`: the ordinal tells them apart.
  defp audit_step_name(%{write_ordinal: ordinal, line_index: index}) when is_integer(ordinal),
    do: {:entity_write_audit, index, ordinal}

  defp audit_step_name(%{line_index: index}), do: {:entity_write_audit, index}

  defp append_sys_variables_event(multi, sys_values, _task, _actor_id, _key, _prefix)
       when map_size(sys_values) == 0,
       do: multi

  defp append_sys_variables_event(multi, sys_values, task, actor_id, idempotency_key, prefix) do
    Multi.run(multi, :sys_variables_event, fn _repo, _changes ->
      # Validation by the strict writer: nothing reaches the event that put_sys/3 refuses.
      with {:ok, _folded} <- fold_sys_map(%{}, sys_values),
           {:ok, result} <-
             EventStore.append(
               %{
                 instance_id: task.instance_id,
                 event_type: VariableMerge.sys_event_type(),
                 payload:
                   Jason.encode!(%{
                     "node_id" => task.node_id,
                     "cause" => "entity_writes",
                     "values" => sys_values
                   }),
                 actor_id: actor_id,
                 idempotency_key: idempotency_key <> "::sys_vars"
               },
               prefix: prefix
             )
             |> IdempotentReplay.fresh() do
        {:ok, result}
      else
        {:error, {:idempotent_replay, _original}} = replay -> replay
        {:error, _reason} -> {:error, {:entity_write_failed, 0, :sys_value}}
      end
    end)
  end

  defp append_entity_writes_applied_event(
         multi,
         applied,
         lines_hash,
         task,
         actor_id,
         idempotency_key,
         prefix
       ) do
    Multi.run(multi, :entity_writes_applied_event, fn _repo, _changes ->
      payload = %{
        "node_id" => task.node_id,
        "task_id" => task.id,
        "dispatch_id" => nil,
        "lines_hash" => lines_hash,
        "lines" =>
          Enum.map(applied, fn line ->
            Map.merge(
              %{
                "line_index" => line.line_index,
                "entity_type" => line.entity_type,
                "record_id" => line.record_id,
                "event_global_seq" => line.event_global_seq
              },
              handler_keys(line)
            )
          end)
      }

      case EventStore.append(
             %{
               instance_id: task.instance_id,
               event_type: EntityPort.applied_event_type(),
               payload: Jason.encode!(payload),
               actor_id: actor_id,
               idempotency_key: idempotency_key <> "::entity_writes"
             },
             prefix: prefix
           )
           |> IdempotentReplay.fresh() do
        {:ok, result} -> {:ok, result}
        {:error, {:idempotent_replay, _original}} = replay -> replay
        {:error, _reason} -> {:error, {:entity_write_failed, 0, :applied_event}}
      end
    end)
  end

  # REQ-194 (design req194-prometheus-metrics.md §7, OBS-02 family 2): fires
  # [:letflow, :task, :completed] AFTER the transaction has already committed (so it
  # can only add microseconds of same-process ETS-counter overhead -- no network
  # call, no GenServer round-trip). Pass-through -- never changes `result`, so
  # interpret_complete_result/1 (called immediately after this in the pipe above)
  # sees exactly what it always saw. Resolves definition_status via a separate,
  # lightweight Definitions.get_by_id/2 call rather than re-deriving it from
  # anything already in scope -- run_complete_task/6's own steps load
  # instance_projection (which carries definition_id) but never the live
  # process_definitions row's current status (design §12 open question 3 leaves the
  # exact resolution path to this call's discretion). Best-effort: any lookup
  # failure (should not happen for an instance whose task was just legitimately
  # completed, but INV-8 says don't assume) simply skips the telemetry emission
  # rather than raising -- this must never turn a real completion into an error.
  # This call references only :telemetry -- never the metrics registry module
  # directly (AC8: a grep for that module's fully-qualified name over this file's
  # real code, excluding this moduledoc, must return zero hits).
  defp emit_task_completed_telemetry(
         {:ok,
          %{
            complete_task_outcome: :completed,
            instance_projection: %InstanceProjection{definition_id: definition_id}
          }} = result,
         prefix
       ) do
    case Definitions.get_by_id(definition_id, prefix: prefix) do
      {:ok, %{status: status}} ->
        :telemetry.execute([:letflow, :task, :completed], %{count: 1}, %{
          definition_status: status
        })

      _lookup_failed ->
        :ok
    end

    result
  end

  defp emit_task_completed_telemetry(result, _prefix), do: result

  # REQ-054 (design doc §4.2) -- SnapshotWriter's second named call site,
  # both branches: the normal-completion path (uses the already-in-hand
  # final_instance_state -- also covers "on instance completion", §4.2's
  # fourth bullet, since final_instance_state.status is whatever this hop
  # chain actually landed on, :active or :completed, no separate call site
  # needed) and the REQ-061 execution-error path (M2's execution_error_event
  # step, reusing snapshot_and_state's seed_instance_state -- accurate here
  # because dispatch_task_completion_hop_chain/5's error branches never
  # mutate any already-persisted token, only the merged variables and the
  # instance's status change). Same best-effort/log-and-swallow contract as
  # maybe_snapshot_after_create/4.
  defp maybe_snapshot_after_complete_task(
         {:ok,
          %{
            complete_task_outcome: :completed,
            task: %Task{instance_id: instance_id},
            event: %{sequence_number: sequence_number},
            transition:
              {:advanced, %InstanceState{} = final_instance_state, _prepared_children,
               _prepared_timers, _prepared_service_task_dispatches}
          }} = result,
         prefix
       ) do
    snapshot_instance(instance_id, final_instance_state, sequence_number, prefix)
    result
  end

  defp maybe_snapshot_after_complete_task(
         {:ok,
          %{
            complete_task_outcome: {:execution_error, error_args},
            task: %Task{instance_id: instance_id},
            execution_error_event: %{sequence_number: sequence_number},
            snapshot_and_state: %{seed_instance_state: %InstanceState{} = seed_instance_state}
          }} = result,
         prefix
       ) do
    error_state = %InstanceState{
      seed_instance_state
      | status: :error,
        variables: error_args.variables,
        variable_labels: Map.get(error_args, :labels, seed_instance_state.variable_labels)
    }

    snapshot_instance(instance_id, error_state, sequence_number, prefix)
    result
  end

  defp maybe_snapshot_after_complete_task(result, _prefix), do: result

  defp maybe_f1_scope(multi, :off, _prefix), do: multi

  defp maybe_f1_scope(multi, {:enforce, %Letflow.Api.Scope.Principal{} = principal}, prefix) do
    Multi.run(multi, :f1_scope, fn _repo, %{task: task} ->
      Letflow.Tasks.f1_recheck(task, principal, prefix)
    end)
  end

  # M1 -- row-lock + fetch the tasks row (design doc §8.1, AC4). Ecto's
  # lock/2 query composition, never a hand-written SQL string (INV-7).
  defp fetch_and_lock_task(repo, task_id, prefix) do
    Task
    |> where([t], t.id == ^task_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :task_not_found}
      %Task{status: :pending} = task -> {:ok, task}
      %Task{status: status} -> {:error, {:task_not_pending, status}}
    end
  end

  # M2 -- row-lock + fetch the owning instance_projections row (design doc
  # §8.1). Defensive: a PENDING task's own instance is expected to already
  # be :active by construction, but this call never assumes it.
  defp fetch_and_lock_instance_projection(repo, instance_id, prefix) do
    InstanceProjection
    |> where([p], p.instance_id == ^instance_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :instance_not_found}
      %InstanceProjection{status: :active} = projection -> {:ok, projection}
      %InstanceProjection{status: status} -> {:error, {:instance_not_active, status}}
    end
  end

  # M3 -- scoped state reconstruction (design doc §6): the narrowest
  # InstanceState.t() sufficient for one dispatch hop-chain seeded from a
  # single completing task, built directly from the already-durable
  # tasks/tokens/instance_projections rows -- not a full REQ-053 event-log
  # replay (design doc §6, MAJOR OQ-2).
  defp build_snapshot_and_state(repo, %Task{} = task, %InstanceProjection{} = projection, prefix) do
    with {:ok, graph, definition_version} <- fetch_graph_and_version(task.instance_id, prefix) do
      active_token_records = load_active_tokens(repo, task.instance_id, prefix)
      active_tokens = Enum.map(active_token_records, &to_pure_token/1)

      with {:ok, own_token} <- find_token_for_task(task, active_tokens) do
        pending_task_tokens = load_pending_task_tokens(repo, task.instance_id, prefix)
        seed_instance_state = build_instance_state(projection, active_tokens, pending_task_tokens)

        {:ok,
         %{
           graph: graph,
           # GH #3409 (F-3): the snapshot row's `definition_ver`, a fact of the form hook (no query).
           definition_version: definition_version,
           seed_instance_state: seed_instance_state,
           # GH #2359: the seed minus the completing token's own {token_id,
           # node_id} entry -- the task being completed is no longer pending
           # once this transaction commits. Used as BOTH the Transition input
           # and the activation diff's `previous` (same value, INV-3b) so a
           # same-node re-entry (A -> gateway -> A) gets a fresh tasks row.
           # `seed_instance_state` stays unstripped for the error-path snapshot.
           post_completion_seed:
             TaskActivation.consume_completed_position(
               seed_instance_state,
               own_token.token_id,
               task.node_id
             ),
           original_active_tokens: active_token_records,
           own_token_id: own_token.token_id
         }}
      end
    end
  end

  # §6.1 -- the same immutable snapshot create/2 captured at instance-start
  # time, never a live re-read of process_definitions.
  defp fetch_graph(instance_id, prefix) do
    with {:ok, graph, _raw} <- fetch_graph_with_raw(instance_id, prefix), do: {:ok, graph}
  end

  # The pinned graph and the snapshot row's definition version (same single read as `fetch_graph/2`).
  defp fetch_graph_and_version(instance_id, prefix) do
    case SnapshotStore.get_by_instance_id(instance_id, prefix: prefix) do
      {:ok, snapshot} ->
        with {:ok, graph} <- build_graph(snapshot.graph),
             do: {:ok, graph, snapshot.definition_ver}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The pinned graph AND the raw snapshot map it was built from (GH #2590 R4b: the stamp's body
  # hash is computed over the raw JSON-normalised form, never over the built struct).
  defp fetch_graph_with_raw(instance_id, prefix) do
    case SnapshotStore.get_by_instance_id(instance_id, prefix: prefix) do
      {:ok, snapshot} ->
        with {:ok, graph} <- build_graph(snapshot.graph), do: {:ok, graph, snapshot.graph}

      {:error, :snapshot_not_found} ->
        {:error, :snapshot_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # §6.2 -- every live token of the instance, not just the completing task's
  # own: dispatch_end/3's "instance becomes :completed iff no token remains
  # live" check needs the instance's full live token set, or a
  # PARALLEL_GATEWAY-split instance's still-running sibling branches would
  # be wrongly invisible to this call.
  defp load_active_tokens(repo, instance_id, prefix) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> repo.all(prefix: prefix)
  end

  # token_id: to_string(record.id) -- the TokenRecord's own DB-generated
  # UUID, stringified, reused directly as this call's Token.t() id (design
  # doc §6.2's own reconstruction invariant, load-bearing for §9's
  # append_multi_from_existing_records/6 and §8.2's reconcile_token_records/5
  # below).
  defp to_pure_token(%TokenRecord{} = record) do
    %Token{
      token_id: to_string(record.id),
      node_id: record.node_id,
      branch_id: record.branch_id,
      waiting_child_instance_id: record.waiting_child_instance_id
    }
  end

  # §6.3 -- a nil result here is a genuine invariant violation (tasks.token_id
  # FK-references tokens.id; a row this call's own :task step just locked and
  # read PENDING from must have a live, :active tokens row), surfaced as a
  # typed error, never a MatchError.
  defp find_token_for_task(%Task{} = task, tokens) do
    case Enum.find(tokens, &(&1.token_id == to_string(task.token_id))) do
      nil -> {:error, {:missing_token_record, task.token_id}}
      token -> {:ok, token}
    end
  end

  # §6.4 -- every currently-PENDING task's token (including the one about to
  # be completed by this call, still PENDING at read time), reduced to a
  # minimal Token.t() carrying token_id and node_id (branch_id left unused at
  # its struct default).
  #
  # node_id is load-bearing here (ISS-0057 fix, docs/issues/ISS-0057.yaml):
  # TaskActivation.newly_pending_tokens/2 now diffs by the {token_id, node_id}
  # pair, not token_id alone -- a token continuing directly from one
  # :HUMAN_TASK to another keeps the same token_id but moves to a new
  # node_id, and the design doc's original §6.4 text (node_id left nil,
  # "unused") made that stale-token_id-only "previous" entry wrongly mask the
  # token's genuinely-new pending position at the next node, so no `tasks`
  # row was ever inserted for it. Populating the task's own real node_id here
  # (the node this PENDING task is actually sitting at) is what lets the pair
  # diff tell "still pending at the same node, already accounted for" apart
  # from "same token, but now pending somewhere new."
  defp load_pending_task_tokens(repo, instance_id, prefix) do
    Task
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> repo.all(prefix: prefix)
    |> Enum.map(&%Token{token_id: to_string(&1.token_id), node_id: &1.node_id, branch_id: nil})
  end

  # §6.5 -- assembling the seed InstanceState.t(). join_counters is read from
  # the same `%InstanceProjection{}` struct fetch_and_lock_instance_projection/3
  # (M2) already locked earlier in this same transaction (ISS-0397 fix,
  # lib/letflow/design/iss0397-join-counters-fix.md §2.5) -- NOT a second,
  # independent, unlocked Repo read, and NOT a read of the periodic
  # `instance_state_snapshots` table (SnapshotWriter.latest_snapshot/2,
  # which is a crash-recovery artifact current only as of up to `interval`
  # events ago -- reading it here would silently reintroduce staleness,
  # exactly what INV-EE48-7 forbids). This closes REQ-048 design doc's own
  # MAJOR OQ-3 / INV-EE48-7 gap: a cross-call PARALLEL_GATEWAY join (split
  # committed by one complete_task/3 call, join reached by a later, separate
  # call) can now durably observe the cohort the split opened.
  defp build_instance_state(
         %InstanceProjection{} = projection,
         active_tokens,
         pending_task_tokens
       ) do
    %InstanceState{
      instance_id: projection.instance_id,
      status: :active,
      tokens: active_tokens,
      variables: projection.variables,
      pending_task_nodes: pending_task_tokens,
      join_counters: SnapshotWriter.deserialize_join_counters(projection.join_counters),
      variable_labels: projection.variable_labels,
      scope_node_id: projection.scope_node_id
    }
  end

  # =========================================================================
  # advance_after_timer_fired/3 (REQ-187, design doc §8) -- the poller's
  # fire path re-entering the engine's own transition/completion machinery
  # to advance a token off the :TIMER node whose timer just fired. Called
  # from Letflow.Scheduler.do_fire/2, still inside fire_timer/2's own
  # already-open Repo.transaction/1 -- this function's own persistence step
  # (§8.4) nests as a real Postgres SAVEPOINT inside it.
  # =========================================================================

  # `@doc false`, matching advance_until_stable/4's and build_graph/1's own
  # existing precedent for a function that is technically public
  # (cross-module callable -- here, from Letflow.Scheduler) but not part of
  # Letflow.Engine's documented client API.
  @doc false
  @spec advance_after_timer_fired(Timer.t(), Ecto.Repo.t(), prefix :: String.t()) ::
          {:ok, :advanced} | {:error, {:instance_not_active, atom()}} | {:error, term()}
  def advance_after_timer_fired(%Timer{} = timer, repo, prefix) do
    with {:ok, projection} <- fetch_and_lock_instance_projection(repo, timer.instance_id, prefix),
         {:ok, snapshot_and_state} <-
           build_snapshot_and_state_for_timer(repo, timer, projection, prefix),
         {:ok, advanced_state, pending_events} <-
           dispatch_timer_fired_hop_chain(snapshot_and_state),
         {:ok, _changes} <-
           persist_timer_fired_advance(
             repo,
             timer,
             projection,
             snapshot_and_state,
             advanced_state,
             pending_events,
             prefix
           ) do
      {:ok, :advanced}
    end
  end

  # design doc §8.2 -- mirrors build_snapshot_and_state/4 exactly, keyed by
  # timer.token_id instead of a task: a direct match against the live
  # token set's own token_id (the live path has the exact persisted id
  # available), not a node_id search (unlike Reconstruction's pure
  # event-log replay, which has no such column to read).
  defp build_snapshot_and_state_for_timer(
         repo,
         %Timer{} = timer,
         %InstanceProjection{} = projection,
         prefix
       ) do
    with {:ok, graph} <- fetch_graph(timer.instance_id, prefix) do
      active_token_records = load_active_tokens(repo, timer.instance_id, prefix)
      active_tokens = Enum.map(active_token_records, &to_pure_token/1)

      with {:ok, own_token} <- find_token_for_timer(timer, active_tokens) do
        pending_task_tokens = load_pending_task_tokens(repo, timer.instance_id, prefix)
        seed_instance_state = build_instance_state(projection, active_tokens, pending_task_tokens)

        {:ok,
         %{
           graph: graph,
           seed_instance_state: seed_instance_state,
           original_active_tokens: active_token_records,
           own_token_id: own_token.token_id
         }}
      end
    end
  end

  # Defensive -- should be unreachable (a TokenRecord is never deleted, only
  # status-flipped, and a "pending" timer's own token is never removed by
  # any code path that leaves the timer "pending"), kept for totality
  # (design doc §8.2).
  defp find_token_for_timer(%Timer{} = timer, tokens) do
    case Enum.find(tokens, &(&1.token_id == timer.token_id)) do
      nil -> {:error, {:unknown_token_id, timer.token_id}}
      token -> {:ok, token}
    end
  end

  # design doc §8.3 -- dispatches the {:timer_fired, token_id} hop directly,
  # then the same advance_until_stable/4/tokens_needing_dispatch/3 worklist
  # loop every other call site already uses, so a :TIMER node whose outgoing
  # edge leads straight into another dispatch-needing node resolves fully in
  # this one call. No Letflow.Engine.ExecutionError wiring is added for this
  # path (out of this requirement's named scope) -- every failure surfaces
  # as {:error, {:transition_failed, reason}}, rolled back the same way any
  # other advance_after_timer_fired/3 failure is.
  defp dispatch_timer_fired_hop_chain(%{
         graph: graph,
         seed_instance_state: %InstanceState{} = seed_state,
         own_token_id: own_token_id
       }) do
    hop_limit = length(graph.nodes) * 4 + 10

    case Transition.transition(graph, seed_state, {:timer_fired, own_token_id}) do
      {:ok, new_instance_state, _pending_events} ->
        newly_pending =
          tokens_needing_dispatch(seed_state.tokens, new_instance_state.tokens, own_token_id)

        case advance_until_stable(graph, new_instance_state, newly_pending, hop_limit - 1) do
          {:ok, advanced_state, pending_events} -> {:ok, advanced_state, pending_events}
          {:error, reason} -> {:error, {:transition_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:transition_failed, reason}}
    end
  end

  # design doc §8.4 -- persists via a small, nested Ecto.Multi (a real
  # Postgres SAVEPOINT, nested inside fire_timer/2's already-open
  # transaction), reusing unmodified the same building blocks the other two
  # call sites use: do_reconcile_token_records/4 (via reconcile_token_records/5),
  # TaskActivation.append_multi_from_existing_records/6,
  # prepare_timer_arms/4 + build_timer_arms_multi/4 (a :TIMER outgoing edge
  # can lead directly into another :TIMER node), prepare_sub_process_children_for_completion/7's
  # own node-lookup/SubProcess.prepare_child_activation/4 step +
  # append_sub_process_children_creation_multi/6, and reconcile_projection/5.
  # No new event is appended here -- TIMER_FIRED (already appended by
  # Scheduler.append_timer_fired_event/4, before this function ever runs)
  # is the one domain event that captures this whole state change. No
  # cancel_pending_timers/5 call is added here either, for the same
  # structural reason as finalize_instance_projection/5's own scope note
  # (§5.2): reaching :completed via a :TIMER node's own outgoing edge
  # requires every other token already gone, so no sibling pending timer
  # can coexist with this completion.
  defp persist_timer_fired_advance(
         repo,
         %Timer{} = timer,
         %InstanceProjection{} = projection,
         %{
           graph: graph,
           seed_instance_state: seed_state,
           original_active_tokens: original_active_tokens
         },
         %InstanceState{} = advanced_state,
         pending_events,
         prefix
       ) do
    actor_id = EventStore.platform_actor_id()
    idempotency_key = "timer_fired:#{timer.id}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           {:ok, prepared_timers} <-
             prepare_timer_arms(pending_events, graph, timer.instance_id, now),
           {:ok, prepared_service_task_dispatches} <-
             prepare_service_task_dispatch_abort_on_empty_url(
               pending_events,
               graph,
               timer.instance_id,
               advanced_state.variables,
               now,
               %{
                 pin_source: {:reconstruct, timer.instance_id, prefix},
                 tenant_id: tenant_id,
                 variable_labels: advanced_state.variable_labels
               }
             ),
           {:ok, sub_process_outcome} <-
             prepare_sub_process_children_for_completion(
               advanced_state,
               original_active_tokens,
               graph,
               pending_events,
               projection,
               actor_id,
               idempotency_key,
               prefix
             ) do
        case sub_process_outcome do
          {:advanced, final_instance_state, prepared_children} ->
            multi =
              Multi.new()
              |> Multi.merge(fn _changes ->
                # ISS-0408 fix (design doc §3.5) -- identical restructuring to
                # build_task_activation_and_reconciliation_multi/4: the insert
                # step and its final_instance_state rewrite must run, inside
                # the transaction, before append_multi_from_existing_records/6
                # or reconcile_token_records/5 see final_instance_state, for
                # the TIMER-path hop chain (a join can fire here too, when the
                # join's last outstanding branch is satisfied by a timer
                # firing rather than a task completing).
                Multi.new()
                |> Multi.run({:hop_chain_token_records, timer.instance_id}, fn repo, _changes ->
                  insert_hop_chain_new_token_records(
                    repo,
                    timer.instance_id,
                    original_active_tokens,
                    final_instance_state.tokens,
                    prefix
                  )
                end)
                |> Multi.merge(fn changes ->
                  {id_map, hop_chain_new_records} =
                    Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                  resolved_final_instance_state = rewrite_token_ids(final_instance_state, id_map)

                  Multi.new()
                  |> TaskActivation.append_multi_from_existing_records(
                    timer.instance_id,
                    graph,
                    seed_state.pending_task_nodes,
                    resolved_final_instance_state,
                    prefix
                  )
                  |> reconcile_token_records(
                    hop_chain_new_records ++ original_active_tokens,
                    resolved_final_instance_state,
                    now,
                    prefix
                  )
                end)
              end)
              |> Multi.merge(fn changes ->
                # ISS-0974 fix: same real-id_map reasoning as the hop-chain
                # merge above -- a same-hop-chain join can mint a token_id not
                # yet persisted. Read the real mapping back out of `changes`
                # rather than assuming identity.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                id_map =
                  Map.new(prepared_timers, fn {token_id, _arm_attrs} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_timer_arms_multi(Multi.new(), prepared_timers, id_map, prefix)
              end)
              |> Multi.merge(fn changes ->
                # REQ-215 design doc §2.1 point 2/§2.5 -- ISS-0974 fix: use the
                # real hop-chain id_map (same as the timer-arms merge above)
                # instead of assuming every token_id in
                # prepared_service_task_dispatches is already persisted.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                id_map =
                  Map.new(prepared_service_task_dispatches, fn %{token_id: token_id} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_service_task_dispatch_multi(
                  Multi.new(),
                  prepared_service_task_dispatches,
                  id_map,
                  tenant_id,
                  prefix
                )
              end)
              |> append_sub_process_children_creation_multi(
                prepared_children,
                timer.instance_id,
                actor_id,
                idempotency_key,
                prefix
              )
              |> Multi.run(:projection, fn inner_repo, _changes ->
                reconcile_projection(inner_repo, projection, final_instance_state, now, prefix)
              end)
              |> append_sub_process_completion_cascade_multi(
                timer.instance_id,
                final_instance_state,
                actor_id,
                idempotency_key,
                prefix
              )

            case repo.transaction(multi) do
              {:ok, changes} ->
                {:ok, changes}

              {:error, _failed_step, reason, _changes} ->
                # ISS-0784 follow-up fix (ISS-0784, root-caused by
                # TEST-DESIGNER against real Postgres): this function's own
                # `repo.transaction(multi)` call above is NOT the outermost
                # transaction boundary on this call path -- it is called from
                # `Letflow.Scheduler.fire_timer/2`'s own already-open
                # `Repo.transaction/1` (a real Postgres SAVEPOINT here, per
                # that function's own moduledoc note), which is still open
                # when this clause runs. Calling
                # `record_task_activation_rejection_audit/5` from here would
                # only ever write into that same still-open outer
                # transaction/connection, not a genuinely independent one --
                # it would be rolled back right along with everything else
                # once `fire_timer/2`'s own `case do {:error, reason} ->
                # Repo.rollback(reason) end` fires. The audit write is
                # therefore issued by `Letflow.Scheduler.attempt_fire/2`
                # instead, strictly after `fire_timer/2`'s own
                # `Repo.transaction/1` has fully returned (see that module).
                # Any `reason` shape here is byte-identical to before ISS-0784.
                {:error, reason}
            end

          {:execution_error, error_args} ->
            # No Letflow.Engine.ExecutionError wiring added for the timer-fire
            # path (design doc §8.3/§8.4 -- out of this requirement's named
            # scope): a SubProcess prepare failure here simply rolls back this
            # whole attempt, same as any other advance_after_timer_fired/3
            # failure.
            {:error, {:execution_error_not_supported_for_timer_fire, error_args}}
        end
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # =========================================================================
  # record_reminder_fired/3 (REQ-494, design §3.2)
  # =========================================================================

  # Called from Letflow.Scheduler.do_fire/2 when timer_type == "reminder",
  # still inside fire_timer/2's already-open Repo.transaction/1. A reminder
  # never advances the instance: it only appends one `task.remind` audit row
  # for the still-pending task at (instance, token, node). No pending task
  # there means the reminder outlived its task (race with completion or
  # escalation) -- `{:ok, :reminder_stale}`, nothing written, and the caller
  # skips the re-arm. Takes no lock of its own: since GH #2707 the caller
  # (Scheduler.fire_timer/2, through lock_for_timer_fire/3) already holds the
  # instance projection before the timer row, and every task status change
  # needs that projection, so this plain read of the pending task is consistent.
  @doc false
  @spec record_reminder_fired(Timer.t(), Ecto.Repo.t(), prefix :: String.t()) ::
          {:ok, :reminded}
          | {:ok, :reminder_stale}
          | {:error, :snapshot_not_found}
          | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}}
          | {:error, {:invalid_reminder_role, node_id :: String.t()}}
          | {:error, term()}
  def record_reminder_fired(%Timer{} = timer, repo, prefix) do
    case pending_reminder_task(timer, repo, prefix) do
      nil ->
        {:ok, :reminder_stale}

      %Task{} = task ->
        with {:ok, graph} <- fetch_graph(timer.instance_id, prefix),
             {:ok, reminder_role} <- reminder_role_for_node(graph, timer.node_id) do
          # `timer` is the pre-fire struct: a non-recurring row has
          # fired_count nil (first and only fire), a recurring one counts up.
          fire_count = if is_nil(timer.fired_count), do: 1, else: timer.fired_count + 1

          case Audit.insert_entry(
                 repo,
                 %{
                   actor_id: EventStore.platform_actor_id(),
                   action: "task.remind",
                   resource_type: "task",
                   resource_id: task.id,
                   before_state: nil,
                   after_state: %{
                     "task_id" => task.id,
                     "node_id" => timer.node_id,
                     "reminder_role" => reminder_role,
                     "fire_count" => fire_count
                   },
                   trace_id: nil
                 },
                 prefix
               ) do
            {:ok, _entry} -> {:ok, :reminded}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # Stale detection by task-row status (no task id on the timer row): every
  # pending reminder for (token, node) belongs to the one pending task there,
  # because a completed/escalated task's reminders are cancelled before a
  # re-entered task is armed (design §4).
  defp pending_reminder_task(%Timer{token_id: nil}, _repo, _prefix), do: nil

  defp pending_reminder_task(%Timer{} = timer, repo, prefix) do
    Task
    |> where(
      [t],
      t.instance_id == ^timer.instance_id and t.token_id == ^timer.token_id and
        t.node_id == ^timer.node_id and t.status == :pending
    )
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(1)
    |> repo.one(prefix: prefix)
  end

  defp reminder_role_for_node(graph, node_id) do
    case Enum.find(graph.nodes, &(&1.id == node_id)) do
      nil ->
        {:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}

      %Graph.Node{attributes: attributes} ->
        case Map.get(attributes || %{}, "reminder_role") do
          role when is_binary(role) ->
            if String.trim(role) == "",
              do: {:error, {:invalid_reminder_role, node_id}},
              else: {:ok, role}

          _ ->
            {:error, {:invalid_reminder_role, node_id}}
        end
    end
  end

  # =========================================================================
  # advance_after_escalation_timer_fired/3 (REQ-396, design doc §4.3)
  # =========================================================================

  # The pending tasks rows of one token: the ONE predicate behind both the escalation fire's
  # pre-`P_x` lock (`lock_for_timer_fire/3`) and its `:original_task_row` step, so the two sets
  # cannot drift apart (GH #2707).
  defp pending_token_tasks_query(token_id) do
    Letflow.Engine.Task
    |> where([t], t.token_id == ^token_id and t.status == :pending)
  end

  @doc false
  # GH #2707 (decision 0061, "Amended (GH #2707, PR-1)"): the lock prelude of `Scheduler.fire_timer/2`,
  # called inside its transaction BEFORE the timer row is locked. Order: (1) escalation timers only,
  # the pending `tasks` rows of the timer's token (the same relative order as `complete_task/3` and
  # `cancel_instance/3`: the task row before `P_x`); (2) `P_x` `FOR UPDATE` with NO status filter, so
  # the scheduler learns the status of a dead instance and can settle its timers; (3) only for an
  # `:active` instance, the parent group, in the mode the fire's pure hop chain decides
  # (`timer_fire_lock_intent/4`, GH #2829: `:completing` when the fire completes the child and so
  # runs the sub-process completion cascade, else `:continuing`; no-op for an instance that is not
  # a waiting child). After this the second UPDATE of a child's projection
  # (`reconcile_projection`) finds its foreign-key locks already held (GH #2708/#2709 mechanism).
  # Writes nothing. `advance_after_*` keep their own `P_x` lock (now a no-op re-lock).
  @spec lock_for_timer_fire(Timer.t(), Ecto.Repo.t() | module(), prefix :: String.t()) ::
          {:ok, InstanceProjection.t()} | {:error, :instance_not_found} | {:error, term()}
  def lock_for_timer_fire(%Timer{} = timer, repo, prefix) do
    if timer.timer_type == TimerTypes.escalation() and not is_nil(timer.token_id) do
      timer.token_id
      |> pending_token_tasks_query()
      |> order_by([t], asc: t.id)
      |> lock("FOR UPDATE")
      |> repo.all(prefix: prefix)
    end

    InstanceProjection
    |> where([p], p.instance_id == ^timer.instance_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil ->
        {:error, :instance_not_found}

      %InstanceProjection{status: :active} = projection ->
        with {:ok, _tokens} <-
               lock_parent_group(
                 repo,
                 timer.instance_id,
                 timer_fire_lock_intent(timer, projection, repo, prefix),
                 prefix
               ) do
          {:ok, projection}
        end

      %InstanceProjection{} = projection ->
        {:ok, projection}
    end
  end

  # GH #2829: the group mode of a timer fire, decided BEFORE the group is locked (decision 0061
  # rule 2) from the same pure hop chain the fire itself runs, under the `P_x` the caller holds
  # (graph, tokens, pending tasks and variables cannot change meanwhile). A fire that completes a
  # child runs the completion cascade, so it needs the ancestor chain `FOR UPDATE`. Not a child, a
  # reminder, a stale escalation or any error -> `:continuing`: the fire then reports the error as
  # it always did, and persists nothing, so no cascade follows. Reads only.
  @spec timer_fire_lock_intent(
          Timer.t(),
          InstanceProjection.t(),
          Ecto.Repo.t() | module(),
          String.t()
        ) :: :completing | :continuing
  defp timer_fire_lock_intent(
         _timer,
         %InstanceProjection{parent_instance_id: nil},
         _repo,
         _prefix
       ),
       do: :continuing

  defp timer_fire_lock_intent(
         %Timer{timer_type: TimerTypes.reminder()},
         _projection,
         _repo,
         _prefix
       ),
       do: :continuing

  defp timer_fire_lock_intent(%Timer{} = timer, projection, repo, prefix) do
    with {:ok, snapshot_and_state} <-
           build_snapshot_and_state_for_timer(repo, timer, projection, prefix),
         {:ok, _snapshot_and_state, %InstanceState{} = advanced_state, _pending_events} <-
           timer_fire_hop_chain(timer, snapshot_and_state) do
      lock_intent(advanced_state)
    else
      _stale_or_error -> :continuing
    end
  end

  # The pure part of a timer fire, shared by the lock prelude and the fire itself so the two
  # cannot drift: `{:ok, snapshot_and_state, advanced_state, pending_events}`, `:stale` (an
  # escalation timer whose token has moved on: the fire is a no-op) or `{:error, _}`.
  defp timer_fire_hop_chain(
         %Timer{timer_type: TimerTypes.escalation()} = timer,
         snapshot_and_state
       ) do
    if escalation_timer_stale?(timer, snapshot_and_state) do
      # ISS-0925: the token is no longer at the node this timer was armed for
      # (its HUMAN_TASK completed and the token moved on). Never act on a
      # different node -- the timer is simply consumed as a no-op.
      :stale
    else
      # GH #2359: the original task is cancelled in this same transaction, so
      # its {token, node} entry must not mask a same-node re-entry. Replace
      # the seed in place (no error-snapshot reader exists on this path).
      snapshot_and_state = %{
        snapshot_and_state
        | seed_instance_state:
            TaskActivation.consume_completed_position(
              snapshot_and_state.seed_instance_state,
              snapshot_and_state.own_token_id,
              timer.node_id
            )
      }

      with {:ok, advanced_state, pending_events} <-
             dispatch_escalation_timer_fired_hop_chain(snapshot_and_state) do
        {:ok, snapshot_and_state, advanced_state, pending_events}
      end
    end
  end

  defp timer_fire_hop_chain(%Timer{}, snapshot_and_state) do
    with {:ok, advanced_state, pending_events} <-
           dispatch_timer_fired_hop_chain(snapshot_and_state) do
      {:ok, snapshot_and_state, advanced_state, pending_events}
    end
  end

  # Called from Letflow.Scheduler.do_fire/2 when timer_type == "escalation",
  # still inside fire_timer/2's already-open Repo.transaction/1. Mirrors
  # advance_after_timer_fired/3 but dispatches {:escalation_timer_fired, ...}
  # (which unconditionally follows the fallback edge) and adds a
  # :cancel_original_task Multi step before :task_activation so the original
  # HUMAN_TASK row is non-actionable before the new task is created.
  @doc false
  @spec advance_after_escalation_timer_fired(Timer.t(), Ecto.Repo.t(), prefix :: String.t()) ::
          {:ok, :advanced} | {:error, {:instance_not_active, atom()}} | {:error, term()}
  def advance_after_escalation_timer_fired(%Timer{} = timer, repo, prefix) do
    with {:ok, projection} <- fetch_and_lock_instance_projection(repo, timer.instance_id, prefix),
         {:ok, snapshot_and_state} <-
           build_snapshot_and_state_for_timer(repo, timer, projection, prefix) do
      case timer_fire_hop_chain(timer, snapshot_and_state) do
        :stale ->
          {:ok, :advanced}

        {:ok, snapshot_and_state, advanced_state, pending_events} ->
          with {:ok, _changes} <-
                 persist_escalation_timer_fired_advance(
                   repo,
                   timer,
                   projection,
                   snapshot_and_state,
                   advanced_state,
                   pending_events,
                   prefix
                 ) do
            {:ok, :advanced}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp escalation_timer_stale?(%Timer{node_id: node_id}, %{
         original_active_tokens: records,
         own_token_id: own_token_id
       }) do
    case Enum.find(records, &(to_string(&1.id) == own_token_id)) do
      %{node_id: current} -> current != node_id
      nil -> false
    end
  end

  # Dispatches {:escalation_timer_fired, token_id} and runs advance_until_stable/4.
  # Mirrors dispatch_timer_fired_hop_chain/1 exactly (same error shape).
  defp dispatch_escalation_timer_fired_hop_chain(%{
         graph: graph,
         seed_instance_state: %InstanceState{} = seed_state,
         own_token_id: own_token_id
       }) do
    hop_limit = length(graph.nodes) * 4 + 10

    case Transition.transition(graph, seed_state, {:escalation_timer_fired, own_token_id}) do
      {:ok, new_instance_state, _pending_events} ->
        newly_pending =
          tokens_needing_dispatch(seed_state.tokens, new_instance_state.tokens, own_token_id)

        case advance_until_stable(graph, new_instance_state, newly_pending, hop_limit - 1) do
          {:ok, advanced_state, pending_events} -> {:ok, advanced_state, pending_events}
          {:error, reason} -> {:error, {:transition_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:transition_failed, reason}}
    end
  end

  # Persists state changes for an escalation timer fire. Mirrors
  # persist_timer_fired_advance/7 but adds :cancel_original_task as the first
  # Multi step (before :task_activation) so audit ordering (AC-3c) is
  # satisfied: the original HUMAN_TASK row's cancelled_at is set before the
  # new task's inserted_at.
  defp persist_escalation_timer_fired_advance(
         repo,
         %Timer{} = timer,
         %InstanceProjection{} = projection,
         %{
           graph: graph,
           seed_instance_state: seed_state,
           original_active_tokens: original_active_tokens
         },
         %InstanceState{} = advanced_state,
         pending_events,
         prefix
       ) do
    actor_id = EventStore.platform_actor_id()
    idempotency_key = "escalation_timer_fired:#{timer.id}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    try do
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           {:ok, prepared_timers} <-
             prepare_timer_arms(pending_events, graph, timer.instance_id, now),
           {:ok, prepared_service_task_dispatches} <-
             prepare_service_task_dispatch_abort_on_empty_url(
               pending_events,
               graph,
               timer.instance_id,
               advanced_state.variables,
               now,
               %{
                 pin_source: {:reconstruct, timer.instance_id, prefix},
                 tenant_id: tenant_id,
                 variable_labels: advanced_state.variable_labels
               }
             ),
           {:ok, sub_process_outcome} <-
             prepare_sub_process_children_for_completion(
               advanced_state,
               original_active_tokens,
               graph,
               pending_events,
               projection,
               actor_id,
               idempotency_key,
               prefix
             ) do
        case sub_process_outcome do
          {:advanced, final_instance_state, prepared_children} ->
            multi =
              Multi.new()
              # ISS-0906: fetch+lock the original HUMAN_TASK row first (mirrors
              # cancel_task_rows/4's fetch_and_lock_open_tasks/3 precedent), so
              # the following :cancel_original_task step can use
              # Task.complete_changeset/2 (changeset-backed Repo.update/2, which
              # bumps updated_at) instead of update_all/3 (which bypassed it).
              |> Multi.run(:original_task_row, fn inner_repo, _changes ->
                timer.token_id
                |> pending_token_tasks_query()
                |> lock("FOR UPDATE")
                |> inner_repo.one(prefix: prefix)
                |> case do
                  nil -> {:ok, :no_pending_task}
                  %Letflow.Engine.Task{} = task -> {:ok, {:found, task}}
                end
              end)
              # AC-3c: cancel the original HUMAN_TASK before creating the new task.
              |> Multi.run(:cancel_original_task, fn inner_repo,
                                                     %{original_task_row: row_result} ->
                case row_result do
                  :no_pending_task ->
                    {:ok, :no_pending_task}

                  {:found, task} ->
                    task
                    |> Letflow.Engine.Task.complete_changeset(%{
                      status: :cancelled,
                      cancelled_at: now
                    })
                    |> inner_repo.update(prefix: prefix)
                    |> case do
                      {:ok, updated} -> {:ok, {:cancelled, task, updated}}
                      {:error, reason} -> {:error, reason}
                    end
                end
              end)
              # REQ-494 design §4.3: cancel the escalated task's pending reminders
              # (incl. re-armed successors) with the task's own cancelled_at. Runs
              # before the arm merge below so a re-entry's fresh reminder
              # survives, and before the audit merge so reminder-row locks are
              # taken before the audit-chain lock (the order a reminder fire uses).
              |> Multi.run(:cancel_reminder_timers, fn inner_repo, _changes ->
                TaskActivation.cancel_pending_reminder_timers(
                  inner_repo,
                  timer.instance_id,
                  timer.token_id,
                  timer.node_id,
                  now,
                  "task_escalated",
                  prefix
                )
              end)
              # ISS-0906: audit the cancellation (task.cancel), mirroring
              # record_task_complete_audit/4 / record_task_assign_audit/2.
              |> Multi.merge(fn %{cancel_original_task: outcome} ->
                case outcome do
                  :no_pending_task ->
                    Multi.new()

                  {:cancelled, before_task, updated_task} ->
                    Audit.append_multi(
                      Multi.new(),
                      :cancel_original_task_audit,
                      %{
                        actor_id: actor_id,
                        action: "task.cancel",
                        resource_type: "task",
                        resource_id: before_task.id,
                        before_state: Task.audit_state(before_task),
                        after_state: Task.audit_state(updated_task),
                        trace_id: nil
                      },
                      prefix
                    )
                end
              end)
              |> Multi.merge(fn _changes ->
                Multi.new()
                |> Multi.run({:hop_chain_token_records, timer.instance_id}, fn repo2, _changes ->
                  insert_hop_chain_new_token_records(
                    repo2,
                    timer.instance_id,
                    original_active_tokens,
                    final_instance_state.tokens,
                    prefix
                  )
                end)
                |> Multi.merge(fn changes ->
                  {id_map, hop_chain_new_records} =
                    Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                  resolved_final_instance_state = rewrite_token_ids(final_instance_state, id_map)

                  Multi.new()
                  |> TaskActivation.append_multi_from_existing_records(
                    timer.instance_id,
                    graph,
                    seed_state.pending_task_nodes,
                    resolved_final_instance_state,
                    prefix
                  )
                  |> reconcile_token_records(
                    hop_chain_new_records ++ original_active_tokens,
                    resolved_final_instance_state,
                    now,
                    prefix
                  )
                end)
              end)
              |> Multi.merge(fn changes ->
                # ISS-0974 fix: use the real hop-chain id_map instead of
                # assuming identity -- a same-hop-chain join can mint a
                # token_id not yet persisted.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                id_map =
                  Map.new(prepared_timers, fn {token_id, _arm_attrs} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_timer_arms_multi(Multi.new(), prepared_timers, id_map, prefix)
              end)
              |> Multi.merge(fn changes ->
                # ISS-0974 fix: same real-id_map reasoning as the timer-arms
                # merge immediately above.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, timer.instance_id})

                id_map =
                  Map.new(prepared_service_task_dispatches, fn %{token_id: token_id} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_service_task_dispatch_multi(
                  Multi.new(),
                  prepared_service_task_dispatches,
                  id_map,
                  tenant_id,
                  prefix
                )
              end)
              |> append_sub_process_children_creation_multi(
                prepared_children,
                timer.instance_id,
                actor_id,
                idempotency_key,
                prefix
              )
              |> Multi.run(:projection, fn inner_repo, _changes ->
                reconcile_projection(inner_repo, projection, final_instance_state, now, prefix)
              end)
              |> append_sub_process_completion_cascade_multi(
                timer.instance_id,
                final_instance_state,
                actor_id,
                idempotency_key,
                prefix
              )

            case repo.transaction(multi) do
              {:ok, changes} ->
                {:ok, changes}

              {:error, _failed_step, reason, _changes} ->
                {:error, reason}
            end

          {:execution_error, error_args} ->
            {:error, {:execution_error_not_supported_for_timer_fire, error_args}}
        end
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # REQ-215 -- a :TIMER -> :SERVICE_TASK outgoing edge's own
  # prepare_service_task_dispatch/5 call, for advance_after_timer_fired/3's
  # own hop chain (design doc §2.1 point 2). Same "no ExecutionError wiring
  # for the timer-fire path" scope boundary persist_timer_fired_advance/7's
  # own {:execution_error, _} clause above already documents -- an
  # :empty_url_error here folds into a typed error that rolls back this
  # whole attempt the same way, rather than routing into
  # Letflow.Engine.set_instance_error/2.
  #
  # ISS-0917 -- a {:catalog_resolution_error, ...} outcome folds into the same
  # kind of typed error (never raised), with the same scope boundary.
  defp prepare_service_task_dispatch_abort_on_empty_url(
         pending_events,
         graph,
         instance_id,
         variables,
         now,
         catalog_ctx
       ) do
    case prepare_service_task_dispatch(
           pending_events,
           graph,
           instance_id,
           variables,
           now,
           catalog_ctx
         ) do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, reason} ->
        {:error, reason}

      {:empty_url_error, node_id, _variables} ->
        {:error, {:service_task_url_rendered_empty_not_supported_for_timer_fire, node_id}}

      {:catalog_resolution_error, node_id, reason, _variables} ->
        {:error, {:service_task_catalog_unresolved_not_supported_for_timer_fire, node_id, reason}}

      # GH 2534 PR 7c-1 (design 4.4): same treatment as the catalog case above.
      {:script_binding_error, node_id, reason, _variables} ->
        {:error, {:script_task_pin_unresolved_not_supported_for_timer_fire, node_id, reason}}

      # GH #2616 part 2: same treatment as the catalog case above (the transaction aborts).
      {:restricted_outbound_error, node_id, keys, _variables} ->
        {:error,
         {:service_task_restricted_variable_outbound_not_supported_for_timer_fire, node_id, keys}}
    end
  end

  # ISS-0929 -- public entry point for Letflow.Engine.SubProcess's completion
  # path, which (unlike complete_task/3) previously discarded the hop chain's
  # pending events, so a TIMER / escalation HUMAN_TASK / SERVICE_TASK reached
  # right after a SUB_PROCESS never got its timers/dispatch rows. Resolves the
  # events eagerly (so a failure can be routed as a typed error by the caller)
  # and appends the resulting Scheduler / ServiceTaskDispatch Multi steps to
  # `multi`. Tenant id is derived from the schema prefix (INV-PD-7), never
  # from caller input.
  #
  # ISS-0975 fix (design doc §2): a PARALLEL_GATEWAY join firing within this
  # same hop chain, reached via Letflow.Engine.SubProcess's own completion
  # re-entry, can mint a token_id that is not yet a real, persisted
  # TokenRecord id at the point this function is called -- the identity
  # id_map this function used to build unconditionally was the 5th instance
  # of the same bug ISS-0974 fixed at 4 sibling call sites. `multi` carries
  # no `changes` map of its own at build time (unlike those 4 sites, this
  # function does not itself run inside an already-open transaction when
  # called), so the real id_map must instead be read back out of the
  # transaction's own accumulated `changes`, at `hop_chain_token_records_key`
  # -- a key some earlier step in the same Multi (the caller's own insert
  # step) is guaranteed to have already populated with a
  # {id_map, [TokenRecord.t()]} pair by the time either Multi.merge/2 callback
  # below actually runs (design doc §2.5). Falls back to identity for every
  # token_id `hop_chain_id_map` doesn't cover -- the common, non-join case
  # (design doc §2.4).
  @doc false
  @spec append_pending_event_arms_multi(
          Multi.t(),
          [Transition.pending_event()],
          Graph.t(),
          instance_id :: Ecto.UUID.t(),
          variables :: map(),
          variable_labels :: map(),
          now :: DateTime.t(),
          prefix :: String.t(),
          hop_chain_token_records_key :: term()
        ) :: {:ok, Multi.t()} | {:error, term()}
  def append_pending_event_arms_multi(
        multi,
        pending_events,
        graph,
        instance_id,
        variables,
        variable_labels,
        now,
        prefix,
        hop_chain_token_records_key
      ) do
    catalog_ctx = %{
      pin_source: {:reconstruct, instance_id, prefix},
      tenant_id: {:schema_prefix, prefix},
      variable_labels: variable_labels
    }

    with {:ok, prepared_timers} <- prepare_timer_arms(pending_events, graph, instance_id, now),
         {:ok, prepared_dispatches} <-
           prepare_service_task_dispatch_abort_on_empty_url(
             pending_events,
             graph,
             instance_id,
             variables,
             now,
             catalog_ctx
           ),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      arms_multi =
        Multi.new()
        |> Multi.merge(fn changes ->
          {hop_chain_id_map, _hop_chain_new_records} =
            Map.fetch!(changes, hop_chain_token_records_key)

          timer_id_map =
            Map.new(prepared_timers, fn {token_id, _attrs} ->
              {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
            end)

          build_timer_arms_multi(Multi.new(), prepared_timers, timer_id_map, prefix)
        end)
        |> Multi.merge(fn changes ->
          {hop_chain_id_map, _hop_chain_new_records} =
            Map.fetch!(changes, hop_chain_token_records_key)

          dispatch_id_map =
            Map.new(prepared_dispatches, fn %{token_id: token_id} ->
              {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
            end)

          build_service_task_dispatch_multi(
            Multi.new(),
            prepared_dispatches,
            dispatch_id_map,
            tenant_id,
            prefix
          )
        end)

      {:ok, Multi.append(multi, arms_multi)}
    end
  end

  # =========================================================================
  # advance_after_service_task_outcome/4 (REQ-215, design doc §3) -- the
  # SERVICE_TASK dispatcher poller's re-entry into the engine's own
  # transition/completion machinery, once a service_task_dispatches row
  # resolves to :advance or :give_up. Called from
  # Letflow.Engine.ServiceTaskDispatcher.poll_and_dispatch/1's own reduce
  # loop, STRICTLY AFTER attempt_dispatch/2's own transaction has already
  # committed and returned its typed dispatch_outcome() -- NOT from inside
  # handle_success/3/handle_give_up/4's own bodies (design doc §3.1's own
  # call-site decision; ServiceTaskDispatcher's own moduledoc "Scope
  # boundary" section forbids it from ever calling Letflow.Engine.* itself).
  #
  # Genuine, named divergence from advance_after_timer_fired/3's own
  # "nests as a real Postgres SAVEPOINT inside the caller's already-open
  # transaction" shape (design doc §3.2): this function opens its OWN
  # Repo.transaction/1, separate from and running strictly after
  # attempt_dispatch/2's own (already-committed) transaction. The dispatch
  # row's own terminal-status write (handle_success/3's "advanced" or
  # handle_give_up/4's "given_up") and this function's own EventStore.append/2
  # (:advance) or set_instance_error/2 call (:give_up) are therefore always
  # two separate commits, never one atomic transaction -- a deliberate,
  # flagged gap (design doc §3.2/§3.3/§7 Open Question 1), the only shape
  # consistent with REQ-214's own scope boundary.
  # =========================================================================

  @doc false
  @spec advance_after_service_task_outcome(
          dispatch_id :: Ecto.UUID.t(),
          outcome :: ServiceTaskDispatcher.dispatch_outcome(),
          repo :: Ecto.Repo.t(),
          prefix :: String.t()
        ) ::
          {:ok, :advanced}
          | {:ok, :error_set}
          | {:ok, :already_final}
          | {:error, {:instance_not_active, atom()}}
          | {:error, {:execution_error_contention, :lock_not_available | :deadlock_detected}}
          | {:error, term()}
  def advance_after_service_task_outcome(dispatch_id, {:advance, decoded_body}, repo, prefix) do
    # GH #2587 PR C2: a SERVICE_TASK node that declares `entity_writes` composes them into this
    # apply (section "SERVICE_TASK entity writes" below). A node without lines runs exactly the
    # code it always did.
    route = {:http, dispatch_id, decoded_body, repo}

    drive_service_apply(
      route,
      prefix,
      service_monotonic_ms() + @service_apply_total_ms,
      1,
      plan_service_entity_writes({:http, dispatch_id}, prefix)
    )
  end

  def advance_after_service_task_outcome(
        dispatch_id,
        {:give_up, standalone_error_attrs},
        _repo,
        prefix
      ) do
    give_up_service_task_dispatch(dispatch_id, standalone_error_attrs, prefix)
  end

  # design doc §3.2 step 1 -- re-locks the dispatch row by dispatch_id (a
  # second lock-acquire on the same row is required regardless, since
  # attempt_dispatch/2's own transaction, and its FOR UPDATE lock, has
  # already closed by the time this function runs). A nil row, or one whose
  # status is no longer "advanced" (this exact re-entry already ran once --
  # a redelivery/retry-at-this-layer case), short-circuits to
  # {:ok, :already_final}.
  defp advance_service_task_dispatch(dispatch_id, decoded_body, repo, prefix, plan) do
    completion_key = "service_task_dispatch:#{dispatch_id}"

    with {:ok, %ServiceTaskDispatch{status: :advanced} = dispatch} <-
           fetch_and_lock_service_task_dispatch(dispatch_id, repo, prefix),
         {:ok, projection} <-
           lock_projection_for_service_apply(repo, dispatch, completion_key, plan, prefix),
         # GH #2587 PR C2 (D-C.10, S3): the duplicate-apply read comes BEFORE the graph and token
         # reads (a committed first apply moved the token and may have ended the instance).
         :ok <- service_duplicate_gate(repo, completion_key, plan, prefix),
         {:ok, graph} <- fetch_graph(dispatch.instance_id, prefix) do
      active_token_records = load_active_tokens(repo, dispatch.instance_id, prefix)
      active_tokens = Enum.map(active_token_records, &to_pure_token/1)

      with {:ok, own_token} <- find_token_for_service_task(dispatch, active_tokens),
           :ok <- check_service_lines_planned(graph, dispatch.node_id, plan) do
        pending_task_tokens = load_pending_task_tokens(repo, dispatch.instance_id, prefix)
        seed_state = build_instance_state(projection, active_tokens, pending_task_tokens)

        case VariableMerge.merge(
               seed_state.variables,
               seed_state.variable_labels,
               decoded_body,
               %{},
               nil
             ) do
          {:ok, merged_variables, merged_labels, _merge_events} ->
            state_with_merged_variables =
              VariableLabels.put_merged(seed_state, merged_variables, merged_labels)

            persist_service_task_advance(
              repo,
              dispatch_ref(dispatch),
              projection,
              graph,
              seed_state,
              state_with_merged_variables,
              active_token_records,
              own_token,
              http_completion(dispatch, decoded_body) |> put_service_entity_plan(plan),
              prefix
            )

          # GH #2587 (SECURITY F2): a tenant endpoint answering a reserved `_sys` key
          # would otherwise roll back with the dispatch row left "advanced" -- a
          # silent stall. It is a terminal, value-free instance ERROR instead, the
          # way an explicit sub-process mapping onto the namespace is.
          {:rejected, unchanged_variables,
           [{:execution_error, key, _value, :reserved_variable_key, _failures}]} ->
            persist_service_task_reserved_key_error(
              repo,
              projection,
              unchanged_variables,
              key,
              "service_task_dispatch:#{dispatch.id}",
              prefix
            )

          {:rejected, _unchanged_variables, _events} = rejection ->
            {:error, {:variable_merge_rejected, rejection}}
        end
      end
    else
      {:ok, %ServiceTaskDispatch{}} -> {:ok, :already_final}
      nil -> {:ok, :already_final}
      :duplicate -> {:ok, :already_final}
      {:error, reason} -> {:error, reason}
    end
  end

  # mirrors ServiceTaskDispatcher.fetch_and_lock_dispatch/2's own FOR UPDATE
  # shape, callable from this module.
  defp fetch_and_lock_service_task_dispatch(dispatch_id, repo, prefix) do
    ServiceTaskDispatch
    |> where([d], d.id == ^dispatch_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> nil
      %ServiceTaskDispatch{} = dispatch -> {:ok, dispatch}
    end
  end

  # GH 2534 PR 7c-1 (design 5.4, CDV C1): the shared advance pipeline below takes a
  # `dispatch_ref` and a `completion` descriptor instead of `%ServiceTaskDispatch{}` and the
  # decoded body. The HTTP call site passes exactly today's values (`http_completion/2`); the
  # script call site (`apply_script_task_result/3`) passes its own event, idempotency key and
  # the two extra Multi steps (run record + row terminal status) in the SAME transaction.
  @typep dispatch_ref :: %{
           id: Ecto.UUID.t(),
           instance_id: Ecto.UUID.t(),
           node_id: String.t(),
           token_id: Ecto.UUID.t()
         }
  @typep completion :: %{
           required(:event_type) => String.t(),
           required(:event_payload) => map(),
           required(:idempotency_key) => String.t(),
           required(:on_advanced) => (Multi.t() -> Multi.t()),
           required(:on_no_matching_edge) => (Multi.t() -> Multi.t()),
           optional(:incident_variables) => map(),
           optional(:incident_labels) => map()
         }

  @spec dispatch_ref(map()) :: dispatch_ref()
  defp dispatch_ref(dispatch) do
    %{
      id: dispatch.id,
      instance_id: dispatch.instance_id,
      node_id: dispatch.node_id,
      token_id: dispatch.token_id
    }
  end

  # The HTTP contract, byte-unchanged: SERVICE_TASK_COMPLETED with
  # `%{dispatch_id, node_id, decoded_body}`, idempotency key "service_task_dispatch:<id>", no
  # extra Multi steps.
  @spec http_completion(ServiceTaskDispatch.t(), map()) :: completion()
  defp http_completion(%ServiceTaskDispatch{} = dispatch, decoded_body) do
    %{
      event_type: "SERVICE_TASK_COMPLETED",
      event_payload: %{
        dispatch_id: dispatch.id,
        node_id: dispatch.node_id,
        decoded_body: decoded_body
      },
      idempotency_key: "service_task_dispatch:#{dispatch.id}",
      on_advanced: &Function.identity/1,
      on_no_matching_edge: &Function.identity/1
    }
  end

  @doc false
  # AC21 regression guard: the HTTP completion's event type, payload keys and idempotency key
  # (pure; exposed only for the pin test).
  @spec http_completion_shape(ServiceTaskDispatch.t(), map()) ::
          {String.t(), [atom()], String.t()}
  def http_completion_shape(%ServiceTaskDispatch{} = dispatch, decoded_body) do
    completion = http_completion(dispatch, decoded_body)

    {completion.event_type, completion.event_payload |> Map.keys() |> Enum.sort(),
     completion.idempotency_key}
  end

  # Mirrors find_token_for_timer/2's own defensive shape -- should be
  # unreachable given the same TokenRecord-never-deleted invariant.
  defp find_token_for_service_task(%{token_id: token_id}, tokens) do
    case Enum.find(tokens, &(&1.token_id == to_string(token_id))) do
      nil -> {:error, {:unknown_token_id, token_id}}
      token -> {:ok, token}
    end
  end

  # design doc §3.2 step 4-5 -- dispatches Transition.advance_off_completed_node/4
  # directly (the widened, @doc false, now-public function, §1.5's decision),
  # clears own_token off pending_service_task_nodes (mirroring
  # dispatch_sub_process_completion/4's own cleared_token step), then feeds
  # the result into advance_until_stable/4 exactly as every other hop chain
  # does, and persists via a Multi mirroring persist_timer_fired_advance/7's
  # own shape. Does NOT re-update the dispatch row's own status (already
  # "advanced", written by ServiceTaskDispatcher.handle_success/3 before this
  # function was ever called) -- instead appends a SERVICE_TASK_COMPLETED
  # domain event carrying the VariableMerge.merge/3 output.
  defp persist_service_task_advance(
         repo,
         dispatch,
         %InstanceProjection{} = projection,
         graph,
         seed_state,
         %InstanceState{} = state_with_merged_variables,
         original_active_tokens,
         own_token,
         completion,
         prefix
       ) do
    outgoing_edges = Enum.filter(graph.edges, &(&1.source == own_token.node_id))

    cleared_pending =
      Enum.reject(
        state_with_merged_variables.pending_service_task_nodes,
        &(&1.token_id == own_token.token_id)
      )

    state_ready_to_advance = %InstanceState{
      state_with_merged_variables
      | pending_service_task_nodes: cleared_pending
    }

    hop_limit = length(graph.nodes) * 4 + 10

    case Transition.advance_off_completed_node(
           graph,
           state_ready_to_advance,
           own_token,
           outgoing_edges
         ) do
      {:ok, new_instance_state, pending_events} ->
        newly_pending =
          tokens_needing_dispatch(
            state_ready_to_advance.tokens,
            new_instance_state.tokens,
            own_token.token_id
          )

        case advance_until_stable(graph, new_instance_state, newly_pending, hop_limit - 1) do
          {:ok, advanced_state, pending_events2} ->
            do_persist_service_task_advance(
              repo,
              dispatch,
              projection,
              graph,
              seed_state,
              original_active_tokens,
              advanced_state,
              pending_events ++ pending_events2,
              completion,
              prefix
            )

          {:error, {:activation_failed, {:no_matching_edge, node_id, evaluated_conditions}}} ->
            persist_service_task_no_matching_edge(
              repo,
              projection,
              state_with_merged_variables,
              node_id,
              evaluated_conditions,
              completion,
              prefix
            )

          {:error, reason} ->
            {:error, {:transition_failed, reason}}
        end

      {:error, {:no_matching_edge, node_id, evaluated_conditions}} ->
        persist_service_task_no_matching_edge(
          repo,
          projection,
          state_with_merged_variables,
          node_id,
          evaluated_conditions,
          completion,
          prefix
        )

        # No generic `{:error, reason}` arm here: `Transition.advance_off_completed_node/4`
        # only ever returns `{:error, {:no_matching_edge, _, _}}` (the type checker
        # rejects a catch-all as unreachable).
    end
  end

  # ISS-0928 -- the hop chain that follows a completed SERVICE_TASK reached an
  # EXCLUSIVE_GATEWAY with no matching condition and no default edge. The
  # dispatch row was already committed "advanced" by
  # `ServiceTaskDispatcher.handle_success/3` in an earlier transaction, so
  # rolling back here (the old bare `{:transition_failed, _}`) left the
  # instance ACTIVE forever with no event/DLQ row. Mirror the human-task
  # path (`dispatch_task_completion_hop_chain/7`): write the ExecutionError
  # records inside the ALREADY-OPEN outer transaction (the projection is
  # already FOR UPDATE-locked) and let it COMMIT. Writes: EXECUTION_ERROR
  # event + DLQ row + projection -> :error. Deliberately NOT written: no
  # SERVICE_TASK_COMPLETED, no token/task/timer/dispatch changes, no variable
  # merge persistence; the dispatch row stays "advanced" (never re-armed, so
  # at-most-once HTTP dispatch is preserved). No snapshot (log replay is
  # authoritative).
  #
  # GH 2534 PR 7c-1: the idempotency key comes from the completion descriptor (HTTP:
  # "service_task_dispatch:<id>", unchanged), and `on_no_matching_edge` appends the script
  # route's run record and terminal row status AFTER the ExecutionError steps, in the same
  # transaction (identity for HTTP).
  defp persist_service_task_no_matching_edge(
         repo,
         %InstanceProjection{} = projection,
         %InstanceState{} = state_with_merged_variables,
         node_id,
         evaluated_conditions,
         completion,
         prefix
       ) do
    error_args =
      build_no_matching_gateway_edge_error_args(
        projection.instance_id,
        node_id,
        evaluated_conditions,
        Map.get(completion, :incident_variables, state_with_merged_variables.variables),
        EventStore.platform_actor_id(),
        completion.idempotency_key
      )
      # The labels belong to the variables recorded above (decision 0062 R7a).
      |> Map.put(
        :labels,
        Map.get(completion, :incident_labels, state_with_merged_variables.variable_labels)
      )

    multi =
      Multi.new()
      |> ExecutionError.append_multi(error_args, prefix: prefix, locked_projection: projection)
      |> completion.on_no_matching_edge.()

    case repo.transaction(multi) do
      {:ok, _changes} -> {:ok, :error_set}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # GH #2587 (SECURITY F2): the HTTP SERVICE_TASK body carried a reserved `_sys` key.
  # Mirrors persist_service_task_no_matching_edge/7: ExecutionError records inside the
  # already-open outer transaction (projection already locked), committed; no merge, no
  # SERVICE_TASK_COMPLETED, the dispatch row stays "advanced" (at-most-once). The value is
  # never carried (details %{}).
  defp persist_service_task_reserved_key_error(
         repo,
         %InstanceProjection{} = projection,
         unchanged_variables,
         key,
         idempotency_key,
         prefix
       ) do
    error_args = %{
      instance_id: projection.instance_id,
      error_type: :reserved_variable_key,
      affected: {:field, key},
      reason: "variable '#{key}' is reserved",
      variables: unchanged_variables,
      details: %{},
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: idempotency_key
    }

    multi =
      ExecutionError.append_multi(Multi.new(), error_args,
        prefix: prefix,
        locked_projection: projection
      )

    case repo.transaction(multi) do
      {:ok, _changes} -> {:ok, :error_set}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Shared by the human-task completion path and the SERVICE_TASK re-entry
  # path so the ExecutionError shape for `:no_matching_gateway_edge` cannot
  # drift between them.
  @spec build_no_matching_gateway_edge_error_args(
          Ecto.UUID.t(),
          String.t(),
          term(),
          map(),
          Ecto.UUID.t() | nil,
          String.t()
        ) :: ExecutionError.error_args()
  defp build_no_matching_gateway_edge_error_args(
         instance_id,
         node_id,
         evaluated_conditions,
         variables,
         actor_id,
         idempotency_key
       ) do
    %{
      instance_id: instance_id,
      error_type: :no_matching_gateway_edge,
      affected: {:node, node_id},
      reason:
        "no outgoing edge matched conditions and no default edge configured for gateway node '#{node_id}'",
      variables: variables,
      details: %{evaluated_conditions: evaluated_conditions},
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }
  end

  defp do_persist_service_task_advance(
         repo,
         dispatch,
         %InstanceProjection{} = projection,
         graph,
         seed_state,
         original_active_tokens,
         %InstanceState{} = advanced_state,
         pending_events,
         completion,
         prefix
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    idempotency_key = completion.idempotency_key

    try do
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           {:ok, prepared_timers} <-
             prepare_timer_arms(pending_events, graph, dispatch.instance_id, now),
           {:ok, prepared_service_task_dispatches} <-
             prepare_service_task_dispatch_abort_on_empty_url(
               pending_events,
               graph,
               dispatch.instance_id,
               advanced_state.variables,
               now,
               %{
                 pin_source: {:reconstruct, dispatch.instance_id, prefix},
                 tenant_id: tenant_id,
                 variable_labels: advanced_state.variable_labels
               }
             ),
           {:ok, sub_process_outcome} <-
             prepare_sub_process_children_for_completion(
               advanced_state,
               original_active_tokens,
               graph,
               pending_events,
               projection,
               EventStore.platform_actor_id(),
               idempotency_key,
               prefix
             ) do
        case sub_process_outcome do
          {:advanced, final_instance_state, prepared_children} ->
            multi =
              Multi.new()
              # GH #2695: the parent group FIRST, before any write that UPDATEs this child's
              # projection row (every event append does, entity-write events included), see
              # lock_parent_group/4. Child -> parent order is kept (dispatch row and child
              # projection are already held); the parent group precedes the entity-type locks
              # of this apply, which is the parent completion's own P-then-E order.
              |> Multi.run(:lock_ancestors, fn inner_repo, _changes ->
                lock_parent_group(
                  inner_repo,
                  dispatch.instance_id,
                  lock_intent(final_instance_state),
                  prefix
                )
              end)
              # GH #2704 (decision 0061, change C-E): the entity-type rows next, BEFORE the token
              # inserts and the task activation (whose `task.create` audit takes the audit chain
              # row), so the order is the same as a HUMAN completion's: group, type rows, audit
              # row. Lock-only steps through the entity port; no write moves.
              |> maybe_service_pre_lock(completion, prefix)
              |> Multi.merge(fn _changes ->
                Multi.new()
                |> Multi.run({:hop_chain_token_records, dispatch.instance_id}, fn repo,
                                                                                  _changes ->
                  insert_hop_chain_new_token_records(
                    repo,
                    dispatch.instance_id,
                    original_active_tokens,
                    final_instance_state.tokens,
                    prefix
                  )
                end)
                |> Multi.merge(fn changes ->
                  {id_map, hop_chain_new_records} =
                    Map.fetch!(changes, {:hop_chain_token_records, dispatch.instance_id})

                  resolved_final_instance_state = rewrite_token_ids(final_instance_state, id_map)

                  Multi.new()
                  |> TaskActivation.append_multi_from_existing_records(
                    dispatch.instance_id,
                    graph,
                    seed_state.pending_task_nodes,
                    resolved_final_instance_state,
                    prefix
                  )
                  |> reconcile_token_records(
                    hop_chain_new_records ++ original_active_tokens,
                    resolved_final_instance_state,
                    now,
                    prefix
                  )
                end)
              end)
              |> Multi.merge(fn changes ->
                # ISS-0974 fix: use the real hop-chain id_map instead of
                # assuming identity -- a same-hop-chain join can mint a
                # token_id not yet persisted.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, dispatch.instance_id})

                id_map =
                  Map.new(prepared_timers, fn {token_id, _arm_attrs} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_timer_arms_multi(Multi.new(), prepared_timers, id_map, prefix)
              end)
              |> Multi.merge(fn changes ->
                # ISS-0974 fix: same real-id_map reasoning as the timer-arms
                # merge immediately above.
                {hop_chain_id_map, _hop_chain_new_records} =
                  Map.fetch!(changes, {:hop_chain_token_records, dispatch.instance_id})

                id_map =
                  Map.new(prepared_service_task_dispatches, fn %{token_id: token_id} ->
                    {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
                  end)

                build_service_task_dispatch_multi(
                  Multi.new(),
                  prepared_service_task_dispatches,
                  id_map,
                  tenant_id,
                  prefix
                )
              end)
              |> append_sub_process_children_creation_multi(
                prepared_children,
                dispatch.instance_id,
                EventStore.platform_actor_id(),
                idempotency_key,
                prefix
              )
              # GH #2587 PR C2 (D-C.11): the declared entity writes, then the SYS and APPLIED
              # events, BEFORE the completed event (replay folds the `_sys` values first). A
              # completion without `:entity_plan` adds no step at all.
              |> maybe_service_entity_writes(completion, advanced_state, dispatch, prefix)
              |> Multi.run(:service_task_completed_event, fn _repo, _changes ->
                append_service_task_completed_event(dispatch, completion, prefix)
              end)
              # GH 2534 PR 7c-1: the script route's run record and terminal row status, before
              # :projection (the event appends need the instance still non-terminal). Identity
              # for HTTP.
              |> completion.on_advanced.()
              |> Multi.run(:projection, fn inner_repo, changes ->
                case fold_service_sys_into_state(final_instance_state, changes) do
                  {:ok, state} ->
                    reconcile_projection(inner_repo, projection, state, now, prefix)

                  {:error, _reason} ->
                    {:error, {:entity_write_failed, 0, :sys_value}}
                end
              end)
              # GH #2648: when this apply completes the instance and it is a sub-process CHILD,
              # cascade the parent's completion steps into this SAME transaction (the helper the
              # HUMAN_TASK tail uses; a failure rolls the whole apply back). Lock order: this
              # apply has already locked the dispatch row and the child projection (and any
              # entity-type locks of its writes); the cascade then locks the parent projection,
              # then the parent token (GH #2695; same parent-side order as cancel_instance/3),
              # so child -> parent (the group is already held since :lock_ancestors, GH #2704;
              # see the Engine moduledoc's lock-order section). A 40P01 on this apply is
              # classified as contention and re-applied for HTTP (planned or not) and planned
              # script applies; an UNPLANNED script apply that deadlocks here lands a terminal
              # script_rejected/apply_failed (see the Engine moduledoc). A no-op for
              # an instance that is not completed or has no waiting parent token.
              |> append_service_sub_process_cascade(
                dispatch.instance_id,
                final_instance_state,
                idempotency_key,
                prefix
              )
              |> append_service_entity_write_audits(completion, dispatch, prefix)

            probe_service_multi(multi)

            case repo.transaction(multi) do
              {:ok, _changes} ->
                {:ok, :advanced}

              # GH #2587 PR C2 (F-C4): with a plan, a failed `{:line, _, _}` step keeps its name so
              # the entry function can run it through the port's interpreter. Every other failed
              # step, and every apply without a plan, returns today's `{:error, reason}`.
              {:error, {:line, _index, _step} = failed_step, reason, _changes}
              when is_map_key(completion, :entity_plan) ->
                {:error, {:entity_write_step_failed, failed_step, reason}}

              # GH #2704: the pre-lock steps are named too, so a failed one (a database fault,
              # `{:sequence_conflict, _}`) is interpreted by the port like a failed line step
              # instead of leaking as a bare reason.
              {:error, {:pre_type_lock, _type} = failed_step, reason, _changes}
              when is_map_key(completion, :entity_plan) ->
                {:error, {:entity_write_step_failed, failed_step, reason}}

              {:error, _failed_step, reason, _changes} ->
                # ISS-0784 follow-up fix (ISS-0784, same root cause as
                # persist_timer_fired_advance/7's own sibling clause above):
                # this function's own `repo.transaction(multi)` call runs
                # nested inside `advance_after_service_task_outcome/4`'s own
                # already-open `repo.transaction(fn -> ... end)` (same `repo`
                # module, same process/connection) -- NOT a genuinely
                # independent transaction. Recording the rejection audit here
                # would roll back right along with `advance_after_service_task_outcome/4`'s
                # own `repo.rollback(reason)` once this `{:error, reason}`
                # propagates up through `advance_service_task_dispatch/4`.
                # The audit write is issued instead by
                # `Letflow.Engine.ServiceTaskDispatcher.call_advance_after_service_task_outcome/3`,
                # strictly after `advance_after_service_task_outcome/4`'s own
                # `repo.transaction/1` has fully returned (see that module).
                # Any `reason` shape here is byte-identical to before ISS-0784.
                {:error, reason}
            end

          {:execution_error, error_args} ->
            {:error, {:execution_error_not_supported_for_service_task_advance, error_args}}
        end
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # GH #2648: the service/script apply's sub-process completion cascade. Reuses
  # append_sub_process_completion_cascade_multi/6 on the same sys-folded final state the
  # :projection step wrote, so the parent merges exactly the child's final variables.
  defp append_service_sub_process_cascade(
         multi,
         _instance_id,
         %InstanceState{status: status},
         _idempotency_key,
         _prefix
       )
       when status != :completed,
       do: multi

  defp append_service_sub_process_cascade(
         multi,
         instance_id,
         %InstanceState{} = final_instance_state,
         idempotency_key,
         prefix
       ) do
    Multi.merge(multi, fn changes ->
      case fold_service_sys_into_state(final_instance_state, changes) do
        {:ok, folded} ->
          append_sub_process_completion_cascade_multi(
            Multi.new(),
            instance_id,
            folded,
            EventStore.platform_actor_id(),
            idempotency_key,
            prefix
          )

        # Unreachable in practice (the :projection step above re-folds the same values and fails
        # first), but never drop the cascade silently: abort and roll the apply back.
        {:error, reason} ->
          Multi.error(Multi.new(), :cascade_fold, reason)
      end
    end)
  end

  # design doc §3.2 step 5's "registration path" -- SERVICE_TASK_COMPLETED
  # is seeded per-tenant via tenant_provisioning.ex's own
  # @platform_event_type_seed_attrs (see that module for the seed entry
  # itself), the same mechanism TIMER_FIRED already uses.
  #
  # GH 2534 PR 7c-1: generalised by the completion descriptor -- HTTP passes
  # SERVICE_TASK_COMPLETED with `%{dispatch_id, node_id, decoded_body}` (unchanged), the
  # script route SCRIPT_TASK_COMPLETED with its section-6 payload.
  defp append_service_task_completed_event(dispatch, completion, prefix) do
    payload = Jason.encode!(completion.event_payload)

    event_attrs = %{
      instance_id: dispatch.instance_id,
      event_type: completion.event_type,
      payload: payload,
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: completion.idempotency_key
    }

    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} = replay -> replay
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # design doc §3.3 -- the :give_up outcome. Calls set_instance_error/2
  # directly with REQ-214's already-built standalone_error_attrs -- no
  # re-derivation, no re-fetch/re-lock of the dispatch row (unlike the
  # :advance clause -- this clause needs no row data beyond what
  # standalone_error_attrs already carries). dispatch_id is accepted for
  # signature uniformity with the :advance clause and future logging/tracing
  # use only.
  #
  # Both {:instance_terminal, _} and {:instance_already_error, _} fold to
  # {:ok, :error_set} -- co-equal "someone else already reached a
  # terminal-enough state first" races (design doc §3.3), not failures.
  defp give_up_service_task_dispatch(_dispatch_id, standalone_error_attrs, prefix) do
    case set_instance_error(standalone_error_attrs, prefix: prefix) do
      {:ok, %{status: :error}} -> {:ok, :error_set}
      {:error, {:instance_terminal, _status}} -> {:ok, :error_set}
      {:error, {:instance_already_error, _error_detail}} -> {:ok, :error_set}
      {:error, reason} -> {:error, reason}
    end
  end

  # =========================================================================
  # GH #2587 / REQ-499 PR C2 (decision 0054; design
  # lib/letflow/design/gh2587-req499-pr-c-service-task-writes.md): SERVICE_TASK entity writes.
  #
  # A SERVICE_TASK node that declares `entity_writes` composes them into the SAME transaction as
  # the apply of its result (HTTP: `advance_after_service_task_outcome/4`; script:
  # `apply_script_task_result/3`), through `do_persist_service_task_advance/10`. Reachable since
  # PR C1 lifted the activation fence (`Definitions.check_entity_writes/3` accepts SERVICE_TASK);
  # GH #2590 R5 lifted it for `module_writes` too (`Definitions.ModuleWrites`): a SERVICE node's
  # handler calls run in the same Multi, after the declarative lines, with the platform sentinel
  # as the event actor and the ACTIVATOR as the field-restriction subject (T-10).
  #
  # A SERVICE_TASK completion is not a request: there is no client, no pending task and the
  # external call is at-most-once (the HTTP dispatch row is already "advanced"; the script row is
  # "running" under a lease). A refusal of the entity step therefore lands the instance in
  # ERROR + DLQ in a SECOND transaction after the first rolled back (NEW product behaviour,
  # D-C.8), never a stall; contention is re-applied by the engine (bounded, D-C.9).
  # =========================================================================

  @typep service_entity_plan :: %{
           lines: [EntityPort.line()],
           module_writes: [EntityPort.module_write_line()],
           owner: EntityPort.owner_stamp() | nil,
           node_id: String.t(),
           instance_id: Ecto.UUID.t(),
           dispatch_id: Ecto.UUID.t(),
           definition_id: Ecto.UUID.t(),
           definition_version: String.t(),
           activator_id: Ecto.UUID.t(),
           authorized: [{String.t(), String.t()}],
           route: :http | :script,
           guard_budget_ms: non_neg_integer()
         }

  @typep service_route ::
           {:http, Ecto.UUID.t(), map(), module()}
           | {:script, ScriptTaskDispatcher.claim(), ScriptTaskDispatcher.result()}

  @typep service_outcome ::
           {:final, term()}
           | :contention
           | {:refuse, atom(), non_neg_integer(), atom()}

  defp service_monotonic_ms, do: System.monotonic_time(:millisecond)

  # ---- plan phase (P0 + P1): read-only except `prepare/2`'s own short transaction ------------

  # Same read set and the same `recorded_activator/2` + `check_activator_active/2` as
  # `plan_entity_writes/3` (D-C.5). `{:ok, nil}` for a node without lines AND for a read problem
  # (the in-transaction S4 guard then fails closed for a node that has lines).
  @spec plan_service_entity_writes(
          {:http, Ecto.UUID.t()} | {:script, ScriptTaskDispatcher.claim()},
          String.t()
        ) :: {:ok, service_entity_plan() | nil} | {:error, term()}
  defp plan_service_entity_writes(ref, prefix) do
    with {:ok, row} <- service_plan_row(ref, prefix),
         {:ok, graph, raw_graph} <- fetch_graph_with_raw(row.instance_id, prefix),
         %{attributes: %{} = attributes} <- find_node(graph, row.node_id),
         declared when declared != {:ok, [], []} <- declared_writes(attributes) do
      resolve_service_entity_plan(row, declared, raw_graph, elem(ref, 0), prefix)
    else
      _no_lines_or_unreadable -> {:ok, nil}
    end
  end

  defp service_plan_row({:http, dispatch_id}, prefix) do
    with {:ok, uuid} <- Ecto.UUID.cast(dispatch_id),
         %ServiceTaskDispatch{status: :advanced} = row <-
           Repo.get(ServiceTaskDispatch, uuid, prefix: prefix) do
      {:ok, row}
    else
      _ -> :none
    end
  end

  defp service_plan_row({:script, claim}, prefix) do
    case ScriptTaskDispatch
         |> ScriptTaskDispatcher.cas_query(claim)
         |> Repo.one(prefix: prefix) do
      %ScriptTaskDispatch{} = row -> {:ok, row}
      nil -> :none
    end
  end

  defp resolve_service_entity_plan(_row, {:malformed, index}, _raw_graph, _route, _prefix),
    do: {:error, {:service_refused, index, :write_not_permitted, :line_malformed}}

  # GH #2590 R5: the node's `module_writes` (handler calls) are planned like a HUMAN completion's
  # (design 6.1 P0b): the combined 20-line cap, the activator, then the run-time authorization
  # of the stamp, hashes, handler and arguments against the pinned snapshot, then the v3 event
  # schema backstop, all BEFORE `prepare/2` and every lock. A refusal is a `:service_refused`
  # (the apply driver lands it in ERROR + DLQ, D-C.8) with ONE public code and the closed detail
  # atom going to the tenant audit only (INV-5).
  defp resolve_service_entity_plan(row, {:ok, lines, module_lines}, raw_graph, route, prefix) do
    with {:cap, true} <-
           {:cap, length(lines) + length(module_lines) <= @max_entity_write_lines},
         %InstanceProjection{definition_id: definition_id} <-
           Repo.get_by(InstanceProjection, [instance_id: row.instance_id], prefix: prefix),
         {:ok, definition} <- Definitions.get_by_id(definition_id, prefix: prefix),
         {:ok, activator_id, authorized} <- recorded_activator(definition, prefix),
         :ok <- check_activator_active(activator_id, prefix),
         owner = owner_stamp(definition),
         :ok <- authorize_service_module_writes(module_lines, owner, raw_graph, lines, prefix),
         :ok <- check_service_applied_event_schema(module_lines, lines, prefix) do
      plan = %{
        lines: lines,
        module_writes: module_lines,
        owner: owner,
        node_id: row.node_id,
        instance_id: row.instance_id,
        dispatch_id: row.id,
        definition_id: definition_id,
        definition_version: definition.version,
        activator_id: activator_id,
        authorized: authorized,
        route: route,
        guard_budget_ms: 10_000
      }

      case EntityPort.impl().prepare(lines, prepare_ctx(prefix, module_lines)) do
        :ok ->
          {:ok, plan}

        {:error, :entity_write_contention} ->
          {:error, {:entity_write_refused, :contention, :entity_write_contention}}

        {:error, _prepare_failure} ->
          {:error, {:entity_write_failed, 0, :prepare}}
      end
    else
      {:cap, false} ->
        {:error, {:service_refused, @max_entity_write_lines, :validation_failed, :too_many_lines}}

      {:error, :entity_write_needs_reactivation} ->
        {:error, :entity_write_needs_reactivation}

      {:error, {:service_refused, _index, _code, _detail}} = refusal ->
        refusal

      _unreadable ->
        {:ok, nil}
    end
  end

  # The service twin of `authorize_module_writes/7`: the same port call, a `:service_refused`
  # instead of a request refusal (the audit entry is written by the landing, with the dispatch id).
  defp authorize_service_module_writes([], _owner, _raw_graph, _lines, _prefix), do: :ok

  defp authorize_service_module_writes(module_lines, owner, raw_graph, lines, prefix) do
    case EntityPort.impl().authorize_module_writes(module_lines, %{
           prefix: prefix,
           owner: owner,
           snapshot_graph: raw_graph,
           entity_write_count: length(lines)
         }) do
      :ok ->
        :ok

      {:error, {index, detail}} ->
        {:error, {:service_refused, index, :write_not_permitted, detail}}
    end
  end

  # The service twin of `check_applied_event_schema/5` (rollout backstop, decision 0054 R4a/R5
  # amendment): a tenant without `TASK_ENTITY_WRITES_APPLIED` v3 cannot append a handler line's
  # APPLIED event, so it is refused up front, fail closed, and lands in ERROR + DLQ.
  defp check_service_applied_event_schema([], _lines, _prefix), do: :ok

  defp check_service_applied_event_schema(_module_lines, lines, prefix) do
    case EventRegistry.max_schema_version(EntityPort.applied_event_type(), prefix) do
      version when is_integer(version) and version >= 3 ->
        :ok

      _outdated ->
        {:error, {:service_refused, length(lines), :write_not_permitted, :event_schema_outdated}}
    end
  end

  # The S4 guard (design 7.2 step 3): after the graph and token reads, a node that declares lines
  # while the descriptor carries no (or a different) plan is refused fail-closed. A node without
  # lines is `:ok` whatever the plan.
  defp check_service_lines_planned(graph, node_id, plan) do
    declared =
      case find_node(graph, node_id) do
        %{attributes: %{} = attributes} -> declared_writes(attributes)
        _no_attributes -> {:ok, [], []}
      end

    # GH #2590 R5: a node that declares `module_writes` is `:ok` only when the plan carries those
    # exact lines too (a plan made from the declarative lines alone would skip the handler calls).
    case {declared, plan} do
      {{:ok, [], []}, _plan} -> :ok
      {{:ok, lines, module_lines}, %{lines: lines, module_writes: module_lines}} -> :ok
      _unplanned -> {:error, {:entity_write_failed, 0, :not_planned}}
    end
  end

  defp put_service_entity_plan(completion, nil), do: completion
  defp put_service_entity_plan(completion, plan), do: Map.put(completion, :entity_plan, plan)

  # ---- the apply driver: attempt -> classify -> re-apply | land ------------------------------

  # `planned` is the already-computed plan result of the FIRST attempt, `:replan` afterwards.
  @spec drive_service_apply(
          service_route(),
          String.t(),
          integer(),
          pos_integer(),
          {:ok, service_entity_plan() | nil} | {:error, term()} | :replan
        ) :: term()
  defp drive_service_apply(route, prefix, deadline_at, attempt_no, planned) do
    remaining = deadline_at - service_monotonic_ms()

    if service_attempt_blocked?(route, attempt_no, remaining) do
      land_service_failure(route, :entity_write_contention, 0, :deadline, prefix)
    else
      planned =
        if planned == :replan,
          do: plan_service_entity_writes(service_route_ref(route), prefix),
          else: planned

      outcome =
        case planned do
          {:ok, nil} ->
            route |> run_service_apply(nil, prefix) |> classify_service_apply_result(false)

          {:ok, plan} ->
            plan = %{plan | guard_budget_ms: service_guard_budget_ms(deadline_at)}
            route |> run_service_apply(plan, prefix) |> classify_service_apply_result(true)

          {:error, reason} ->
            classify_service_plan_error(reason)
        end

      handle_service_outcome(outcome, route, prefix, deadline_at, attempt_no)
    end
  end

  # An attempt starts only with the stated worst-case bound left, except the HTTP route's first
  # attempt (no lease to overrun). The landing is never gated.
  defp service_attempt_blocked?({:http, _id, _body, _repo}, 1, _remaining), do: false

  defp service_attempt_blocked?(_route, _attempt_no, remaining),
    do: remaining < @service_attempt_gate_ms

  defp service_guard_budget_ms(deadline_at) do
    (deadline_at - service_monotonic_ms() - @service_pre_guard_bound_ms) |> max(0) |> min(10_000)
  end

  defp service_route_ref({:http, dispatch_id, _body, _repo}), do: {:http, dispatch_id}
  defp service_route_ref({:script, claim, _result}), do: {:script, claim}

  defp handle_service_outcome({:final, result}, _route, _prefix, _deadline_at, _attempt_no),
    do: result

  defp handle_service_outcome(:contention, route, prefix, deadline_at, attempt_no) do
    if attempt_no < @service_apply_attempts do
      service_backoff(attempt_no)
      drive_service_apply(route, prefix, deadline_at, attempt_no + 1, :replan)
    else
      land_service_failure(route, :entity_write_contention, 0, :exhausted, prefix)
    end
  end

  defp handle_service_outcome({:refuse, code, index, detail}, route, prefix, _deadline_at, _n),
    do: land_service_failure(route, code, index, detail, prefix)

  # Constant 100 ms / 300 ms backoffs; none in a build with `:engine_test_seams` (config/test.exs),
  # the same compile-time switch as the test seams below.
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    defp service_backoff(_attempt_no) do
      _ = @service_backoffs_ms
      :ok
    end
  else
    defp service_backoff(attempt_no),
      do: Process.sleep(Enum.at(@service_backoffs_ms, attempt_no - 1, 300))
  end

  defp run_service_apply({:http, dispatch_id, body, repo}, plan, prefix),
    do: run_http_apply(dispatch_id, body, repo, plan, prefix)

  defp run_service_apply({:script, claim, result}, plan, prefix),
    do: apply_script_task_result_once(claim, normalize_script_result(result), plan, prefix)

  # With no plan this is exactly the transaction the HTTP apply always ran (no rescue, no SET
  # LOCAL). With a plan the SET LOCALs are its FIRST statements and a contention class is mapped.
  defp run_http_apply(dispatch_id, decoded_body, repo, nil, prefix) do
    repo.transaction(fn ->
      case advance_service_task_dispatch(dispatch_id, decoded_body, repo, prefix, nil) do
        {:ok, result} -> result
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp run_http_apply(dispatch_id, decoded_body, repo, plan, prefix) do
    rescue_service_contention(fn ->
      repo.transaction(fn ->
        set_service_entity_write_timeouts(repo)

        case advance_service_task_dispatch(dispatch_id, decoded_body, repo, prefix, plan) do
          {:ok, result} -> result
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end)
  end

  defp set_service_entity_write_timeouts(repo) do
    repo.query!(@entity_write_set_lock_timeout)
    repo.query!(@entity_write_set_statement_timeout)
    :ok
  end

  defp rescue_service_contention(fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}} when code in @contention_error_codes ->
          {:error, {:entity_write_refused, :contention, :entity_write_contention}}

        _other ->
          reraise error, __STACKTRACE__
      end

    _error in DBConnection.ConnectionError ->
      {:error, {:entity_write_refused, :contention, :entity_write_contention}}
  end

  # ---- classification (D-C.8, section 7.5 of the design) -------------------------------------

  @spec classify_service_apply_result(term(), boolean()) :: service_outcome()
  defp classify_service_apply_result({:ok, _outcome} = ok, _planned?), do: {:final, ok}

  defp classify_service_apply_result({:error, reason} = error, _planned?) do
    case reason do
      {:entity_write_failed, index, step} when is_integer(index) and is_atom(step) ->
        {:refuse, :entity_write_failed, index, step}

      {:entity_write_refused, :contention, _code} ->
        :contention

      {:entity_write_step_failed, failed_step, inner} ->
        interpret_service_step_failure(failed_step, inner)

      # GH #2648: planned or not (HTTP; the script route's unplanned apply bypasses this
      # driver). An UNPLANNED apply that completes a sub-process child also takes
      # the parent token and projection locks through the cascade, so it can be a deadlock victim;
      # the dispatch row is already "advanced" and nothing else would ever re-apply it.
      {:transaction_failed, %Postgrex.Error{postgres: %{code: code}}}
      when code in @contention_error_codes ->
        :contention

      {:transaction_failed, %DBConnection.ConnectionError{}} ->
        :contention

      # GH #2577: a derived key of this apply was already claimed. The apply's own completion
      # was written by the first claimant, so the answer is the existing one (D-3).
      {:idempotent_replay, _original} ->
        {:final, {:ok, :already_final}}

      _not_an_entity_write_class ->
        {:final, error}
    end
  end

  defp interpret_service_step_failure(failed_step, inner) do
    case EntityPort.impl().interpret_failure(failed_step, inner) do
      {:refused, _index, :entity_write_contention, _detail} ->
        :contention

      # REQ-606 (decision 0067 D6): a full trigger backlog drains on its own, so it is retried like
      # contention and lands as `entity_write_contention`; it is not a service refusal code.
      {:refused, _index, :trigger_backlog_full, _detail} ->
        :contention

      # A `sys:step:` key cannot be claimed by a client: treated as "a prior apply committed".
      {:refused, _index, :idempotency_conflict, _detail} ->
        {:final, {:ok, :already_final}}

      {:refused, index, code, detail} ->
        {:refuse, code, index, detail}

      {:failed, index, step} ->
        {:refuse, :entity_write_failed, index, step}

      :not_a_line_failure ->
        {:final, {:error, inner}}
    end
  end

  defp classify_service_plan_error({:entity_write_refused, :contention, _code}), do: :contention

  defp classify_service_plan_error(:entity_write_needs_reactivation),
    do: {:refuse, :entity_write_needs_reactivation, 0, :activator}

  defp classify_service_plan_error({:entity_write_failed, index, step}),
    do: {:refuse, :entity_write_failed, index, step}

  defp classify_service_plan_error({:service_refused, index, code, detail}),
    do: {:refuse, code, index, detail}

  # ---- the composition inside the nested Multi ------------------------------------------------

  defp maybe_service_entity_writes(
         multi,
         %{entity_plan: plan, idempotency_key: completion_key},
         advanced_state,
         dispatch,
         prefix
       ) do
    variables = advanced_state.variables

    ctx = %{
      prefix: prefix,
      origin: {:dispatch, plan.dispatch_id},
      instance_id: dispatch.instance_id,
      node_id: plan.node_id,
      definition_id: plan.definition_id,
      definition_version: plan.definition_version,
      # No human completes: the event actor is the platform sentinel (D-C.4, proof test C-1);
      # the restriction subject is the ACTIVATOR and `source.activator_id` records it.
      actor_id: EventStore.platform_actor_id(),
      subject_id: plan.activator_id,
      activator_id: plan.activator_id,
      authorized: plan.authorized,
      variables: fn _changes -> variables end,
      variable_labels: fn _changes -> advanced_state.variable_labels end,
      # This Multi exists only when the hop chain advanced: nothing to skip.
      skip?: fn _changes -> false end,
      guard_budget_ms: plan.guard_budget_ms,
      # GH #2590 R5: the handler calls of the node, with the stamp's opaque strings (the engine
      # names no module); `HandlerWrites` re-resolves everything from them.
      module_writes: plan.module_writes,
      owner: plan.owner,
      entity_write_count: length(plan.lines)
    }

    multi
    |> then(&EntityPort.impl().multi(&1, plan.lines, ctx))
    |> Multi.merge(fn changes ->
      service_entity_tail_events(
        Map.fetch!(changes, :entity_writes),
        plan,
        completion_key,
        prefix
      )
    end)
  end

  defp maybe_service_entity_writes(multi, _no_plan, _state, _dispatch, _prefix), do: multi

  # GH #2704 (C-E): the pre-lock group of the entity-type rows of a planned completion; a
  # completion without `:entity_plan` adds no step at all.
  defp maybe_service_pre_lock(multi, %{entity_plan: plan}, prefix),
    do: EntityPort.lock_types(multi, plan.lines, plan.module_writes, %{prefix: prefix})

  defp maybe_service_pre_lock(multi, _no_plan, _prefix), do: multi

  # Test seam (same compile-time switch as `__complete_task_multi_step_names__/3`): sends the step
  # names of the service Multi about to run to the pid in `:service_multi_probe`. Absent from
  # every build without `config :letflow, :engine_test_seams`.
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    defp probe_service_multi(multi) do
      case Application.get_env(:letflow, :service_multi_probe) do
        pid when is_pid(pid) ->
          names =
            Enum.map(Multi.to_list(multi), fn
              {:merge, {:merge, _fun}} -> :__merge__
              {name, _op} -> name
            end)

          send(pid, {:service_multi_names, names})

        _none ->
          :ok
      end

      :ok
    end
  else
    defp probe_service_multi(_multi), do: :ok
  end

  defp service_entity_tail_events(
         %{applied: applied, lines_hash: lines_hash, sys_values: sys_values},
         plan,
         completion_key,
         prefix
       ) do
    sentinel = EventStore.platform_actor_id()
    node = %{instance_id: plan.instance_id, node_id: plan.node_id}

    Multi.new()
    |> append_sys_variables_event(sys_values, node, sentinel, completion_key, prefix)
    |> Multi.run(:entity_writes_applied_event, fn _repo, _changes ->
      payload = %{
        "node_id" => plan.node_id,
        "task_id" => nil,
        "dispatch_id" => plan.dispatch_id,
        "lines_hash" => lines_hash,
        "lines" =>
          Enum.map(applied, fn line ->
            Map.merge(
              %{
                "line_index" => line.line_index,
                "entity_type" => line.entity_type,
                "record_id" => line.record_id,
                "event_global_seq" => line.event_global_seq
              },
              handler_keys(line)
            )
          end)
      }

      case EventStore.append(
             %{
               instance_id: plan.instance_id,
               event_type: EntityPort.applied_event_type(),
               payload: Jason.encode!(payload),
               actor_id: sentinel,
               idempotency_key: completion_key <> "::entity_writes"
             },
             prefix: prefix
           )
           |> IdempotentReplay.fresh() do
        {:ok, result} -> {:ok, result}
        {:error, {:idempotent_replay, _original}} = replay -> replay
        {:error, _reason} -> {:error, {:entity_write_failed, 0, :applied_event}}
      end
    end)
  end

  defp service_entity_tail_events(:skipped, _plan, _completion_key, _prefix), do: Multi.new()

  defp fold_service_sys_into_state(
         %InstanceState{} = state,
         %{entity_writes: %{sys_values: values}}
       )
       when map_size(values) > 0,
       do: fold_sys_values(state, values)

  defp fold_service_sys_into_state(%InstanceState{} = state, _changes), do: {:ok, state}

  # Per-line audit, LAST in the Multi so the tenant-wide audit chain lock is held the shortest.
  # Ids and counters only: no field name, no field value (INV-2).
  defp append_service_entity_write_audits(multi, %{entity_plan: plan}, _dispatch, prefix) do
    Multi.merge(multi, fn changes ->
      %{applied: applied, lines_hash: lines_hash} = Map.fetch!(changes, :entity_writes)

      Enum.reduce(applied, Multi.new(), fn line, acc ->
        attrs = %{
          actor_id: EventStore.platform_actor_id(),
          action: "entity_write.process_step",
          resource_type: "entity_record",
          resource_id: line.record_id,
          before_state: nil,
          after_state:
            Map.merge(
              %{
                "entity_type" => line.entity_type,
                "record_id" => line.record_id,
                "dispatch_id" => plan.dispatch_id,
                "activator_id" => plan.activator_id,
                "instance_id" => plan.instance_id,
                "node_id" => plan.node_id,
                "definition_id" => plan.definition_id,
                "definition_version" => plan.definition_version,
                "line_index" => line.line_index,
                "lines_hash" => lines_hash
              },
              handler_keys(line)
            ),
          trace_id: nil
        }

        Multi.run(acc, audit_step_name(line), fn repo, _changes ->
          Audit.insert_entry(repo, attrs, prefix)
        end)
      end)
    end)
  end

  defp append_service_entity_write_audits(multi, _no_plan, _dispatch, _prefix), do: multi

  # ---- duplicate-apply gate (D-C.10) ---------------------------------------------------------

  defp lock_projection_for_service_apply(repo, dispatch, completion_key, plan, prefix) do
    case fetch_and_lock_instance_projection(repo, dispatch.instance_id, prefix) do
      {:error, {:instance_not_active, _status}} = not_active when plan != nil ->
        if service_completion_key_present?(repo, completion_key, prefix),
          do: :duplicate,
          else: not_active

      other ->
        other
    end
  end

  defp service_duplicate_gate(_repo, _completion_key, nil, _prefix), do: :ok

  defp service_duplicate_gate(repo, completion_key, _plan, prefix) do
    if service_completion_key_present?(repo, completion_key, prefix), do: :duplicate, else: :ok
  end

  # An EXPLICIT read of the completion key, never a collision: `EventStore.append/2` answers a
  # claimed key with the ORIGINAL event as `{:ok, _}` (D-C.8 b), which a caller must not mistake
  # for a fresh write.
  defp service_completion_key_present?(repo, completion_key, prefix) do
    IdempotencyRecord
    |> where([i], i.idempotency_key == ^completion_key)
    |> repo.exists?(prefix: prefix)
  end

  # ---- the ERROR landing (D-C.8), a SECOND transaction ---------------------------------------

  defp land_service_failure(route, code, index, detail, prefix) do
    code = if code in @service_refusal_codes, do: code, else: :entity_write_failed

    if code == :entity_write_failed do
      Logger.error(
        "service task entity write failed internally: step=#{inspect(detail)} " <>
          "index=#{index} dispatch_id=#{service_route_dispatch_id(route)}"
      )
    end

    case route do
      {:http, dispatch_id, _body, _repo} ->
        land_http_entity_write_failure(dispatch_id, code, index, detail, prefix, 1)

      {:script, claim, result} ->
        land_script_entity_write_failure(claim, result, code, index, detail, prefix, 1)
    end
  end

  defp service_route_dispatch_id({:http, dispatch_id, _body, _repo}), do: dispatch_id
  defp service_route_dispatch_id({:script, %{dispatch_id: dispatch_id}, _result}), do: dispatch_id

  # The landing always runs on `Letflow.Repo` (the `repo` argument of the public entry point is
  # `Repo` in every caller), like the best-effort audit entry below.
  #
  # ONE transaction (a single Multi, so a failed step is a plain `{:error, step, reason, _}` and
  # not a poisoned nested transaction): the SET LOCAL pair, the dispatch row lock, the projection
  # lock, the EXPLICIT completion-key read, then the ExecutionError steps. A contention class
  # raised anywhere in it is mapped by `rescue_service_contention/1` and re-run.
  defp land_http_entity_write_failure(dispatch_id, code, index, detail, prefix, attempt_no) do
    result =
      rescue_service_contention(fn ->
        Repo.transaction(http_landing_multi(dispatch_id, code, index, prefix))
      end)

    case result do
      {:ok, %{landing_dispatch: dispatch}} ->
        record_service_entity_write_refusal_audit(
          dispatch.instance_id,
          dispatch.node_id,
          dispatch.id,
          index,
          code,
          detail,
          prefix
        )

        {:ok, :error_set}

      {:error, {:entity_write_refused, :contention, _code}}
      when attempt_no < @service_apply_attempts ->
        service_backoff(attempt_no)
        land_http_entity_write_failure(dispatch_id, code, index, detail, prefix, attempt_no + 1)

      {:error, _step, reason, _changes} ->
        classify_http_landing_failure(reason, dispatch_id)

      {:error, reason} ->
        classify_http_landing_failure(reason, dispatch_id)
    end
  end

  # A completion key already present (a prior apply committed), a dispatch row no longer
  # `advanced`, a cancelled / ended instance: someone else got there first, benign.
  defp classify_http_landing_failure(:landing_already_final, _dispatch_id),
    do: {:ok, :already_final}

  defp classify_http_landing_failure({:instance_not_active, _status}, _dispatch_id),
    do: {:ok, :already_final}

  defp classify_http_landing_failure({tag, _detail}, _dispatch_id)
       when tag in [:instance_terminal, :instance_already_error],
       do: {:ok, :already_final}

  defp classify_http_landing_failure(reason, dispatch_id) do
    # The residual of D-C.8 (d): the dispatch row stays "advanced" and the instance ACTIVE.
    # Logged as a classified tag only; the dispatcher writes `service_task.advance_failed`.
    tag = service_landing_failure_tag(reason)

    Logger.error(
      "service task entity write landing failed: dispatch_id=#{dispatch_id} reason=#{tag}"
    )

    {:error, {:entity_write_landing_failed, tag}}
  end

  defp service_landing_failure_tag({:entity_write_refused, :contention, _code}), do: :contention
  defp service_landing_failure_tag(_other), do: :other

  defp http_landing_multi(dispatch_id, code, index, prefix) do
    completion_key = "service_task_dispatch:#{dispatch_id}"

    Multi.new()
    |> Multi.run(:landing_timeouts, fn repo, _changes ->
      set_service_entity_write_timeouts(repo)
      {:ok, :set}
    end)
    |> Multi.run(:landing_dispatch, fn repo, _changes ->
      case fetch_and_lock_service_task_dispatch(dispatch_id, repo, prefix) do
        {:ok, %ServiceTaskDispatch{status: :advanced} = dispatch} -> {:ok, dispatch}
        _gone_or_not_advanced -> {:error, :landing_already_final}
      end
    end)
    |> Multi.run(:landing_projection, fn repo, %{landing_dispatch: dispatch} ->
      fetch_and_lock_instance_projection(repo, dispatch.instance_id, prefix)
    end)
    |> Multi.run(:landing_key_check, fn repo, _changes ->
      if service_completion_key_present?(repo, completion_key, prefix),
        do: {:error, :landing_already_final},
        else: {:ok, :absent}
    end)
    |> Multi.merge(fn %{landing_dispatch: dispatch, landing_projection: projection} ->
      error_args = %{
        instance_id: projection.instance_id,
        error_type: :entity_write_refused,
        affected: {:node, dispatch.node_id},
        reason: "service task entity write refused: #{code}",
        # the PRE-merge variables: the response body is never copied into an error event
        variables: projection.variables,
        details: %{
          "line_index" => index,
          "code" => Atom.to_string(code),
          "dispatch_id" => dispatch.id
        },
        actor_id: EventStore.platform_actor_id(),
        idempotency_key: completion_key
      }

      ExecutionError.append_multi(Multi.new(), error_args,
        prefix: prefix,
        locked_projection: projection
      )
    end)
  end

  # ---- the stuck-`advanced` landing (GH #2688 / REQ-513, design D3/D4) ------------------------

  @typedoc "What `land_stuck_service_dispatch/2` answers; one value per case (design D3)."
  @type stuck_landing_result ::
          {:ok, :landed | :already_final | :instance_moved_on | :not_in_class | :too_young}
          | {:error, :not_found | :contention | :landing_failed}

  @doc """
  Lands an HTTP SERVICE_TASK dispatch row stuck `"advanced"` as an ExecutionError (instance
  ERROR + one DLQ row), once. ONE transaction that re-checks everything under the dispatch row
  lock (the same lock the apply path takes first, so a late apply and this landing serialise on
  it): row still `advanced`, instance projection ACTIVE, completion key absent, row older than
  the minimum age (`ServiceTaskDispatcher.stuck_advance_min_age_seconds/0`, floor 120 s), node
  in the entity-write class (`stuck_entity_write_class?/3`). Any other state is a benign
  `{:ok, _}` and nothing is written. The row's own status is never changed (as D-C.8).

  A row id that is absent in `prefix` (unknown, or another tenant's) is `{:error, :not_found}`
  in both cases: indistinguishable (INV-5). Nothing is written in an error case.
  """
  @spec land_stuck_service_dispatch(Ecto.UUID.t(), String.t()) :: stuck_landing_result()
  def land_stuck_service_dispatch(dispatch_id, prefix)
      when is_binary(dispatch_id) and is_binary(prefix) do
    result =
      rescue_service_contention(fn ->
        Repo.transaction(stuck_landing_multi(dispatch_id, prefix))
      end)

    case result do
      {:ok, %{stuck_dispatch: dispatch}} ->
        record_stuck_advance_landed_audit(dispatch, prefix)
        {:ok, :landed}

      {:error, {:entity_write_refused, :contention, _code}} ->
        {:error, :contention}

      {:error, _step, reason, _changes} ->
        classify_stuck_landing_failure(reason, dispatch_id)

      {:error, reason} ->
        classify_stuck_landing_failure(reason, dispatch_id)
    end
  end

  defp classify_stuck_landing_failure(:stuck_not_found, _dispatch_id), do: {:error, :not_found}
  defp classify_stuck_landing_failure(:stuck_already_final, _id), do: {:ok, :already_final}

  defp classify_stuck_landing_failure(:stuck_instance_moved_on, _id),
    do: {:ok, :instance_moved_on}

  defp classify_stuck_landing_failure(:stuck_not_in_class, _id), do: {:ok, :not_in_class}
  defp classify_stuck_landing_failure(:stuck_too_young, _id), do: {:ok, :too_young}

  defp classify_stuck_landing_failure(reason, dispatch_id) do
    # Logged as a classified tag only (the reason can hold variables).
    tag = service_landing_failure_tag(reason)
    Logger.error("stuck advance landing failed: dispatch_id=#{dispatch_id} reason=#{tag}")
    {:error, if(tag == :contention, do: :contention, else: :landing_failed)}
  end

  defp stuck_landing_multi(dispatch_id, prefix) do
    completion_key = "service_task_dispatch:#{dispatch_id}"

    Multi.new()
    |> Multi.run(:stuck_timeouts, fn repo, _changes ->
      set_service_entity_write_timeouts(repo)
      {:ok, :set}
    end)
    |> Multi.run(:stuck_dispatch, fn repo, _changes ->
      case fetch_and_lock_service_task_dispatch(dispatch_id, repo, prefix) do
        nil -> {:error, :stuck_not_found}
        {:ok, %ServiceTaskDispatch{status: :advanced} = dispatch} -> {:ok, dispatch}
        {:ok, _landed_or_completed} -> {:error, :stuck_already_final}
      end
    end)
    |> Multi.run(:stuck_projection, fn repo, %{stuck_dispatch: dispatch} ->
      case fetch_and_lock_instance_projection(repo, dispatch.instance_id, prefix) do
        {:ok, projection} -> {:ok, projection}
        {:error, _cancelled_error_or_gone} -> {:error, :stuck_instance_moved_on}
      end
    end)
    |> Multi.run(:stuck_key_check, fn repo, _changes ->
      if service_completion_key_present?(repo, completion_key, prefix),
        do: {:error, :stuck_already_final},
        else: {:ok, :absent}
    end)
    |> Multi.run(:stuck_age_check, fn _repo, %{stuck_dispatch: dispatch} ->
      cutoff =
        DateTime.add(
          DateTime.utc_now(),
          -ServiceTaskDispatcher.stuck_advance_min_age_seconds(),
          :second
        )

      # `dispatched_at` is required on an `advanced` row; a nil one fails closed.
      case dispatch.dispatched_at do
        %DateTime{} = at ->
          if DateTime.compare(at, cutoff) == :gt,
            do: {:error, :stuck_too_young},
            else: {:ok, :old}

        nil ->
          {:error, :stuck_too_young}
      end
    end)
    |> Multi.run(:stuck_class_check, fn _repo, %{stuck_dispatch: dispatch} ->
      case stuck_entity_write_class?(dispatch.instance_id, dispatch.node_id, prefix) do
        :in_class -> {:ok, :in_class}
        _other_or_unreadable -> {:error, :stuck_not_in_class}
      end
    end)
    |> Multi.merge(fn %{stuck_dispatch: dispatch, stuck_projection: projection} ->
      error_args = %{
        instance_id: projection.instance_id,
        error_type: :service_task_apply_lost,
        affected: {:node, dispatch.node_id},
        # fixed sentence, no values: the sweeper has no body, plan or line index
        reason: "service task dispatch apply lost: result not recorded",
        # the PRE-merge variables, as D-C.8
        variables: projection.variables,
        details: %{"dispatch_id" => dispatch.id, "code" => "dispatch_apply_lost"},
        actor_id: EventStore.platform_actor_id(),
        idempotency_key: completion_key
      }

      ExecutionError.append_multi(Multi.new(), error_args,
        prefix: prefix,
        locked_projection: projection
      )
    end)
  end

  # Best-effort, strictly after the landing transaction returned (ISS-0784 rollback note); ids and
  # a fixed code only, no values.
  defp record_stuck_advance_landed_audit(%ServiceTaskDispatch{} = dispatch, prefix) do
    attrs = %{
      actor_id: EventStore.platform_actor_id(),
      action: "service_task.stuck_advance_landed",
      resource_type: "instance",
      resource_id: dispatch.instance_id,
      before_state: nil,
      after_state: %{
        "node_id" => dispatch.node_id,
        "dispatch_id" => dispatch.id,
        "code" => "dispatch_apply_lost"
      },
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      _other ->
        Logger.warning(
          "could not record service_task.stuck_advance_landed for dispatch #{dispatch.id} " <>
            "(instance #{dispatch.instance_id})"
        )

        :ok
    end
  rescue
    _exception ->
      Logger.warning(
        "recording service_task.stuck_advance_landed for dispatch #{dispatch.id} raised"
      )

      :ok
  end

  # The script route lands through the CAS apply itself: `script_failure/7` writes the
  # ExecutionError, the run record and the row `failed` in one transaction, and a row that is no
  # longer `running` (swept, cancelled, already applied) answers `{:ok, :stale}` and writes nothing.
  defp land_script_entity_write_failure(claim, result, code, index, detail, prefix, attempt_no) do
    fail_detail =
      if code == :entity_write_contention,
        do: :entity_write_contention,
        else: :entity_write_refused

    facts =
      case result do
        {:ok, _output, facts} -> facts
        {:failed, _code, _detail, facts} -> facts
      end

    landing = {:failed, :script_rejected, fail_detail, facts}

    case apply_script_task_result_once(claim, normalize_script_result(landing), nil, prefix) do
      {:ok, :failed} ->
        record_service_entity_write_refusal_audit(
          claim.instance_id,
          claim.node_id,
          claim.dispatch_id,
          index,
          code,
          detail,
          prefix
        )

        {:ok, :failed}

      {:ok, other} ->
        {:ok, other}

      {:error, _reason} when attempt_no < @service_apply_attempts ->
        service_backoff(attempt_no)

        land_script_entity_write_failure(
          claim,
          result,
          code,
          index,
          detail,
          prefix,
          attempt_no + 1
        )

      {:error, reason} ->
        # Returned to the script dispatcher, whose follow-up applies `script_rejected` /
        # `apply_failed` through the same CAS (never a silent stall).
        {:error, reason}
    end
  end

  # Test seams (GH #2587 PR C2), compiled ONLY when `config :letflow, :engine_test_seams` is true
  # (config/test.exs; absent from every other build): the HTTP landing driven directly (the
  # landing-against-an-existing-completion-key case), and the HTTP apply with the plan phase
  # forced to "no plan" (the S4 fail-closed guard case).
  if Application.compile_env(:letflow, :engine_test_seams, false) do
    @doc false
    @spec __land_http_entity_write_failure__(Ecto.UUID.t(), atom(), non_neg_integer(), String.t()) ::
            term()
    def __land_http_entity_write_failure__(dispatch_id, code, index, prefix),
      do: land_http_entity_write_failure(dispatch_id, code, index, :test_seam, prefix, 1)

    @doc false
    @spec __http_apply_with_unreadable_plan__(Ecto.UUID.t(), map(), String.t()) :: term()
    def __http_apply_with_unreadable_plan__(dispatch_id, body, prefix) do
      drive_service_apply(
        {:http, dispatch_id, body, Repo},
        prefix,
        service_monotonic_ms() + @service_apply_total_ms,
        1,
        {:ok, nil}
      )
    end
  end

  # Best-effort tenant audit record of the refusal, AFTER the rollback and the landing: ids, an
  # index and closed atoms only; no field name, no value, no entity type (INV-2, INV-5).
  defp record_service_entity_write_refusal_audit(
         instance_id,
         node_id,
         dispatch_id,
         index,
         code,
         detail,
         prefix
       ) do
    attrs = %{
      actor_id: EventStore.platform_actor_id(),
      action: "entity_write.refused",
      resource_type: "instance",
      resource_id: instance_id,
      before_state: nil,
      after_state: %{
        "instance_id" => instance_id,
        "node_id" => node_id,
        "dispatch_id" => dispatch_id,
        "line_index" => index,
        "code" => Atom.to_string(code),
        "detail" => Atom.to_string(detail)
      },
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      _other ->
        Logger.warning(
          "could not record entity_write.refused for dispatch #{dispatch_id} (instance #{instance_id})"
        )

        :ok
    end
  rescue
    _exception ->
      Logger.warning("recording entity_write.refused for dispatch #{dispatch_id} raised")
      :ok
  end

  # =========================================================================
  # apply_script_task_result/3 (GH 2534 PR 7c-1, decision 0053 D2/F-E; design
  # lib/letflow/design/gh2534-7c-script-handler.md 5.4, C4, C13, C16) -- the
  # script SERVICE_TASK route's re-entry. ONE transaction: the CAS on the dispatch
  # row (FOR UPDATE), then the projection lock (dispatch row -> projection, the
  # order cancel_instance/3 also takes), then the instance effect AND the row's
  # terminal status. Unlike the HTTP route (two commits), nothing here is ever
  # committed terminal without its instance effect.
  # =========================================================================

  @doc """
  Applies one script run's result (design 5.4). Returns `{:ok, :stale}` and writes NOTHING
  when the CAS `(id, instance_id, node_id, attempt, status = 'running')` matches no row
  (duplicate, late, swept or cancelled apply). An instance no longer `:active` marks the row
  `cancelled` / `instance_not_active` with no event (C13). A success merges ONLY the declared
  output with the definition's real variable validations and advances the token, appending
  `SCRIPT_TASK_COMPLETED` and `SCRIPT_RUN_RECORDED` and setting the row `applied`; a failure
  (or a merge rejection) writes the ExecutionError incident (ERROR + DLQ), the run record and
  the row `failed`. Any `{:error, _}` rolls the whole transaction back (row stays `running`).
  Never raises.
  """
  @spec apply_script_task_result(
          ScriptTaskDispatcher.claim(),
          ScriptTaskDispatcher.result(),
          prefix :: String.t()
        ) :: {:ok, :applied | :failed | :cancelled | :stale} | {:error, term()}
  def apply_script_task_result(claim, {:ok, _output, _facts} = result, prefix)
      when is_binary(prefix) do
    # GH #2587 PR C2: a successful run of a node that declares `entity_writes` composes them into
    # this apply (D-C.9: a bounded re-apply under the lease, then the CAS-guarded landing).
    # A failed run (`{:failed, ...}`) never reaches the entity step and takes the plain path.
    case plan_service_entity_writes({:script, claim}, prefix) do
      {:ok, nil} ->
        apply_script_task_result_once(claim, normalize_script_result(result), nil, prefix)

      planned ->
        drive_service_apply(
          {:script, claim, result},
          prefix,
          script_deadline_at(claim, prefix),
          1,
          planned
        )
    end
  rescue
    _ -> {:error, :raised}
  end

  def apply_script_task_result(claim, result, prefix) when is_binary(prefix),
    do: apply_script_task_result_once(claim, normalize_script_result(result), nil, prefix)

  # D-C.9: `min(20 s, lease_expires_at - now - 2 s)`, read from the CAS row (the engine claim map
  # carries no claim time). A row that no longer matches (swept, applied) leaves nothing: the
  # landing then answers `{:ok, :stale}`.
  defp script_deadline_at(claim, prefix) do
    now_ms = service_monotonic_ms()

    case ScriptTaskDispatch
         |> ScriptTaskDispatcher.cas_query(claim)
         |> Repo.one(prefix: prefix) do
      %ScriptTaskDispatch{lease_expires_at: %DateTime{} = lease_expires_at} ->
        lease_remaining_ms =
          DateTime.diff(lease_expires_at, DateTime.utc_now(), :millisecond) -
            @service_lease_margin_ms

        now_ms + min(@service_apply_total_ms, lease_remaining_ms)

      _no_row_or_no_lease ->
        now_ms
    end
  end

  # One CAS-guarded apply transaction. With a plan the SET LOCALs are its first statements and a
  # contention class is mapped BEFORE the blanket clause below can erase it.
  defp apply_script_task_result_once(claim, result, plan, prefix) do
    run = fn ->
      Repo.transaction(fn ->
        if plan != nil, do: set_service_entity_write_timeouts(Repo)

        case do_apply_script_task_result(Repo, claim, result, plan, prefix) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    # GH #2577 (D-4): the replay is mapped here, after the transaction has returned. Inside it,
    # ScriptTaskDispatcher.apply_with_followup/3 would turn any error into a script_rejected row.
    # The failure landing (script_failure/7) shares the SCRIPT_TASK_COMPLETED key, so its replay
    # arrives as :idempotency_key_reuse from ExecutionError.append_multi/3 and maps the same way.
    outcome = if plan == nil, do: run.(), else: rescue_service_contention(run)

    case outcome do
      {:error, {:idempotent_replay, _original}} -> {:ok, :stale}
      {:error, :idempotency_key_reuse} -> {:ok, :stale}
      outcome -> outcome
    end
  rescue
    # SEC S3: nothing caught is bound, formatted or logged (a 40P01 deadlock lands here too;
    # the dispatcher's follow-up B' then re-evaluates the same CAS).
    _ -> {:error, :raised}
  end

  defp normalize_script_result({:ok, output, facts}),
    do: {:ok, output, %{facts | outcome: :ok, detail: nil}}

  defp normalize_script_result({:failed, code, detail, facts}),
    do: {:failed, code, detail, %{facts | outcome: code, detail: detail}}

  defp do_apply_script_task_result(repo, claim, result, plan, prefix) do
    ScriptTaskDispatch
    |> ScriptTaskDispatcher.cas_query(claim)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil ->
        {:ok, :stale}

      %ScriptTaskDispatch{} = row ->
        # AC18a test seam (honoured only under :scripts_test_hooks): between the CAS lock and
        # the projection lock.
        ScriptTaskDispatcher.pause(:script_task_apply_pause, :after_cas)

        case fetch_and_lock_instance_projection(repo, row.instance_id, prefix) do
          {:ok, projection} ->
            apply_locked_script_result(repo, row, projection, result, plan, prefix)

          {:error, _not_active_or_missing} ->
            with {:ok, _} <-
                   finish_script_row(
                     repo,
                     row,
                     :cancelled,
                     script_outcome_string(result),
                     "instance_not_active",
                     prefix
                   ) do
              {:ok, :cancelled}
            end
        end
    end
  end

  defp script_outcome_string({:ok, _output, _facts}), do: "ok"
  defp script_outcome_string({:failed, code, _detail, _facts}), do: Atom.to_string(code)

  defp apply_locked_script_result(repo, row, projection, {:ok, output, facts}, plan, prefix) do
    with {:ok, graph} <- fetch_graph(row.instance_id, prefix) do
      active_token_records = load_active_tokens(repo, row.instance_id, prefix)
      active_tokens = Enum.map(active_token_records, &to_pure_token/1)

      with {:ok, own_token} <- find_token_for_service_task(row, active_tokens),
           :ok <- check_service_lines_planned(graph, row.node_id, plan) do
        pending_task_tokens = load_pending_task_tokens(repo, row.instance_id, prefix)
        seed_state = build_instance_state(projection, active_tokens, pending_task_tokens)

        # D2: real validations from the definition's variable schema (this route only; the
        # HTTP merge keeps nil validations).
        case VariableSchema.variable_validations(
               repo,
               projection.definition_id,
               seed_state.variables,
               output,
               prefix: prefix
             ) do
          {:error, _reason} ->
            script_failure(repo, row, projection, :script_rejected, :apply_failed, facts, prefix)

          {:ok, validations} ->
            # Decision 0062 seam: labels reach the merge only through the run facts (the part-3
            # runtime sets them; part 1 tests do). Absent means an unlabelled output.
            output_labels = VariableLabels.take(Map.get(facts, :output_labels, %{}), output)

            case VariableMerge.merge(
                   seed_state.variables,
                   seed_state.variable_labels,
                   output,
                   output_labels,
                   validations
                 ) do
              {:ok, merged_variables, merged_labels, _merge_events} ->
                persist_service_task_advance(
                  repo,
                  dispatch_ref(row),
                  projection,
                  graph,
                  seed_state,
                  VariableLabels.put_merged(seed_state, merged_variables, merged_labels),
                  active_token_records,
                  own_token,
                  script_completion(row, projection, output, output_labels, facts, prefix)
                  |> put_service_entity_plan(plan),
                  prefix
                )
                # R7: these three clauses are EXHAUSTIVE -- persist_service_task_advance/10
                # returns only {:ok, :advanced}, {:ok, :error_set} or {:error, _} (its rescue
                # folds any raise). The Elixir type checker proves it: a catch-all clause here
                # fails compile --warnings-as-errors as unreachable.
                |> case do
                  {:ok, :advanced} -> {:ok, :applied}
                  {:ok, :error_set} -> {:ok, :failed}
                  {:error, reason} -> {:error, reason}
                end

              # The rejected value is NOT recorded anywhere (C16). The merge reason is
              # the fail code (GH #2587 D-A1.11): :variable_schema_rejected or
              # :reserved_variable_key.
              {:rejected, _unchanged_variables,
               [{:execution_error, _key, _value, reason, _failures}]} ->
                script_failure(repo, row, projection, :output_invalid, reason, facts, prefix)
            end
        end
      end
    end
  end

  defp apply_locked_script_result(
         repo,
         row,
         projection,
         {:failed, code, detail, facts},
         _plan,
         prefix
       ) do
    script_failure(repo, row, projection, code, detail, facts, prefix)
  end

  # Section 6 payload; on_advanced/on_no_matching_edge add the run record and the row's
  # terminal status to the same Multi (5.4 step 3).
  defp script_completion(row, projection, output, output_labels, facts, prefix) do
    record = RunRecord.build(facts)

    %{
      event_type: "SCRIPT_TASK_COMPLETED",
      event_payload:
        %{
          "dispatch_id" => row.id,
          "node_id" => row.node_id,
          "attempt" => row.attempt,
          "script_key" => row.script_key,
          "script_version" => row.script_version,
          "output" => output
        }
        |> VariableLabels.put_label_field("output_labels", output_labels),
      idempotency_key: "script_task_dispatch:#{row.id}:#{row.attempt}",
      # C16 (SEC S3): the no-matching-edge incident records the CURRENT variables, unchanged
      # (the script output is not committed on that path).
      incident_variables: projection.variables,
      incident_labels: projection.variable_labels,
      on_advanced: fn multi ->
        multi
        |> append_script_run_record_step(row, record, prefix)
        |> finish_script_row_step(row, :applied, "ok", nil, prefix)
      end,
      on_no_matching_edge: fn multi ->
        multi
        |> append_script_run_record_step(
          row,
          %{record | "detail" => "no_matching_gateway_edge"},
          prefix
        )
        |> finish_script_row_step(row, :failed, "ok", "no_matching_gateway_edge", prefix)
      end
    }
  end

  # 5.4 step 4: ExecutionError (instance ERROR + DLQ) with the C16 args -- the CURRENT
  # variables (unchanged), a fixed reason sentence per outcome code, codes and constants only
  # in details -- plus SCRIPT_RUN_RECORDED and the row `failed`, one nested Multi.
  defp script_failure(repo, row, projection, code, detail, facts, prefix) do
    facts = %{facts | outcome: code, detail: detail}
    detail_string = detail && Atom.to_string(detail)

    error_args = %{
      instance_id: row.instance_id,
      error_type: :script_task_failed,
      affected: {:node, row.node_id},
      reason: script_failure_sentence(code),
      variables: projection.variables,
      labels: projection.variable_labels,
      details: %{
        outcome: Atom.to_string(code),
        detail: detail_string,
        fail_code: facts.fail_code,
        script_key: row.script_key,
        script_version: row.script_version,
        attempt: row.attempt
      },
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: "script_task_dispatch:#{row.id}:#{row.attempt}"
    }

    multi =
      Multi.new()
      |> ExecutionError.append_multi(error_args, prefix: prefix, locked_projection: projection)
      |> append_script_run_record_step(row, RunRecord.build(facts), prefix)
      |> finish_script_row_step(row, :failed, Atom.to_string(code), detail_string, prefix)

    case repo.transaction(multi) do
      {:ok, _changes} -> {:ok, :failed}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp script_failure_sentence(:script_error), do: "script service task failed: script error"

  defp script_failure_sentence(:budget_exceeded),
    do: "script service task failed: instruction budget exceeded"

  defp script_failure_sentence(:memory_limit_exceeded),
    do: "script service task failed: memory limit exceeded"

  defp script_failure_sentence(:output_invalid),
    do: "script service task failed: invalid output"

  defp script_failure_sentence(:timeout), do: "script service task failed: timeout"

  defp script_failure_sentence(:script_failed),
    do: "script service task failed: the script reported a declared failure"

  defp script_failure_sentence(:script_rejected),
    do: "script service task failed: the run was rejected"

  defp script_failure_sentence(:script_busy),
    do: "script service task failed: no script capacity available"

  defp append_script_run_record_step(multi, row, record, prefix) do
    Multi.run(multi, :script_run_recorded, fn _repo, _changes ->
      EventStore.append(
        %{
          instance_id: row.instance_id,
          event_type: "SCRIPT_RUN_RECORDED",
          payload: Jason.encode!(record),
          actor_id: EventStore.platform_actor_id(),
          idempotency_key: "script_run:#{row.id}:#{row.attempt}"
        },
        prefix: prefix
      )
      |> IdempotentReplay.fresh()
      |> case do
        {:ok, appended} -> {:ok, appended}
        {:error, {:idempotent_replay, _original}} = replay -> replay
        {:error, reason} -> {:error, {:event_append_failed, reason}}
      end
    end)
  end

  defp finish_script_row_step(multi, row, status, outcome, detail, prefix) do
    Multi.run(multi, :script_task_dispatch_finish, fn repo, _changes ->
      finish_script_row(repo, row, status, outcome, detail, prefix)
    end)
  end

  # Under the CAS lock already held: the row's terminal status, guarded again by
  # (id, attempt, status = 'running').
  defp finish_script_row(repo, row, status, outcome, detail, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ScriptTaskDispatch
    |> where([d], d.id == ^row.id and d.attempt == ^row.attempt and d.status == :running)
    |> repo.update_all(
      [
        set: [
          status: status,
          outcome: outcome,
          outcome_detail: detail,
          finished_at: now,
          updated_at: now
        ]
      ],
      prefix: prefix
    )
    |> case do
      {1, _} -> {:ok, 1}
      _other -> {:error, :script_task_dispatch_not_running}
    end
  end

  # REQ-459/REQ-460 AMENDMENT (supersedes the "rejection -> ERROR" wording of the
  # M4 paragraph below FOR THIS HUMAN_TASK COMPLETION PATH ONLY): a value that a
  # variable_schema rejects, and a `required_outputs` key that is absent or null in
  # the CORRECTED output, no longer reach VariableMerge.merge/3 at all. Both are
  # caller errors, so this step returns
  # {:error, {:completion_refused, {:output_refused, missing, rejected}}} BEFORE
  # any write; the enclosing Multi rolls back (it had only taken row locks and read),
  # interpret_complete_result/3 writes one best-effort audit record and the router
  # answers a retryable 422. The instance is NOT put into ERROR and no
  # EXECUTION_ERROR event is raised (design req459 §2.2 step 6b). The checks reuse the
  # ONE variable_schemas read below. apply_variable_merge/6's {:rejected, _} ->
  # {:execution_error, _} clause is therefore unreachable here and survives only as a
  # last-resort guard. The SUB_PROCESS completion merge (REQ-062,
  # Letflow.Engine.SubProcess) and the other engine-internal EXECUTION_ERROR callers
  # are NOT changed and still route a schema rejection to instance ERROR.
  #
  # M4 -- EE-09 variable merge (design doc §7 / req061 §5.1). A
  # VariableMerge.merge/3 rejection WAS routed (see the amendment above: not any
  # more on this path) into an
  # ExecutionError.error_args() tagged {:execution_error, _} instead of
  # aborting this Multi.run/3 step, so the enclosing Ecto.Multi can still
  # commit an ERROR-transition tail (req061 §5.3) rather than rolling back
  # everything. `projection`,
  # `actor_id`, `idempotency_key` are threaded through here (widening this
  # function's own arity beyond req061 design doc §5.1's literal 2-arg
  # `merge_outcome_for/2` @spec -- flagged as a deliberate, safe deviation
  # for REVIEWER: error_args() needs `instance_id` (from the already-locked
  # `instance_projection`) and the caller's own `actor_id`/`idempotency_key`,
  # neither of which the design's own 2-arg signature has access to).
  #
  # REQ-109 widened this further, to /7: `repo` (which Ecto.Multi.run/3 has
  # always handed this step and which was previously discarded as `_repo`) and
  # `prefix` (already a closure variable of run_complete_task/6, used by the
  # sibling :task/:instance_projection/:snapshot_and_state/:transition steps)
  # are both needed by VariableSchema.variable_validations/5. The lookup key,
  # `projection.definition_id`, needs no new plumbing at all -- it rides on the
  # already-locked projection this function's first argument already carries.
  # Unlike the two {:execution_error, _} routings, a lookup failure is NOT a
  # business outcome: it returns {:error, _} and aborts the Multi (req109
  # §5.3).
  #
  # GH#310 / ISS-0091: this @spec's {:variable_schema_lookup_failed, _} member is
  # accurate to this function's own body (the `else` clause below still produces
  # it) but is, as of that issue, unreachable in practice -- both
  # VariableSchema.error_reason() members are foreclosed before this function is
  # ever called from complete_task/3 (see that function's own complete_error()
  # comment). Kept here deliberately: this is a private step function whose @spec
  # should describe what it can locally return, not what its one caller happens to
  # guarantee upstream. Do not read its presence here as contradicting
  # complete_error()'s narrower, public-facing union above.
  @spec merge_output_variables(
          InstanceProjection.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          current_variables :: map(),
          output_variables :: map(),
          output_labels :: %{String.t() => [String.t()]},
          repo :: module(),
          prefix :: String.t() | nil,
          refusal_context()
        ) ::
          {:ok,
           {:merged,
            %{
              new_variables: map(),
              new_labels: map(),
              merge_events: [VariableMerge.labelled_merge_event()]
            }}
           | {:execution_error, ExecutionError.error_args()}}
          | {:error, {:variable_schema_lookup_failed, VariableSchema.error_reason()}}
          | {:error, {:completion_refused, completion_refusal()}}
  defp merge_output_variables(
         projection,
         actor_id,
         idempotency_key,
         current_variables,
         output_variables,
         output_labels,
         repo,
         prefix,
         %{required: required, allowed: allowed}
       ) do
    # GH #2587 (decision 0054 D1a, design D-A1.3): a reserved key in the CORRECTED
    # output is a caller error, refused as a retryable 422 before the schema read and
    # before merge/3 (which would refuse it too, but into instance ERROR). Key names
    # only; the value is never carried.
    case VariableMerge.reserved_keys(output_variables) do
      [] ->
        merge_unreserved_output_variables(
          projection,
          actor_id,
          idempotency_key,
          current_variables,
          output_variables,
          output_labels,
          repo,
          prefix,
          required,
          allowed
        )

      reserved ->
        {:error, {:completion_refused, {:output_refused, [], reserved}}}
    end
  end

  defp merge_unreserved_output_variables(
         projection,
         actor_id,
         idempotency_key,
         current_variables,
         output_variables,
         output_labels,
         repo,
         prefix,
         required,
         allowed
       ) do
    with {:ok, variable_validations} <-
           VariableSchema.variable_validations(
             repo,
             projection.definition_id,
             current_variables,
             output_variables,
             prefix: prefix
           ) do
      # REQ-460 steps 6b-ii..iv (design req459 §2.2): required keys over the
      # CORRECTED map, then schema rejections restricted to the allowed names.
      missing = RequiredOutputs.missing_keys(required, output_variables)
      rejected = RequiredOutputs.rejected_keys(variable_validations, missing, allowed)

      if missing != [] or rejected != [] or RequiredOutputs.any_rejected?(variable_validations) do
        {:error, {:completion_refused, {:output_refused, missing, rejected}}}
      else
        apply_variable_merge(
          projection,
          actor_id,
          idempotency_key,
          current_variables,
          output_variables,
          output_labels,
          variable_validations
        )
      end
    else
      {:error, reason} -> {:error, {:variable_schema_lookup_failed, reason}}
    end
  end

  # REQ-460 (design req459 §2.2 step 4, halves 4a and 4c) plus REQ-463's 4b between
  # them (rule A, SeparationOfDuties.check/5: one query only when the node names a
  # distinct_from, none otherwise; 4c stays pure). 4b runs first: an authorization
  # decision (403) precedes input validation (422). Judges the SUBMITTED map, before form-expression
  # correction, so a caller error is refused before step 5's domain error could
  # commit an instance ERROR. Only the submitted map counts: a value the instance
  # already holds from an earlier pass never satisfies a required key.
  @spec check_completion_guards(
          module(),
          Graph.t(),
          Task.t(),
          map(),
          Ecto.UUID.t() | nil,
          String.t(),
          entity_plan() | nil
        ) ::
          {:ok, :guards_passed | :no_guards}
          | {:error, {:completion_refused, completion_refusal()}}
  defp check_completion_guards(
         repo,
         graph,
         %Task{} = task,
         output_variables,
         actor_id,
         prefix,
         plan
       ) do
    # GH #2587 PR B2 (CDV M1, D-B.3): AFTER separation of duties and required outputs, a
    # node that declares `entity_writes` while this completion has NO plan is refused
    # fail-closed (nothing committed, 500 through `entity_write_failed`). A node without
    # lines takes no new branch, so a completion without lines is byte-identical to before.
    with {:ok, _passed} = passed <-
           existing_completion_guards(repo, graph, task, output_variables, actor_id, prefix),
         :ok <- check_entity_writes_planned(graph, task, plan) do
      passed
    end
  end

  defp check_entity_writes_planned(_graph, _task, plan) when not is_nil(plan), do: :ok

  defp check_entity_writes_planned(graph, %Task{} = task, nil) do
    # GH #2590 R4b (design 6.3): `module_writes` counts like `entity_writes`. A node that declares
    # either while this completion has no plan (unreadable definition row, e.g. a deleted stamped
    # definition, OQ-R9) is refused, never executed without a readable stamp.
    case find_node(graph, task.node_id) do
      %{attributes: %{} = attributes} ->
        if Enum.any?(
             ["entity_writes", "module_writes"],
             &(Map.get(attributes, &1) not in [nil, []])
           ),
           do: {:error, {:completion_refused, :entity_writes_not_planned}},
           else: :ok

      _no_attributes ->
        :ok
    end
  end

  defp existing_completion_guards(repo, graph, %Task{} = task, output_variables, actor_id, prefix) do
    case SeparationOfDuties.check(repo, graph, task, actor_id, prefix) do
      {:error, {:separation_of_duties, _blocking_node_ids} = refusal} ->
        {:error, {:completion_refused, refusal}}

      :ok ->
        case RequiredOutputs.required_outputs(find_node(graph, task.node_id)) do
          [] ->
            guards_passed_or_none(graph, task)

          required ->
            case RequiredOutputs.missing_keys(required, output_variables) do
              [] -> {:ok, :guards_passed}
              missing -> {:error, {:completion_refused, {:output_refused, missing, []}}}
            end
        end
    end
  end

  # Payload only (no later step reads it): :guards_passed when the node carries a
  # distinct_from that passed, :no_guards when it carries neither attribute.
  defp guards_passed_or_none(graph, %Task{} = task) do
    case find_node(graph, task.node_id) do
      %{attributes: %{"distinct_from" => [_ | _]}} -> {:ok, :guards_passed}
      _ -> {:ok, :no_guards}
    end
  end

  defp find_node(%Graph{nodes: nodes}, node_id), do: Enum.find(nodes, &(&1.id == node_id))

  # The per-task data merge_output_variables/8 needs for rule C: the node's
  # required keys and the names a refusal may report (task's own pinned
  # form_schema.properties union required_outputs; INV-2).
  @spec refusal_context(Graph.t(), Task.t()) :: refusal_context()
  defp refusal_context(graph, %Task{} = task) do
    required = RequiredOutputs.required_outputs(find_node(graph, task.node_id))
    %{required: required, allowed: RequiredOutputs.allowed_keys(task.form_schema, required)}
  end

  @spec apply_variable_merge(
          InstanceProjection.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          current_variables :: map(),
          output_variables :: map(),
          output_labels :: %{String.t() => [String.t()]},
          VariableMerge.variable_validations()
        ) ::
          {:ok,
           {:merged,
            %{
              new_variables: map(),
              new_labels: map(),
              merge_events: [VariableMerge.labelled_merge_event()]
            }}
           | {:execution_error, ExecutionError.error_args()}}
  defp apply_variable_merge(
         projection,
         actor_id,
         idempotency_key,
         current_variables,
         output_variables,
         output_labels,
         variable_validations
       ) do
    # A human completion is an unlabelled source (decision 0062 R9); a computed field carries the
    # labels of its inputs (R14), so `output_labels` is the write for those keys.
    case VariableMerge.merge(
           current_variables,
           projection.variable_labels,
           output_variables,
           output_labels,
           variable_validations
         ) do
      {:ok, new_variables, new_labels, merge_events} ->
        {:ok,
         {:merged,
          %{new_variables: new_variables, new_labels: new_labels, merge_events: merge_events}}}

      # REQ-460: unreachable from merge_output_variables/8, which refuses every
      # schema rejection (422, no state change) before calling this function with
      # the very same validations. Retained as a last-resort guard so a future
      # caller of this helper can never silently drop a rejection.
      {:rejected, unchanged_variables,
       [{:execution_error, key, rejected_value, :variable_schema_rejected, failures}]} ->
        # decision 0062 SR-OPT-12: a labelled value is never echoed into the error details
        {rejected_value, failures} =
          VariableLabels.scrub_rejection(key, rejected_value, failures, output_labels)

        error_args = %{
          instance_id: projection.instance_id,
          error_type: :variable_schema_rejected,
          affected: {:field, key},
          reason: "variable '#{key}' failed schema validation",
          variables: unchanged_variables,
          details: %{rejected_value: rejected_value, failures: failures},
          actor_id: actor_id,
          idempotency_key: idempotency_key
        }

        {:ok, {:execution_error, error_args}}

      # GH #2587: equally unreachable from merge_output_variables/8, which refuses a
      # reserved key first. The value is never carried (D-A1.2).
      {:rejected, unchanged_variables,
       [{:execution_error, key, _rejected_value, :reserved_variable_key, _failures}]} ->
        error_args = %{
          instance_id: projection.instance_id,
          error_type: :reserved_variable_key,
          affected: {:field, key},
          reason: "variable '#{key}' is reserved",
          variables: unchanged_variables,
          details: %{},
          actor_id: actor_id,
          idempotency_key: idempotency_key
        }

        {:ok, {:execution_error, error_args}}
    end
  end

  # REQ-292 -- mirrors apply_variable_merge/6's own error_args construction
  # above, for a FormExpressionReevaluation.reevaluation_error() rather than
  # a VariableSchema rejection. Reuses the exact same
  # ExecutionError.append_multi/3 authority mechanism (design doc §5.3/§7):
  # the instance flips to :error, the task stays :pending, and
  # `merge_output_variables/7` is never called at all for this completion
  # (nothing was merged, so `variables` below is `current_variables`,
  # unchanged).
  @spec build_reevaluation_execution_error_args(
          FormExpressionReevaluation.reevaluation_error(),
          InstanceProjection.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          current_variables :: map()
        ) :: ExecutionError.error_args()
  defp build_reevaluation_execution_error_args(
         reevaluation_error,
         projection,
         actor_id,
         idempotency_key,
         current_variables
       ) do
    %{
      instance_id: projection.instance_id,
      error_type: reevaluation_error.error_type,
      affected: {:field, reevaluation_error.field},
      reason: reevaluation_error.reason,
      variables: current_variables,
      details: reevaluation_error.details,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }
  end

  # REQ-292 -- rides the two new FormExpressionReevaluation.reevaluation_event()
  # kinds inside the SAME merge_events list VariableMerge.merge/3 already
  # produces :variable_overwritten events into (design doc §2). Identity on
  # every other branch (an {:execution_error, _} from a corrected
  # submission still failing variable_schema_rejected, or the pre-existing,
  # effectively unreachable {:error, :variable_schema_lookup_failed} case) --
  # deliberate, non-load-bearing simplification (design doc §9 open question
  # 1): the submission is already being rejected on other grounds, so there
  # is nothing left to log a disagreement against.
  @spec prepend_form_expression_events(
          {:ok, {:merged, map()} | {:execution_error, map()}} | {:error, term()},
          [FormExpressionReevaluation.reevaluation_event()]
        ) :: {:ok, {:merged, map()} | {:execution_error, map()}} | {:error, term()}
  defp prepend_form_expression_events(
         {:ok, {:merged, %{merge_events: merge_events} = merged}},
         form_events
       ) do
    {:ok, {:merged, %{merged | merge_events: form_events ++ merge_events}}}
  end

  defp prepend_form_expression_events(other, _form_events), do: other

  # M5 -- the first {:complete_task, token_id} hop, then the existing
  # advance_until_stable/4 / tokens_needing_dispatch/3 worklist loop (reused
  # unchanged, design doc §1) for every subsequent {:advance_token, ...} hop.
  # Never returns a bare {:error, _} for REQ-050's own no-matching-edge case
  # (req061 §5.2) -- routed into an ExecutionError.error_args() tagged
  # {:execution_error, _} instead, same reasoning as merge_output_variables/2
  # above. This applies whether the no-matching-edge is discovered on the
  # completing task's own first Transition.transition/3 call (below) OR one
  # or more hops later inside advance_until_stable/4's internal worklist loop
  # (wrapped there as {:error, {:activation_failed, {:no_matching_edge, ...}}},
  # unwrapped and rewired in the `case advance_until_stable(...)` below) --
  # REQ-050's realistic trigger is a downstream gateway, so both call sites
  # must be covered, not just the same-hop case (rework iteration 1, was
  # previously only rewired for the same-hop case). Any *other*
  # Transition.transition/3 error (hop-limit, unimplemented node type, etc.)
  # is intentionally left unrewired (req061 §5.2/§12 OQ-4 -- only
  # {:no_matching_edge, ...} is in this requirement's named scope) and still
  # aborts the transaction via {:error, {:transition_failed, reason}} or
  # {:error, {:activation_failed, reason}} exactly as before.
  defp dispatch_task_completion_hop_chain(
         _snapshot_and_state,
         _projection,
         _actor_id,
         _idempotency_key,
         {:execution_error, error_args},
         _completed_at,
         _prefix
       ) do
    # M4 already fired (REQ-049's own rejection) -- pass-through, no
    # transition dispatched on top of a rejected merge (req061 §5.2).
    {:ok, {:execution_error, error_args}}
  end

  defp dispatch_task_completion_hop_chain(
         %{
           graph: graph,
           post_completion_seed: %InstanceState{} = seed_state,
           own_token_id: own_token_id,
           original_active_tokens: original_active_tokens
         },
         projection,
         actor_id,
         idempotency_key,
         {:merged, %{new_variables: merged_variables, new_labels: merged_labels}},
         completed_at,
         prefix
       ) do
    state_with_merged_variables =
      VariableLabels.put_merged(seed_state, merged_variables, merged_labels)

    hop_limit = length(graph.nodes) * 4 + 10

    case Transition.transition(graph, state_with_merged_variables, {:complete_task, own_token_id}) do
      {:ok, new_instance_state, _pending_events} ->
        newly_pending =
          tokens_needing_dispatch(
            state_with_merged_variables.tokens,
            new_instance_state.tokens,
            own_token_id
          )

        case advance_until_stable(graph, new_instance_state, newly_pending, hop_limit - 1) do
          {:ok, advanced_state, pending_events} ->
            # REQ-187 design doc §3 -- the symmetric {:timer_armed, ...}
            # preparation step, run alongside prepare_sub_process_children_for_completion/7
            # (both consume this same hop-chain's own pending_events).
            # completed_at doubles as "the arrival timestamp" here (AC1) --
            # the same instant this hop-chain landed at rest, matching
            # finalize_instance_projection/5's own completed_at/cancelled_at
            # reuse precedent -- no second clock read.
            with {:ok, prepared_timers} <-
                   prepare_timer_arms(pending_events, graph, projection.instance_id, completed_at),
                 {:ok, prepared_service_task_dispatches} <-
                   prepare_service_task_dispatch_for_completion(
                     pending_events,
                     graph,
                     projection,
                     advanced_state.variables,
                     advanced_state.variable_labels,
                     completed_at,
                     actor_id,
                     idempotency_key,
                     prefix
                   ) do
              case prepare_sub_process_children_for_completion(
                     advanced_state,
                     original_active_tokens,
                     graph,
                     pending_events,
                     projection,
                     actor_id,
                     idempotency_key,
                     prefix
                   ) do
                {:ok, {:advanced, advanced_state2, prepared_children}} ->
                  {:ok,
                   {:advanced, advanced_state2, prepared_children, prepared_timers,
                    prepared_service_task_dispatches}}

                {:ok, {:execution_error, error_args}} ->
                  {:ok, {:execution_error, error_args}}

                {:error, reason} ->
                  {:error, reason}
              end
            else
              {:error, {:empty_url_error, error_args}} ->
                {:ok, {:execution_error, error_args}}

              {:error, {:catalog_resolution_error, error_args}} ->
                {:ok, {:execution_error, error_args}}

              {:error, {:script_binding_error, error_args}} ->
                {:ok, {:execution_error, error_args}}

              {:error, {:restricted_outbound_error, error_args}} ->
                {:ok, {:execution_error, error_args}}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, {:activation_failed, {:no_matching_edge, node_id, evaluated_conditions}}} ->
            error_args =
              build_no_matching_gateway_edge_error_args(
                projection.instance_id,
                node_id,
                evaluated_conditions,
                state_with_merged_variables.variables,
                actor_id,
                idempotency_key
              )
              # The labels belong to the variables recorded above (decision 0062 R7a).
              |> Map.put(:labels, state_with_merged_variables.variable_labels)

            {:ok, {:execution_error, error_args}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, {:no_matching_edge, node_id, evaluated_conditions}} ->
        error_args =
          build_no_matching_gateway_edge_error_args(
            projection.instance_id,
            node_id,
            evaluated_conditions,
            state_with_merged_variables.variables,
            actor_id,
            idempotency_key
          )
          # The labels belong to the variables recorded above (decision 0062 R7a).
          |> Map.put(:labels, state_with_merged_variables.variable_labels)

        {:ok, {:execution_error, error_args}}

      {:error, reason} ->
        {:error, {:transition_failed, reason}}
    end
  end

  # REQ-215 design doc §2.1 point 1/§2.4 -- dispatch_task_completion_hop_chain/7's
  # own {:service_task_dispatch_requested, ...} pending_event() consumer.
  # Unlike the :TIMER-fire and create/2 call sites, the parent instance
  # already exists here and is already locked (M2,
  # fetch_and_lock_instance_projection/3), so an :empty_url_error routes
  # into the SAME {:execution_error, error_args} tagged-tuple channel
  # dispatch_task_completion_hop_chain/7's own :no_matching_edge clauses
  # already use (AC4) -- build_service_task_empty_url_error/5 builds the
  # exact standalone_error_attrs() shape ExecutionError.append_multi/3
  # expects. No service_task_dispatches row is ever inserted for this event
  # (structurally -- prepare_service_task_dispatch/5 halts before building
  # arm_attrs for it).
  defp prepare_service_task_dispatch_for_completion(
         pending_events,
         graph,
         projection,
         variables,
         variable_labels,
         now,
         actor_id,
         idempotency_key,
         prefix
       ) do
    # ISS-0917 -- pins are reconstructed lazily (only if a catalog node is
    # activated) under the row lock this hop already holds; tenant_id is
    # derived from the schema prefix, never from caller input (INV-PD-7).
    catalog_ctx = %{
      pin_source: {:reconstruct, projection.instance_id, prefix},
      tenant_id: {:schema_prefix, prefix},
      actor_id: actor_id,
      variable_labels: variable_labels
    }

    case prepare_service_task_dispatch(
           pending_events,
           graph,
           projection.instance_id,
           variables,
           now,
           catalog_ctx
         ) do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, reason} ->
        {:error, reason}

      # GH 2534 PR 7c-1 (design 4.4): routed into an ExecutionError like the catalog case
      # below (the projection is already locked on this path); fixed reason sentence, the
      # reason atom only in details.
      # GH #2616 part 2 (decision 0062 R12): the refusal is an EXECUTION_ERROR on the already-locked
      # projection, like the catalog and script cases below. Key names only in details.
      {:restricted_outbound_error, node_id, keys, variables} ->
        error_args =
          ServiceTask.build_restricted_outbound_error_attrs(%{
            instance_id: projection.instance_id,
            node_id: node_id,
            keys: keys,
            variables: variables,
            variable_labels: variable_labels,
            actor_id: actor_id,
            idempotency_key: idempotency_key
          })

        {:error, {:restricted_outbound_error, error_args}}

      # GH #2616 part 2 (decision 0062 R7a, R8h): every EXECUTION_ERROR written here snapshots
      # `variables` from the post-merge state, so it carries `variable_labels` from the same state.
      # Without them the event would fall back to the locked projection's labels, which miss the
      # keys a completion computes (R14), and the history of the event would show those values.
      {:script_binding_error, node_id, reason, variables} ->
        error_args = %{
          instance_id: projection.instance_id,
          error_type: :script_task_pin_unresolved,
          affected: {:node, node_id},
          reason: "script service task has no usable script pin recorded for this instance",
          variables: variables,
          labels: variable_labels,
          details: %{reason: reason},
          actor_id: actor_id,
          idempotency_key: idempotency_key
        }

        {:error, {:script_binding_error, error_args}}

      {:catalog_resolution_error, node_id, reason, variables} ->
        error_args =
          build_service_task_catalog_unresolved_error(
            projection.instance_id,
            node_id,
            reason,
            variables,
            variable_labels,
            actor_id,
            idempotency_key
          )

        {:error, {:catalog_resolution_error, error_args}}

      {:empty_url_error, node_id, variables} ->
        error_args =
          build_service_task_empty_url_error(
            projection.instance_id,
            node_id,
            variables,
            variable_labels,
            actor_id,
            idempotency_key
          )

        {:error, {:empty_url_error, error_args}}
    end
  end

  # req062 design doc §3.3 -- the dispatch_task_completion_hop_chain/6 call
  # site's own {:sub_process_start, ...} pending_event() consumer. Unlike
  # prepare_sub_process_children/5 (create/2's own call site), the parent
  # instance already exists here and is already locked (M2,
  # fetch_and_lock_instance_projection/3) -- an activation failure routes
  # into an {:execution_error, error_args} tagged tuple (req061 §5.2/§5.3's
  # own established channel) instead of aborting the whole transaction, so
  # ExecutionError.append_multi/3 still commits an ERROR-transition tail
  # against this already-locked projection.
  #
  # A derived (non-UUID-shaped) token_id reaching a SUB_PROCESS node within
  # this same hop chain (a PARALLEL_GATEWAY split/join branch landing there
  # before ever being persisted as its own tokens row) is not supported --
  # do_reconcile_token_records/4 already rejects any brand-new token_id
  # appearing during a complete_task/3 hop chain
  # ({:new_token_during_resume_not_supported, token_id}); this is the same,
  # pre-existing limitation surfaced earlier and with its own name, not a
  # new gap this requirement introduces.
  defp prepare_sub_process_children_for_completion(
         advanced_state,
         original_active_tokens,
         graph,
         pending_events,
         projection,
         actor_id,
         idempotency_key,
         prefix
       ) do
    sub_process_starts = Enum.filter(pending_events, &match?({:sub_process_start, _, _}, &1))
    persisted_token_ids = MapSet.new(original_active_tokens, &to_string(&1.id))

    sub_process_starts
    |> Enum.reduce_while({:ok, []}, fn {:sub_process_start, token_id, node_id}, {:ok, acc} ->
      with {:ok, parent_token_record_id} <-
             resolve_parent_token_record_id(token_id, persisted_token_ids),
           %Graph.Node{} = node <- Enum.find(graph.nodes, &(&1.id == node_id)) || :unknown_node,
           {:ok, prepared} <-
             SubProcess.prepare_child_activation(
               projection.instance_id,
               advanced_state.variables,
               node,
               parent_variable_labels: advanced_state.variable_labels,
               prefix: prefix
             ) do
        {:cont, {:ok, [{parent_token_record_id, prepared} | acc]}}
      else
        :unknown_node ->
          {:halt, {:error, {:unknown_node_id, node_id}}}

        {:error, {:sub_process_after_split_join_not_supported, _token_id} = reason} ->
          {:halt, {:error, reason}}

        {:error, failure} ->
          # GH #2616 part 2 (decision 0062 R7a): the snapshot is the post-merge state, so its labels travel too.
          error_args =
            failure
            |> SubProcess.to_error_args(
              projection.instance_id,
              node_id,
              advanced_state.variables,
              actor_id,
              idempotency_key
            )
            |> Map.put(:labels, advanced_state.variable_labels)

          {:halt, {:execution_error, error_args}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, {:advanced, advanced_state, Enum.reverse(acc)}}
      {:execution_error, error_args} -> {:ok, {:execution_error, error_args}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_parent_token_record_id(
          token_id :: String.t(),
          persisted_token_ids :: MapSet.t(String.t())
        ) ::
          {:ok, String.t()}
          | {:error, {:sub_process_after_split_join_not_supported, String.t()}}
  defp resolve_parent_token_record_id(token_id, persisted_token_ids) do
    if MapSet.member?(persisted_token_ids, token_id) do
      {:ok, token_id}
    else
      {:error, {:sub_process_after_split_join_not_supported, token_id}}
    end
  end

  # The req061 §5.3 Multi.merge/2 branch point -- replaces
  # build_task_activation_and_reconciliation_multi/3's former unconditional
  # call site. Inspects changes.transition first:
  #
  #   * {:execution_error, error_args} -- routes into
  #     ExecutionError.append_multi/3, reusing M2's own already-locked
  #     instance_projection (no second lock). None of the normal-path steps
  #     run: no task activation, no token reconciliation, no
  #     complete_task_row/5, no TASK_COMPLETED event, no reconcile_projection/5
  #     call. The task stays :pending; only the instance flips to :error.
  #   * {:advanced, final_instance_state} -- returns exactly the former
  #     unconditional tail (task activation, token reconciliation,
  #     complete_task_row/5, append_task_completed_event/5,
  #     reconcile_projection/5), each function's own body untouched --
  #     `normalized_changes` below unwraps the :merge/:transition tags those
  #     functions' own destructuring clauses were already written against,
  #     so none of them need editing.
  #
  # Both branches append one :complete_task_outcome marker step so
  # interpret_complete_result/1 can tell the two committed paths apart
  # without re-deriving it from which optional keys are present in the final
  # changes map.
  defp build_complete_task_tail_multi(
         %{transition: {:execution_error, error_args}, instance_projection: projection},
         _actor_id,
         _output_variables,
         _completed_at,
         _idempotency_key,
         _plan,
         prefix
       ) do
    Multi.new()
    |> ExecutionError.append_multi(error_args, prefix: prefix, locked_projection: projection)
    |> Multi.run(:complete_task_outcome, fn _repo, _changes ->
      {:ok, {:execution_error, error_args}}
    end)
  end

  defp build_complete_task_tail_multi(
         %{
           merge: {:merged, merge_outcome},
           transition:
             {:advanced, unfolded_instance_state, prepared_children, prepared_timers,
              prepared_service_task_dispatches}
         } = changes,
         actor_id,
         output_variables,
         completed_at,
         idempotency_key,
         plan,
         prefix
       ) do
    # GH #2587 PR B2 (F-3, D-B.10): the engine-only `_sys` values of this completion's
    # entity writes are folded (strict put_sys/3) into the final state the projection write
    # and the sub-process cascade read. A failed fold leaves it unfolded; the
    # :sys_variables_event step re-validates the same pairs and rolls the transaction back.
    final_instance_state =
      case Map.get(changes, :entity_writes) do
        %{sys_values: values} when map_size(values) > 0 ->
          case fold_sys_values(unfolded_instance_state, values) do
            {:ok, folded} -> folded
            {:error, _reason} -> unfolded_instance_state
          end

        _no_sys_values ->
          unfolded_instance_state
      end

    normalized_changes =
      changes
      |> Map.put(:merge, merge_outcome)
      |> Map.put(:transition, final_instance_state)

    parent_instance_id = normalized_changes.task.instance_id

    # ISS-0392 fix (design doc §2.2/§2.4, Revision 2, build-time skip/defer):
    # if any prepared_children entry's own graph already ran to completion
    # synchronously (child_initial_state.status == :completed, resolved in
    # plain Elixir by prepare_child_activation/4 before any Multi step for
    # that child exists), that child's own completion cascade
    # (SubProcess.maybe_chain_synchronous_completion/6 -> append_completion_multi/5
    # -> build_completion_write_steps/12, appended below via
    # append_sub_process_children_creation_multi/6) will append its own
    # {:task_records, parent_instance_id} step for this SAME parent_instance_id
    # -- colliding with the one build_task_activation_and_reconciliation_multi/4
    # would otherwise append here. Per §2.3's dominance argument, call (2)'s
    # diff strictly dominates call (1)'s, so call (1)'s task-activation step is
    # skipped entirely (not built, then replaced -- Ecto.Multi has no such
    # primitive, see design doc §2.1) whenever this predicate is true.
    skip_task_activation? =
      Enum.any?(prepared_children, fn {_parent_token_record_id, prepared} ->
        prepared.child_initial_state.status == :completed
      end)

    # GH #2359: runs BEFORE the timer-arm steps below (status-guarded only on
    # "pending"), so a same-node re-entry's freshly armed escalation timer is
    # not cancelled along with the completed task's own.
    #
    # GH #2695 / #2704: the ancestor group (P_p, T_p) is NOT taken here any more: it is the
    # `:lock_ancestors` step of build_complete_task_multi/7, right after :transition and before
    # the entity-type rows, so every tail write below follows it.
    Multi.new()
    |> Multi.run(:cancel_escalation_timers, fn repo, _changes ->
      # ISS-0925: a normally-completed HUMAN_TASK must not leave its escalation
      # timer pending (it would fire later against whatever node the token is on).
      TaskActivation.cancel_pending_escalation_timers(
        repo,
        normalized_changes.task.instance_id,
        normalized_changes.task.token_id,
        normalized_changes.task.node_id,
        completed_at,
        prefix
      )
    end)
    # REQ-494 design §4.2: same position argument -- the completed task's
    # pending reminders (incl. re-armed successors) are cancelled before the
    # arm steps, so a same-node re-entry's fresh reminder survives.
    |> Multi.run(:cancel_reminder_timers, fn repo, _changes ->
      TaskActivation.cancel_pending_reminder_timers(
        repo,
        normalized_changes.task.instance_id,
        normalized_changes.task.token_id,
        normalized_changes.task.node_id,
        completed_at,
        "task_completed",
        prefix
      )
    end)
    |> Multi.append(
      build_task_activation_and_reconciliation_multi(
        normalized_changes,
        completed_at,
        prefix,
        skip_task_activation?
      )
    )
    |> Multi.merge(fn changes ->
      # REQ-187 design doc §3.2 -- positioned immediately after
      # :token_reconciliation (the step that resolves real TokenRecord ids
      # here -- every token_id in final_instance_state is already a real,
      # persisted TokenRecord id by construction, do_reconcile_token_records/4's
      # own {:new_token_during_resume_not_supported, _} guard forecloses
      # anything else) and before :event. Citation correction (CODE-DESIGN-VALIDATOR,
      # design doc §13 item 3): append_sub_process_children_creation_multi/6
      # actually sits AFTER :event/:projection below, not before -- this
      # step's own placement here follows the design's explicit instruction,
      # not that (incorrect) precedent claim.
      #
      # ISS-0974 fix: a PARALLEL_GATEWAY join firing within this same hop
      # chain can mint a token_id that is NOT yet a real, persisted
      # TokenRecord id at this point -- build_task_activation_and_reconciliation_multi/4
      # (called just above, in the same pipe) already resolved the real
      # mapping via insert_hop_chain_new_token_records/5 and stashed it in
      # `changes` under {:hop_chain_token_records, parent_instance_id}. Read
      # it back out and fall back to identity for every token_id it doesn't
      # cover (the sparse/common "no join fired" case) instead of assuming
      # every token_id is already real.
      {hop_chain_id_map, _hop_chain_new_records} =
        Map.fetch!(changes, {:hop_chain_token_records, parent_instance_id})

      id_map =
        Map.new(prepared_timers, fn {token_id, _arm_attrs} ->
          {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
        end)

      build_timer_arms_multi(Multi.new(), prepared_timers, id_map, prefix)
    end)
    |> Multi.merge(fn changes ->
      # REQ-215 design doc §2.1 point 1/§2.5 -- positioned alongside the
      # timer-arms merge immediately above, same ISS-0974 real-id_map
      # reasoning (every token_id in prepared_service_task_dispatches is
      # mapped to its real, persisted TokenRecord id, whether it was already
      # real or was minted fresh by a same-hop-chain join).
      # `prefix` was already validated by this function's own caller
      # (complete_task/3's top-level `with` chain) -- the error branch here
      # is unreachable in practice, but matched via `with` rather than a
      # bare `=` so a future invariant break surfaces as a typed Multi
      # error instead of a MatchError, consistent with this module's own
      # with/<- idiom elsewhere (e.g. create/2, persist_timer_fired_advance/7).
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
        {hop_chain_id_map, _hop_chain_new_records} =
          Map.fetch!(changes, {:hop_chain_token_records, parent_instance_id})

        id_map =
          Map.new(prepared_service_task_dispatches, fn %{token_id: token_id} ->
            {token_id, Map.get(hop_chain_id_map, token_id, token_id)}
          end)

        build_service_task_dispatch_multi(
          Multi.new(),
          prepared_service_task_dispatches,
          id_map,
          tenant_id,
          prefix
        )
      else
        {:error, reason} ->
          Multi.error(Multi.new(), :service_task_dispatch_tenant_lookup, reason)
      end
    end)
    |> Multi.run(:task_complete, fn repo, _changes ->
      complete_task_row(
        repo,
        normalized_changes.task,
        actor_id,
        output_variables,
        completed_at,
        prefix
      )
    end)
    |> Multi.merge(fn changes ->
      record_task_complete_audit(normalized_changes.task, changes, actor_id, prefix)
    end)
    |> append_entity_write_tail(
      Map.get(changes, :entity_writes),
      plan,
      normalized_changes.task,
      actor_id,
      idempotency_key,
      prefix
    )
    |> Multi.run(:event, fn _repo, _changes ->
      append_task_completed_event(
        normalized_changes,
        output_variables,
        actor_id,
        idempotency_key,
        prefix
      )
    end)
    |> Multi.run(:projection, fn repo, _changes ->
      reconcile_projection(
        repo,
        normalized_changes.instance_projection,
        final_instance_state,
        completed_at,
        prefix
      )
    end)
    |> append_sub_process_children_creation_multi(
      prepared_children,
      parent_instance_id,
      actor_id,
      idempotency_key,
      prefix
    )
    |> append_sub_process_completion_cascade_multi(
      parent_instance_id,
      final_instance_state,
      actor_id,
      idempotency_key,
      prefix
    )
    |> Multi.run(:complete_task_outcome, fn _repo, _changes -> {:ok, :completed} end)
  end

  # req062 design doc §3.3 -- appends each child spawned by this hop chain's
  # own newly-entered SUB_PROCESS node(s) (already prepared/pre-validated by
  # prepare_sub_process_children_for_completion/7, above -- a failure there
  # already short-circuited into the execution_error clause instead of
  # reaching this function at all).
  defp append_sub_process_children_creation_multi(
         multi,
         prepared_children,
         parent_instance_id,
         actor_id,
         idempotency_key,
         prefix
       ) do
    Enum.reduce(prepared_children, multi, fn {parent_token_record_id, prepared}, acc_multi ->
      SubProcess.append_start_multi(
        acc_multi,
        parent_instance_id,
        parent_token_record_id,
        prepared.node_id,
        prepared,
        %{actor_id: actor_id, idempotency_key: idempotency_key},
        prefix: prefix
      )
    end)
  end

  # req062 design doc §3.4 -- the OTHER direction: this instance (the one
  # whose task just completed) may itself be a sub-process child. If it just
  # reached :completed as a result, look up its own waiting parent token
  # (Letflow.Engine.SubProcess.find_waiting_parent_token/3) and, if one
  # exists, cascade the parent's own completion steps into this same
  # transaction (Letflow.Engine.SubProcess.append_completion_multi/6) --
  # recursing grandparent-ward internally when the cascade itself completes
  # a further ancestor.
  defp append_sub_process_completion_cascade_multi(
         multi,
         instance_id,
         %InstanceState{status: :completed} = final_instance_state,
         actor_id,
         idempotency_key,
         prefix
       ) do
    lookup_key = {:sub_process_parent_lookup, instance_id}

    multi
    |> Multi.run(lookup_key, fn repo, _changes ->
      SubProcess.find_waiting_parent_token(repo, instance_id, prefix)
    end)
    |> Multi.merge(fn changes ->
      # Multi.run/3 stores the unwrapped ok-value in `changes`, not the
      # {:ok, _} tuple find_waiting_parent_token/3 itself returns -- match
      # the raw value here, not the tuple.
      case Map.fetch!(changes, lookup_key) do
        nil ->
          Multi.new()

        %TokenRecord{} = parent_token ->
          case SubProcess.append_completion_multi(
                 Multi.new(),
                 instance_id,
                 final_instance_state.variables,
                 parent_token,
                 child_final_labels: final_instance_state.variable_labels,
                 prefix: prefix,
                 actor_id: actor_id,
                 idempotency_key: idempotency_key
               ) do
            {:ok, cascade_multi} ->
              cascade_multi

            {:error, error_args} ->
              Multi.new() |> ExecutionError.append_multi(error_args, prefix: prefix)
          end
      end
    end)
  end

  defp append_sub_process_completion_cascade_multi(
         multi,
         _instance_id,
         _final_instance_state,
         _actor_id,
         _idempotency_key,
         _prefix
       ),
       do: multi

  # M6/M7 -- built together via Multi.merge/2 (the idiomatic Ecto mechanism
  # for appending Multi steps whose concrete arguments are only known once
  # earlier steps have run inside this same transaction): task activation for
  # any freshly-reached :HUMAN_TASK node(s) (design doc §9,
  # TaskActivation.append_multi_from_existing_records/6), then token-record
  # reconciliation (design doc §8.2). Neither of these two steps' own
  # callback bodies reads from `changes` once called -- both close over
  # already-resolved plain values, matching each function's own @spec.
  #
  # ISS-0392 fix (design doc §2.5): gains `skip_task_activation? :: boolean()`
  # as its 4th parameter. When true, the {:task_records, instance_id} step is
  # omitted entirely (see maybe_append_task_activation_multi/7 below) --
  # return type is unchanged, still a bare Multi.t().
  defp build_task_activation_and_reconciliation_multi(
         changes,
         completed_at,
         prefix,
         skip_task_activation?
       ) do
    %{
      task: task,
      snapshot_and_state: %{
        graph: graph,
        post_completion_seed: seed_state,
        original_active_tokens: original_active_tokens
      },
      transition: final_instance_state
    } = changes

    instance_id = task.instance_id

    # ISS-0408 fix (design doc §3.4): the insert-hop-chain-new-token-records
    # step and its final_instance_state rewrite must run, inside the
    # transaction, before either maybe_append_task_activation_multi/7 or
    # reconcile_token_records/5 sees final_instance_state -- both assume
    # every token_id they see already names a real, persisted TokenRecord
    # row, which is only true post-rewrite for a hop chain that fired a
    # PARALLEL_GATEWAY join. Wrapped in one Multi.merge/2 so the rewritten
    # state can be threaded as a plain local into both sibling steps rather
    # than re-read from `changes`.
    Multi.new()
    |> Multi.merge(fn _changes ->
      Multi.new()
      |> Multi.run({:hop_chain_token_records, instance_id}, fn repo, _changes ->
        insert_hop_chain_new_token_records(
          repo,
          instance_id,
          original_active_tokens,
          final_instance_state.tokens,
          prefix
        )
      end)
      |> Multi.merge(fn changes ->
        {id_map, hop_chain_new_records} =
          Map.fetch!(changes, {:hop_chain_token_records, instance_id})

        resolved_final_instance_state = rewrite_token_ids(final_instance_state, id_map)

        Multi.new()
        |> maybe_append_task_activation_multi(
          skip_task_activation?,
          instance_id,
          graph,
          seed_state.pending_task_nodes,
          resolved_final_instance_state,
          prefix
        )
        |> reconcile_token_records(
          hop_chain_new_records ++ original_active_tokens,
          resolved_final_instance_state,
          completed_at,
          prefix
        )
      end)
    end)
  end

  # ISS-0392 fix (design doc §2.4) -- when skip_task_activation? is true, a
  # synchronously-completing SUB_PROCESS child's own completion cascade is
  # the sole appender of {:task_records, parent_instance_id} for this hop
  # chain (see build_complete_task_tail_multi/6's own predicate comment
  # above); this function must NOT append that step in that case. When
  # false, behavior is byte-for-byte what this call did before this fix.
  defp maybe_append_task_activation_multi(
         multi,
         true = _skip_task_activation?,
         _instance_id,
         _graph,
         _previous_pending_task_nodes,
         _final_instance_state,
         _prefix
       ) do
    multi
  end

  defp maybe_append_task_activation_multi(
         multi,
         false = _skip_task_activation?,
         instance_id,
         graph,
         previous_pending_task_nodes,
         final_instance_state,
         prefix
       ) do
    TaskActivation.append_multi_from_existing_records(
      multi,
      instance_id,
      graph,
      previous_pending_task_nodes,
      final_instance_state,
      prefix
    )
  end

  # ISS-0408 fix (design doc §3.2) -- inserts a real TokenRecord row for
  # every token in final_tokens that is genuinely new within this hop chain
  # (i.e. its pure token_id is not one of original_active_tokens' own real,
  # DB-loaded ids) -- today this is only ever a PARALLEL_GATEWAY join-merged
  # token (Transition.fire_join/5's derived
  # "<origin>/<join_node>/joined" string), minted before task-activation and
  # token-reconciliation run so both see an already-real TokenRecord id,
  # exactly as if the token had existed before this hop chain started.
  #
  # Returns BOTH the {synthetic_token_id => real_id} map (rewrite_token_ids/2's
  # own input) AND the freshly-inserted [TokenRecord.t()] list itself --
  # design doc §5.2 states do_reconcile_token_records/5's own `original_ids`
  # membership guard should "just work" post-rewrite without being modified,
  # but that guard is built strictly from whatever `original_tokens` list its
  # caller passes it (engine.ex's own do_reconcile_token_records/5,
  # unmodified per this design's own explicit instruction) -- a token this
  # step JUST inserted is, definitionally, not a member of
  # original_active_tokens (loaded at hop-chain-seed time, before this step
  # ran). Reconciling that gap without editing do_reconcile_token_records/5
  # itself means its caller (reconcile_token_records/5's own call site, both
  # of them) must pass an original_tokens list that already includes these
  # just-inserted records -- true and correct by the time reconciliation
  # runs (later in the same transaction), not a widening of what "original"
  # means, just an accurate accounting of what already exists in the DB at
  # the point the guard actually executes.
  #
  # The empty-set case (the overwhelming majority of hop chains -- no join
  # fired) returns {:ok, {%{}, []}} with no Repo call at all, matching
  # insert_token_records/4's and TaskActivation.append_multi/6's own
  # newly_pending == []/[]-clause fast paths.
  #
  # ISS-0975: `defp` -> `def`/@doc false -- Letflow.Engine.SubProcess's own
  # completion path (build_completion_write_steps/13) needs this exact same
  # insert-before-reconcile treatment and has no local reason to duplicate
  # it (design doc §1.1): this function's own Multi step key is always the
  # caller's responsibility, so there is nothing collision-prone inside it
  # to justify a sub_process.ex-local copy, unlike reconcile_parent_tokens/5.
  @doc false
  @spec insert_hop_chain_new_token_records(
          repo :: Ecto.Repo.t(),
          instance_id :: Ecto.UUID.t(),
          original_active_tokens :: [TokenRecord.t()],
          final_tokens :: [Token.t()],
          prefix :: String.t()
        ) ::
          {:ok, {%{optional(String.t()) => Ecto.UUID.t()}, [TokenRecord.t()]}}
          | {:error, term()}
  def insert_hop_chain_new_token_records(
        repo,
        instance_id,
        original_active_tokens,
        final_tokens,
        prefix
      ) do
    original_ids = MapSet.new(original_active_tokens, &to_string(&1.id))

    hop_chain_new_tokens =
      Enum.filter(final_tokens, &(not MapSet.member?(original_ids, &1.token_id)))

    case hop_chain_new_tokens do
      [] ->
        {:ok, {%{}, []}}

      _ ->
        hop_chain_new_tokens
        |> Enum.reduce_while({:ok, {%{}, []}}, fn %Token{} = token, {:ok, {id_map, records}} ->
          case insert_token_record(repo, instance_id, token, prefix) do
            {:ok, %TokenRecord{} = record} ->
              {:cont, {:ok, {Map.put(id_map, token.token_id, record.id), [record | records]}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
    end
  end

  # ISS-0408 fix (design doc §3.4) -- pure rewrite of final_instance_state's
  # own .tokens list, replacing each synthetic (hop-chain-local-new)
  # token_id with the real TokenRecord id insert_hop_chain_new_token_records/5
  # just assigned it, stringified to match to_pure_token/1's own
  # to_string(record.id) convention. id_map == %{} (no join fired this hop
  # chain) is a no-op: instance_state is returned unchanged rather than
  # rebuilding an identical tokens list.
  #
  # ISS-0975: `defp` -> `def`/@doc false, same cross-module-reuse reason as
  # insert_hop_chain_new_token_records/5 immediately above (design doc §1.1).
  @doc false
  @spec rewrite_token_ids(InstanceState.t(), %{optional(String.t()) => Ecto.UUID.t()}) ::
          InstanceState.t()
  def rewrite_token_ids(%InstanceState{} = instance_state, id_map) when id_map == %{} do
    instance_state
  end

  def rewrite_token_ids(%InstanceState{} = instance_state, id_map) do
    # Rewrites BOTH .tokens and .pending_task_nodes: dispatch_human_task/3
    # (transition.ex:385-389) appends the just-dispatched Token struct (at
    # whatever token_id it carried at dispatch time -- the synthetic
    # join-derived id, for a join-then-HUMAN_TASK hop) to its own separate
    # pending_task_nodes list, not a reference into .tokens -- so a token
    # that is both the join's own final resting token AND newly-pending
    # (the ISS-0408 scenario) has two independent copies of the same
    # pre-rewrite token_id that both need the same substitution for
    # TaskActivation.newly_pending_tokens/2's own diff (which reads
    # .pending_task_nodes, not .tokens) to see a real id.
    rewrite_one = fn %Token{} = token ->
      case Map.fetch(id_map, token.token_id) do
        {:ok, real_id} -> %Token{token | token_id: to_string(real_id)}
        :error -> token
      end
    end

    %InstanceState{
      instance_state
      | tokens: Enum.map(instance_state.tokens, rewrite_one),
        pending_task_nodes: Enum.map(instance_state.pending_task_nodes, rewrite_one)
    }
  end

  # §8.2 -- new function. Advances/completes existing tokens rows to match
  # final_instance_state's final token positions; a token_id present in
  # final_instance_state.tokens with no matching original record is a typed,
  # rolled-back failure (INV-EE48-8), never a silent mis-insert.
  defp reconcile_token_records(
         %Multi{} = multi,
         original_active_tokens,
         %InstanceState{} = final_instance_state,
         completed_at,
         prefix
       ) do
    Multi.run(multi, :token_reconciliation, fn repo, _changes ->
      do_reconcile_token_records(
        repo,
        original_active_tokens,
        final_instance_state.tokens,
        completed_at,
        prefix
      )
    end)
  end

  defp do_reconcile_token_records(repo, original_tokens, final_tokens, completed_at, prefix) do
    original_ids = MapSet.new(original_tokens, &to_string(&1.id))

    case Enum.find(final_tokens, &(not MapSet.member?(original_ids, &1.token_id))) do
      %Token{token_id: token_id} ->
        {:error, {:new_token_during_resume_not_supported, token_id}}

      nil ->
        final_by_id = Map.new(final_tokens, &{&1.token_id, &1})

        original_tokens
        |> Enum.reduce_while({:ok, []}, fn %TokenRecord{} = record, {:ok, acc} ->
          case reconcile_one_token_record(repo, record, final_by_id, completed_at, prefix) do
            {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reconcile_one_token_record(
         repo,
         %TokenRecord{} = record,
         final_by_id,
         completed_at,
         prefix
       ) do
    case Map.fetch(final_by_id, to_string(record.id)) do
      {:ok, %Token{node_id: node_id}} when node_id != record.node_id ->
        update_token_record(repo, record, %{node_id: node_id}, prefix)

      {:ok, _unchanged} ->
        {:ok, record}

      :error ->
        update_token_record(
          repo,
          record,
          %{status: :completed, completed_at: completed_at},
          prefix
        )
    end
  end

  defp update_token_record(repo, %TokenRecord{} = record, attrs, prefix) do
    record
    |> TokenRecord.advance_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # M8 -- flips the tasks row to COMPLETED (design doc §8, table row M8).
  # output_variables here is the caller's original, unmerged map -- the
  # task's own record of what it submitted.
  # REQ-195 -- complete_task/3's own actor_id (attrs[:actor_id], already an
  # explicit, required argument) is real, non-nil. `before_task` is the
  # pre-complete row (`normalized_changes.task`, fetched+locked earlier in
  # this same Multi); `changes.task_complete` is the post-complete row
  # `:task_complete` just produced.
  defp record_task_complete_audit(before_task, changes, actor_id, prefix) do
    updated = Map.fetch!(changes, :task_complete)

    Audit.append_multi(
      Multi.new(),
      :audit,
      %{
        actor_id: actor_id,
        action: "task.complete",
        resource_type: "task",
        resource_id: before_task.id,
        before_state: Task.audit_state(before_task),
        after_state: Task.audit_state(updated),
        trace_id: nil
      },
      prefix
    )
  end

  # ISS-0784 (`lib/letflow/design/iss0784-task-activation-rollback-audit-signal.md`)
  # -- records that a task-activation attempt was rejected by
  # `TaskActivation.resolve_form_schema/1`'s `{:invalid_form_schema, node_id,
  # reason}` check and the enclosing transaction was rolled back per INV-8.
  #
  # Called from the failure branch of each of the four
  # `{:error, _failed_step, reason, _changes} -> {:error, reason}` unwrap
  # points (design §2/§3) -- NEVER as a step folded into the Multi that just
  # failed, because `Ecto.Multi`'s all-or-nothing semantics would roll this
  # write back right along with the failed attempt it's meant to record
  # (design §3). This function opens its own, independent
  # `Repo.transaction/1`, run and awaited synchronously, and must only ever
  # be invoked once the DB-level transaction that produced the rejection has
  # genuinely closed (committed or rolled back) -- not merely "returned
  # `{:error, ...}` from an inner `Ecto.Multi`" if that inner call itself
  # runs nested inside a still-open outer transaction.
  #
  # ISS-0784 follow-up fix -- sites 1/2 (`interpret_create_result/8`,
  # `interpret_complete_result/3`, both above, in this module) call this
  # directly from their own inline clause, because `create/2`/
  # `complete_task/3` open the *only* transaction on those call paths, so
  # `repo.transaction(multi)` returning `{:error, ...}` there really does
  # mean the DB-level transaction has closed. Sites 3/4
  # (`persist_timer_fired_advance/7`, `do_persist_service_task_advance/10`,
  # both above) do NOT call this directly any more -- TEST-DESIGNER proved
  # against real Postgres that both are reached from inside a further-out
  # caller's own already-open transaction
  # (`Letflow.Scheduler.fire_timer/2`, `Letflow.Engine.advance_after_service_task_outcome/4`
  # respectively), so calling this function from inside those two inline
  # clauses would only ever write into that same still-open outer
  # transaction and be rolled back with it. This function is `@doc false def`
  # (not `defp`) specifically so `Letflow.Scheduler.attempt_fire/2` and
  # `Letflow.Engine.ServiceTaskDispatcher.call_advance_after_service_task_outcome/3`
  # can call it themselves, strictly after their own respective outer
  # transaction has fully returned.
  #
  # Best-effort per design §6, matching `snapshot_instance/4`'s own
  # established "log and swallow" convention (~line 1465): a failure writing
  # this audit entry is logged via `Logger.warning/1` and never propagated --
  # it must never turn the original `{:invalid_form_schema, ...}` rollback
  # into a different error, and must never raise.
  @doc false
  @spec record_task_activation_rejection_audit(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          reason :: {:not_well_formed, path :: [String.t()]} | :too_deep,
          actor_id :: Ecto.UUID.t() | nil,
          prefix :: String.t()
        ) :: :ok
  def record_task_activation_rejection_audit(instance_id, node_id, reason, actor_id, prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "task_activation.rejected",
      resource_type: "instance",
      resource_id: instance_id,
      before_state: nil,
      after_state: %{
        "node_id" => node_id,
        "reason" => encode_form_schema_rejection_reason(reason)
      },
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording task_activation.rejected for " <>
            "instance #{instance_id} (node #{node_id}): #{inspect(insert_reason)}"
        )

        :ok

      {:error, rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording task_activation.rejected for instance " <>
            "#{instance_id} (node #{node_id}): #{inspect(rollback_reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording task_activation.rejected for instance " <>
          "#{instance_id} (node #{node_id}): #{inspect(exception)}"
      )

      :ok
  end

  # REQ-460 (design req459 §2.4, §5) -- one `task.completion_refused` audit record
  # for a refused HUMAN_TASK completion. Same shape and rules as
  # record_task_activation_rejection_audit/5 above: its own synchronous
  # Repo.transaction/1, direct Audit.insert_entry/3 (never append_multi/4, which hides
  # the same call), opened only after the refused transaction has returned, function-
  # level rescue, log-and-swallow, always :ok. Guarantee: AT MOST ONE record per
  # refused request, exactly one when the audit store is healthy. Carries ids and
  # key NAMES only -- never a submitted value, name or email. Must not be called
  # inside an enclosing transaction (it would roll back with it); the one caller is
  # interpret_complete_result/3.
  @doc false
  @spec record_completion_refusal_audit(
          instance_id :: Ecto.UUID.t(),
          task_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          actor_id :: Ecto.UUID.t() | nil,
          refusal :: completion_refusal(),
          prefix :: String.t()
        ) :: :ok
  def record_completion_refusal_audit(instance_id, task_id, node_id, actor_id, refusal, prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "task.completion_refused",
      resource_type: "task",
      resource_id: task_id,
      before_state: nil,
      after_state: completion_refusal_after_state(refusal, instance_id, node_id),
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording task.completion_refused for task " <>
            "#{task_id}: #{inspect(insert_reason)}"
        )

        :ok

      {:error, rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording task.completion_refused for task " <>
            "#{task_id}: #{inspect(rollback_reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording task.completion_refused for task " <>
          "#{task_id}: #{inspect(exception)}"
      )

      :ok
  end

  # Rule A (REQ-463) records the sorted blocking node ids (the earlier completer is
  # the actor, so no other user id is repeated); rule C records key names only.
  defp completion_refusal_after_state(
         {:separation_of_duties, blocking_node_ids},
         instance_id,
         node_id
       ) do
    %{
      "rule" => "separation_of_duties",
      "instance_id" => instance_id,
      "node_id" => node_id,
      "blocking_node_ids" => Enum.sort(blocking_node_ids)
    }
  end

  defp completion_refusal_after_state(
         {:output_refused, missing_keys, rejected_keys},
         instance_id,
         node_id
       ) do
    %{
      "rule" => "output_refused",
      "instance_id" => instance_id,
      "node_id" => node_id,
      "missing_keys" => missing_keys,
      "rejected_keys" => rejected_keys
    }
  end

  # ISS-0928 -- best-effort audit for a SERVICE_TASK re-entry failure that is
  # NOT routed to an ExecutionError (hop limit, unknown token, variable-merge
  # rejection, DB failure ...). Called by
  # `ServiceTaskDispatcher.call_advance_after_service_task_outcome/3` strictly
  # after `advance_after_service_task_outcome/4` has returned, same
  # post-return rule and log-and-swallow, never-raise contract as
  # `record_task_activation_rejection_audit/5`. Stores/logs only ids and an
  # atom tag, never the failure reason (it can hold variables / response body).
  @doc false
  @spec record_service_task_advance_failure_audit(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t() | nil,
          reason_tag :: atom(),
          actor_id :: Ecto.UUID.t() | nil,
          prefix :: String.t()
        ) :: :ok
  def record_service_task_advance_failure_audit(
        instance_id,
        node_id,
        reason_tag,
        actor_id,
        prefix
      ) do
    attrs = %{
      actor_id: actor_id,
      action: "service_task.advance_failed",
      resource_type: "instance",
      resource_id: instance_id,
      before_state: nil,
      after_state: %{"node_id" => node_id, "reason" => Atom.to_string(reason_tag)},
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, _insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording service_task.advance_failed for " <>
            "instance #{instance_id} (node #{node_id}, reason #{reason_tag})"
        )

        :ok

      {:error, _rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording service_task.advance_failed for instance " <>
            "#{instance_id} (node #{node_id}, reason #{reason_tag})"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording service_task.advance_failed for instance " <>
          "#{instance_id} (node #{node_id}, reason #{reason_tag}): #{inspect(exception)}"
      )

      :ok
  end

  # ISS-0784 design §4.2 -- exhaustive encoder over
  # `Letflow.Definitions.JsonSchemaShape.check/1`'s own two-member error
  # union (minus the outer `:error` tag), for a JSON-safe `after_state`.
  # Deliberately has no catch-all clause: if that union ever grows a third
  # member, this fails to compile until updated (design §4.2/§10 OQ-2), which
  # is the intended signal rather than a silently masked new rejection shape.
  @spec encode_form_schema_rejection_reason({:not_well_formed, path :: [String.t()]} | :too_deep) ::
          map()
  defp encode_form_schema_rejection_reason({:not_well_formed, path}) do
    %{"code" => "not_well_formed", "path" => path}
  end

  defp encode_form_schema_rejection_reason(:too_deep) do
    %{"code" => "too_deep", "path" => nil}
  end

  defp complete_task_row(repo, %Task{} = task, actor_id, output_variables, completed_at, prefix) do
    attrs = %{
      status: :completed,
      completed_by: actor_id,
      completed_at: completed_at,
      output_variables: output_variables
    }

    task
    |> Task.complete_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # M9 -- appends the TASK_COMPLETED event (design doc §10, EE-04 AC1,
  # REQ-025). merge_events (VARIABLE_OVERWRITTEN outcomes) are embedded as
  # informational metadata inside this one event's payload, never appended
  # as their own separate rows (INV-EE48-5).
  #
  # REQ-391 §3.2 -- attachments_at_decision is read and embedded INSIDE this
  # same Multi/transaction (unlike Letflow.Repository.Attachments' own
  # post-commit, best-effort ATTACHMENT_ATTACHED/REMOVED events, §2.3):
  # active_instance_guard already proved the instance is ACTIVE earlier in
  # this same Multi, so there is no terminated-instance edge case to protect
  # against here, and no reason to weaken the existing all-or-nothing
  # completion guarantee.
  defp append_task_completed_event(changes, output_variables, actor_id, idempotency_key, prefix) do
    %{
      task: task,
      merge: %{merge_events: merge_events} = merge,
      transition: final_instance_state
    } = changes

    # Labels of the keys this completion wrote (always empty for a human completer, R9).
    output_labels = VariableLabels.take(Map.get(merge, :new_labels, %{}), output_variables)

    attachments_at_decision =
      task.instance_id
      |> Attachments.list_all_for_instance(prefix: prefix)
      |> Enum.map(&attachment_snapshot/1)

    payload =
      %{
        task_id: task.id,
        node_id: task.node_id,
        output_variables: output_variables,
        merged_variable_events: VariableLabels.encode_merge_events(merge_events),
        activated_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
        attachments_at_decision: attachments_at_decision
      }
      |> VariableLabels.put_label_field(:output_labels, output_labels)
      |> Jason.encode!()

    event_attrs = %{
      instance_id: task.instance_id,
      event_type: "TASK_COMPLETED",
      payload: payload,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} = replay -> replay
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # REQ-391 §3.3 -- field selection mirrors attachment_json/1's existing
  # INV-2 allowlist (lib/letflow/routers/instances.ex) minus instance_id/
  # description (redundant at this scope); content_hash is deliberately
  # excluded, same reasoning as that allowlist's own comment ("never
  # included"). Embedded directly into the immutable TASK_COMPLETED payload
  # (design §4) -- a snapshot, not a bare attachment_id requiring a later
  # lookup, so it survives a subsequent delete/2 call on the same attachment
  # (delete/2 is a hard delete, no tombstone).
  defp attachment_snapshot(%Letflow.Repository.Attachment{} = attachment) do
    %{
      attachment_id: attachment.id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      byte_size: attachment.byte_size,
      uploaded_by: attachment.uploaded_by,
      created_at: DateTime.to_iso8601(attachment.created_at)
    }
  end

  # M10 -- projection reconciliation (design doc §8.3). last_event_seq is not
  # set here -- EventStore.append/2's own update_projection/3 (M9's own
  # nested Multi) already advances it as part of the :event step above.
  #
  # join_counters is persisted unconditionally on every call (ISS-0397 fix,
  # lib/letflow/design/iss0397-join-counters-fix.md §2.4) -- not just calls
  # that touched a gateway: a hop-chain with no outstanding cohort serialises
  # an empty map, which is both correct and idempotent against the column's
  # own `%{}` default. This function is shared between
  # build_complete_task_tail_multi/6's success tail and
  # persist_timer_fired_advance/7's own `:projection` Multi step -- both
  # already pass the fully-dispatched `final_instance_state` whose
  # `.join_counters` Transition.transition/3's hop-chain may have just
  # mutated, so fixing this one function covers both call sites. No new
  # Repo call, no new lock: this is one more field on the UPDATE this
  # transaction was already issuing against the row fetch_and_lock_instance_projection/3
  # (M2) locked earlier.
  defp reconcile_projection(
         repo,
         %InstanceProjection{} = projection,
         %InstanceState{} = final_instance_state,
         completed_at,
         prefix
       ) do
    attrs = %{
      status: final_instance_state.status,
      current_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
      variables: final_instance_state.variables,
      join_counters: SnapshotWriter.serialize_join_counters(final_instance_state.join_counters),
      variable_labels: final_instance_state.variable_labels
    }

    attrs =
      if final_instance_state.status == :completed do
        Map.put(attrs, :completed_at, completed_at)
      else
        attrs
      end

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §8's table + §3's complete_result()).
  # ---------------------------------------------------------------------

  # req061 §5.4 -- the new leading clause: the Multi as a whole still
  # resolves as {:ok, %{...}} from Ecto.Multi's own perspective on this
  # branch too (it commits -- that is the entire point: ERROR state must
  # durably persist, not roll back). Distinguished from the success clause
  # below purely via :complete_task_outcome's own tag, not by which optional
  # keys are present.
  defp interpret_complete_result(
         {:ok, %{complete_task_outcome: {:execution_error, error_args}}},
         _actor_id,
         _prefix
       ) do
    {:error, {:instance_execution_error, error_args.error_type, error_args.affected}}
  end

  defp interpret_complete_result(
         {:ok,
          %{
            complete_task_outcome: :completed,
            task: %Task{} = task,
            transition:
              {:advanced, %InstanceState{} = final_instance_state, _prepared_children,
               _prepared_timers, _prepared_service_task_dispatches},
            task_complete: %Task{} = completed_task
          }},
         _actor_id,
         _prefix
       ) do
    {:ok,
     %{
       task_id: task.id,
       instance_id: task.instance_id,
       instance_status: final_instance_state.status,
       current_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
       variables: final_instance_state.variables,
       variable_labels: final_instance_state.variable_labels,
       completed_at: completed_task.completed_at
     }}
  end

  # REQ-460 (design req459 §2.4): a completion guard refused the request. The
  # transaction has already rolled back (only locks and SELECTs preceded the
  # refusal), so the one audit record is written NOW, in its own transaction.
  defp interpret_complete_result(
         {:error, _failed_step,
          {:completion_refused, {:output_refused, missing, rejected} = refusal}, changes},
         actor_id,
         prefix
       ) do
    task = Map.fetch!(changes, :task)

    record_completion_refusal_audit(
      task.instance_id,
      task.id,
      task.node_id,
      actor_id,
      refusal,
      prefix
    )

    {:error, {:output_refused, %{missing_keys: missing, rejected_keys: rejected}}}
  end

  # REQ-463 (design req459 §2.4): rule A refused the completion. Same post-rollback
  # audit as above; the public error is detail-free (the blocking node ids reach
  # only the audit record).
  defp interpret_complete_result(
         {:error, _failed_step, {:completion_refused, {:separation_of_duties, _ids} = refusal},
          changes},
         actor_id,
         prefix
       ) do
    task = Map.fetch!(changes, :task)

    record_completion_refusal_audit(
      task.instance_id,
      task.id,
      task.node_id,
      actor_id,
      refusal,
      prefix
    )

    {:error, :separation_of_duties}
  end

  # GH #3409 (F-3): the form validation hook refused, or could not give a verdict. Nothing
  # committed, no audit row (F-4). Neither internal term may leave this module.
  defp interpret_complete_result(
         {:error, _failed_step, {:completion_refused, {:form_hook_refused, verdict}}, _changes},
         _actor_id,
         _prefix
       ) do
    {:error, {:form_hook_refused, verdict}}
  end

  defp interpret_complete_result(
         {:error, _failed_step, {:completion_refused, {:form_hook_failed, code}}, _changes},
         _actor_id,
         _prefix
       ) do
    {:error, {:form_hook_failed, code}}
  end

  # GH #2587 PR B2: the guard's fail-closed "lines but no plan" refusal. Nothing committed.
  defp interpret_complete_result(
         {:error, _failed_step, {:completion_refused, :entity_writes_not_planned}, _changes},
         _actor_id,
         _prefix
       ) do
    {:error, {:entity_write_failed, 0, :not_planned}}
  end

  # GH #2587 PR B2: the contention result of `run_transaction/2` is a 2-tuple (no Multi
  # envelope); it must not reach the 4-tuple catch-all.
  defp interpret_complete_result(
         {:error, {:entity_write_refused, :contention, _code}} = result,
         _actor_id,
         _prefix
       ) do
    result
  end

  # GH #2587 PR B2: a failed `{:line, i, step}` is routed through the port's interpreter
  # (engine -> entities is forbidden, so it cannot call Records directly). A refusal writes
  # one best-effort audit entry AFTER the rollback, ids and a closed detail atom only. GH #2590
  # R4b: a failed `{:type_lock, type}` (a handler call's ascending type lock, a database fault
  # only) goes through the same door and comes back as an internal failure.
  defp interpret_complete_result(
         {:error, failed_step, reason, changes},
         actor_id,
         prefix
       )
       when (is_tuple(failed_step) and tuple_size(failed_step) == 3 and
               elem(failed_step, 0) == :line) or
              (is_tuple(failed_step) and tuple_size(failed_step) == 2 and
                 elem(failed_step, 0) == :type_lock) do
    case EntityPort.impl().interpret_failure(failed_step, reason) do
      {:refused, index, code, detail} ->
        task = Map.fetch!(changes, :task)

        record_entity_write_refusal_audit(task, actor_id, index, code, detail, prefix)

        if code == :entity_write_contention,
          do: {:error, {:entity_write_refused, :contention, code}},
          else: {:error, {:entity_write_refused, index, code}}

      {:failed, index, step} ->
        Logger.error(
          "entity write line #{index} failed internally at step #{inspect(step)} " <>
            "(task #{Map.fetch!(changes, :task).id})"
        )

        {:error, {:entity_write_failed, index, step}}

      :not_a_line_failure ->
        {:error, reason}
    end
  end

  # GH #2577 (D-1): a complete_task key claimed by another request (another task's
  # TASK_COMPLETED, or a derived sys_vars / entity_writes key). A same-task retry never gets
  # here: fetch_and_lock_task answers task_not_pending first. This call is not the claimant,
  # so the original is not returned; the answer is key reuse (#2543).
  defp interpret_complete_result(
         {:error, _failed_step, {:idempotent_replay, _original}, _changes},
         _actor_id,
         _prefix
       ) do
    {:error, :idempotency_key_reuse}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape complete_error() promises (or passes a
  # raw changeset/term() through, matching those catch-all clauses); this
  # just unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  #
  # ISS-0784 -- additionally, when `reason` is the `{:invalid_form_schema,
  # node_id, form_schema_reason}` rejection surfacing from
  # `TaskActivation.append_multi_from_existing_records/7` (via the hop-chain
  # advance dispatched from `:transition`), records a best-effort audit entry
  # in a second, independent transaction, opened only now that
  # `Repo.transaction/1` has already returned this `{:error, ...}` and rolled
  # back (design §3). `instance_id` is read from `_changes.task.instance_id`
  # -- the `:task` step is always fetched first and is always present in
  # `changes_so_far` by the time any later `:task_records`-keyed step can
  # fail (design §2 row 2). Any other `reason` shape is byte-identical to
  # before this issue.
  defp interpret_complete_result({:error, _failed_step, reason, changes}, actor_id, prefix) do
    case reason do
      {:invalid_form_schema, node_id, form_schema_reason} ->
        instance_id = Map.fetch!(changes, :task).instance_id

        record_task_activation_rejection_audit(
          instance_id,
          node_id,
          form_schema_reason,
          actor_id,
          prefix
        )

      _other ->
        :ok
    end

    {:error, reason}
  end

  # GH #2587 PR B2: the best-effort tenant audit record of a refused entity write, written
  # AFTER the rolled-back transaction (its own transaction, like
  # record_completion_refusal_audit/6). The public body is one code per refusal (INV-5);
  # the closed `detail` class lives only here. Ids, an index and atoms only: no field name,
  # no field value, no entity type.
  defp record_entity_write_refusal_audit(%Task{} = task, actor_id, index, code, detail, prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "entity_write.refused",
      resource_type: "task",
      resource_id: task.id,
      before_state: nil,
      after_state: %{
        "instance_id" => task.instance_id,
        "node_id" => task.node_id,
        "line_index" => index,
        "code" => Atom.to_string(code),
        "detail" => Atom.to_string(detail)
      },
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      other ->
        Logger.warning(
          "could not record entity_write.refused for task #{task.id}: #{inspect(other)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "recording entity_write.refused for task #{task.id} raised: #{inspect(exception)}"
      )

      :ok
  end

  # =========================================================================
  # cancel_instance/3 (EE-08, REQ-052) -- see
  # lib/letflow/design/req052-instance-cancellation.md for the full design
  # this section implements.
  # =========================================================================

  @type cancel_attrs :: %{
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type cancel_opts :: [prefix: String.t()]

  @type cancel_error ::
          {:error, :invalid_instance_id}
          | {:error, :idempotency_key_reuse}
          | {:error, :invalid_schema_name}
          | {:error, :missing_actor_id}
          | {:error, :missing_idempotency_key}
          | {:error, :instance_not_found}
          | {:error, {:instance_already_terminal, status :: :completed | :cancelled}}
          | {:error, {:event_append_failed, term()}}
          | {:error, :cancel_contention}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:transaction_failed, Exception.t()}}
          | {:error, term()}

  @type cancel_result :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:status) => :cancelled,
          required(:cancelled_task_ids) => [Ecto.UUID.t()],
          required(:cancelled_at) => DateTime.t(),
          optional(:replayed) => true
        }

  @doc """
  Cancels an instance (EE-08): sets every currently `PENDING` `tasks` row and
  every currently `ACTIVE`/`WAITING` `tokens` row of the instance to
  `CANCELLED`, appends exactly one `INSTANCE_CANCELLED` event (REQ-025), and
  sets the `instance_projections` row to `CANCELLED` -- all inside one
  `Ecto.Multi`/`Repo.transaction/1`. Row-level `SELECT ... FOR UPDATE`
  locking on the `tasks` row set (locked before `instance_projections`,
  matching `complete_task/3`'s own global lock-ordering rule) serializes a
  `cancel_instance/3` call against a concurrent `complete_task/3` call on the
  same instance: exactly one of the two commits, the other observes a
  distinct, typed conflict error.

  GH #2706: the open tasks are read a second time after the instance
  projection and the ancestor group, with `FOR UPDATE SKIP LOCKED`, so a task
  a concurrent writer inserted while this call waited is cancelled too (and
  listed in `cancelled_task_ids` and in the INSTANCE_CANCELLED payload). A
  pending task that another transaction holds at that point is never waited
  for: the attempt rolls back and is retried (at most 3 attempts, within one
  contention-timeout constant of the first attempt's start; no retry when the
  caller already holds a transaction, whose transaction then becomes
  rollback-only); on exhaustion the result is `{:error, :cancel_contention}`. The first
  statement of the transaction sets a transaction-local `lock_timeout` (5 s,
  `Letflow.Engine.Contention.lock_timeout_ms/0`, the same value as the retry budget above;
  skipped when the caller already holds a transaction): a lock wait that exceeds it (55P03) or
  a deadlock this call loses (40P01) rolls everything back and returns
  `{:error, :cancel_contention}` (HTTP 503); nothing is committed, so a retry is safe.

  Cancelling an instance whose `instance_projections.status` is already
  `:completed`/`:cancelled` (`Letflow.EventStore.InstanceProjection.terminal?/1`,
  reused unchanged -- the same predicate `Letflow.EventStore.append/2`'s own
  `active_instance_guard/3` already applies) returns
  `{:error, {:instance_already_terminal, status}}` and writes nothing. An
  `:error`-status instance is treated the same as an `:active` one --
  cancellable -- since `terminal?/1` only returns `true` for
  `:completed`/`:cancelled` (design doc §6).

  GH #2577: a same-key replay of a cancel that was applied (the key was claimed by this
  instance's INSTANCE_CANCELLED, by the same actor) returns the original result with
  `replayed: true` and changes nothing, even though the instance is now terminal; a key
  claimed by anything else is `{:error, :idempotency_key_reuse}`.

  `attrs[:actor_id]`/`attrs[:idempotency_key]` are pre-validated here, before
  the transaction opens, since this function has no other caller-supplied
  payload to validate (design doc §5, diverging from `complete_task/3`'s own
  "no pre-check, let `append/2` validate" convention).

  See this module's moduledoc for the `Letflow.ParallelApproval`/
  `Letflow.ApprovalSupervisor` SUPERSESSION and the SCH-03/REQ-056 scope
  boundary this function does not implement.
  """
  @spec cancel_instance(
          instance_id :: Ecto.UUID.t(),
          attrs :: cancel_attrs(),
          opts :: cancel_opts()
        ) :: {:ok, cancel_result()} | cancel_error()
  def cancel_instance(instance_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, instance_id} <- cast_instance_id(instance_id),
         {:ok, actor_id, idempotency_key} <- fetch_actor_and_idempotency_key(attrs),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      cancelled_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      run_cancel_instance(
        instance_id,
        actor_id,
        idempotency_key,
        cancelled_at,
        prefix
      )
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §5) -- zero DB writes attempted.
  # ---------------------------------------------------------------------

  # Defensive INV-8 guard, matching cast_task_id/1's own precedent above:
  # instance_id flows into a `where i.instance_id == ^instance_id` query
  # (M2, below) -- a malformed, non-UUID-shaped value there raises
  # Ecto.Query.CastError rather than returning a typed error.
  defp cast_instance_id(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp fetch_actor_and_idempotency_key(attrs) do
    case {Map.get(attrs, :actor_id), Map.get(attrs, :idempotency_key)} do
      {nil, _idempotency_key} -> {:error, :missing_actor_id}
      {_actor_id, nil} -> {:error, :missing_idempotency_key}
      {actor_id, idempotency_key} -> {:ok, actor_id, idempotency_key}
    end
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §7) -- one Ecto.Multi.
  # ---------------------------------------------------------------------

  # GH #2706: the leftover (a pending task the post-`P_x` re-read cannot lock because another
  # transaction holds it, usually one queued behind `P_x`) aborts the attempt with the named reason below;
  # this loop is the only reader of that exact `{:error, :open_tasks_recheck, :cancel_task_held_by_other, _}`
  # shape. A new attempt starts only while fewer than 3 attempts ran AND less than one contention
  # timeout elapsed since the start of the first attempt (monotonic clock, blocked time included),
  # and never when the caller already holds a transaction (a rolled-back Multi cannot be re-run
  # inside the caller's transaction, which stays rollback-only): then the typed error is returned at
  # once. Nothing is committed by an aborted attempt, so a retry is safe.
  @cancel_max_attempts 3

  defp run_cancel_instance(instance_id, actor_id, idempotency_key, cancelled_at, prefix) do
    started_at = System.monotonic_time(:millisecond)
    nested? = Repo.in_transaction?()
    retry? = not nested?

    attempt = fn ->
      cancel_attempt(instance_id, actor_id, idempotency_key, cancelled_at, prefix, nested?)
    end

    run_cancel_attempts(attempt, 1, started_at, retry?, instance_id)
  end

  @doc false
  # The retry loop of `cancel_instance/3`, public only so its caps are unit-testable without a
  # database: `attempt` returns `:held_by_other` (retryable) or `{:final, result}`. There is
  # deliberately NO pause between attempts: the retry starts with the class-1 locking read, which
  # blocks on the holder and so paces itself, and the re-read never waits. The time cap reads
  # `Contention.lock_timeout_ms/0`, the same value as the DB `lock_timeout` of the attempt.
  @spec run_cancel_attempts(
          (-> :held_by_other | {:final, term()}),
          pos_integer(),
          integer(),
          boolean(),
          Ecto.UUID.t()
        ) :: term()
  def run_cancel_attempts(attempt, n, started_at, retry?, instance_id) do
    case attempt.() do
      :held_by_other ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if retry? and n < @cancel_max_attempts and elapsed < Contention.lock_timeout_ms() do
          run_cancel_attempts(attempt, n + 1, started_at, retry?, instance_id)
        else
          # no PII: the attempt number and the instance id only
          Logger.warning(
            "cancel_instance contention: gave up after attempt #{n} (retry allowed: #{retry?}) " <>
              "instance_id=#{instance_id}"
          )

          {:error, :cancel_contention}
        end

      {:final, result} ->
        result
    end
  end

  defp cancel_attempt(instance_id, actor_id, idempotency_key, cancelled_at, prefix, nested?) do
    try do
      result =
        cancel_multi(instance_id, actor_id, idempotency_key, cancelled_at, prefix, nested?)

      case result do
        {:error, :open_tasks_recheck, :cancel_task_held_by_other, _changes} ->
          :held_by_other

        other ->
          {:final, interpret_cancel_result(other, instance_id, cancelled_at)}
      end
    rescue
      exception ->
        # GH #2706 (design 3.2): a lock timeout (55P03) or deadlock victim (40P01) rolled the
        # whole transaction back; it is retryable (a 503), not an internal failure. Log the
        # classified tag and the instance id only, never the exception text.
        case Contention.contention_code(exception) do
          {:ok, code} ->
            Logger.warning("cancel_instance contention: #{code} instance_id=#{instance_id}")
            {:final, {:error, :cancel_contention}}

          :error ->
            {:final, {:error, {:transaction_failed, exception}}}
        end
    end
  end

  # GH #2706 (design 3.1): the first statement of the cancel transaction bounds every later lock
  # wait; the statement itself lives in `Contention.set_cancel_lock_timeout/2` (GH #2868).
  defp set_cancel_lock_timeout(repo, nested?),
    do: Contention.set_cancel_lock_timeout(repo, nested?)

  defp cancel_multi(instance_id, actor_id, idempotency_key, cancelled_at, prefix, nested?) do
    Multi.new()
    |> Multi.run(:lock_timeout, fn repo, _changes -> set_cancel_lock_timeout(repo, nested?) end)
    |> Multi.run(:open_tasks, fn repo, _changes ->
      fetch_and_lock_open_tasks(repo, instance_id, prefix)
    end)
    |> Multi.run(:service_task_dispatch_cancellations, fn repo, _changes ->
      # REQ-215 design doc §4 -- positioned before :instance_projection
      # (class 1, like :open_tasks), for the lock-ordering reason: acquire
      # the service_task_dispatches lock before the instance_projections
      # lock, matching every other code path's lock order (avoids an AB-BA
      # Postgres deadlock). Unlike the timers (GH #2707: now after `P_x`,
      # see :timer_cancellations below) these rows are not P-protected.
      ServiceTaskDispatcher.cancel_pending_dispatches(repo, instance_id, cancelled_at, prefix)
    end)
    |> Multi.run(:script_task_dispatch_cancellations, fn repo, _changes ->
      # GH 2534 PR 7c-1 (design 5.6, CDV C5): the script route's pending AND running rows,
      # same lock-order rule (dispatch row before the projection), the order
      # apply_script_task_result/3 takes too; an ineligible cancel rolls it back.
      ScriptTaskDispatcher.cancel_open_dispatches(repo, instance_id, cancelled_at, prefix)
    end)
    |> Multi.run(:instance_projection, fn repo, _changes ->
      # GH #2695: parent-side order: P then T, same as the cascade.
      fetch_and_lock_instance_projection_for_cancel(repo, instance_id, prefix)
    end)
    |> Multi.run(:replay_check, fn repo, _changes ->
      # GH #2577 -- with the projection lock held, a key already claimed by this instance's
      # INSTANCE_CANCELLED answers the original result (ahead of :eligibility, which would say
      # "already cancelled"); any other claim is :idempotency_key_reuse. Aborts the Multi, so no
      # cancel side effect of the steps above commits.
      cancel_replay_check(repo, instance_id, actor_id, idempotency_key, prefix)
    end)
    |> Multi.run(:eligibility, fn _repo, %{instance_projection: projection} ->
      check_cancel_eligibility(projection)
    end)
    |> Multi.run(:lock_ancestors, fn repo, _changes ->
      # GH #2708: after the child's projection (L3) and its eligibility, and BEFORE the FIRST
      # UPDATE of the child's projection row (the :event step's last_event_seq bump). That is
      # what makes the second UPDATE's FK check safe: the check then queues KEY SHARE on the
      # parent token and projection, which this transaction already holds. A cancel never
      # completes the child: KEY SHARE, immediate parent only. No-op for a non-waiting child.
      lock_parent_group(repo, instance_id, :continuing, prefix)
    end)
    |> Multi.run(:open_tasks_recheck, fn repo, _changes ->
      # GH #2706 (decision 0061, "Amended (GH #2706, PR-1)"): the class-1 read above ran before
      # `P_x`, so a task a concurrent writer inserted since is invisible to it. No task can be
      # inserted for this instance while `P_x` is held (the immediate `tasks.instance_id`
      # foreign key needs KEY SHARE on it), so this read, which starts after `P_x` and the
      # group, is complete. NON-WAITING (SKIP LOCKED): a wait on a task row here could close a
      # cycle with its holder, who is queued behind `P_x`.
      recheck_open_tasks(repo, instance_id, prefix)
    end)
    |> Multi.run(:timer_cancellations, fn repo, _changes ->
      # GH #2707 (decision 0061, "Amended (GH #2707, PR-1)"): timer rows are P-protected. They are
      # touched only while `P_x` is held, so this step sits after `:instance_projection`, the
      # ancestor group and `:open_tasks_recheck`, and before `:task_cancellations`. That is the
      # order `Scheduler.fire_timer/2` has (`P_x` before the timer row, through
      # `Engine.lock_for_timer_fire/3`), which removes the AB-BA between the two. REQ-187 design
      # doc §6.1-§6.2 (SCH-03) still holds: every pending timer of the instance is cancelled,
      # now including one a cascade armed while this cancel waited for `P_x`. An ineligible
      # cancel no longer runs this UPDATE at all (`:eligibility` stops the Multi first).
      TaskActivation.cancel_pending_timers(
        repo,
        instance_id,
        cancelled_at,
        "instance_cancelled",
        prefix
      )
    end)
    |> Multi.run(:task_cancellations, fn repo, %{open_tasks_recheck: open_tasks} ->
      cancel_task_rows(repo, open_tasks, cancelled_at, prefix)
    end)
    |> Multi.run(:live_tokens, fn repo, _changes ->
      fetch_and_lock_live_tokens(repo, instance_id, prefix)
    end)
    |> Multi.run(:token_cancellations, fn repo, %{live_tokens: live_tokens} ->
      cancel_token_rows(repo, live_tokens, cancelled_at, prefix)
    end)
    |> Multi.run(:event, fn _repo, changes ->
      append_instance_cancelled_event(
        instance_id,
        changes,
        actor_id,
        idempotency_key,
        prefix
      )
    end)
    |> Multi.run(:projection, fn repo, %{instance_projection: projection} ->
      cancel_instance_projection(repo, projection, cancelled_at, prefix)
    end)
    |> Multi.merge(fn changes ->
      record_instance_cancel_audit(changes, instance_id, actor_id, prefix)
    end)
    |> Repo.transaction()
  end

  defp cancel_replay_check(repo, instance_id, actor_id, idempotency_key, prefix) do
    case IdempotentReplay.lookup(repo, idempotency_key, prefix) do
      :none ->
        {:ok, nil}

      {:ok, %EventStore.Event{} = original} ->
        if original.event_type == "INSTANCE_CANCELLED" and original.instance_id == instance_id and
             IdempotentReplay.same_uuid?(original.actor_id, actor_id) do
          {:error, {:idempotent_replay, original}}
        else
          {:error, :idempotency_key_reuse}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # REQ-195 -- cancel_instance/3's own actor_id (attrs[:actor_id], already an
  # explicit, required argument) is real, non-nil. before_state is the
  # pre-cancel row (:instance_projection, fetched+locked earlier in this
  # same Multi); after_state is the post-cancel row this Multi's own
  # :projection step just produced.
  defp record_instance_cancel_audit(changes, instance_id, actor_id, prefix) do
    before = Map.fetch!(changes, :instance_projection)
    updated = Map.fetch!(changes, :projection)

    Audit.append_multi(
      Multi.new(),
      :audit,
      %{
        actor_id: actor_id,
        action: "instance.cancel",
        resource_type: "instance",
        resource_id: instance_id,
        before_state: Audit.struct_state(before),
        after_state: Audit.struct_state(updated),
        trace_id: nil
      },
      prefix
    )
  end

  # M1 -- row-lock + fetch every open (:pending) tasks row for this instance,
  # deterministically ordered (design doc §7, §7.1) -- must run, and lock,
  # before M2 (instance_projections), matching complete_task/3's own global
  # lock-ordering rule verbatim.
  defp fetch_and_lock_open_tasks(repo, instance_id, prefix) do
    tasks =
      Task
      |> where([t], t.instance_id == ^instance_id and t.status == :pending)
      |> order_by([t], asc: t.id)
      |> lock("FOR UPDATE")
      |> repo.all(prefix: prefix)

    {:ok, tasks}
  end

  # GH #2706: the post-`P_x` re-read of the open tasks, `FOR UPDATE SKIP LOCKED`, ordered by id.
  # Rows this transaction already holds (the class-1 read) are returned, rows held by another
  # transaction are skipped. A pending row that the plain read sees but the locking read could not
  # take is held by someone else (usually a transaction queued behind `P_x`, e.g. a completer; a row
  # held only by `FOR KEY SHARE`, e.g. a concurrent foreign-key insert, is skipped too and costs one
  # extra bounded retry): it is never waited for, the attempt aborts with `:cancel_task_held_by_other` (the retry loop in
  # `run_cancel_attempts/5` is the only reader of that reason). The pending set cannot grow while
  # `P_x` is held, so the two reads need no further guard.
  defp recheck_open_tasks(repo, instance_id, prefix) do
    tasks =
      Task
      |> where([t], t.instance_id == ^instance_id and t.status == :pending)
      |> order_by([t], asc: t.id)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> repo.all(prefix: prefix)

    pending_ids =
      Task
      |> where([t], t.instance_id == ^instance_id and t.status == :pending)
      |> select([t], t.id)
      |> repo.all(prefix: prefix)

    if pending_ids -- Enum.map(tasks, & &1.id) == [] do
      {:ok, tasks}
    else
      {:error, :cancel_task_held_by_other}
    end
  end

  # M2 -- row-lock + fetch the instance_projections row. Unlike
  # fetch_and_lock_instance_projection/3 (complete_task/3's own M2), this does
  # NOT reject a non-:active status itself -- eligibility (M3, terminal?/1) is
  # the shared, reused predicate for that (design doc §6).
  # GH #2695: locks the waiting parent group of `instance_id` (parent projection, then the
  # waiting token). Every UPDATE of a sub-process child's projection row takes foreign-key
  # locks on the parent's token and projection (`parent_token_id`, `parent_instance_id`), in an
  # order fixed per tenant schema by constraint-trigger names, so the group must already be held
  # (P then T) before that UPDATE or a parent cancel (P then T) can deadlock against it. A child
  # that completes locks the whole ancestor chain (its cascade will walk it); a child that
  # continues locks the immediate parent only, FOR KEY SHARE (compatible between siblings, still
  # queued ahead of a cancel's FOR UPDATE). No-op for an instance that is not a child.
  #
  # GH #2704: the mode is an INTENT decided from the pure transition (`lock_intent/1`) before the
  # first lock of the group and never upgraded within a transaction (decision 0061 rule 2).
  @spec lock_parent_group(
          Ecto.Repo.t() | module(),
          Ecto.UUID.t(),
          :completing | :continuing,
          String.t() | nil
        ) :: {:ok, [TokenRecord.t()]} | {:error, term()}
  defp lock_parent_group(repo, instance_id, :completing, prefix),
    do: SubProcess.lock_waiting_parent_chain(repo, instance_id, prefix)

  defp lock_parent_group(repo, instance_id, :continuing, prefix) do
    with {:ok, token} <- SubProcess.lock_waiting_parent(repo, instance_id, prefix, :key_share) do
      {:ok, List.wrap(token)}
    end
  end

  @spec lock_intent(InstanceState.t()) :: :completing | :continuing
  defp lock_intent(%{status: :completed}), do: :completing
  defp lock_intent(_state), do: :continuing

  defp fetch_and_lock_instance_projection_for_cancel(repo, instance_id, prefix) do
    # GH #2702: a synthetic entity-type instance is invisible here (nil row ->
    # the same :instance_not_found as an absent id); nothing is locked or written.
    InstanceProjection
    |> where([p], p.instance_id == ^instance_id)
    |> InstanceVisibility.exclude_synthetic(prefix)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :instance_not_found}
      %InstanceProjection{} = projection -> {:ok, projection}
    end
  end

  # M3 -- pure check, no I/O: reuses InstanceProjection.terminal?/1 unchanged
  # (design doc §6) rather than a second, independently-maintained predicate.
  # Nothing has been written yet when this runs -- M1/M2 only locked/read.
  defp check_cancel_eligibility(%InstanceProjection{status: status} = projection) do
    if InstanceProjection.terminal?(status) do
      {:error, {:instance_already_terminal, status}}
    else
      {:ok, projection}
    end
  end

  # M4 -- Task.complete_changeset/2, already shipped, reused unchanged.
  defp cancel_task_rows(repo, open_tasks, cancelled_at, prefix) do
    attrs = %{status: :cancelled, cancelled_at: cancelled_at}

    open_tasks
    |> Enum.reduce_while({:ok, []}, fn %Task{} = task, {:ok, acc} ->
      task
      |> Task.complete_changeset(attrs)
      |> repo.update(prefix: prefix)
      |> case do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      {:error, reason} -> {:error, reason}
    end
  end

  # M5 -- row-lock + fetch every live (:active/:waiting) tokens row for this
  # instance, deterministically ordered (design doc §7).
  defp fetch_and_lock_live_tokens(repo, instance_id, prefix) do
    tokens =
      TokenRecord
      |> where([t], t.instance_id == ^instance_id and t.status in [:active, :waiting])
      |> order_by([t], asc: t.id)
      |> lock("FOR UPDATE")
      |> repo.all(prefix: prefix)

    {:ok, tokens}
  end

  # M5 (cont.) -- TokenRecord.advance_changeset/2, already shipped, reused
  # unchanged.
  defp cancel_token_rows(repo, live_tokens, cancelled_at, prefix) do
    attrs = %{status: :cancelled, cancelled_at: cancelled_at}

    live_tokens
    |> Enum.reduce_while({:ok, []}, fn %TokenRecord{} = token, {:ok, acc} ->
      token
      |> TokenRecord.advance_changeset(attrs)
      |> repo.update(prefix: prefix)
      |> case do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      {:error, reason} -> {:error, reason}
    end
  end

  # M6 -- appends the INSTANCE_CANCELLED event (design doc §9, REQ-025).
  # Runs BEFORE M7 (the instance_projections status write) -- load-bearing:
  # EventStore.append/2's own active_instance_guard/3 reads
  # instance_projections.status itself, inside this same outer transaction.
  # If M7 ran first, that guard would read the just-written :cancelled status
  # and reject its own call.
  defp append_instance_cancelled_event(
         instance_id,
         %{open_tasks_recheck: open_tasks, live_tokens: live_tokens},
         actor_id,
         idempotency_key,
         prefix
       ) do
    payload =
      Jason.encode!(%{
        cancelled_task_ids: Enum.map(open_tasks, & &1.id),
        cancelled_token_ids: Enum.map(live_tokens, & &1.id)
      })

    event_attrs = %{
      instance_id: instance_id,
      event_type: "INSTANCE_CANCELLED",
      payload: payload,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    # GH #2577 -- last expression of the Multi step (see IdempotentReplay).
    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} = replay -> replay
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # M7 -- InstanceProjection.update_changeset/2, already shipped, reused
  # unchanged. last_event_seq intentionally omitted from attrs -- M6's own
  # EventStore.append/2 call already advanced it, matching
  # reconcile_projection/5's own precedent above.
  defp cancel_instance_projection(repo, %InstanceProjection{} = projection, cancelled_at, prefix) do
    attrs = %{status: :cancelled, cancelled_at: cancelled_at}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: prefix)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §3's cancel_result()).
  # ---------------------------------------------------------------------

  defp interpret_cancel_result(
         {:ok, %{instance_projection: %InstanceProjection{}, open_tasks_recheck: open_tasks}},
         instance_id,
         cancelled_at
       ) do
    {:ok,
     %{
       instance_id: instance_id,
       status: :cancelled,
       cancelled_task_ids: Enum.map(open_tasks, & &1.id),
       cancelled_at: cancelled_at
     }}
  end

  # GH #2577 -- a same-key replay of an applied cancel: the original answer, rebuilt from the
  # stored INSTANCE_CANCELLED event and the (already cancelled) projection read under the lock.
  defp interpret_cancel_result(
         {:error, :replay_check, {:idempotent_replay, original}, changes},
         instance_id,
         cancelled_at
       ) do
    cancelled_task_ids = Map.get(original.payload || %{}, "cancelled_task_ids", [])
    projection = Map.get(changes, :instance_projection)

    {:ok,
     %{
       instance_id: instance_id,
       status: :cancelled,
       cancelled_task_ids: cancelled_task_ids,
       cancelled_at: (projection && projection.cancelled_at) || cancelled_at,
       replayed: true
     }}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape cancel_error() promises (or passes a
  # raw changeset/term() through, matching those catch-all clauses); this
  # just unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  defp interpret_cancel_result(
         {:error, _failed_step, reason, _changes},
         _instance_id,
         _cancelled_at
       ) do
    {:error, reason}
  end

  # =========================================================================
  # set_instance_error/2 (EE-10, REQ-061) -- see
  # lib/letflow/design/req061-execution-error-handling.md §4 for the full
  # design this section implements. The standalone public entry point onto
  # Letflow.Engine.ExecutionError.append_multi/3, the shared composable sink;
  # complete_task/3's own REQ-049/050 call sites (above) call
  # ExecutionError.append_multi/3 directly instead, already inside their own
  # open Multi -- set_instance_error/2 is for a caller with no other Multi of
  # its own open (design doc §4's own future REQ-056/057/062 callers).
  # =========================================================================

  @type standalone_error_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:error_type) => ExecutionError.error_type(),
          required(:affected) => ExecutionError.affected(),
          required(:reason) => String.t(),
          required(:variables) => map(),
          optional(:details) => map(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t()
        }

  @type set_error_opts :: [prefix: String.t(), dlq_landed_externally: boolean()]

  @type set_error_result :: %{
          instance_id: Ecto.UUID.t(),
          status: :error,
          error_type: ExecutionError.error_type(),
          error_detail: map()
        }

  @type set_error_error ::
          {:error, :invalid_instance_id}
          | {:error, :invalid_schema_name}
          | {:error, :missing_actor_id_or_idempotency_key}
          | {:error, :instance_not_found}
          | {:error, {:instance_terminal, status :: :completed | :cancelled}}
          | {:error, {:instance_already_error, error_detail :: map()}}
          | {:error, {:event_append_failed, term()}}
          | {:error, {:execution_error_contention, :lock_not_available | :deadlock_detected}}
          # GH #2577 (D-2): the EXECUTION_ERROR key is claimed by another request.
          | {:error, :idempotency_key_reuse}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  Standalone entry point for setting an instance to `ERROR` (EE-10) from
  outside any other function's own open `Ecto.Multi` -- the shape
  `attrs[:instance_id]` and every other `error_args()` field is supplied by
  the caller. Unlike `cancel_instance/3`, `attrs[:actor_id]` may be
  explicitly `nil` (structurally legal here) for a future actor-less caller
  (design doc §12 OQ-3) -- `attrs[:idempotency_key]` is still required,
  non-nilable, matching every other event-appending call in this module.

  Delegates the actual `ERROR`-transition work to
  `Letflow.Engine.ExecutionError.append_multi/3` -- the shared, composable
  sink every engine-internal failure funnels into (design doc §3). See that
  module's moduledoc for the OBS-05 dead-letter (S6) scope boundary and the
  "ERROR is not terminal" invariant this function's own callers should not
  assume otherwise.

  GH #2706 PR-3 (design section 4): the transaction is bounded by a transaction-local
  `lock_timeout` (`Letflow.Engine.Contention.lock_timeout_ms/0`, set first, skipped when the
  caller already holds a transaction); it bounds EVERY lock wait of the landing (the instance row
  `FOR UPDATE` as well as the parent group). A lock timeout (55P03) or deadlock victim (40P01) in the
  landing is retried in a fresh transaction, 3 attempts in all with 100 ms / 300 ms backoffs, only
  when this call opened the transaction. After the last failure the result is
  `{:error, {:execution_error_contention, code}}` (a contention failure never raises; any other
  exception is re-raised); the instance stays `:active`
  (it is not moved to `ERROR` without the parent group lock, see decision 0061). Unless the
  caller passed `dlq_landed_externally: true`, a standalone best-effort `dlq_entries` row
  (`context_json` `{"landing": "contention"}`, no variables, no reason text, no details) tells the
  operator; it is not written for a nested call, whose transaction is aborted.
  """
  @spec set_instance_error(
          attrs :: standalone_error_attrs(),
          opts :: set_error_opts()
        ) :: {:ok, set_error_result()} | set_error_error()
  def set_instance_error(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, instance_id} <- cast_instance_id(Map.get(attrs, :instance_id)),
         {:ok, idempotency_key} <- fetch_idempotency_key_for_error(attrs),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      error_args = %{
        instance_id: instance_id,
        error_type: Map.fetch!(attrs, :error_type),
        affected: Map.fetch!(attrs, :affected),
        reason: Map.fetch!(attrs, :reason),
        variables: Map.fetch!(attrs, :variables),
        details: Map.get(attrs, :details, %{}),
        actor_id: Map.get(attrs, :actor_id),
        idempotency_key: idempotency_key
      }

      dlq_landed_externally = Keyword.get(opts, :dlq_landed_externally, false)
      nested? = Repo.in_transaction?()

      attempt = fn ->
        error_landing_transaction(error_args, prefix, dlq_landed_externally, nested?)
      end

      run_error_landing_attempts(attempt, 1, nested?, error_args, prefix, dlq_landed_externally)
      |> maybe_snapshot_after_set_instance_error(instance_id, prefix)
      |> interpret_set_instance_error_result(instance_id, error_args.error_type)
    end
  end

  # GH #2706 PR-3 (design 4.2): the landing transaction. Its first statement bounds every later
  # lock wait (the same step as the cancel's, `set_cancel_lock_timeout/2`, skipped when nested).
  # `ExecutionError.append_multi/3` itself is unchanged: it raises on a lock timeout (55P03) or a
  # deadlock victim (40P01), which is caught here and only here.
  defp error_landing_transaction(error_args, prefix, dlq_landed_externally, nested?) do
    Multi.new()
    |> Multi.run(:lock_timeout, fn repo, _changes -> set_cancel_lock_timeout(repo, nested?) end)
    |> ExecutionError.append_multi(error_args,
      prefix: prefix,
      dlq_landed_externally: dlq_landed_externally
    )
    |> Repo.transaction()
  rescue
    exception ->
      case Contention.contention_code(exception) do
        {:ok, code} -> {:contention, code}
        :error -> reraise exception, __STACKTRACE__
      end
  end

  # At most 3 attempts in all, constant 100 ms / 300 ms backoffs between them (none in a
  # `:engine_test_seams` build, see `service_backoff/1`), retried only when this call opened the
  # transaction (a nested attempt left the caller's transaction aborted: the typed error at once).
  defp run_error_landing_attempts(attempt, n, nested?, error_args, prefix, dlq_landed_externally) do
    case attempt.() do
      # the cap is deliberately the service-apply cap (3 attempts, the same backoff table)
      {:contention, _code} when not nested? and n < @service_apply_attempts ->
        service_backoff(n)

        run_error_landing_attempts(
          attempt,
          n + 1,
          nested?,
          error_args,
          prefix,
          dlq_landed_externally
        )

      {:contention, code} ->
        # no PII: the classified tag, the attempt count and the instance id only
        Logger.warning(
          "set_instance_error contention: #{code} after attempt #{n} instance_id=#{error_args.instance_id}"
        )

        unless dlq_landed_externally or nested? do
          land_contention_dlq_row(error_args, prefix, code, n)
        end

        {:error, {:execution_error_contention, code}}

      other ->
        other
    end
  end

  # Best-effort standalone row in its OWN transaction (a failed landing cannot write in the aborted
  # one), after the failed one rolled back; it takes no ancestor lock and no instance lock and never
  # raises. Only fixed text, the error type, the affected descriptor and the contention tag are
  # stored: the variables, the original reason text and the details map can carry tenant data and
  # are NOT copied. Skipped when nested (the caller's transaction is aborted, nothing can be
  # written in a separate one).
  defp land_contention_dlq_row(error_args, prefix, code, attempts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      entry_type: "event",
      instance_id: error_args.instance_id,
      reason: "execution error could not be recorded on the instance (lock contention)",
      error_detail: %{
        "error_type" => to_string(error_args.error_type),
        "affected" => contention_affected(error_args.affected),
        "contention" => to_string(code),
        "attempts" => attempts
      },
      context_json: %{"landing" => "contention"},
      first_failed_at: now,
      last_failed_at: now
    }

    case Dlq.enqueue(attrs, prefix: prefix) do
      {:ok, _entry} ->
        :ok

      {:error, _changeset} ->
        # never log or inspect the changeset (it holds the row attributes)
        Logger.warning(
          "set_instance_error contention: DLQ row not written instance_id=#{error_args.instance_id}"
        )
    end
  rescue
    _exception ->
      Logger.warning(
        "set_instance_error contention: DLQ row not written instance_id=#{error_args.instance_id}"
      )
  end

  defp contention_affected({:node, id}), do: %{"node" => id}
  defp contention_affected({:field, name}), do: %{"field" => name}
  defp contention_affected(_other), do: %{}

  # REQ-054 (design doc §4.2) -- SnapshotWriter's third named call site
  # (ExecutionError.append_multi/3, via this standalone entry point).
  # Unlike complete_task/3's own execution-error branch, no InstanceState is
  # already in hand here -- set_instance_error/2 opens no Multi step that
  # reads tokens/pending tasks, by design (its whole point is a caller with
  # no other open Multi of its own). Rather than fabricate a partial
  # InstanceState from instance_projections.current_nodes (which has no
  # token_id/branch_id/join_counters and would risk a snapshot that
  # disagrees with full-log replay, violating INV-ISS-1), this reuses
  # Letflow.Engine.Reconstruction.reconstruct_instance/2 -- already-shipped,
  # already the correctness-verified source of truth for "current
  # InstanceState from the durable log" -- to obtain an accurate state.
  # Acceptable here specifically because set_instance_error/2 is a rare,
  # already-expensive write (an execution error), not the hot path
  # create/2 and complete_task/3 are optimizing; a full-log reconstruction
  # on every call would defeat REQ-054's own purpose if done on those paths,
  # but not on this one. Same best-effort/log-and-swallow contract as
  # maybe_snapshot_after_create/4.
  defp maybe_snapshot_after_set_instance_error(
         {:ok, %{execution_error_projection_update: %InstanceProjection{}}} = result,
         instance_id,
         prefix
       ) do
    case Reconstruction.reconstruct_instance(instance_id, prefix: prefix) do
      {:ok, %{instance_state: %InstanceState{} = instance_state, last_sequence_number: seq}}
      when is_integer(seq) ->
        snapshot_instance(instance_id, instance_state, seq, prefix)

      {:ok, %{last_sequence_number: nil}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Letflow.Engine.Reconstruction.reconstruct_instance/2 failed while snapshotting " <>
            "after set_instance_error/2 for instance #{instance_id}: #{inspect(reason)}"
        )
    end

    result
  end

  defp maybe_snapshot_after_set_instance_error(result, _instance_id, _prefix), do: result

  # idempotency_key is the one field this pre-transaction phase itself
  # validates non-nil/non-empty (matching EventStore.append/2's own
  # fetch_idempotency_key/1 requirement) -- actor_id is deliberately not
  # rejected when nil (design doc §4, §12 OQ-3).
  defp fetch_idempotency_key_for_error(attrs) do
    case Map.get(attrs, :idempotency_key) do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _other -> {:error, :missing_actor_id_or_idempotency_key}
    end
  end

  defp interpret_set_instance_error_result(
         {:ok, %{execution_error_projection_update: %InstanceProjection{} = projection}},
         instance_id,
         error_type
       ) do
    {:ok,
     %{
       instance_id: instance_id,
       status: :error,
       error_type: error_type,
       error_detail: projection.error_detail
     }}
  end

  # ExecutionError.append_multi/3's own :execution_error_projection_lock step
  # returns {:error, {:instance_not_found}} (a tuple-wrapped atom, design doc
  # §2's eligibility_error() shape) -- flattened here to the bare
  # :instance_not_found atom this function's own set_error_error() promises
  # (design doc §4). Every other reason (e.g. {:instance_terminal, _},
  # {:instance_already_error, _}) already matches its own set_error_error()
  # member shape verbatim and passes through unchanged.
  defp interpret_set_instance_error_result(
         {:error, _failed_step, {:instance_not_found}, _changes},
         _instance_id,
         _error_type
       ) do
    {:error, :instance_not_found}
  end

  defp interpret_set_instance_error_result(
         {:error, _failed_step, reason, _changes},
         _instance_id,
         _error_type
       ) do
    {:error, reason}
  end

  # GH #2706 PR-3: the typed contention result of `run_error_landing_attempts/6` (a 2-tuple,
  # unlike a failed Multi's 4-tuple above) passes through unchanged.
  defp interpret_set_instance_error_result(
         {:error, {:execution_error_contention, _code}} = error,
         _instance_id,
         _error_type
       ),
       do: error

  # =========================================================================
  # land_service_task_exhaustion/2 (REQ-177) -- see
  # lib/letflow/design/req177-dlq-hooks.md §2 for the full design this
  # section implements. Hook A of REQ-177's two DLQ landing hooks.
  # =========================================================================

  @typedoc """
  Extends `ServiceTask.service_task_give_up_context()` with the two
  additional fields a DLQ row needs that context does not itself carry
  (design doc §2.2).
  """
  @type service_task_dlq_landing_context :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t(),
          required(:variables) => map(),
          required(:last_failure_kind) => ServiceTask.failure_kind(),
          required(:attempt_index) => ServiceTask.attempt_index(),
          required(:retry_limit) => non_neg_integer(),
          required(:attempted_request) => %{
            required(:method) => String.t(),
            required(:url) => String.t(),
            optional(:body) => String.t() | nil,
            optional(:headers) => %{optional(String.t()) => String.t()}
          }
        }

  @doc """
  Hook A of REQ-177 (design doc §2). Called by a future SERVICE_TASK
  dispatch orchestrator (none exists in this codebase yet, per
  `Letflow.Engine.ServiceTask`'s own moduledoc) whenever
  `ServiceTask.decide_failure/3` returns `:give_up` for a SERVICE_TASK node,
  in place of calling `set_instance_error/2` directly.

  Re-derives the exhaustion/non-exhaustion split
  `ServiceTask.decide_failure/3`'s own return value does not carry (design
  doc §3): exactly `ServiceTask.is_retriable_failure(context.last_failure_kind)
  == true and context.attempt_index >= context.retry_limit`. When that is
  **not** the case (an immediately non-retriable failure kind), returns
  `{:error, :not_exhaustion}` and calls neither `Letflow.Dlq.enqueue/2` nor
  `set_instance_error/2` -- the caller is expected to call
  `set_instance_error/2` directly for that case instead, so Hook B
  (`Letflow.Engine.ExecutionError.append_multi/3`'s own
  `:execution_error_dlq_landing` step) lands it generically.

  On genuine exhaustion: lands exactly one `dlq_entries` row via
  `Letflow.Dlq.enqueue/2` (`entry_type: "event"`, `instance_id`,
  `full_reason` naming the classified failure kind, `source_payload` the
  attempted request, `first_failed_at`/`last_failed_at` both the current UTC
  time read at landing, design doc §5.1) **before** delegating to
  `set_instance_error/2` with `dlq_landed_externally: true` so Hook B does
  not also land a row for this same transition (design doc §4).

  **Deferred follow-up (REQ-176's `retry/2`), per the requirement's own
  acceptance criterion:** landing a DLQ entry here does not itself, and
  `Letflow.Dlq.retry/2` called against the entry this function creates does
  not either, re-invoke the original SERVICE_TASK dispatch. Two pieces are
  still missing before it could: (a) a wired SERVICE_TASK transport (the
  injectable `ServiceTask.transport_fun()` -- "no concrete implementation
  ... exists in this codebase yet" per that module's own moduledoc) that a
  future `retry/2`-driven re-dispatch path would need to call, and (b) the
  dispatch orchestrator itself (this function's own caller, which does not
  exist yet) that would need to exist before anything calls `retry/2` in
  response to an operator action at all.
  """
  @spec land_service_task_exhaustion(
          context :: service_task_dlq_landing_context(),
          opts :: set_error_opts()
        ) ::
          {:ok, set_error_result()}
          | {:error, :not_exhaustion}
          | set_error_error()
          | {:error, {:dlq_enqueue_failed, Ecto.Changeset.t()}}
  def land_service_task_exhaustion(context, opts) when is_map(context) and is_list(opts) do
    last_failure_kind = Map.fetch!(context, :last_failure_kind)
    attempt_index = Map.fetch!(context, :attempt_index)
    retry_limit = Map.fetch!(context, :retry_limit)

    if ServiceTask.is_retriable_failure(last_failure_kind) and attempt_index >= retry_limit do
      land_service_task_exhaustion_dlq_entry(context, opts, last_failure_kind, retry_limit)
    else
      {:error, :not_exhaustion}
    end
  end

  defp land_service_task_exhaustion_dlq_entry(context, opts, last_failure_kind, retry_limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    dlq_attrs = %{
      entry_type: "event",
      instance_id: Map.fetch!(context, :instance_id),
      full_reason:
        "service task failed (#{last_failure_kind}): retries exhausted after #{retry_limit} attempts",
      source_payload: Map.fetch!(context, :attempted_request),
      retry_limit: retry_limit,
      first_failed_at: now,
      last_failed_at: now
    }

    case Dlq.enqueue(dlq_attrs, opts) do
      {:ok, _entry} ->
        set_instance_error(
          build_service_task_dlq_landing_error_attrs(context),
          Keyword.put(opts, :dlq_landed_externally, true)
        )

      {:error, changeset} ->
        {:error, {:dlq_enqueue_failed, changeset}}
    end
  end

  # Same standalone_error_attrs() shape
  # ServiceTask.build_service_task_give_up_error_attrs/1 already builds from
  # an equivalent (strict-subset) context -- built inline here rather than
  # via that function since this context carries extra fields it doesn't
  # accept (design doc §2.4 step 3).
  defp build_service_task_dlq_landing_error_attrs(context) do
    last_failure_kind = Map.fetch!(context, :last_failure_kind)
    attempt_index = Map.fetch!(context, :attempt_index)
    retry_limit = Map.fetch!(context, :retry_limit)

    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_retries_exhausted,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason:
        "service task failed (#{last_failure_kind}): retries exhausted after #{retry_limit} attempts",
      variables: Map.fetch!(context, :variables),
      details: %{
        last_failure_kind: last_failure_kind,
        attempt_index: attempt_index,
        retry_limit: retry_limit
      },
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end

  # ===================================================================================
  # REQ-078 -- metrics counters (lib/letflow/design/req078-supporting-routes.md §11.4)
  #
  # These back GET /api/v1/metrics. They are `COUNT(*)` aggregates over tables
  # that already exist in the caller's tenant schema -- NOT a metrics
  # subsystem. See Letflow.Routers.Metrics's moduledoc: S6 observability owns
  # Letflow's metrics subsystem, and this endpoint is expected to be
  # superseded when it lands.
  # ===================================================================================

  @typedoc """
  status atom -> row count, within one tenant schema. Every status in the
  owning schema's closed enum is present, zero-valued if unseen.
  """
  @type status_counts :: %{atom() => non_neg_integer()}

  # Declared before their readers -- module attributes are read at expansion
  # time. Both mirror the closed `Ecto.Enum` value sets of the schemas below.
  @instance_status_zero_fill %{active: 0, completed: 0, cancelled: 0, error: 0}
  @task_status_zero_fill %{pending: 0, completed: 0, cancelled: 0}

  @doc """
  Counts `instance_projections` rows by `status`, scoped to `opts[:prefix]`.
  One query.

  **Grouped over the schema field, never the raw column.**
  `instance_projections.status` is a *keyword-mapped* `Ecto.Enum`
  (`[active: "ACTIVE", completed: "COMPLETED", ...]`), so the values stored in
  Postgres are the uppercase strings, not the atom names. A `group_by` written
  against the raw column would yield keys like `"ACTIVE"`, which would never
  match the `:active` atoms the zero-fill uses — silently producing an
  all-zero map plus unexpected extra keys. Composing over the schema field
  makes Ecto's enum loader map each value back to its atom first.

  `opts[:prefix]` is validated via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` **before** the
  query is constructed. Composed with `Ecto.Query` and bound parameters only
  (INV-7).
  """
  @spec count_instances_by_status(opts :: [prefix: String.t()]) ::
          {:ok, status_counts()} | {:error, :invalid_schema_name}
  def count_instances_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        InstanceProjection
        |> group_by([p], p.status)
        |> select([p], {p.status, count(p.instance_id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@instance_status_zero_fill, counts)}
    end
  end

  @doc """
  Counts `tasks` rows by `status`, scoped to `opts[:prefix]`. One query.

  Same keyword-mapped-enum caveat as `count_instances_by_status/1` — see its
  `@doc`. `tasks.status` stores `"PENDING"`/`"COMPLETED"`/`"CANCELLED"`, so
  the `group_by` is composed over the schema field, not the raw column.
  """
  @spec count_tasks_by_status(opts :: [prefix: String.t()]) ::
          {:ok, status_counts()} | {:error, :invalid_schema_name}
  def count_tasks_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        Task
        |> group_by([t], t.status)
        |> select([t], {t.status, count(t.id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@task_status_zero_fill, counts)}
    end
  end
end
