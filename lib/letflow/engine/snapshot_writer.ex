defmodule Letflow.Engine.SnapshotWriter do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  EE-01x (REQ-054) — periodic execution-state snapshots. Ports
  `snapshot_writer.zig` (R-Co's ISS-601, design artefact
  `src/design/iss601_state_snapshots.md`). See
  `lib/letflow/design/req054-instance-state-snapshots.md` for the full
  design this module implements.

  ## `instance_state_snapshots` vs. `instance_definition_snapshots` — two
  ## "snapshot" tables that must never be confused

  `instance_state_snapshots` (this module) is **not**
  `instance_definition_snapshots` (`Letflow.Definitions.SnapshotStore`,
  REQ-027/033). The two names are one word apart and a name collision would
  be a silent data-model error:

  * `instance_definition_snapshots` holds the immutable PD-08 **definition
    graph** bound to an instance at start — exactly one row per instance,
    write-once.
  * `instance_state_snapshots` (this module) holds periodic **execution
    state** (`Letflow.Engine.InstanceState.t()`) — zero or more rows per
    instance, accumulating over the instance's life. A row, once written, is
    never updated in place (INV-ISS-2); new snapshots are new rows.

  `SnapshotWriter` depends only on `Letflow.Engine.InstanceState`,
  `Letflow.Engine.Token`, `Letflow.Engine.JoinCounter`, and `Letflow.Repo`.
  It has no dependency on `Letflow.Definitions.SnapshotStore`, and that
  module has no dependency on this one.

  ## `error_detail` is deliberately not serialised (design doc §2.1)

  The requirement text names `error_detail` as one of the fields
  `take_snapshot/4` serialises, alongside `status`, `tokens`, `variables`,
  and `pending_task_nodes`. Read against the shipped
  `Letflow.Engine.InstanceState` struct, **no `error_detail` field exists on
  `InstanceState.t()`** — it is a column on `instance_projections`
  (`Letflow.Engine.ExecutionError`), populated by the write path, never
  carried by `InstanceState.t()` itself. `take_snapshot/4` serialises
  exactly `InstanceState.t()`'s own fields: `status`, `tokens`, `variables`,
  `pending_task_nodes`, and `join_counters` (REQ-051's parallel-join cohort
  tracking, also part of `InstanceState.t()` and also omitted from the
  requirement text's list — the same class of omission). Consequence: a
  snapshot taken while `status == :error` captures that status but not the
  structured error detail; a reconstruction seeded from that snapshot also
  will not have `error_detail` — `Letflow.Engine.Reconstruction.replay/3`
  never populated it into `InstanceState.t()` either, so this is a
  pre-existing gap in what `InstanceState.t()` itself can represent, not one
  this module introduces or enlarges.

  ## Open question — where does the "events since last snapshot" counter
  ## live? (design doc §6, flagged per the requirement text's explicit
  ## instruction, not silently defaulted)

  `maybe_take_snapshot/4` needs to know, at each event-append call site, how
  many events have accumulated since the instance's last snapshot, to
  decide whether `current_sequence_number` has crossed a multiple of
  `interval`. Two candidate mechanisms:

  1. **Pure row-based check, no in-memory counter** (the option this module
     implements). `latest_snapshot/2`'s own `sequence_number` combined with
     `current_sequence_number` gives
     `current_sequence_number - (latest_snapshot_sequence_number || 0)`
     with zero additional process state. This fits
     `docs/migration/stage-3-instance-engine.md`'s second Early finding
     (lines 174-184) and, concretely,
     `lib/letflow/design/req045-instance-start-engine-shell.md` §1's
     resolution of the adjacent process-vs-row question for EE-01 itself:
     instances are **plain transactional context-module calls, no
     `:gen_statem`, no `DynamicSupervisor`, no per-instance process**.
     REQ-045's own reasoning (every write already transactional;
     REQ-053's reconstruction, this requirement's own sibling, makes state
     cheaply rebuildable; no timer/backpressure/OS-resource) applies with
     equal or greater force to a per-instance snapshot *cadence counter*,
     which is even less than the full instance state REQ-045 already
     declined to keep in a process.
  2. **In-process counter (a struct-held pool-handle shape).** R-Co's
     `SnapshotWriter` is a struct holding a pool handle — structurally the kind of thing that
     *could* hold a per-instance counter if REQ-045 had resolved to
     supervised per-instance processes. It did not, so an in-process
     counter has no natural home in Letflow's current instance-engine shape
     without inventing a process this stage's own resolved design question
     said not to introduce for EE-01's scope.

  **This module implements option 1** — a pure row-based cadence check via
  `latest_snapshot/2`, no in-memory or per-process counter, no new
  supervised process. `maybe_take_snapshot/4`'s `opts` therefore needs no
  field beyond `prefix`/`interval`. Flagged here, per the requirement text's
  explicit instruction, for SECURITY-REVIEWER/REVIEWER to confirm rather
  than accept by default — `stage-3-instance-engine.md`'s second Early
  finding is explicit that process-per-instance is **not** automatically
  the right call for every piece of engine state, and this reading (that a
  snapshot cadence counter fails that bar too) should be checked, not
  assumed.

  ## INV-ISS-2 — snapshot table is never read on any write path but its own

  `take_snapshot/4` only ever `INSERT`s. `maybe_take_snapshot/4` only ever
  `SELECT`s (via `latest_snapshot/2`, to decide whether to call
  `take_snapshot/4`) or `INSERT`s (via that same call). Neither ever
  `UPDATE`s or `DELETE`s a row — a row, once written, is immutable.

  ## INV-ISS-4 — no `tenant_id` (Decision 0006 D2)

  `instance_state_snapshots` carries no `tenant_id` column and this module
  casts none — the per-tenant Postgres schema (`prefix:`) is the sole
  isolation boundary, same as every table added since D2 shipped.
  """

  import Ecto.Query

  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.InstanceStateSnapshot
  alias Letflow.Engine.JoinCounter
  alias Letflow.Engine.Token
  alias Letflow.Repo

  @default_interval 1000

  @type take_snapshot_opts :: [prefix: String.t()]
  @type cadence_opts :: [prefix: String.t(), interval: pos_integer()]

  @doc """
  Serialises `InstanceState.t()` (`status`, `tokens`, `variables`,
  `pending_task_nodes`, `join_counters` — see moduledoc "`error_detail` is
  deliberately not serialised") into one `instance_state_snapshots` row,
  current as of `sequence_number`. Does not validate `sequence_number`
  against any prior snapshot's — see `maybe_take_snapshot/4`, the only
  caller in this codebase that establishes that ordering.
  """
  @spec take_snapshot(
          instance_id :: Ecto.UUID.t(),
          InstanceState.t(),
          sequence_number :: pos_integer(),
          opts :: take_snapshot_opts()
        ) :: {:ok, snapshot_id :: Ecto.UUID.t()} | {:error, term()}
  def take_snapshot(instance_id, %InstanceState{} = instance_state, sequence_number, opts)
      when is_integer(sequence_number) and sequence_number > 0 and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    snapshot = %InstanceStateSnapshot{
      id: Ecto.UUID.generate(),
      instance_id: instance_id,
      sequence_number: sequence_number,
      state: serialize_state(instance_state)
    }

    case Repo.insert(snapshot, prefix: prefix) do
      {:ok, %InstanceStateSnapshot{id: id}} -> {:ok, id}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Cadence check: writes a snapshot (delegating to `take_snapshot/4`) when
  `current_sequence_number` has advanced at least `interval` (default
  #{@default_interval}, `snapshot_writer.zig`'s `DEFAULT_SNAPSHOT_INTERVAL`)
  events past the instance's own latest snapshot, or writes nothing when it
  has not. Both outcomes are success — see moduledoc "Open question" for how
  this cadence check obtains "events since last snapshot" with no in-memory
  counter (a pure row-based check against `latest_snapshot/2`).

  Call sites (design doc §4.2, this requirement's own implementation scope):
  after event appends (`Letflow.Engine.create/2`, `complete_task/3`,
  `Letflow.Engine.ExecutionError.append_multi/3`) and on instance
  completion.
  """
  @spec maybe_take_snapshot(
          instance_id :: Ecto.UUID.t(),
          InstanceState.t(),
          current_sequence_number :: pos_integer(),
          opts :: cadence_opts()
        ) :: {:ok, :snapshotted | :skipped} | {:error, term()}
  def maybe_take_snapshot(
        instance_id,
        %InstanceState{} = instance_state,
        current_sequence_number,
        opts
      )
      when is_integer(current_sequence_number) and current_sequence_number > 0 and
             is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    interval = Keyword.get(opts, :interval, @default_interval)

    last_snapshot_sequence_number =
      case latest_snapshot(instance_id, prefix: prefix) do
        {:ok, {_state, sequence_number}} -> sequence_number
        {:error, :snapshot_not_found} -> 0
      end

    if current_sequence_number - last_snapshot_sequence_number >= interval do
      case take_snapshot(instance_id, instance_state, current_sequence_number, prefix: prefix) do
        {:ok, _snapshot_id} -> {:ok, :snapshotted}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :skipped}
    end
  end

  @doc """
  The latest (highest `sequence_number`) snapshot row for `instance_id`,
  deserialised back into an `InstanceState.t()`, paired with the
  `sequence_number` it is current as of.
  `{:error, :snapshot_not_found}` when no row exists for the instance — the
  common case for any instance that has not yet crossed one snapshot
  interval.
  """
  @spec latest_snapshot(instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          {:ok, {InstanceState.t(), sequence_number :: pos_integer()}}
          | {:error, :snapshot_not_found}
  def latest_snapshot(instance_id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      InstanceStateSnapshot
      |> where([s], s.instance_id == ^instance_id)
      |> order_by([s], desc: s.sequence_number)
      |> limit(1)

    case Repo.one(query, prefix: prefix) do
      nil ->
        {:error, :snapshot_not_found}

      %InstanceStateSnapshot{state: state, sequence_number: sequence_number} ->
        {:ok, {deserialize_state(instance_id, state), sequence_number}}
    end
  end

  # ---------------------------------------------------------------------
  # Design doc §2.2 -- serialise/deserialise round-trip.
  # ---------------------------------------------------------------------

  defp serialize_state(%InstanceState{} = instance_state) do
    %{
      "status" => status_to_string(instance_state.status),
      "tokens" => Enum.map(instance_state.tokens, &token_to_map/1),
      "variables" => instance_state.variables,
      "pending_task_nodes" => Enum.map(instance_state.pending_task_nodes, &token_to_map/1),
      "join_counters" => serialize_join_counters(instance_state.join_counters),
      "variable_labels" => instance_state.variable_labels,
      "scope_node_id" => instance_state.scope_node_id
    }
  end

  defp token_to_map(%Token{} = token) do
    %{
      "node_id" => token.node_id,
      "token_id" => token.token_id,
      "branch_id" => token.branch_id,
      "waiting_child_instance_id" => token.waiting_child_instance_id
    }
  end

  # ---------------------------------------------------------------------
  # ISS-0397 (design doc §2.3) -- the JoinCounter.t() <-> plain-map codec,
  # promoted from private helpers inlined in serialize_state/1 /
  # deserialize_state/2 to public functions so Letflow.Engine can reuse the
  # exact same, already-REQ-054-reviewed format to persist join_counters on
  # `instance_projections` on every complete_task/3 / advance_after_timer_fired/3
  # call, not just this module's own periodic (every-`interval`-events)
  # snapshot writes. Calling these two functions is NOT the same as calling
  # this module's own take_snapshot/4 / maybe_take_snapshot/4 / latest_snapshot/2
  # -- Letflow.Engine never reads or writes the `instance_state_snapshots`
  # table itself; it calls only these pure map-shape functions.
  # ---------------------------------------------------------------------

  @doc """
  Serialises a `JoinCounter.t()` cohort map (keyed by `join_node_id`) to a
  plain, JSON-encodable map -- the exact format `instance_state_snapshots`
  already stores its own `"join_counters"` key in (design doc §2.3), reused
  verbatim by `Letflow.Engine.reconcile_projection/5` (ISS-0397) to persist
  `instance_projections.join_counters`. Pure, no `Ecto`/`Repo` dependency.
  """
  @spec serialize_join_counters(%{optional(String.t()) => JoinCounter.t()}) :: map()
  def serialize_join_counters(join_counters) do
    Map.new(join_counters, &join_counter_entry_to_map/1)
  end

  defp join_counter_entry_to_map({join_node_id, %JoinCounter{} = counter}) do
    {join_node_id,
     %{
       "join_node_id" => counter.join_node_id,
       "origin_token_id" => counter.origin_token_id,
       "expected_from_branches" => Enum.sort(MapSet.to_list(counter.expected_from_branches)),
       "received_from_branches" => Enum.sort(MapSet.to_list(counter.received_from_branches)),
       "cancelled_branches" => Enum.sort(MapSet.to_list(counter.cancelled_branches))
     }}
  end

  @doc """
  Inverse of `serialize_join_counters/1` -- deserialises a plain map (as
  read back from either `instance_state_snapshots.state["join_counters"]` or
  `instance_projections.join_counters`, ISS-0397) to a
  `%{optional(String.t()) => JoinCounter.t()}` cohort map. Pure, no
  `Ecto`/`Repo` dependency.
  """
  @spec deserialize_join_counters(map()) :: %{optional(String.t()) => JoinCounter.t()}
  def deserialize_join_counters(join_counters) do
    Map.new(join_counters, &join_counter_entry_from_map/1)
  end

  defp deserialize_state(instance_id, %{} = state) do
    %InstanceState{
      instance_id: instance_id,
      status: status_from_string(Map.fetch!(state, "status")),
      tokens: Enum.map(Map.fetch!(state, "tokens"), &token_from_map/1),
      variables: Map.fetch!(state, "variables"),
      pending_task_nodes: Enum.map(Map.fetch!(state, "pending_task_nodes"), &token_from_map/1),
      join_counters: deserialize_join_counters(Map.fetch!(state, "join_counters")),
      # A snapshot written before decision 0062 lacks the key: no labels.
      variable_labels: Map.get(state, "variable_labels", %{}),
      # Likewise a snapshot written before REQ-531: unscoped.
      scope_node_id: Map.get(state, "scope_node_id")
    }
  end

  # Same value set InstanceProjection's own Ecto.Enum already declares:
  # active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED",
  # error: "ERROR" (design doc §2.2, "status string -> atom via the same
  # value set InstanceProjection's Ecto.Enum already declares").
  defp status_to_string(:active), do: "ACTIVE"
  defp status_to_string(:completed), do: "COMPLETED"
  defp status_to_string(:cancelled), do: "CANCELLED"
  defp status_to_string(:error), do: "ERROR"

  defp status_from_string("ACTIVE"), do: :active
  defp status_from_string("COMPLETED"), do: :completed
  defp status_from_string("CANCELLED"), do: :cancelled
  defp status_from_string("ERROR"), do: :error

  defp token_from_map(%{} = map) do
    %Token{
      node_id: Map.fetch!(map, "node_id"),
      token_id: Map.fetch!(map, "token_id"),
      branch_id: Map.get(map, "branch_id"),
      waiting_child_instance_id: Map.get(map, "waiting_child_instance_id")
    }
  end

  defp join_counter_entry_from_map({join_node_id, %{} = map}) do
    {join_node_id,
     %JoinCounter{
       join_node_id: Map.fetch!(map, "join_node_id"),
       origin_token_id: Map.fetch!(map, "origin_token_id"),
       expected_from_branches: MapSet.new(Map.fetch!(map, "expected_from_branches")),
       received_from_branches: MapSet.new(Map.fetch!(map, "received_from_branches")),
       cancelled_branches: MapSet.new(Map.fetch!(map, "cancelled_branches"))
     }}
  end
end
