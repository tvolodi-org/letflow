defmodule Letflow.Scheduler.RecordDeadlineSweep do
  @moduledoc """
  Generic deadline-driven record transition sweep (REQ-331). Given a
  **configured** entity type, datetime field, and status field/value, finds
  records in one tenant schema whose datetime field is in the past and whose
  status field matches, and applies a configured status transition to each,
  one `Repo.transaction/1` per record. Called by
  `Letflow.Scheduler.Poller`'s eighth per-tenant sweep -- this module itself
  starts no process and owns no state, the same "plain context module called
  by Poller" shape `Letflow.Scheduler`/`Letflow.Ordering` already use.

  Provenance: FR-BB310, `backend/internal/sessions/autojob.go`. Cited here
  as a bare path plus FR-BB id only, per 0022 rule 1 and this requirement's
  own hard constraint -- no further description of what that file does is
  given in this module, its comments, or its tests.

  ## Rule-1 vocabulary constraint (hard, checked mechanically)

  No module, function, config key, permission atom, log message, error
  atom, test name, or comment produced for this requirement names the six
  forbidden words. A `rule()` is fully generic: an entity type name, a
  datetime field name, a status field name/value pair, a new status value,
  and two optional extras (a completion-timestamp field, a post-commit
  callback) -- nothing here is specific to any one vertical.

  ## Where a sweep rule is declared, who may declare one, permission atom

  A `rule()` is declared in **Application config** (`config :letflow,
  :deadline_sweep, rules: [...]`), read fresh on every call via
  `Application.get_env/3` -- never cached, matching this platform's existing
  `:ordering`/`:alert_hooks` config-gated sweeps
  (`lib/letflow/scheduler/poller.ex`'s own `maybe_run_ordering_cycle/1` and
  `maybe_run_alert_detection/3`), which are declared exactly the same way for
  exactly the same reason. This is a **deploy-time, platform-operator-only**
  declaration -- there is no HTTP route, permission-gated action, or any
  other runtime mechanism by which a tenant (or anyone acting as one) can
  create, edit, or remove a rule. Consequently **no new permission atom is
  needed**: nothing in this requirement's scope exposes a capability that a
  permission could gate, because nothing here is reachable from tenant-scoped
  request handling at all.

  This directly satisfies the INV-1 constraint this requirement's own
  acceptance criteria name ("a tenant cannot configure a sweep over another
  tenant's data") **by construction, not by an application-level check**: since
  no tenant-facing code path can write or influence `:deadline_sweep` config,
  there is no way for a tenant to configure anything here in the first place,
  for its own data or anyone else's. What INV-1 *does* still require -- and
  what `run/2` still enforces explicitly -- is that every read and write this
  module issues carries the tenant schema it was asked to sweep as an
  explicit `prefix:` option (never a `tenant_id` looked up from the config or
  from a query result), so the *same* rule, applied identically to every
  schema `Letflow.Scheduler.Poller` iterates, only ever reads and writes
  inside the one schema it was called for.

  A config-key/deploy-only declaration was chosen over an
  `entity_definitions`-attribute or a new dedicated table for the same reason
  `docs/requirements.yaml`'s REQ-331 text itself gives for bucket B over
  bucket A: a definition is declarative data with no execution context, and
  this platform's declared verticals do not yet need a **tenant-self-service**
  way to declare a sweep rule (no acceptance criterion asks for one) -- adding
  either a definition attribute or a new table now, ahead of a real caller
  needing tenant-level self-service, would be exactly the speculative-generality
  failure mode `docs/anti-patterns.md`/decision `0022` both exist to prevent.
  If a future requirement needs a tenant to self-declare its own rule, that is
  a new requirement's own scope, not a silent widening of this one.

  ## Concurrency (AC-9)

  Two application instances (or two concurrent sweep ticks) must never
  transition the same row twice. `run/2` claims and transitions **one**
  record at a time -- `fetch_one_due_locked/3`'s query ends in `limit(1) |>
  lock("FOR UPDATE SKIP LOCKED")`, executed inside the *same*
  `Repo.transaction/1` call that performs the transition, so the lock is held
  for exactly the duration of that one record's own write. A second, truly
  concurrent caller racing for the same row gets `nil` back from that locked
  `Repo.one/2` (SKIP LOCKED excludes an already-locked row rather than
  blocking for it) and moves on to whatever else is due -- see
  `test/letflow/scheduler/record_deadline_sweep_test.exs`'s
  "AC-4 SKIP LOCKED" describe block for the empirical proof, including how it
  was validated that removing the lock clause makes the test fail.

  ## Per-record transaction isolation (AC-8)

  `sweep_tenant/2` claims and transitions records one at a time in a loop,
  each iteration its own `Repo.transaction/1` call (via `claim_and_transition_one/2`).
  A record whose transition fails (a changeset error, a raised exception
  from `Letflow.Entities.Records.update_record/2`, anything) rolls back
  *only that one record's* transaction via `Repo.rollback/1` and is logged;
  the loop continues to the next due record regardless, and every other
  tenant schema `Letflow.Scheduler.Poller` iterates is wholly unaffected
  (that isolation lives in `Poller`'s own `run_sweep/4` `try/rescue`, not
  here).

  ## Managed types (GH #2583)

  The sweep writes through `Letflow.Entities.Records.update_record/2`, i.e.
  with the `:tenant` authority, so it touches no managed type by
  construction (decision 0054 D12: no entity write from timers). A rule on a
  `managed_by` type makes `Records` answer `{:error, :entity_type_managed}`
  for each due record: that record's transaction rolls back, the per-record
  warning above logs ids and the reason atom only (never `field_values`), the
  id joins `failed_ids` for the rest of the call, and the next tick retries
  and is refused again. There is no rule pre-check.

  ## The completion-timestamp detail (AC-3/AC-5)

  When a `rule()` names a `:completion_field`, the transitioned record's
  `field_values[completion_field]` is set to the **exact, unmodified string
  value already stored** at `field_values[datetime_field]` -- the deadline
  the record was due against -- never to `DateTime.utc_now()` at the moment
  the sweep actually ran. A record due at `T` and swept at `T` plus any delay
  still completes at `T`. See
  `test/letflow/scheduler/record_deadline_sweep_test.exs`'s "AC-6 completion
  timestamp" describe block, which asserts the exact value, not a range.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Repo

  @type rule :: %{
          required(:entity_type) => String.t(),
          required(:datetime_field) => String.t(),
          required(:status_field) => String.t(),
          required(:due_status_value) => String.t(),
          required(:new_status_value) => String.t(),
          optional(:completion_field) => String.t() | nil,
          optional(:callback_mfa) => {module(), atom(), list()} | nil
        }

  # A fixed, well-known nil-UUID system actor -- this sweep is never invoked
  # by a real user, so there is no `actor_id` to thread through from a
  # request. Matches the shape (a constant sentinel actor id for a
  # system-triggered write), not the value, of other system-triggered write
  # paths in this codebase.
  @system_actor_id "00000000-0000-0000-0000-000000000000"

  # Caps how many records one call to run/2 will transition for one
  # (tenant, rule) pair in a single tick -- prevents one very backed-up
  # tenant/rule from starving `Letflow.Scheduler.Poller`'s own tick cadence.
  # A tenant with more than this many due records simply catches up over
  # several ticks, matching the existing scheduler's own "no special-cased
  # recovery logic, the next tick catches up" posture.
  @default_batch_limit 500

  @doc """
  Sweeps `tenant_schema` for `rule`, transitioning up to `@default_batch_limit`
  due records, one `Repo.transaction/1` per record. Called by
  `Letflow.Scheduler.Poller`'s per-tenant sweep loop; never raises past this
  function under a rule/record processing failure -- Poller's own
  `with_admission/3`/`run_sweep/4` wrapping around this call still applies as
  defense in depth, matching every other sweep's convention, but this
  function's own per-record loop already isolates a single record's failure
  internally (see moduledoc).
  """
  @spec run(tenant_schema :: String.t(), rule()) :: :ok
  def run(tenant_schema, rule) when is_binary(tenant_schema) and is_map(rule) do
    sweep_tenant(tenant_schema, normalize_rule(rule), @default_batch_limit, MapSet.new())
    :ok
  end

  defp normalize_rule(rule) do
    Map.merge(%{completion_field: nil, callback_mfa: nil}, rule)
  end

  defp sweep_tenant(_tenant_schema, _rule, 0, _failed_ids), do: :ok

  # `failed_ids` (AC-8) -- a record whose transition just failed is excluded
  # from `fetch_one_due_locked/3` for the REST OF THIS CALL, not retried
  # forever within one tick. Without this, a permanently-failing due record
  # (ordered first) would be reselected by every subsequent iteration --
  # since a rolled-back attempt leaves its status field unchanged, still due
  # -- starving every other due record behind it in this same tenant/rule
  # for the whole batch. The next tick still retries it fresh (empty
  # `failed_ids`), which is the intended, no-special-recovery-logic posture
  # this scheduler already uses elsewhere (Poller's own moduledoc).
  defp sweep_tenant(tenant_schema, rule, remaining, failed_ids) when remaining > 0 do
    case claim_and_transition_one(tenant_schema, rule, failed_ids) do
      :none ->
        :ok

      {:transitioned, record_id} ->
        invoke_callback(rule, record_id, tenant_schema)
        sweep_tenant(tenant_schema, rule, remaining - 1, failed_ids)

      {:record_error, record_id, reason} ->
        Logger.warning(
          "deadline sweep: one record failed to transition, continuing with the rest",
          schema: tenant_schema,
          entity_type: rule.entity_type,
          record_id: record_id,
          reason: inspect(reason)
        )

        sweep_tenant(tenant_schema, rule, remaining - 1, MapSet.put(failed_ids, record_id))
    end
  end

  # One transaction, one record: the locked SELECT and the write it guards
  # happen inside the same Repo.transaction/1 call (AC-8/AC-9). A failed
  # transition rolls back only this one call via Repo.rollback/1 -- it never
  # raises out of this function.
  @spec claim_and_transition_one(String.t(), rule(), MapSet.t(Ecto.UUID.t())) ::
          :none | {:transitioned, Ecto.UUID.t()} | {:record_error, Ecto.UUID.t(), term()}
  defp claim_and_transition_one(tenant_schema, rule, failed_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      case fetch_one_due_locked(tenant_schema, rule, now, failed_ids) do
        nil ->
          :none

        %Latest{} = record ->
          case apply_transition(record, rule, tenant_schema) do
            {:ok, _result} -> {:transitioned, record.record_id}
            {:error, reason} -> Repo.rollback({record.record_id, reason})
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {record_id, reason}} -> {:record_error, record_id, reason}
    end
  end

  # AC-9/AC-4: LIMIT 1, FOR UPDATE SKIP LOCKED, evaluated inside the caller's
  # own transaction -- a concurrent caller racing for the same row gets `nil`
  # here rather than blocking for it. `field_values` is jsonb; `->>` extracts
  # the stored string value, and it is cast to `timestamptz` only for the
  # comparison, never rewritten in place.
  @spec fetch_one_due_locked(String.t(), rule(), DateTime.t(), MapSet.t(Ecto.UUID.t())) ::
          Latest.t() | nil
  defp fetch_one_due_locked(tenant_schema, rule, now, failed_ids) do
    Latest
    |> where([r], r.entity_type == ^rule.entity_type and r.deleted == false)
    |> where(
      [r],
      fragment("(?->>?)::timestamptz", r.field_values, ^rule.datetime_field) <= ^now
    )
    |> where(
      [r],
      fragment("?->>?", r.field_values, ^rule.status_field) == ^rule.due_status_value
    )
    |> where([r], r.record_id not in ^MapSet.to_list(failed_ids))
    |> order_by([r], asc: r.inserted_at)
    |> limit(1)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.one(prefix: tenant_schema)
  end

  # AC-6: the completion field, if configured, is set to the EXACT stored
  # string already at field_values[datetime_field] -- never to `now`.
  @spec apply_transition(Latest.t(), rule(), String.t()) ::
          {:ok, Records.command_result()} | Records.command_error()
  defp apply_transition(%Latest{} = record, rule, tenant_schema) do
    updated_field_values =
      record.field_values
      |> Map.put(rule.status_field, rule.new_status_value)
      |> put_completion_field(rule, record)

    # scope-all: scheduler system write, no HTTP user
    Records.update_record(
      %{
        entity_type: rule.entity_type,
        record_id: record.record_id,
        field_values: updated_field_values,
        actor_id: @system_actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      tenant_schema
    )
  end

  defp put_completion_field(field_values, %{completion_field: nil}, _record), do: field_values

  defp put_completion_field(field_values, %{completion_field: completion_field} = rule, record) do
    Map.put(field_values, completion_field, Map.get(record.field_values, rule.datetime_field))
  end

  defp invoke_callback(%{callback_mfa: nil}, _record_id, _tenant_schema), do: :ok

  defp invoke_callback(%{callback_mfa: {mod, fun, extra_args}}, record_id, tenant_schema) do
    try do
      apply(mod, fun, [record_id, tenant_schema | extra_args])
    rescue
      error ->
        Logger.warning("deadline sweep: post-transition callback raised",
          module: mod,
          function: fun,
          record_id: record_id,
          schema: tenant_schema,
          error: Exception.format(:error, error, __STACKTRACE__)
        )
    end

    :ok
  end
end
