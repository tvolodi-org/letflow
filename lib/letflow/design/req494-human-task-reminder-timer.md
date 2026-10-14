# WF-02 Design -- REQ-494 / GH #2325: opt-in non-cancelling HUMAN_TASK reminder timer

Run-id: WF03-GH2325-REMINDER-20261014 (WF-02 CODE-DESIGNER step)
Branch: feature/WF03-GH2325-REMINDER-20261014
Type: backend feature (engine timer arming/firing, scheduler fire routing, definition validator,
one router error-body extension). No migration, no new event type, no new route.
Binding source: `docs/requirements.yaml` REQ-494 (FACTS, CHANGE 1-6, AC 1-12).
Diagnosis: `handoffs/WF03-GH2325-REMINDER-20261014/step-01-issue-fixer.json` (hazards h1-h4).
Prior design whose ordering this must respect: `lib/letflow/design/gh2359-gateway-reentry-task-row.md`
section 5 (cancel-before-arm) and section 3 (`post_completion_seed` / `consume_completed_position/3`).
Every line number below was read on this branch (cut from main incl. 05a0dfeb1).

## 1. What exists today (grounding)

| Fact | Source |
|---|---|
| `"reminder"` already an allowed timer type | `scheduler/timer.ex:48` `@timer_types ["deadline", "reminder", "escalation", "scheduled_transition"]`; only guard `validate_inclusion(:timer_type, @timer_types)` at `timer.ex:129` |
| No DB check on `timer_type` | `priv/repo/migrations/20260829020001_create_timers.exs:26-29` ("`timer_type` is plain :string, NOT Ecto.Enum ... `validate_inclusion/3` ... is the only guard"), column `:80` `add :timer_type, :string, null: false` |
| Recurrence columns exist | migration `:92-95` (`repeat_expression :string`, `repeat_interval_us :bigint`, `repeat_total :integer`, `fired_count :integer`); `chk_timers_recurrence_shape` `:111-121`; `Timer.arm_changeset/2` casts all four (`timer.ex:106-119`) |
| Re-arm keeps token/node/type | `Scheduler.build_rearm_attrs/2` `scheduler.ex:470-486` (`token_id: fired_timer.token_id`, `timer_type: fired_timer.timer_type`, `node_id: fired_timer.node_id`, `fire_at: DateTime.add(fired_timer.fire_at, fired_timer.repeat_interval_us, :microsecond)`, `fired_count: new_fired_count`) |
| Series cap semantics | `maybe_rearm_timer/3` `scheduler.ex:450-466`: `new_fired_count = fired_timer.fired_count + 1`; `if fired_timer.repeat_total != nil and new_fired_count >= fired_timer.repeat_total -> {:ok, :series_complete}`. So `repeat_total` = total number of fires |
| Fire routing (h1) | `do_fire/2` `scheduler.ex:297-328`: marks fired (`:301-304`), appends TIMER_FIRED (`:305-306`), `case timer.timer_type do "escalation" -> advance_after_escalation_timer_fired; _ -> advance_after_timer_fired end` (`:310-317`), then `maybe_rearm_timer(timer, now, tenant_schema)` unconditionally (`:323`) |
| TIMER_FIRED payload | `append_timer_fired_event/4` `scheduler.ex:373-393` (`timer_id, node_id, timer_type, fired_late, scheduled_fire_at, actual_fired_at`; idempotency key `"timer_fired:#{timer.id}"`); event type registered per tenant `tenant_provisioning.ex:1129` |
| Timer <-> task link | `timers.token_id` (`timer.ex:54`) is the TokenRecord id (`build_timer_arms_multi/4` `engine.ex:845-846`: `token_record_id = Map.fetch!(id_map, token_id)`, `Map.put(arm_attrs, :token_id, token_record_id)`); `tasks.token_id` (`engine/task.ex:59`) holds the same id (complete-task cancels with `normalized_changes.task.token_id`, `engine.ex:4553`; escalation fire finds the task `where t.token_id == ^timer.token_id and t.status == :pending`, `engine.ex:3106-3107`) |
| Escalation arm | `Transition.dispatch_human_task/3` `transition.ex:438-452` emits `{:escalation_timer_armed, token.token_id, node.id}` iff `escalation_timer_duration` is a non-empty binary (`:443-445`); `prepare_timer_arms/4` `engine.ex:700-772`; `resolve_escalation_timer_arm_attrs/4` `engine.ex:802-827`; step name `{:scheduler_escalation_timer, token_record_id}` `engine.ex:848-855`, every other type falls to `[prefix: prefix]` = default step `:scheduler_timer` (`scheduler.ex:152`) |
| Complete-task cancel position (GH #2359) | `build_complete_task_tail_multi/6` `engine.ex:4543-4558` `:cancel_escalation_timers` runs first, then `Multi.append(build_task_activation_and_reconciliation_multi(...))` `:4559-4566`, then timer arms `:4567-4597` |
| Escalation cancel helper | `TaskActivation.cancel_pending_escalation_timers/6` `task_activation.ex:555-577`, scoped `instance_id, token_id, node_id, timer_type == "escalation", status == "pending"`, reason hard-coded `"task_completed"` |
| Escalation fire Multi (h4) | `persist_escalation_timer_fired_advance/7` `engine.ex:3055-...`: `:original_task_row` `:3105-3114`, `:cancel_original_task` `:3116-3134` (uses `now` from `:3070`), audit merge `:3137-3158`, task activation `:3159-3191`, timer arms `:3192-3205` |
| Instance-end cancel (generic) | `finalize_instance_projection` `engine.ex:2045-2052` `TaskActivation.cancel_pending_timers(repo, instance_id, attrs.completed_at, "instance_completed", prefix)`; `cancel_instance/3` `engine.ex:5768-5774` reason `"instance_cancelled"`; helper `task_activation.ex:535-545` filters only `instance_id` + `status == "pending"` (untyped) |
| advance-timer ambiguity (h3) | `Scheduler.resolve_advance_target/3` `scheduler.ex:348-360` returns `{:error, :ambiguous_pending_timers}` for >1 pending; router `routers/instances.ex:757-758` `Response.bad_request(conn, "instance has more than one pending timer; specify timer_id")` |
| Problem-details extensions | `Response.bad_request/2` takes only `detail` (`api/response.ex:126-127` `def bad_request(conn, detail), do: send_problem(conn, Error.bad_request(detail))`); `send_problem/2` `response.ex:116-123`; `Error` struct has `extensions: nil` (`api/error.ex:70`), merged only when a non-empty map (`error.ex:128-134`); precedent `Error.output_refused/2` `error.ex:313-327` puts `"code"` in extensions |
| CHK-21 | `graph.ex:1071-1131`; registered in `validate_node_attributes/1` list `graph.ex:452-469` (`&check_human_task_escalation/1` at `:461`); highest is CHK-27 (`graph.ex:443`, `:1312`) |
| Duration grammar / parser | `valid_iso8601_duration?/1` `graph.ex:1401-1423` (private); `parse_iso8601_duration/1` `graph.ex:1482-1510` (public) with `Y = 365 days`, date-part `M = 30 days` (`graph.ex:1463-1468`) |
| RoleBinding | `task_roles/1` `role_binding.ex:32-47`, `for key <- ["role", "escalation_role"]` at `:37` |
| Audit | `Audit.append_multi/4` `audit.ex:182-191` (`multi, step_name :: atom, attrs :: entry_attrs, prefix`); `Audit.insert_entry/3` `audit.ex:231-240` (`repo, attrs, prefix`; safe to call directly inside a caller's `Repo.transaction/1`, moduledoc `:197-207`); `entry_attrs` `audit.ex:121-129` (`actor_id, action, resource_type, resource_id, before_state :: map | nil, after_state :: map | nil, trace_id`) |
| System actor | `EventStore.platform_actor_id/0` `event_store.ex:891`; same actor used for escalation `task.cancel` (`engine.ex:3068`, `:3147`) |

## 2. Arm paths: every place a HUMAN_TASK row is created

All six live paths below create task rows from the same hop-chain `pending_events` and arm timers
through the SAME two private functions, `prepare_timer_arms/4` and `build_timer_arms_multi/4`. The
reminder is therefore added in exactly those two functions (plus the `Transition` emitter) and
reaches every path with no per-call-site change.

| # | Path | Task rows created at | `prepare_timer_arms/4` call | `build_timer_arms_multi/4` call | `now` used |
|---|---|---|---|---|---|
| P1 | `create/2` (`start_instance/6`) | `TaskActivation.append_multi(...)` `engine.ex:1714` | `engine.ex:579-580` | `engine.ex:1685-1696` (id map `TaskActivation.token_id_to_record_id/2`) | `now` read once `engine.ex:555` |
| P2 | `complete_task/3` hop chain (incl. same-node re-entry, GH #2359) | `build_task_activation_and_reconciliation_multi/4` appended `engine.ex:4559-4566` | `engine.ex:4230-4231` (`completed_at`) | `engine.ex:4567-4597` | `completed_at` |
| P3 | TIMER-node fire (`advance_after_timer_fired/3` -> `persist_timer_fired_advance/7`) | `append_multi_from_existing_records` `engine.ex:2860` | `engine.ex:2808-2809` | `engine.ex:2880-2888` | `now` `engine.ex:2804` |
| P4 | escalation fire (`advance_after_escalation_timer_fired/3` -> `persist_escalation_timer_fired_advance/7`, incl. re-entry) | `engine.ex:3177` | `engine.ex:3074-3075` | `engine.ex:3192-3205` | `now` `engine.ex:3070` |
| P5 | service-task outcome continuation | `engine.ex:3751` | `engine.ex:3706-3707` | `engine.ex:3770-3778` | `now` `engine.ex:3701` |
| P6 | sub-process completion continuation (`SubProcess.build_completion_write_steps`) | `sub_process.ex:1027` | via `Engine.append_pending_event_arms_multi/8` `engine.ex:3330-3345`, called `sub_process.ex:1051-1061` | `engine.ex:3358-3368` | `completed_at` |

Not armed (pre-existing gap, inherited, out of scope): the INITIAL HUMAN_TASK rows of a child
instance (`sub_process.ex:583-591` `TaskActivation.insert_attrs(...)`) get neither an escalation
nor a reminder timer, because the child's activation discards its pending events
(`sub_process.ex:333-334` `{:ok, child_final_state, _pending_events} ->`). REQ-494 item 2 lists
create, complete-task, timer-fire and escalation-fire; this gap is identical for escalation today
and is recorded as OQ-4, not fixed here.

### 2.1 Emitter: `Transition.dispatch_human_task/3` (`transition.ex:438-452`)

New `pending_event()` variant appended to the type union at `transition.ex:152-161`:

    | {:reminder_timer_armed, token_id :: String.t(), node_id :: String.t()}

`dispatch_human_task/3` returns `{:ok, new_state, escalation_events ++ reminder_events}`, where
`reminder_events = [{:reminder_timer_armed, token.token_id, node.id}]` iff BOTH
`attributes["reminder_timer_duration"]` is a non-empty binary AND `attributes["reminder_role"]` is
a binary with `String.trim/1 != ""`; otherwise `[]`. Order: escalation event first, reminder
second. `pending_task_nodes` handling is unchanged (still one append, `transition.ex:439`).
Requiring the role as well as the duration (escalation keys on the duration only, `:443`) is a
deliberate hardening: a definition activated before CHK-28 existed could carry a stray
`reminder_timer_duration`; without a role it stays inert instead of arming a timer whose fire would
fail. Consumers that pattern-match pending events all filter or have catch-alls
(`engine.ex:665`, `:711`, `:714`, `:4409`; `reconstruction.ex:874-888` `_other_pending_event`), so
the new variant is ignored everywhere except `prepare_timer_arms/4`. The moduledoc paragraph at
`transition.ex:136-150` gains one sentence naming the new variant.

### 2.2 `prepare_timer_arms/4` (`engine.ex:700-772`)

* Add `reminder_arms = Enum.filter(pending_events, &match?({:reminder_timer_armed, _, _}, &1))`
  beside `escalation_arms` (`:713-714`), resolved with the same `Enum.find(graph.nodes, ...)` /
  `reduce_while` shape as `:732-750`, calling a new private resolver (2.3).
* The `length(timer_arms) > 1` guard (`:726`) still counts only `{:timer_armed, ...}`; reminder and
  escalation arms use compound step names and are exempt, like escalation today (`:730-731`).
* Result order: `escalation_prepared ++ reminder_prepared ++ deadline_prepared` (today
  `escalation_prepared ++ Enum.reverse(acc)` at `:767`).
* `@spec` (`:700-709`) is unchanged: the new resolver's errors reuse the existing tags
  `{:graph_structure_invalid, {:unknown_node_id, String.t()}}` and
  `{:invalid_timer_duration, node_id :: String.t(), value :: term()}`, so no caller's error
  handling or public error union changes. Both are defensive-only after CHK-28.

### 2.3 New private resolver, beside `resolve_escalation_timer_arm_attrs/4` (`engine.ex:802-827`)

    @spec resolve_reminder_timer_arm_attrs(
            Graph.Node.t(),
            node_id :: String.t(),
            instance_id :: Ecto.UUID.t(),
            now :: DateTime.t()
          ) ::
            {:ok, Scheduler.arm_attrs()}
            | {:error, {:invalid_timer_duration, node_id :: String.t(), value :: term()}}

Returned map, every key (no `:token_id`; filled by `build_timer_arms_multi/4` as for every type):

| Key | Value |
|---|---|
| `instance_id` | `instance_id` |
| `timer_type` | `"reminder"` |
| `node_id` | `node_id` |
| `fire_at` | `DateTime.add(now, seconds, :second)` where `{:ok, seconds} = Graph.parse_iso8601_duration(attributes["reminder_timer_duration"])` (same `now` as the escalation arm in the same call, REQ item 2). `"P0D"` gives `fire_at == now` |
| interval ABSENT (`reminder_repeat_interval` nil or key missing): `repeat_expression`, `repeat_interval_us`, `repeat_total`, `fired_count` | all four keys omitted (=> NULL), first branch of `chk_timers_recurrence_shape` (migration `:113-114`) |
| interval PRESENT: `repeat_expression` | the `reminder_repeat_interval` string verbatim, e.g. `"PT1H"` |
| `repeat_interval_us` | `interval_seconds * 1_000_000` where `{:ok, interval_seconds} = Graph.parse_reminder_repeat_interval(interval)` (section 6.2); `PT1H` -> `3_600_000_000` |
| `fired_count` | `0` |
| `repeat_total` | `1 + reminder_repeat_count` when the count is present (count 2 -> 3); `51` when the count is absent (50 repeats cap) |

Check-constraint proof for the interval branch (migration `:116-118`): `repeat_expression` not
null; `repeat_interval_us` not null (the constraint does not check > 0; the value is positive because `Graph.parse_reminder_repeat_interval/1` rejects zero or negative intervals at CHK-28); `fired_count = 0 >= 0`; `repeat_total` in 2..51,
so `>= 1` and `fired_count (0) <= repeat_total`. Re-armed successors keep `repeat_total` and have
`fired_count` 1..`repeat_total - 1` (`maybe_rearm_timer/3` inserts only while
`new_fired_count < repeat_total`, `scheduler.ex:454`), so `fired_count <= repeat_total` holds for
every row ever inserted. `Timer.rearm_changeset/2` requires `repeat_expression,
repeat_interval_us, fired_count` (`timer.ex:193-205`), all non-null on a recurring reminder.

Error cases: duration not a binary or `parse_iso8601_duration/1 == :error` ->
`{:error, {:invalid_timer_duration, node_id, raw_duration}}`; interval present but
`parse_reminder_repeat_interval/1 == :error`, or count present but not an integer in 1..50, or
count present with interval absent -> `{:error, {:invalid_timer_duration, node_id, raw_interval_or_count}}`.
All unreachable for a definition that passed CHK-28.

### 2.4 `build_timer_arms_multi/4` (`engine.ex:843-859`)

Add one `case arm_attrs.timer_type` clause: `"reminder" -> [prefix: prefix, step_name:
{:scheduler_reminder_timer, token_record_id}]`. Without it the reminder would take the `_ ->`
default `:scheduler_timer` step and RAISE on a duplicate step name whenever a deadline TIMER is
armed in the same hop chain (`scheduler.ex:152-155`). No signature change.

## 3. Fire: dedicated `"reminder"` branch (h1, h2)

### 3.1 `Scheduler.do_fire/2` (`scheduler.ex:297-328`) -- private, restructured

Steps in order (the first two are untouched, so TIMER_FIRED is appended for every reminder fire,
stale or not, REQ item 3):

1. `Timer.fire_changeset(%{status: "fired", fired_at: now})` (`:301-304`), unchanged.
2. `append_timer_fired_event/4` (`:305-306`), unchanged; payload `timer_type: "reminder"`.
3. Routing step now binds `{:ok, fire_outcome}` from a new private router:

        @spec route_fire(Timer.t(), tenant_schema :: String.t()) ::
                {:ok, :advanced | :reminded | :reminder_stale} | {:error, term()}

   `"escalation"` -> `Letflow.Engine.advance_after_escalation_timer_fired/3` (unchanged);
   `"reminder"` -> `Letflow.Engine.record_reminder_fired/3` (3.2);
   `_` -> `Letflow.Engine.advance_after_timer_fired/3` (unchanged). For the two existing branches
   only `{:ok, :advanced}` and `{:error, _}` pass through (the `{:ok, :advanced}` contract of
   `:310` is preserved exactly; an unexpected `{:ok, other}` is not silently accepted).
4. Re-arm step: `fire_outcome == :reminder_stale` -> skip, `{:ok, :not_rearmed_stale}` (no call to
   `maybe_rearm_timer/3`); otherwise `maybe_rearm_timer(timer, now, tenant_schema)` exactly as `:323`.
5. Return `{:ok, :fired}` in all three success outcomes. `else {:error, reason} -> {:error, reason}`
   unchanged.

`fire_timer/2`'s public `@spec` (`scheduler.ex:276-277`) is UNCHANGED:
`{:ok, :fired} | {:ok, :already_final} | {:error, term()}`. A stale reminder is `{:ok, :fired}`,
never `{:error, _}`, so `attempt_fire/2` (`:494-544`) returns `:fired`, never reaches
`safe_record_fire_failure/2` (`:577-581`), never `land_exhausted_timer/3` / `Dlq.enqueue/2`
(`:613-638`). `maybe_rearm_timer/3` (public, `:440-486`) is unchanged.

### 3.2 New `Letflow.Engine.record_reminder_fired/3` (beside `advance_after_escalation_timer_fired/3`, `engine.ex:2962-3014`)

    @doc false
    @spec record_reminder_fired(Timer.t(), Ecto.Repo.t(), prefix :: String.t()) ::
            {:ok, :reminded}
            | {:ok, :reminder_stale}
            | {:error, :snapshot_not_found}
            | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}}
            | {:error, {:invalid_reminder_role, node_id :: String.t()}}
            | {:error, term()}

Runs on the caller's repo inside `fire_timer/2`'s open `Repo.transaction/1`. Behaviour:

1. **Stale detection by task-row status, no new column.** The link is the existing triple
   `(timers.instance_id, timers.token_id, timers.node_id)` == `(tasks.instance_id, tasks.token_id,
   tasks.node_id)` (columns proven in section 1). Query (NO lock): `Letflow.Engine.Task` where
   `instance_id == ^timer.instance_id and token_id == ^timer.token_id and node_id ==
   ^timer.node_id and status == :pending`, `order_by desc: inserted_at, desc: id`, `limit 1`,
   `repo.one(prefix: prefix)`. At most one row matches (GH #2359 INV-3); the limit keeps it total.
   `timer.token_id == nil` (column is nullable, `timer.ex:54`) -> stale without querying.
   No task id is stored on the timer row and none is needed: every pending reminder for
   `(token, node)` belongs to the one pending task there, because the old task's reminders are
   cancelled before a re-entered task is armed (section 4).
2. No pending row -> `{:ok, :reminder_stale}`. No audit row, no graph read, no other write.
3. Pending row found -> `fetch_graph(timer.instance_id, prefix)` (`engine.ex:2571-2577`, a
   non-locking snapshot read) -> `Enum.find(graph.nodes, &(&1.id == timer.node_id))`
   (nil -> `{:error, {:graph_structure_invalid, {:unknown_node_id, node_id}}}`) ->
   `reminder_role = attributes["reminder_role"]`, required to be a non-blank binary
   (else `{:error, {:invalid_reminder_role, node_id}}`, defensive: the emitter in 2.1 already
   required it on the same immutable snapshot).
4. `fire_count = 1` when `timer.fired_count == nil` (non-recurring row); `timer.fired_count + 1`
   otherwise (`timer` is the pre-fire struct, as `scheduler.ex:318-322` notes).
5. `Audit.insert_entry(repo, attrs, prefix)` with exactly:
   `actor_id: EventStore.platform_actor_id()`, `action: "task.remind"`, `resource_type: "task"`,
   `resource_id: task.id`, `before_state: nil`,
   `after_state: %{"task_id" => task.id, "node_id" => timer.node_id, "reminder_role" => reminder_role, "fire_count" => fire_count}`
   (string keys, exactly four), `trace_id: nil`. `{:ok, _entry} -> {:ok, :reminded}`;
   `{:error, r} -> {:error, r}`.
6. Nothing else: the task row, tokens, `instance_projections.status`, variables and
   `current_nodes` are not written; `Transition` is not called; no edge is followed. (The
   projection's `last_event_seq` advances because step 2's TIMER_FIRED append updates it,
   `event_store.ex:774`; that is existing behaviour for every timer type.)

Why not lock the task row or the projection here: `complete_task/3` locks task -> projection
(`engine.ex:2505-2530`) and then UPDATEs timers; a reminder fire holds the timer row
(`scheduler.ex:395-400`), so taking task/projection row locks here would add a new lock-order
inversion. The read is non-locking; race analysis in section 7.

The instance status is not checked: an `:error` instance's pending task is genuinely overdue and is
reminded. A terminal instance cannot have a pending reminder except via the race in 7 (H-g).

## 4. Cancellation

### 4.1 New sibling helper (GH #2359 asked that `cancel_pending_escalation_timers/6` not be changed)

In `Letflow.Engine.TaskActivation`, directly after `cancel_pending_escalation_timers/6`
(`task_activation.ex:555-577`):

    @spec cancel_pending_reminder_timers(
            repo :: Ecto.Repo.t(),
            instance_id :: Ecto.UUID.t(),
            token_id :: Ecto.UUID.t(),
            node_id :: String.t(),
            cancelled_at :: DateTime.t(),
            cancel_reason :: String.t(),
            prefix :: String.t()
          ) :: {:ok, non_neg_integer()}

One `update_all` scoped `instance_id == ^instance_id and token_id == ^token_id and node_id ==
^node_id and timer_type == "reminder" and status == "pending"`, `set: [status: "cancelled",
cancelled_at: cancelled_at, cancel_reason: cancel_reason]`, on the caller's repo/prefix, same
status-guard semantics as `:563-577`. It catches re-armed successors too (they carry the same
token/node/type, `scheduler.ex:475-477`). `cancel_pending_escalation_timers/6` is untouched.

### 4.2 Complete-task (REQ 4a)

In `build_complete_task_tail_multi/6`, add `Multi.run(:cancel_reminder_timers, ...)` IMMEDIATELY
after `:cancel_escalation_timers` (`engine.ex:4547-4558`) and before the
`Multi.append(build_task_activation_and_reconciliation_multi(...))` at `:4559`. Arguments:
`normalized_changes.task.instance_id`, `.token_id`, `.node_id`, `completed_at`,
`"task_completed"`, `prefix`. Reads only `normalized_changes.task`, so it is dependency-safe at
that position (same argument as GH #2359 section 5). Resulting tail order:
`:cancel_escalation_timers`, `:cancel_reminder_timers`, task activation/reconciliation, timer
arms (`{:scheduler_escalation_timer, id}`, `{:scheduler_reminder_timer, id}`), service dispatch,
`:task_complete`, ... The cancel only sees rows that existed before this transaction's arm steps,
so a same-node re-entry's fresh reminder survives.

### 4.3 Escalation fire (REQ 4b, h4)

In `persist_escalation_timer_fired_advance/7`, add `Multi.run(:cancel_reminder_timers, ...)`
between `:cancel_original_task` (`engine.ex:3116-3134`) and the `task.cancel` audit merge
(`:3137`). Arguments: `timer.instance_id`, `timer.token_id`, `timer.node_id`, `now` (the same
`now` `:cancel_original_task` writes into the task's `cancelled_at`, `:3070`, `:3126`),
`"task_escalated"` (OQ-2), `prefix`. Runs whatever `:original_task_row` found (with
`:no_pending_task` it is a harmless status-guarded no-op). It precedes the arm merge
(`:3192-3205`), so an escalation re-entry `A -default-> gw -> A` keeps its fresh reminder.
Placed before the audit merge so this transaction takes the reminder rows' locks before the
tenant audit-chain lock (`audit.ex:242-243`), the order a concurrent reminder fire also uses
(timer row, then audit chain in 3.2 step 5); this avoids adding a timer/audit-chain AB-BA.
On the stale branch (`engine.ex:2979-2983`, token already moved) nothing is cancelled: the
original task's reminders were cancelled when it completed.

### 4.4 Instance completion / cancellation (REQ 4c): unchanged

`engine.ex:2045-2052` and `engine.ex:5768-5774` call `cancel_pending_timers/5`, whose query
(`task_activation.ex:536-542`) is `where([t], t.instance_id == ^instance_id and t.status ==
"pending")` with no `timer_type` filter, so it already cancels reminders with
`"instance_completed"` / `"instance_cancelled"`. No change.

## 5. POST /instances/:id/advance-timer (REQ item 5, h3)

Only `routers/instances.ex:757-758` changes. `Response.bad_request/2` cannot carry an extension
(`response.ex:127` builds `Error.bad_request(detail)` and sends it), so the clause builds the
problem itself and sends it with `Response.send_problem/2`:
`%Error{Error.bad_request("instance has more than one pending timer; specify timer_id") | extensions: %{"code" => "ambiguous_pending_timers"}}`
(`Error` is already aliased, `routers/instances.ex:311`; a private helper
`defp ambiguous_pending_timers_problem() :: Error.t()` is acceptable). No new `Error`
constructor: `type`/`title` must stay the generic bad-request ones (AC9).
`Error.serialise/1` takes the second clause (`error.ex:128-134`):
`Map.take([:type, :title, :status, :detail, :trace_id]) |> Map.merge(extensions)`.

Caller-visible responses (decoded JSON, content type `application/problem+json`):

| Case | Status | Body |
|---|---|---|
| >1 pending timer, no `timer_id` | 400 | exactly `{"type": <problems_base> <> "bad-request", "title": "Bad Request", "status": 400, "detail": "instance has more than one pending timer; specify timer_id", "trace_id": <conn trace id or "">, "code": "ambiguous_pending_timers"}`; six keys, no others |
| `timer_id` names a pending timer of this instance (reminder or other) | 200 | unchanged: `{"instance_id", "timer_id", "node_id", "timer_status": "fired"}` (`:762-770`); for a reminder the task stays pending |
| exactly one pending timer, no `timer_id` | 200 | unchanged |
| 0 pending / wrong instance | 404 | unchanged `Response.not_found/1` |
| malformed / invalid ids | 400 / 422 | unchanged |

Moduledoc table row `routers/instances.ex:17` gains "(`code: ambiguous_pending_timers`)" after
"400 ambiguous pending timers". `Scheduler.resolve_advance_target/3` unchanged.

## 6. Validator CHK-28 and RoleBinding

### 6.1 `check_human_task_reminder/1` (private, `graph.ex`, directly after CHK-21 `:1131`)

Registered in `validate_node_attributes/1` immediately after `&check_human_task_escalation/1`
(`graph.ex:461`); the `@doc` at `:429-450` gains a CHK-28 line. Only `:HUMAN_TASK` nodes are
checked (as CHK-21, `:1080`); reminder keys on other node types are ignored and inert (the emitter
is HUMAN_TASK-only). Non-map attributes -> `[]` (as `:1131`). `nil` value == key absent.

Per node, two independent parts; each yields at most ONE violation, so a node yields 0, 1 or 2.

Pair part (first matching rule wins):
1. `reminder_timer_duration` non-nil and (not a binary or `valid_iso8601_duration?/1` false) ->
   `:invalid_reminder_timer`. (Stricter than CHK-21, which lets a non-binary duration with a role
   through `:1099`.)
2. duration present and valid, and `reminder_role` not a binary with non-blank trim ->
   `:missing_reminder_role`.
3. duration nil and `reminder_role` non-nil -> `:missing_reminder_timer_duration`.

Repeat part, only when `reminder_repeat_interval` or `reminder_repeat_count` is non-nil; first
matching rule wins, all produce `:invalid_reminder_repeat`:
1. `reminder_timer_duration` nil or `reminder_role` nil (pair absent).
2. count non-nil and interval nil.
3. interval non-nil and `Graph.parse_reminder_repeat_interval(interval) == :error`.
4. count non-nil and not (`is_integer(count) and count in 1..50`) (floats, strings, booleans fail).

Messages name the node id and the attribute, e.g. `"Node 'a' (HUMAN_TASK) has an invalid
'reminder_repeat_interval' (\"P1M\"); only fixed-length units (W, D, H, M after T, S) greater than zero are allowed"`.

### 6.2 New public pure helper in `Letflow.Definitions.Graph`

    @spec parse_reminder_repeat_interval(term()) :: {:ok, pos_integer()} | :error

Returns `{:ok, seconds}` iff: the value is a binary; `valid_iso8601_duration?/1` is true; the date
part (text between `P` and the first `T`, or after `P` when there is no `T`) contains neither
`"Y"` nor `"M"`; and `parse_iso8601_duration/1` gives `{:ok, s}` with `s > 0`. Otherwise
`:error`. The explicit Y/M rejection is required because `parse_iso8601_duration/1` silently maps
`Y` to 365 days and date-part `M` to 30 days (`graph.ex:1463-1468`): `"P1M"` and `"P1Y"` are
grammatically valid and would otherwise pass. `"PT1M"` (minutes) passes; `"P0D"`, `"PT0S"` fail
(zero). One function used by both CHK-28 and the engine resolver (2.3), so the two cannot drift.

| Input | Result |
|---|---|
| `"PT1H"` | `{:ok, 3600}` |
| `"P1W"` | `{:ok, 604800}` |
| `"P1DT2H"` | `{:ok, 93600}` |
| `"PT30M"` | `{:ok, 1800}` |
| `"P0D"`, `"PT0S"` | `:error` |
| `"P1M"`, `"P1Y"`, `"P1Y2D"`, `"P1MT1H"` | `:error` |
| `"NOT-ISO"`, `3600`, `nil` | `:error` |

### 6.3 `RoleBinding.task_roles/1` (`role_binding.ex:37`)

Key list becomes `["role", "escalation_role", "reminder_role"]`; `@doc` (`:27-31`) names it.
Effect: an unbound `reminder_role` now appears in the advisory unbound-role warnings
(`warnings_for_definitions/2`, `:75-83`), never as a violation. `single_member_pairs/1` is NOT
changed (it is about `attributes["role"]` only, `:88`).

## 7. Duplicate-row and race hazards (GH #2359 lesson: Transition appends without removing)

| ID | Hazard | Resolution / proof |
|---|---|---|
| H-a | Same-node re-entry via complete-task arms a new reminder and the old one survives, or the cancel kills the new one | Cancel (4.2) runs before the arm merge (`engine.ex:4567`) and only sees `pending` rows existing before it; result: old R1 `cancelled/"task_completed"`, exactly one new pending R2 (same token/node, new id). Test T-07 |
| H-b | Same, via escalation fire re-entry | 4.3 runs before `:3192`; R1 `cancelled/"task_escalated"`, one new R2. Test T-08b |
| H-c | Node with both escalation and reminder arms twice or collides | Two prepared entries with distinct `timer_type`; distinct step names `{:scheduler_escalation_timer, id}` / `{:scheduler_reminder_timer, id}`; one row of each. Test T-02b |
| H-d | GH #2359's duplicate `{T,A}` entry in `pending_task_nodes` producing two reminder events | Events are emitted once per `dispatch_human_task/3` call (one per arrival), not derived from `pending_task_nodes`; the stale-entry strip (`consume_completed_position/3`, `engine.ex:2988-2996` and `post_completion_seed`) is unchanged. A duplicate event for one token would make `Ecto.Multi` raise on a duplicate step name (fail loud, not a silent double row), same as escalation |
| H-e | Sub-process continuation double events | `Enum.uniq(transition_pending_events ++ hop_pending_events)` `sub_process.ex:899-900` |
| H-f | Re-armed successor outlives its task | Successors carry token/node/type (`scheduler.ex:475-477`), so 4.1's scoped cancel catches them; a stale fire never re-arms (3.1 step 4) |
| H-g | `cancel_instance/3` racing a recurring reminder fire leaves an orphan pending successor | `cancel_instance/3` UPDATEs timers before locking the projection (`engine.ex:5751-5775`); its statement waits on the fired row's lock and does not see the successor inserted by the committing fire (READ COMMITTED statement snapshot). The orphan later fails TIMER_FIRED with `{:instance_terminated, :cancelled}` (`event_store.ex:592-593`), is retried and, after `max_fire_retries`, lands in the DLQ. Pre-existing for every recurring timer type; REQ 4c says instance end is unchanged. Residual, OQ-1 |
| H-h | Reminder fire vs `complete_task/3` / escalation fire on the same instance | No orphan: TIMER_FIRED's `update_projection` (`event_store.ex:774`) makes the fire wait for, or hold, the projection row lock that both other paths take before their cancel step (`engine.ex:2520-2524`, `:2976`), so their cancel statement starts after the fire commits and sees any successor. Deadlock possibility (fire holds timer and waits for the projection, the other holds the projection and waits for the timer row) is the SAME pre-existing class escalation timers already have with `:cancel_escalation_timers`; Postgres aborts one side (a fire abort is retried; a `complete_task` abort is a retriable caller error). Not introduced or widened beyond "one more timer row per task". The poller fires a tenant's due timers sequentially (`scheduler.ex:213-230`), so reminder vs escalation fires of one instance only overlap via concurrent advance-timer calls |

End state examples (token T, node A, reminder PT1H, escalation PT4H):

| After | `timers` rows for (T, A) |
|---|---|
| task created | E1 escalation pending; R1 reminder pending (`fire_at = now + 3600s`, recurrence NULL) |
| R1 fired | E1 pending; R1 fired; task pending; one `task.remind` (`fire_count 1`) |
| complete A, A -> gw -> A | E1 cancelled/`task_completed`; R1 (if still pending) cancelled/`task_completed`; E2 pending; R2 pending |
| E fires (no loop, A -> B) | E fired; R pending -> cancelled/`task_escalated` with `cancelled_at == task.cancelled_at` |

## 8. Caller-visible return shapes of every touched public function

| Function | Return (unchanged unless marked) |
|---|---|
| `Scheduler.fire_timer/2` | `{:ok, :fired}` for a reminder (reminded OR stale); `{:ok, :already_final}` for a non-pending row (e.g. reminder cancelled by completion); `{:error, term()}` on failure. Internal `:reminded` / `:reminder_stale` / `:series_complete` / `:not_rearmed_stale` are NOT visible; tests must assert rows, not these tags |
| `Scheduler.attempt_fire/2`, `poll_and_fire/1` | unchanged; a stale reminder counts as `fired` |
| `Scheduler.maybe_rearm_timer/3`, `resolve_advance_target/3`, `create/2` | unchanged |
| `Engine.record_reminder_fired/3` (NEW, `@doc false`) | `{:ok, :reminded} | {:ok, :reminder_stale} | {:error, ...}` per 3.2; only caller is `Scheduler.do_fire/2` |
| `Engine.create/2`, `Engine.complete_task/3`, `Engine.advance_after_timer_fired/3`, `Engine.advance_after_escalation_timer_fired/3`, `Engine.append_pending_event_arms_multi/8` | unchanged shapes; only extra rows written |
| `TaskActivation.cancel_pending_reminder_timers/7` (NEW) | `{:ok, non_neg_integer()}` |
| `TaskActivation.cancel_pending_escalation_timers/6`, `cancel_pending_timers/5` | unchanged |
| `Transition.transition/3` | `{:ok, InstanceState.t(), [pending_event()]}`; a HUMAN_TASK arrival may now include `{:reminder_timer_armed, token_id, node_id}` after any `{:escalation_timer_armed, ...}` |
| `Graph.validate_node_attributes/1` | `%{valid: boolean(), violations: [%Violation{code: atom(), message: String.t()}]}`; new codes `:invalid_reminder_timer`, `:missing_reminder_role`, `:missing_reminder_timer_duration`, `:invalid_reminder_repeat` |
| `Graph.parse_reminder_repeat_interval/1` (NEW) | `{:ok, pos_integer()} | :error` |
| `RoleBinding.task_roles/1` | `[%{role_name: String.t(), node_ids: [String.t()]}]`, now including reminder roles |
| `POST /instances/:id/advance-timer` | section 5 table |

## 9. Test matrix

Seams that exist today: timers are fired deterministically with `Scheduler.fire_timer/2`, ignoring
`fire_at`, e.g. `test/letflow/engine/gh2359_gateway_reentry_task_row_test.exs:329`
`assert {:ok, :fired} = Scheduler.fire_timer(e1.id, ctx.schema_name)` and
`test/letflow/engine/human_task_escalation_test.exs:156-158` ("Force-fire the escalation timer
directly (bypasses poll's fire_at check ..."). Case helpers to copy (not import) from the gh2359
file: `tenant_schema!/0` (`TenantFixture.provisioned_tenant!/1`), `activate!/3`
(`Definitions.create/2` + `Definitions.activate/2`, which runs CHK-28), `start_instance!/3`,
`complete/3` (random `actor_id` UUID; no user rows needed), `tasks_at/2`, `pending/1`,
`reload_task!/2`, `projection!/1`, `event_count/1`, `assert_no_duplicate_pending!/1`. No optional
arguments in helpers (`docs/anti-patterns.md` ~L1968). Audit rows: query `Letflow.Audit.Entry`
by `resource_type == "task" and resource_id == ^task.id and action == "task.remind"` as
`human_task_escalation_test.exs:177-187` does. DLQ: `Letflow.Dlq.Entry` by `reference_id`.
Router: `build_conn/4` + `dispatch/1` with `roles: ["PROCESS_OPERATOR"]` and
`pending_timer_ids/2` (`routers/instances_test.exs:184-189`, `:584-653`).

Fixture nodes (string-keyed, as gh2359):
`ht(id)` = `%{"id"=>id,"node_type"=>"HUMAN_TASK","attributes"=>%{"role"=>"r"}}`;
`ht_rem(id, dur)` adds `"reminder_timer_duration"=>dur, "reminder_role"=>"r-remind"`;
`ht_rem_rep(id, dur, interval, count)` adds `"reminder_repeat_interval"=>interval,
"reminder_repeat_count"=>count`; `ht_rem_rep_no_count(id, dur, interval)` adds only the interval
(separate helpers, no optional arg);
`ht_rem_esc(id, rdur, edur)` = `ht_rem` plus `"escalation_timer_duration"=>edur, "escalation_role"=>"r-escalated"`;
`ht_rem_rep_no_count_esc(id, rdur, interval, edur)` = `ht_rem_rep_no_count` plus the escalation pair.
Graphs: `G_ab` = `start -> a -> b -> end` (instance stays active after `a`);
`G_loop(a)` = gh2359 `direct_graph/1` (`a -> gw`, `gw -[approved==true]-> end`, `gw -[default]-> a`);
`G_timer` = `start -> t (TIMER "PT1H") -> a -> end`; `G_esc_ab` = `start -> a(esc) -> b -> end`.

New files: `test/letflow/engine/req494_human_task_reminder_timer_test.exs`
(`Letflow.Engine.Req494HumanTaskReminderTimerTest`, `use Letflow.DataCase, async: false`);
`test/letflow/definitions/reminder_validation_test.exs` (pure, `async: true`). Extended:
`test/letflow/definitions/role_binding_test.exs`, `test/letflow/routers/instances_test.exs`
(`describe "advance-timer"`). NOT edited: every file named in AC11.

| ID | AC | Test (describe / name) | Setup | Expected |
|---|---|---|---|---|
| T-01 | 1 | engine / "no reminder_* keys arms no reminder timer on create, complete, timer fire, escalation fire" | (i) `G_ab` with `ht("a")`, `ht("b")`: create, complete a; (ii) `G_timer` with `ht("a")`: fire t's deadline timer; (iii) `G_esc_ab` with a = escalation `"PT1H"`, role `r-escalated`, no reminder, `ht("b")`: fire the escalation timer | after each step `count(timers where instance_id and timer_type == "reminder") == 0`; (iii) escalation still behaves as today (a cancelled, b pending). Plus a static assertion test: `System.cmd("git", ["grep", "-l", "reminder_", "--", "test/fixtures", "priv", "scripts"])` returns exit 1 / empty output (today: `grep -rln "reminder_" test/fixtures priv scripts` prints nothing, exit 1, run on this branch) |
| T-02a | 2 | engine / "a reminder-only node arms exactly one pending reminder on task creation" | `G_ab`, a = `ht_rem("a", "PT1H")` | exactly 1 `timers` row with `timer_type "reminder"`, `status "pending"`, `node_id "a"`, `token_id == task.token_id`, all four recurrence columns nil; `abs(DateTime.diff(r.fire_at, DateTime.add(task.inserted_at, 3600, :second), :millisecond)) <= 1000`; 0 escalation rows |
| T-02b | 2 | engine / "a node with reminder and escalation arms one of each, escalation unchanged" | `G_ab`, a = `ht_rem_esc("a", "PT1H", "PT4H")` | exactly 1 pending reminder (fire_at ~ inserted_at+3600s within 1s) and exactly 1 pending escalation (fire_at ~ inserted_at+14400s within 1s), both same token/node; total pending timers 2 |
| T-02c | 2 | engine / "reminders are armed on complete-task, timer-fire and escalation-fire paths" | (i) `G_ab`, b = `ht_rem("b","PT1H")`, complete a; (ii) `G_timer`, a = `ht_rem("a","PT1H")`, fire t; (iii) `G_esc_ab`, a escalation-only, b = `ht_rem("b","PT1H")`, fire escalation | each: exactly one pending reminder for the new task's token at its node, fire_at within 1s of `task.inserted_at + 3600s` |
| T-02d | 2 (H-c, step names) | engine / "a reminder and a deadline TIMER armed in one hop chain do not collide" | `start -> split(PARALLEL) -> a (ht_rem "PT1H")` and `split -> t (TIMER "PT1H") -> join`, `a -> join`, `join -> end` | `Engine.create/2` returns `{:ok, _}`; 1 pending reminder at a, 1 pending deadline at t |
| T-03 | 3 | engine / "firing a non-recurring reminder records it and changes nothing else" | `G_ab`, a = `ht_rem("a","PT1H")`; snapshot before: task row, `TokenRecord`s (id, node_id, status), projection `status`, `variables`, `current_nodes`, `count(tasks)` | `{:ok, :fired} = Scheduler.fire_timer(r.id, schema)`; task row equal to before (status `:pending`, same `updated_at`); token node_id `"a"`; projection status/variables/current_nodes `==` before; `count(tasks)` unchanged; exactly one `TIMER_FIRED` event whose decoded payload has `"timer_id" == r.id` and `"timer_type" == "reminder"`; exactly one `task.remind` entry with `actor_id == EventStore.platform_actor_id()`, `resource_id == task.id`, `before_state == nil`, `after_state == %{"task_id" => task.id, "node_id" => "a", "reminder_role" => "r-remind", "fire_count" => 1}`; no event of any other type added (event count +1); r.status `"fired"`; 0 pending reminders |
| T-04a | 4 | engine / "an interval PT1H count 2 series fires 3 times then completes" | `G_ab`, a = `ht_rem_rep("a","PT2H","PT1H",2)` | armed row: `repeat_expression "PT1H"`, `repeat_interval_us 3_600_000_000`, `fired_count 0`, `repeat_total 3`. Fire row1 -> audit `fire_count 1`, new pending row2 `fired_count 1`, `fire_at == row1.fire_at + 3600s` exactly; fire row2 -> `fire_count 2`, row3 `fired_count 2`; fire row3 -> `fire_count 3`, and NO pending reminder remains; total reminder rows 3; 3 `task.remind` rows with fire_count `[1,2,3]` |
| T-04b | 4 | engine / "interval without count arms repeat_total 51" | a = `ht_rem_rep_no_count("a","PT1H","P1W")` | `repeat_total 51`, `repeat_expression "P1W"`, `repeat_interval_us 604_800_000_000`, `fired_count 0` |
| T-04c | 4 | (covered by T-02a) no interval -> four NULLs | | |
| T-05a | 5 | engine / "a reminder fired after its task completed is stale: no audit, no re-arm, no DLQ" | `G_ab`, a = `ht_rem_rep("a","PT1H","PT1H",2)`; complete a (R1 cancelled); simulate the race orphan: `Repo.update_all(from(t in Timer, where: t.id == ^r1.id), set: [status: "pending", cancelled_at: nil, cancel_reason: nil], prefix: schema)` | `{:ok, :fired} = Scheduler.fire_timer(r1.id, schema)`; exactly 1 `TIMER_FIRED` with `timer_id == r1.id`, `timer_type "reminder"`; 0 `task.remind` rows; 0 pending reminder rows for the instance; `Dlq.Entry` with `reference_id == r1.id` count 0; r1 `status "fired"`, `fire_error_count 0` |
| T-05b | 5 | engine / "a reminder fired after its task was cancelled by escalation is stale" | `G_esc_ab`, a = `ht_rem_esc("a","PT1H","PT4H")`; fire escalation (R1 cancelled); resurrect R1 as above | same assertions as T-05a |
| T-06 | 6 | engine / "completing the task cancels its reminder with reason task_completed" | `G_ab`, a = `ht_rem("a","PT1H")` | after complete: R1 `status "cancelled"`, `cancel_reason "task_completed"`, `cancelled_at` not nil; 0 pending reminders |
| T-06b | 6 (scope) | engine / "completing one task does not cancel a sibling token's reminder" | `start -> split(PARALLEL) -> a (ht_rem)`, `split -> c (ht_rem)`, `a -> join`, `c -> join`, `join -> end` | complete a: a's reminder cancelled; c's reminder still pending |
| T-07 | 7 | engine / "re-entry after completion arms a fresh reminder and cancels the old" | `G_loop(ht_rem("a","PT1H"))`, complete a with `approved=false`; variant with `ht_rem_esc("a","PT1H","PT4H")` | exactly one new pending task at a (`assert_no_duplicate_pending!`); R1 cancelled/`task_completed`; exactly one pending reminder R2, `R2.id != R1.id`, same token/node; variant: also exactly one pending escalation, total pending timers 2 |
| T-08a | 8 | engine / "reminder and escalation coexist; escalation cancels the reminder in the same transaction" | `G_esc_ab`, a = `ht_rem_rep_no_count_esc("a","PT1H","PT1H","PT4H")` | fire R1: task a pending, 1 `task.remind`, successor R2 pending. Fire E: task a `:cancelled`; R2 `status "cancelled"`, `cancel_reason "task_escalated"`, `R2.cancelled_at == reload(task_a).cancelled_at`; 0 pending reminders for (T, a); task b pending |
| T-08b | 7/8 (H-b) | engine / "escalation re-entry keeps a fresh reminder" | `G_loop(ht_rem_esc("a","PT1H","P0D"))` | fire E1: old task cancelled, R1 cancelled/`task_escalated`, exactly one new pending R2 and one new pending E2 for the new task row |
| T-09a | 9 | advance-timer / "two pending timers and no timer_id return 400 with code ambiguous_pending_timers" | instance on `G_ab` with a = `ht_rem_esc("a","PT1H","PT4H")` | 400; `Jason.decode!(resp_body) |> Map.keys() |> Enum.sort()` is exactly `["code","detail","status","title","trace_id","type"]`; `"code" == "ambiguous_pending_timers"`, `"detail" == "instance has more than one pending timer; specify timer_id"`, `"status" == 400`, `"title" == "Bad Request"`, `"type" == Error.bad_request("x").type`; content type `application/problem+json`; still 2 pending timers |
| T-09b | 9 | advance-timer / "timer_id naming the reminder fires only the reminder" | same instance, body `%{"timer_id" => r.id}` | 200, `"timer_id" == r.id`, `"node_id" == "a"`, `"timer_status" == "fired"`; task still pending; escalation still pending |
| T-09c | 9 | existing `:586` and `:625` tests unchanged and green (single pending -> 200; two deadlines -> 400) | | the existing AC7 test additionally passes untouched |
| T-10 | 10 | CHK-28 / one test per row | `attr_node`-style HUMAN_TASK graphs (pure) with `"role" => "approver"` | `:invalid_reminder_timer`: duration `"NOT-ISO"` + role; `:missing_reminder_role`: duration `"PT1H"`, role `nil` / `""` / `"   "`; `:missing_reminder_timer_duration`: role only; `:invalid_reminder_repeat`: interval `"PT1H"` without pair; count 2 with pair but no interval; count 51; count 0; count `2.0`; count `"2"`; interval `"P0D"`; `"P1M"`; `"P1Y"`; `"NOT-ISO"`. Valid (empty violations): pair only (`"PT1H"`, role); pair + `"PT1H"`; pair + `"P1W"`; pair + `"PT1H"` + count 50; pair with duration `"P0D"`. Each invalid case asserts `codes(result) == [code]` and the message contains the node id |
| T-10b | 10 | Graph pure / "parse_reminder_repeat_interval/1" | table in 6.2 | exact results |
| T-10c | 10 | role_binding / "collects reminder_role" | `human("a", %{"role"=>"role-a","reminder_role"=>"role-r"})` | `task_roles/1` includes `%{role_name: "role-r", node_ids: ["a"]}` |
| T-11 | 11 | no new test; the listed files run unedited | | `git diff --stat main -- <those files>` empty; suite green |
| T-12 | 12 | command gate | | section 9.2 commands with real output quoted by TEST-RUNNER / RELEASE-VALIDATOR |

### 9.1 Mutants TEST-DESIGN-VALIDATOR should run (each must turn at least the named test red)

| Mutant | Must fail |
|---|---|
| M1 drop the stale check (always write `task.remind`) | T-05a, T-05b |
| M2 re-arm even when stale (call `maybe_rearm_timer/3` unconditionally, today's `:323`) | T-05a (pending successor appears) |
| M3 remove the escalation-fire `:cancel_reminder_timers` step | T-08a |
| M4 move the escalation-fire cancel after the arm merge | T-08b |
| M5 move the complete-task reminder cancel after the arm merge | T-07 |
| M6 cancel helper scoped by instance only (drop token/node filter) | T-06b, T-08b |
| M7 remove the `"reminder"` routing branch (falls to `advance_after_timer_fired/3`) | T-03 (`{:error, _}`), T-04a |
| M8 `fire_count = fired_count` (off by one) | T-03, T-04a |
| M9 `repeat_total = count` / `50` | T-04a / T-04b |
| M10 reminder step name falls to the default `:scheduler_timer` | T-02d |
| M11 reminder emitted only when escalation is present | T-02a |
| M12 accept `M` in the date part in `parse_reminder_repeat_interval/1` | T-10 (`"P1M"`), T-10b |
| M13 router keeps `Response.bad_request/2` (no `code`) | T-09a |
| M14 `cancel_reason` of the escalation path changed to `"task_completed"` | T-08a |

### 9.2 Commands (AC12)

    LETFLOW_DEV_DB_CONFIRMED=1 MIX_ENV=test mix compile --warnings-as-errors
    mix format --check-formatted
    LETFLOW_DEV_DB_CONFIRMED=1 MIX_ENV=test mix test test/letflow/engine test/letflow/scheduler_test.exs test/letflow/scheduler_req188_test.exs test/letflow/scheduler test/letflow/definitions test/letflow/routers/instances_test.exs test/letflow/scripts
    mix letflow.check_boundaries

## 10. Blast radius

* Files: `lib/letflow/engine/transition.ex` (type union + `dispatch_human_task/3`),
  `lib/letflow/engine.ex` (`prepare_timer_arms/4`, new `resolve_reminder_timer_arm_attrs/4`,
  `build_timer_arms_multi/4` clause, `:cancel_reminder_timers` in two Multis, new
  `record_reminder_fired/3`), `lib/letflow/engine/task_activation.ex` (+1 function),
  `lib/letflow/scheduler.ex` (`do_fire/2` routing/re-arm step, private `route_fire/2`),
  `lib/letflow/definitions/graph.ex` (CHK-28 + `parse_reminder_repeat_interval/1`),
  `lib/letflow/definitions/role_binding.ex` (one key), `lib/letflow/routers/instances.ex`
  (one clause + moduledoc row). Tests per section 9.
* Behaviour change for definitions WITHOUT `reminder_*`: none in rows (no event emitted, no row
  armed). Two observable deltas on shared steps: (a) one extra no-op `UPDATE` per task completion
  and per escalation fire (0 rows); (b) a stray definition activated before CHK-28 that carries
  BOTH `reminder_timer_duration` and `reminder_role` starts arming reminders (no shipped definition
  does: grep in T-01; tenant-authored ones are not inspectable from here, OQ-5).
* No migration: `timer_type` is a free string with no DB check (migration `:26-29`, `:80`),
  `"reminder"` is already in `@timer_types` (`timer.ex:48`), the recurrence quartet and its CHECK
  accept every row shape in 2.3 (proof there). No new event type (TIMER_FIRED reused, registry
  `tenant_provisioning.ex:1129`); `audit_entries.action` is a free string (diagnosis, migration
  20260830020001), so `"task.remind"` needs no schema change.
* Unchanged: `cancel_pending_escalation_timers/6`, `cancel_pending_timers/5`,
  `maybe_rearm_timer/3`, `resolve_advance_target/3`, `fire_timer/2` spec, every HTTP route other
  than the one 400 body, the SPA.
* Not changed but affected for opted-in definitions only (listed, not edited, per REQ OQ):
  UAT `uat/scenarios/swiftroute/shipment-ops-timeout-escalation.yaml:67` (advance-timer without
  `timer_id`); `test/support/simulation/runner.ex:404-417` `Repo.get_by(Timer, [instance_id,
  node_id, status: "pending"])` would raise `Ecto.MultipleResultsError` for a node carrying both
  timers (OQ-3).
* SECURITY-REVIEWER n/a (REQ-494 and GH #2325 AC4): no new route; the 400 body adds one constant
  string and no entity data (INV-2/INV-4 unaffected); every new read/write (`tasks`, `timers`,
  `audit_entries`, definition snapshot) is on existing tenant-schema tables through the caller's
  `prefix` (`scheduler.ex:166` derives `tenant_id` from the prefix; `Audit.insert_entry/3`
  resolves tenant from the prefix, `audit.ex:233-235`); no cross-tenant read, no egress, no
  notification channel. Becomes required only if a later requirement adds a notification
  table/route or email.
* REVIEWER required (shared Multi step order, scheduler routing).

## 11. Open questions / ambiguities

* OQ-1 (residual, not built): H-g, `cancel_instance/3` vs a recurring reminder fire can leave an
  orphan successor that later goes to the DLQ via `{:instance_terminated, :cancelled}`.
  Pre-existing for every recurring timer; REQ 4c keeps instance-end cancellation unchanged. Fix
  options for a follow-up: run `cancel_pending_timers/5` twice (second statement sees committed
  successors) or have `do_fire/2` mark a reminder on a terminal instance cancelled before the
  TIMER_FIRED append. Flag to REVIEWER.
* OQ-2 (decided here, REQ silent): escalation-path `cancel_reason` is `"task_escalated"` (precise;
  distinguishes from the instance-level reasons). `"task_cancelled"` is the alternative if ORCH
  prefers the GH #2325 AC2 wording; T-08a/M14 pin whichever is chosen.
* OQ-3: `test/support/simulation/runner.ex:407-411` and REQ-494's own listed UAT scenario assume
  one pending timer per node; harmless until a shipped definition opts in (the vortex 8D
  follow-up, GH #2325 AC3, must pass `timer_id` or filter by type).
* OQ-4: child-instance initial HUMAN_TASKs arm neither escalation nor reminder
  (`sub_process.ex:333-334`); inherited gap, separate issue if wanted.
* OQ-5: the emitter requires the role as well as the duration (2.1), a deliberate difference from
  escalation; it only matters for definitions that bypassed CHK-28.
* REQ open questions carried: cap 50 is used as written; no reminder >= escalation warning is built.
* No question blocks the build.
