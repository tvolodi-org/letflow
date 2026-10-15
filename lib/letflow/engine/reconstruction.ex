defmodule Letflow.Engine.Reconstruction do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  EE-11 (REQ-053) — state reconstruction by event replay. Ports
  `reconstruction.zig`'s `reconstructInstance()` (R-Co's `src/design/engine.md`
  "Section EE-11: State Reconstruction", L5237). See
  `lib/letflow/design/req053-state-reconstruction.md` for the full design
  this module implements.

  ## Findings confirmed against shipped code, not assumed (design doc §1)

  * `Letflow.EventStore.read/2` does **not** span `events_archive` — its own
    pipeline (`query_instance_events/3` -> `resolve_payloads/2`) queries only
    the `events` table. `read_full_log/2` below is this requirement's own
    new, separate query, merging `events` and `events_archive` by
    `sequence_number` (the one total order preserved across an `archive/1`
    move — REQ-026's own design §7.3, INV-AR-1/AR-2).
  * Six `event_type` values are known to be appended for an instance as of
    REQ-187's own rework: `INSTANCE_STARTED`, `TASK_COMPLETED`,
    `INSTANCE_CANCELLED`, `EXECUTION_ERROR`, (req062, SPC-01)
    `SUB_PROCESS_COMPLETED`, and (REQ-187) `TIMER_FIRED`. `TIMER_FIRED`'s own
    persisted payload (`Letflow.Scheduler`'s `append_timer_fired_event/4`)
    carries `node_id`, no `token_id` — its replay clause mirrors
    `TASK_COMPLETED`'s own position-match shape, not `SUB_PROCESS_COMPLETED`'s
    marker-based one, and needs no variable-merge step (a `TIMER_FIRED`
    payload carries no `output_variables`). No `PARALLEL_SPLIT`/`PARALLEL_JOIN_*` event type
    is ever persisted (REQ-051's `pending_event()` union stays entirely
    in-memory). A later persisted event type needs its own replay clause
    added to `apply_event/3` below by whichever requirement adds it — any
    unrecognized `event_type` string surfaces as
    `{:replay_failed, {:unrecognized_event_type, event_type, event_id}}`,
    never silently skipped. Since then the SERVICE_TASK completions gained clauses too:
    `SCRIPT_TASK_COMPLETED`/`SCRIPT_RUN_RECORDED` (GH 2534 PR 7c-1) and the HTTP
    route's `SERVICE_TASK_COMPLETED` (GH 2595), whose recorded `decoded_body` is merged
    verbatim, exactly as the live `:advance` path merged it.
  * `SUB_PROCESS_COMPLETED`'s own persisted payload
    (`Letflow.Engine.SubProcess.append_sub_process_completed_event/8`) writes
    `child_instance_id`, `output_variables` (already
    interface-filtered/merge-ready — the same value
    `SubProcess.build_parent_merge_variables/2` produced on the live path,
    not the child's raw full variable map), `merged_variable_events`, and
    `activated_nodes`. It carries no `node_id` field at all (unlike
    `TASK_COMPLETED`) — replay below matches the completing token by its
    in-memory `waiting_child_instance_id` against the payload's
    `child_instance_id` instead, since that is the one field the payload
    actually carries that identifies which parked token this event closes.
  * `Letflow.Engine.Transition.transition/3` cannot replay from event payload
    alone: no persisted event payload records the `token_id`/`branch_id`
    `Letflow.Engine.create/2`/`complete_task/3` minted for that hop. Exact
    `token_id`/`branch_id` values are therefore **not** reconstructible
    bit-for-bit from the event log — only token **positions** (`node_id`s)
    are. Every token this module mints during replay uses a freshly
    generated `token_id` (`Ecto.UUID.generate/0`), never a value read back
    from any event.
  * `instance_projections.current_nodes` is a list of `node_id` strings, not
    full token records — a field-for-field comparison against the live
    projection is therefore necessarily over `current_nodes` (a
    node-id multiset), `variables`, and `status`, never over
    `InstanceState.tokens`'s richer `token_id`/`branch_id` fields, which have
    no projection-side counterpart at all.

  ## NFR-04 — R-Co's documented performance target (AC7, informational only)

  R-Co's EE-11 AC2 states a documented performance target — 10,000 events
  replayed in under 5 seconds (NFR-04). Letflow has not adopted an NFR
  requirement covering reconstruction performance, and no benchmark harness
  exists in this codebase as of this requirement. This target is recorded
  here as R-Co's documented context only; it is not a Letflow acceptance
  criterion, and no code in this module is written, tuned, or tested against
  it.

  ## Scope boundary (AC7)

  `POST /api/v1/instances/:id/reconstruct` is S4 (api-surface) scope, not
  built here. This module is the context-module function a future S4 route
  wraps.

  ## What "same tokens" means for AC1 (design doc §6)

  `reconstruct_instance/2`'s resulting `InstanceState.tokens` uses
  freshly-minted `token_id`/`branch_id` values on every call — these can
  never be compared byte-for-byte against either the original run's
  in-memory tokens (never persisted) or `instance_projections` (no
  `token_id`/`branch_id` column at all). "Same tokens" is therefore a
  node-id-multiset comparison against `current_nodes`, `variables`, and
  `status`; "task set" compares `pending_task_nodes`'s `node_id`s against
  the `tasks` table's own `:pending`-status rows for the instance (not
  `instance_projections`, which carries no task-set column at all) — see the
  design doc §6 for the full statement, including the flagged correction to
  the requirement text's literal "equal to the persisted instance_projections
  row" framing for that one field.

  ## Ground truth is the event log, never the projection (INV-RC-2)

  No function on the replay path (`read_full_log/2`, `replay/3`) ever reads
  `instance_projections` — only `write_back/4` (opt-in) touches that table,
  and only to write, never to seed replay state from it.

  ## Read-only by default (INV-RC-1)

  `reconstruct_instance(id, prefix: p)` (no `write_back` key, or
  `write_back: false`) performs zero `Repo.insert`/`update`/`delete` calls
  anywhere in its call graph. `write_back` defaults to `false`; omitting the
  key entirely from `opts` is equivalent to `write_back: false`, never
  treated as an error or as "unspecified -> true".

  ## Deliberate divergences from the design's literal text (flagged for
  ## REVIEWER, per this codebase's own established precedent for this class
  ## of gap — e.g. `Letflow.Engine`'s `merge_output_variables/5` widening
  ## beyond req061 design doc §5.1's literal 2-arg signature)

  1. **`write_back/3`'s third argument widened to an opts list.** The design
     doc §7 states `write_back(instance_id, InstanceState.t(), prefix)` and
     separately states (same section) that `last_event_seq` is set from the
     merged log's own `last_sequence_number` — a value `write_back/3`'s own
     3-arg literal signature has no way to receive. Implemented here as
     `write_back/3` with `opts :: [prefix: String.t(), last_sequence_number:
     non_neg_integer() | nil]` as the third argument, rather than either (a)
     silently guessing an incorrect `last_event_seq`, or (b) re-deriving it
     with a second, wasteful query inside `write_back/3` itself.
  2. **Write-back's insert path (projection row absent) fetches the
     instance's snapshot a second time to source `definition_id`.**
     `InstanceProjection.insert_changeset/2` requires `definition_id`, which
     has no `InstanceState.t()` counterpart (design doc §7's own insert
     extension does not name where this required field comes from). Sourced
     here from `Letflow.Definitions.SnapshotStore.get_by_instance_id/2`
     (already known to exist — `replay/3` would otherwise have already
     returned `:instance_not_found`/`{:replay_failed,
     {:snapshot_unavailable, _}}`). `correlation_key` is left `nil` on this
     insert path — it has no `InstanceState.t()` counterpart either and this
     module does not re-read `INSTANCE_STARTED`'s own payload a second time
     just to recover it; a genuinely correlation-key-bearing instance whose
     projection row was deleted and then write-back-inserted loses that one
     informational field until a later write repopulates it.
  3. **`replay_failure_reason()` gains two variants beyond the design doc
     §3 type block's literal list**, both explicitly anticipated by the design
     doc's own prose even though omitted from that literal `@type` block:
     `{:duplicate_sequence_number, sequence_number}` (design doc §4) and
     `{:ambiguous_task_node, node_id}` (design doc §5.3/§9 OQ-3).
  4. **`{:variable_merge_rejected, event_id, key}` — a new variant with no
     design doc precedent at all.** `TASK_COMPLETED` replay merges
     `payload.output_variables` via `Letflow.Engine.VariableMerge.merge/3`
     (design doc §5.3), reusing the exact call `complete_task/3` itself
     makes — but `complete_task/3`'s own call site routes a `:rejected`
     merge outcome into `Letflow.Engine.ExecutionError` (REQ-061,
     `engine.ex:1093-1106`), a write-path this module never takes (INV-RC-1,
     INV-RC-2). The design doc's §5.3 table does not name this case. Since a
     `TASK_COMPLETED` event was only ever durably appended after its own
     original `merge/3` call already succeeded, replaying it against the same
     durable variable state should not be able to observe a rejection in
     practice — this variant exists purely so an actual occurrence (a
     genuine data-integrity condition, e.g. a schema tightened after the
     fact) surfaces as a named, pattern-matchable replay failure instead of
     crashing or being silently absorbed.

  ## REQ-054 — snapshot-aware replay-source selection

  PROVENANCE (historical, not current decision authority):
  `read_full_log/2` is widened to `read_full_log/3`, taking a new
  `min_sequence_number` argument (defaulting to `1` for every existing
  full-replay caller) — the same class of deliberate, additive-arity
  divergence as `write_back/3`'s opts-list widening above, not a change to
  the merge/dedup logic itself. `replay/3` becomes `replay/4`: its new
  first step, `select_replay_source/2` (ports `reconstruction.zig`'s
  `determineReplaySourceForSnapshot()`), asks
  `Letflow.Engine.SnapshotWriter.latest_snapshot/2` — a **different**
  snapshot table from the `SnapshotStore.get_by_instance_id/2` call
  immediately below it in `replay/4`'s body (`instance_state_snapshots`,
  periodic execution state, vs. `instance_definition_snapshots`, the
  immutable PD-08 graph — see `Letflow.Engine.SnapshotWriter`'s moduledoc
  for the full distinction) — whether a prior execution-state snapshot
  exists for this instance. When one does, `replay/4` seeds `fold_events/3`
  from that snapshot's deserialised `InstanceState.t()` instead of a fresh
  `:START` token, and folds only events with `sequence_number` greater than
  the snapshot's own — `fold_events/3` and every `apply_event/3` clause are
  unchanged, so a divergence between the snapshot-sourced and full-replay
  results (INV-ISS-1, `lib/letflow/design/req054-instance-state-snapshots.md`
  §5.4) can only come from the snapshot's serialise/deserialise round-trip,
  never from two different fold implementations drifting apart.

  ## OQ-1 (two-query race, design doc §9) — not closed by this
  ## implementation

  `read_full_log/2`'s two queries run inside one `Repo.transaction/2` under
  Postgres's default `READ COMMITTED` isolation, querying `events_archive`
  first (the design doc's own argued-safe ordering, since `archive/1` only
  ever moves rows into it, never out). This implementation does not upgrade
  to `REPEATABLE READ`/`SERIALIZABLE` — left exactly as the design doc
  flagged it, for REVIEWER to confirm sufficiency.
  """

  import Ecto.Query

  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.Token
  alias Letflow.Engine.Transition
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.StoredPayload
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # design doc §12.2 -- a short, human-readable, structurally-non-UUID string
  # (contains `:`, which Ecto.UUID.generate/0 output never does) used to park
  # a token's waiting_child_instance_id during replay when its
  # {:sub_process_start, ...} pending event has been seen but the matching
  # SUB_PROCESS_COMPLETED event has not yet replayed. Private to this module
  # only -- Transition's own dispatch_sub_process_entry/4 guard only checks
  # not is_nil(waiting_child_instance_id), never equality against a specific
  # value.
  @replay_pending_child_marker "reconstruction:pending_child"

  @type reconstruct_opts :: [
          prefix: String.t(),
          write_back: boolean()
        ]

  @type reconstruct_result :: %{
          instance_id: Ecto.UUID.t(),
          instance_state: InstanceState.t(),
          event_count: non_neg_integer(),
          last_sequence_number: non_neg_integer() | nil,
          write_back: :skipped | :written
        }

  @type replay_source ::
          {:full_replay, min_sequence_number :: 1}
          | {:from_snapshot, InstanceState.t(), min_sequence_number :: pos_integer()}

  @type merged_event :: %{
          event_id: Ecto.UUID.t(),
          event_type: String.t(),
          payload: map(),
          sequence_number: pos_integer(),
          created_at: DateTime.t()
        }

  @type replay_failure_reason ::
          {:snapshot_unavailable, :snapshot_not_found | term()}
          | {:graph_build_failed, term()}
          | {:transition_error, Transition.transition_error()}
          | {:activation_failed, term()}
          | {:unrecognized_event_type, event_type :: String.t(), event_id :: Ecto.UUID.t()}
          | {:malformed_payload, event_id :: Ecto.UUID.t(), reason :: term()}
          | {:duplicate_sequence_number, sequence_number :: pos_integer()}
          | {:ambiguous_task_node, node_id :: String.t()}
          | {:variable_merge_rejected, event_id :: Ecto.UUID.t(), key :: term()}
          | {:ambiguous_sub_process_completion, child_instance_id :: String.t()}
          | {:child_start_event_missing, child_instance_id :: String.t()}

  @type reconstruct_error ::
          {:error, :instance_not_found}
          | {:error, {:lock_contention, instance_id :: Ecto.UUID.t()}}
          | {:error, {:replay_failed, replay_failure_reason()}}
          | {:error, :invalid_schema_name}
          | {:error, :invalid_instance_id}

  @doc """
  Reconstructs `instance_id`'s current `Letflow.Engine.InstanceState` purely
  from its durable event log (`events` + `events_archive`, merged and
  ordered by `sequence_number`) — never from `instance_projections`
  (INV-RC-2). Read-only unless `opts[:write_back] == true` (INV-RC-1). See
  this module's moduledoc for the full algorithm, the confirmed-not-assumed
  findings it is built on, and the flagged divergences from the gate-approved
  design doc.
  """
  @spec reconstruct_instance(instance_id :: Ecto.UUID.t(), opts :: reconstruct_opts()) ::
          {:ok, reconstruct_result()} | reconstruct_error()
  def reconstruct_instance(instance_id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    write_back? = Keyword.get(opts, :write_back, false) == true

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, cast_instance_id} <- cast_instance_id(instance_id),
         replay_source <- select_replay_source(cast_instance_id, prefix),
         {:ok, merged_events} <-
           read_full_log(cast_instance_id, prefix, min_sequence_number(replay_source)),
         {:ok, instance_state} <- replay(cast_instance_id, merged_events, prefix, replay_source) do
      last_sequence_number = last_sequence_number(merged_events)

      result = %{
        instance_id: cast_instance_id,
        instance_state: instance_state,
        event_count: length(merged_events),
        last_sequence_number: last_sequence_number,
        write_back: :skipped
      }

      if write_back? do
        case write_back(cast_instance_id, instance_state,
               prefix: prefix,
               last_sequence_number: last_sequence_number
             ) do
          {:ok, :written} -> {:ok, %{result | write_back: :written}}
          {:error, _reason} = error -> error
        end
      else
        {:ok, result}
      end
    end
  end

  defp cast_instance_id(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  # ---------------------------------------------------------------------
  # Step 1 (design doc §4) -- merged event read across events/events_archive.
  # ---------------------------------------------------------------------

  # REQ-054 widening: min_sequence_number defaults to 1 for the full-replay
  # path (every event), so this stays the identical query REQ-053 built for
  # every caller that still passes 1 -- see moduledoc "REQ-054 --
  # snapshot-aware replay-source selection". Both Event and ArchivedEvent
  # queries gain a `sequence_number > min_sequence_number - 1` clause
  # (design doc §5.1), i.e. `>= min_sequence_number`.
  #
  # Public/`@doc false` (REQ-059 widening) for the same precedent
  # `Letflow.Engine.advance_until_stable/4` etc. already set (see that
  # module's own comment) -- `Letflow.Engine.PinResolver.reconstruct_effective_pins/2`
  # (req059-pin-resolver.md §6) reuses this exact merged, archive-aware read
  # rather than writing a second, independently-drifting copy of the same
  # events/events_archive merge logic.
  @doc false
  @spec read_full_log(
          instance_id :: Ecto.UUID.t(),
          prefix :: String.t(),
          min_sequence_number :: pos_integer()
        ) :: {:ok, [merged_event()]} | {:error, term()}
  def read_full_log(instance_id, prefix, min_sequence_number) do
    Repo.transaction(fn ->
      # events_archive queried first -- the design doc §9 OQ-1's own
      # argued-safe ordering under READ COMMITTED (archive/1 only ever moves
      # rows into events_archive, never out of it).
      archived_events =
        ArchivedEvent
        |> where([e], e.instance_id == ^instance_id)
        |> where([e], e.sequence_number > ^(min_sequence_number - 1))
        |> order_by([e], asc: e.sequence_number)
        |> Repo.all(prefix: prefix)
        |> Enum.map(&normalize_merged_event/1)

      live_events_result =
        Event
        |> where([e], e.instance_id == ^instance_id)
        |> where([e], e.sequence_number > ^(min_sequence_number - 1))
        |> order_by([e], asc: e.sequence_number)
        |> Repo.all(prefix: prefix)
        |> resolve_live_payloads(prefix)

      case live_events_result do
        {:ok, live_events} ->
          merged = Enum.sort_by(archived_events ++ live_events, & &1.sequence_number)

          case find_duplicate_sequence_number(merged) do
            nil -> merged
            duplicate -> Repo.rollback({:duplicate_sequence_number, duplicate})
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp normalize_merged_event(%schema{} = event) when schema in [Event, ArchivedEvent] do
    %{
      event_id: event.event_id,
      event_type: event.event_type,
      payload: event.payload,
      sequence_number: event.sequence_number,
      created_at: event.created_at
    }
  end

  # `events_archive.payload` always holds the fully-resolved payload, never a
  # `$ref` pointer (`Letflow.EventStore.archive/1`'s own moduledoc, INV-AR-3)
  # -- only live `events` rows can still be a `$ref` needing resolution
  # against `event_payload_store`. Mirrors
  # `Letflow.EventStore`'s own private `resolve_payloads/2`/
  # `substitute_resolved_payloads/2` (not reused directly -- that pair is
  # private to that module and scoped to its own `Event.t()` return shape;
  # duplicated here in minimal form against this module's own
  # `merged_event()` shape instead of exporting a wider a la carte payload
  # helper from `EventStore` for one call site).
  defp resolve_live_payloads(events, prefix) do
    ref_ids = for %Event{payload: %{"$ref" => ref_id}} <- events, do: ref_id

    case ref_ids do
      [] ->
        {:ok, Enum.map(events, &normalize_merged_event/1)}

      _ref_ids ->
        resolved_map =
          StoredPayload
          |> where([sp], sp.event_id in ^ref_ids)
          |> select([sp], {sp.event_id, sp.payload})
          |> Repo.all(prefix: prefix)
          |> Map.new()

        substitute_resolved_payloads(events, resolved_map)
    end
  end

  defp substitute_resolved_payloads(events, resolved_map) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case event.payload do
        %{"$ref" => ref_id} ->
          case Map.fetch(resolved_map, ref_id) do
            {:ok, payload} ->
              {:cont, {:ok, [normalize_merged_event(%{event | payload: payload}) | acc]}}

            :error ->
              {:halt, {:error, {:malformed_payload, event.event_id, :payload_resolution_failed}}}
          end

        _payload ->
          {:cont, {:ok, [normalize_merged_event(event) | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp find_duplicate_sequence_number(merged_events) do
    merged_events
    |> Enum.map(& &1.sequence_number)
    |> Enum.frequencies()
    |> Enum.find_value(fn {sequence_number, count} ->
      if count > 1, do: sequence_number
    end)
  end

  defp last_sequence_number([]), do: nil
  defp last_sequence_number(merged_events), do: List.last(merged_events).sequence_number

  # ---------------------------------------------------------------------
  # Step 2 (design doc §5) -- fold the merged log into an InstanceState.
  # ---------------------------------------------------------------------

  # PROVENANCE (historical, not current decision authority):
  # REQ-054's own new lookup, against a different table (`instance_state_snapshots`,
  # execution state) than the `SnapshotStore.get_by_instance_id/2` call below
  # (`instance_definition_snapshots`, the graph) -- state seed vs. graph
  # seed, two independent axes. Ports `reconstruction.zig`'s
  # `determineReplaySourceForSnapshot()` (design doc §5.2). Cannot itself
  # fail: `SnapshotWriter.latest_snapshot/2`'s only two outcomes are
  # `{:error, :snapshot_not_found}` and `{:ok, {state, sequence_number}}`.
  @spec select_replay_source(instance_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          replay_source()
  defp select_replay_source(instance_id, prefix) do
    case SnapshotWriter.latest_snapshot(instance_id, prefix: prefix) do
      {:error, :snapshot_not_found} ->
        {:full_replay, 1}

      {:ok, {state_snapshot, snapshot_sequence_number}} ->
        {:from_snapshot, state_snapshot, snapshot_sequence_number + 1}
    end
  end

  defp min_sequence_number({:full_replay, min_sequence_number}), do: min_sequence_number
  defp min_sequence_number({:from_snapshot, _state, min_sequence_number}), do: min_sequence_number

  @spec replay(
          instance_id :: Ecto.UUID.t(),
          events :: [merged_event()],
          prefix :: String.t(),
          replay_source()
        ) ::
          {:ok, InstanceState.t()}
          | {:error, :instance_not_found}
          | {:error, {:replay_failed, replay_failure_reason()}}
  defp replay(instance_id, events, prefix, replay_source) do
    case SnapshotStore.get_by_instance_id(instance_id, prefix: prefix) do
      {:ok, graph_snapshot} ->
        with {:ok, graph} <- build_graph_for_replay(graph_snapshot.graph),
             {:ok, seed_state} <- seed_state_for_replay(instance_id, graph, replay_source) do
          case fold_events(graph, seed_state, events, prefix) do
            {:ok, final_state} -> {:ok, final_state}
            {:error, reason} -> {:error, {:replay_failed, reason}}
          end
        else
          {:error, reason} -> {:error, {:replay_failed, reason}}
        end

      # Design doc §4/§5.1's own existence-determination rule: neither table
      # having a row for instance_id is not, by itself, :instance_not_found
      # -- a zero-event, snapshot-committed instance is a real,
      # reconstructible instance (AC4). instance_not_found is returned only
      # when the merged event list is ALSO empty. REQ-054 (design doc §5.3):
      # a {:full_replay, 1} replay_source (no state snapshot yet -- the
      # common, zero-events-so-far case) is normal here too, not evidence of
      # a missing instance -- this rule's inputs are unchanged by REQ-054.
      {:error, :snapshot_not_found} when events == [] ->
        {:error, :instance_not_found}

      {:error, :snapshot_not_found} ->
        {:error, {:replay_failed, {:snapshot_unavailable, :snapshot_not_found}}}

      {:error, other} ->
        {:error, {:replay_failed, {:snapshot_unavailable, other}}}
    end
  end

  # design doc §5.2: {:full_replay, 1} still seeds fresh from :START
  # (unchanged from REQ-053); {:from_snapshot, state_snapshot, _} seeds the
  # fold directly from the deserialised snapshot state instead --
  # fold_events/3 and every apply_event/3 clause below are identical either
  # way (INV-ISS-1's correctness bar, design doc §5.4).
  defp seed_state_for_replay(instance_id, graph, {:full_replay, 1}) do
    seed_instance_state(instance_id, graph)
  end

  defp seed_state_for_replay(_instance_id, _graph, {:from_snapshot, state_snapshot, _min_seq}) do
    {:ok, state_snapshot}
  end

  defp build_graph_for_replay(graph_map) do
    case Engine.build_graph(graph_map) do
      {:ok, graph} -> {:ok, graph}
      {:error, {:graph_structure_invalid, reason}} -> {:error, {:graph_build_failed, reason}}
    end
  end

  # Design doc §5.2 -- the zero-events seed state (AC4): a fresh token on the
  # graph's :START node, empty variables, :active status. Reuses
  # Engine.find_start_node/1 rather than re-deriving it.
  defp seed_instance_state(instance_id, graph) do
    case Engine.find_start_node(graph) do
      {:ok, start_node} ->
        token_id = Ecto.UUID.generate()
        root_token = %Token{token_id: token_id, node_id: start_node.id, branch_id: instance_id}

        {:ok,
         %InstanceState{
           instance_id: instance_id,
           status: :active,
           tokens: [root_token],
           variables: %{},
           pending_task_nodes: []
         }}

      {:error, {:graph_structure_invalid, reason}} ->
        {:error, {:graph_build_failed, reason}}
    end
  end

  defp fold_events(_graph, state, [], _prefix), do: {:ok, state}

  defp fold_events(graph, state, [event | rest], prefix) do
    case apply_event(graph, state, event, prefix) do
      {:ok, new_state} -> fold_events(graph, new_state, rest, prefix)
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------
  # Design doc §5.3 -- per-event-type replay clauses.
  # ---------------------------------------------------------------------

  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "INSTANCE_STARTED"} = event,
         _prefix
       ) do
    with {:ok, initial_variables} <- fetch_map_field(event, "initial_variables") do
      reseeded_state = %InstanceState{state | variables: initial_variables}
      worklist = Enum.map(reseeded_state.tokens, & &1.token_id)

      resolve_pending_events(
        Engine.advance_until_stable(graph, reseeded_state, worklist, hop_limit(graph))
      )
    end
  end

  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "TASK_COMPLETED"} = event,
         _prefix
       ) do
    with {:ok, node_id} <- fetch_string_field(event, "node_id"),
         {:ok, output_variables} <- fetch_map_field(event, "output_variables"),
         {:ok, token} <- find_task_completion_token(state.tokens, node_id) do
      case VariableMerge.merge(state.variables, output_variables, nil) do
        {:ok, new_variables, _merge_events} ->
          # Drop this token's now-completed (token_id, node_id) entry from
          # pending_task_nodes before dispatching the completion hop. The
          # live single-hop Engine.complete_task/3 path never carries this
          # forward because it re-derives pending_task_nodes fresh from the
          # `tasks` table (status == :pending) on every call
          # (Engine.load_pending_task_tokens/3) -- an already-completed
          # entry simply never reappears in the next call's seed state.
          # This fold has no such per-call reseed: it threads one
          # InstanceState through the whole event log, and
          # dispatch_human_task/3 (transition.ex) only ever appends to
          # pending_task_nodes, never removes. Without this explicit
          # removal, pending_task_nodes would accumulate every HUMAN_TASK
          # node a token has EVER visited across the whole replay instead
          # of reflecting only the currently-open set (test/specs/REQ-053.md
          # AC1 known open finding). Matched on {token_id, node_id}, not
          # node_id alone, mirroring ISS-0057's fix (a token can revisit the
          # same node_id under a different token_id is not possible here,
          # but keeping both keys matches TaskActivation's own diff key).
          pending_after_completion =
            Enum.reject(
              state.pending_task_nodes,
              &(&1.token_id == token.token_id and &1.node_id == node_id)
            )

          state_with_merged_variables = %InstanceState{
            state
            | variables: new_variables,
              pending_task_nodes: pending_after_completion
          }

          dispatch_task_completion(graph, state_with_merged_variables, token.token_id)

        {:rejected, _unchanged_variables,
         [{:execution_error, key, _rejected_value, :variable_schema_rejected, _failures}]} ->
          {:error, {:variable_merge_rejected, event.event_id, key}}
      end
    end
  end

  defp apply_event(_graph, %InstanceState{} = state, %{event_type: "INSTANCE_CANCELLED"}, _prefix) do
    {:ok,
     %InstanceState{
       state
       | status: :cancelled,
         tokens: [],
         pending_task_nodes: [],
         join_counters: %{}
     }}
  end

  defp apply_event(
         _graph,
         %InstanceState{} = state,
         %{event_type: "EXECUTION_ERROR"} = event,
         _prefix
       ) do
    with {:ok, variables} <- fetch_map_field(event, "variables") do
      {:ok, %InstanceState{state | status: :error, variables: variables}}
    end
  end

  # req062 (SPC-01) -- mirrors TASK_COMPLETED's own clause shape: read back
  # the same fields the live path persisted (moduledoc finding above),
  # merge via the same Letflow.Engine.VariableMerge.merge/3 call the live
  # completion path makes (SubProcess.build_completion_multi_from_merge/10),
  # then dispatch through the same {:sub_process_completed, token_id}
  # Transition.transition/3 event the live path dispatches
  # (SubProcess.append_completion_multi/5). No node_id is persisted on this
  # event type, so the completing token is found by matching the payload's
  # child_instance_id against each in-memory token's own
  # waiting_child_instance_id instead (find_sub_process_completion_token/2).
  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "SUB_PROCESS_COMPLETED"} = event,
         prefix
       ) do
    with {:ok, child_instance_id} <- fetch_string_field(event, "child_instance_id"),
         {:ok, output_variables} <- fetch_map_field(event, "output_variables"),
         {:ok, parent_node_id} <- fetch_child_parent_node_id(child_instance_id, prefix),
         {:ok, %Token{} = parked_token} <-
           find_sub_process_completion_token(state.tokens, parent_node_id, child_instance_id) do
      case VariableMerge.merge(state.variables, output_variables, nil) do
        {:ok, new_variables, _merge_events} ->
          resolved_token = %Token{parked_token | waiting_child_instance_id: child_instance_id}

          state_with_merged_variables = %InstanceState{
            state
            | variables: new_variables,
              tokens: replace_token(state.tokens, resolved_token)
          }

          dispatch_sub_process_completion(
            graph,
            state_with_merged_variables,
            resolved_token.token_id
          )

        {:rejected, _unchanged_variables,
         [{:execution_error, key, _rejected_value, :variable_schema_rejected, _failures}]} ->
          {:error, {:variable_merge_rejected, event.event_id, key}}
      end
    end
  end

  # REQ-187 design doc §9 -- mirrors TASK_COMPLETED's own clause shape
  # (position match by node_id, not SUB_PROCESS_COMPLETED's marker-based
  # match): the persisted TIMER_FIRED payload
  # (Scheduler.append_timer_fired_event/4, unchanged) carries node_id, no
  # token_id, so the completing token is found the same way
  # find_task_completion_token/2 already does. No variable-merge step is
  # needed here -- a TIMER_FIRED payload carries no output_variables to
  # merge, unlike TASK_COMPLETED/SUB_PROCESS_COMPLETED. Independent of
  # Engine.advance_after_timer_fired/3 -- the two never call each other,
  # they are two independent derivations of the same post-TIMER_FIRED
  # InstanceState.
  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "TIMER_FIRED"} = event,
         _prefix
       ) do
    with {:ok, node_id} <- fetch_string_field(event, "node_id"),
         {:ok, token} <- find_task_completion_token(state.tokens, node_id) do
      dispatch_timer_fired(graph, state, token.token_id)
    end
  end

  # GH 2534 PR 7c-1 (decision 0053 D5, MUST 11; design gh2534-7c-script-handler.md section 6):
  # the per-run record changes no state.
  defp apply_event(
         _graph,
         %InstanceState{} = state,
         %{event_type: "SCRIPT_RUN_RECORDED"},
         _prefix
       ) do
    {:ok, state}
  end

  # GH 2534 PR 7c-1: a script SERVICE_TASK's RECORDED output is applied, never re-computed --
  # replay re-executes no script (this file references no script runtime). Mirrors the live
  # path: merge the recorded output (validations already ran live, as for TASK_COMPLETED),
  # drop the token from pending_service_task_nodes, advance off the node, then drain.
  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "SCRIPT_TASK_COMPLETED"} = event,
         _prefix
       ) do
    apply_service_task_completion(graph, state, event, "output")
  end

  # GH 2595: the HTTP SERVICE_TASK :advance outcome (Engine.advance_service_task_dispatch/4 ->
  # persist_service_task_advance/10, payload `%{dispatch_id, node_id, decoded_body}`). The live
  # path applies NO response mapping: ServiceTask.classify_failure_kind/1 yields the 2xx body's
  # whole decoded JSON object, and the engine merges that map as-is via
  # VariableMerge.merge(variables, decoded_body, nil), then advances off the node exactly as
  # the script route does. The persisted decoded_body is that same map, so replay applies it
  # verbatim from the payload -- no definition or config is consulted, nothing is re-fetched.
  defp apply_event(
         graph,
         %InstanceState{} = state,
         %{event_type: "SERVICE_TASK_COMPLETED"} = event,
         _prefix
       ) do
    apply_service_task_completion(graph, state, event, "decoded_body")
  end

  defp apply_event(_graph, _state, %{event_type: event_type, event_id: event_id}, _prefix) do
    {:error, {:unrecognized_event_type, event_type, event_id}}
  end

  # Shared by SCRIPT_TASK_COMPLETED ("output") and SERVICE_TASK_COMPLETED ("decoded_body"): both
  # live routes run the same Engine.persist_service_task_advance/10 pipeline after merging their
  # map into the variables, so both replay folds are this one function.
  defp apply_service_task_completion(graph, %InstanceState{} = state, event, output_key) do
    with {:ok, node_id} <- fetch_string_field(event, "node_id"),
         {:ok, output} <- fetch_map_field(event, output_key),
         {:ok, token} <- find_task_completion_token(state.tokens, node_id) do
      case VariableMerge.merge(state.variables, output, nil) do
        {:ok, new_variables, _merge_events} ->
          state_with_merged_variables = %InstanceState{
            state
            | variables: new_variables,
              pending_service_task_nodes:
                Enum.reject(state.pending_service_task_nodes, &(&1.token_id == token.token_id))
          }

          dispatch_service_task_completion(graph, state_with_merged_variables, token)

        {:rejected, _unchanged_variables,
         [{:execution_error, key, _rejected_value, :variable_schema_rejected, _failures}]} ->
          {:error, {:variable_merge_rejected, event.event_id, key}}
      end
    end
  end

  # GH 2534 PR 7c-1: the live SERVICE_TASK completion hop (Engine.persist_service_task_advance)
  # dispatches Transition.advance_off_completed_node/4 on the node's outgoing edges, then
  # drains with Engine.advance_until_stable/4 -- which returns pending events but persists
  # nothing, so no dispatch row is ever armed on this path.
  defp dispatch_service_task_completion(graph, state, token) do
    outgoing_edges = Enum.filter(graph.edges, &(&1.source == token.node_id))

    case Transition.advance_off_completed_node(graph, state, token, outgoing_edges) do
      {:ok, new_state, _pending_events} ->
        newly_pending =
          Engine.tokens_needing_dispatch(state.tokens, new_state.tokens, token.token_id)

        resolve_pending_events(
          Engine.advance_until_stable(graph, new_state, newly_pending, hop_limit(graph) - 1)
        )

      {:error, reason} ->
        {:error, {:transition_error, reason}}
    end
  end

  # design doc §5.3 TASK_COMPLETED row -- position match (by node_id), not
  # token_id match, since the original token_id is unrecoverable (moduledoc
  # finding above). Zero or >=2 live tokens at that node_id is a named,
  # surfaced replay-fidelity gap (design doc §9 OQ-3), never a silent guess.
  defp find_task_completion_token(tokens, node_id) do
    case Enum.filter(tokens, &(&1.node_id == node_id)) do
      [token] -> {:ok, token}
      _zero_or_many -> {:error, {:ambiguous_task_node, node_id}}
    end
  end

  # req062 (SPC-01, design doc §12.3.3) SUB_PROCESS_COMPLETED row -- matched by
  # BOTH the parked token's own node_id (sourced from the completing child's
  # own INSTANCE_STARTED payload, fetch_child_parent_node_id/2 below) AND the
  # generic replay-parked marker (@replay_pending_child_marker). node_id alone
  # disambiguates between concurrently-parked siblings (design doc §12.3.0's
  # rework); the marker alone rules out a token sitting at that node_id for an
  # unrelated reason. Zero or >=2 matches is a named, surfaced replay-fidelity
  # gap, never a silent guess -- mirrors find_task_completion_token/2's own
  # zero-or-many handling.
  defp find_sub_process_completion_token(tokens, parent_node_id, child_instance_id) do
    case Enum.filter(tokens, fn token ->
           token.node_id == parent_node_id and
             token.waiting_child_instance_id == @replay_pending_child_marker
         end) do
      [token] -> {:ok, token}
      _zero_or_many -> {:error, {:ambiguous_sub_process_completion, child_instance_id}}
    end
  end

  # design doc §12.3.1/12.3.2 -- reads the completing child's own single
  # INSTANCE_STARTED event (its own instance_id stream, not the parent's) to
  # recover parent_node_id, the node the parent's token was sitting on when it
  # spawned this specific child (SubProcess.append_instance_started_event_for_child/8's
  # own persisted payload field). Still a read-only Repo.all -- INV-RC-1 -- and
  # still never reads instance_projections -- INV-RC-2 -- but is a genuinely
  # new shape of read for this module: a different instance's own event log
  # (moduledoc divergence 5).
  @spec fetch_child_parent_node_id(child_instance_id :: String.t(), prefix :: String.t()) ::
          {:ok, node_id :: String.t()}
          | {:error, {:child_start_event_missing, child_instance_id :: String.t()}}
          | {:error, {:malformed_payload, event_id :: Ecto.UUID.t(), reason :: term()}}
  defp fetch_child_parent_node_id(child_instance_id, prefix) do
    archived_events =
      ArchivedEvent
      |> where([e], e.instance_id == ^child_instance_id and e.event_type == "INSTANCE_STARTED")
      |> Repo.all(prefix: prefix)
      |> Enum.map(&normalize_merged_event/1)

    live_events_result =
      Event
      |> where([e], e.instance_id == ^child_instance_id and e.event_type == "INSTANCE_STARTED")
      |> Repo.all(prefix: prefix)
      |> resolve_live_payloads(prefix)

    with {:ok, live_events} <- live_events_result do
      case archived_events ++ live_events do
        [event] -> fetch_string_field(event, "parent_node_id")
        _zero_or_many -> {:error, {:child_start_event_missing, child_instance_id}}
      end
    end
  end

  # Same shape as Transition's own private replace_token/2 (transition.ex) --
  # replaces the token whose token_id matches new_token's, preserving list
  # order otherwise. Not reused directly (Transition's is private to that
  # module).
  @spec replace_token([Token.t()], Token.t()) :: [Token.t()]
  defp replace_token(tokens, %Token{token_id: token_id} = new_token) do
    Enum.map(tokens, fn
      %Token{token_id: ^token_id} -> new_token
      other -> other
    end)
  end

  # Mirrors Engine.complete_task/3's own dispatch_task_completion_hop_chain/5
  # shape: the first {:complete_task, token_id} hop is dispatched directly
  # (its own failure is a distinct :transition_error, matching the design
  # doc §5.3 table), then the same worklist loop as INSTANCE_STARTED's own
  # clause drives every subsequent {:advance_token, _} hop.
  defp dispatch_task_completion(graph, state, token_id) do
    case Transition.transition(graph, state, {:complete_task, token_id}) do
      {:ok, new_state, _pending_events} ->
        newly_pending = Engine.tokens_needing_dispatch(state.tokens, new_state.tokens, token_id)

        resolve_pending_events(
          Engine.advance_until_stable(graph, new_state, newly_pending, hop_limit(graph))
        )

      {:error, reason} ->
        {:error, {:transition_error, reason}}
    end
  end

  # REQ-187 counterpart to dispatch_task_completion/3 above, same shape:
  # dispatches the single {:timer_fired, token_id} hop directly (advances
  # the token off the :TIMER node along its outgoing edge, same
  # advance_off_completed_node/4 algorithm TASK_COMPLETED's :HUMAN_TASK
  # completion uses -- design doc §1.4), then drains the same worklist loop.
  defp dispatch_timer_fired(graph, state, token_id) do
    case Transition.transition(graph, state, {:timer_fired, token_id}) do
      {:ok, new_state, _pending_events} ->
        newly_pending = Engine.tokens_needing_dispatch(state.tokens, new_state.tokens, token_id)

        resolve_pending_events(
          Engine.advance_until_stable(graph, new_state, newly_pending, hop_limit(graph))
        )

      {:error, reason} ->
        {:error, {:transition_error, reason}}
    end
  end

  # req062 (SPC-01) counterpart to dispatch_task_completion/3 above, same
  # shape: dispatches the single {:sub_process_completed, token_id} hop
  # directly (Letflow.Engine.Transition clears the token's
  # waiting_child_instance_id and advances it off the :SUB_PROCESS node,
  # same algorithm TASK_COMPLETED's :HUMAN_TASK completion uses -- design
  # doc §2.4), then drains the same worklist loop.
  defp dispatch_sub_process_completion(graph, state, token_id) do
    case Transition.transition(graph, state, {:sub_process_completed, token_id}) do
      {:ok, new_state, _pending_events} ->
        newly_pending = Engine.tokens_needing_dispatch(state.tokens, new_state.tokens, token_id)

        resolve_pending_events(
          Engine.advance_until_stable(graph, new_state, newly_pending, hop_limit(graph))
        )

      {:error, reason} ->
        {:error, {:transition_error, reason}}
    end
  end

  # design doc §12.2 -- replaces the former drop_pending_events/1. Same
  # 3-tuple-in/2-tuple-out adapter shape ({:ok, state, pending_events} ->
  # {:ok, new_state} / {:error, _} = error -> error), except instead of
  # unconditionally discarding pending_events, folds over the list and, for
  # every {:sub_process_start, token_id, _node_id} entry, parks that token by
  # setting its waiting_child_instance_id to @replay_pending_child_marker --
  # real child-instance creation is a live-path-only DB write
  # (Letflow.Engine.SubProcess's own Multi) this module must never perform
  # (INV-RC-1). :parallel_split/:parallel_join_fired/:parallel_join_cancelled
  # entries are still dropped exactly as before -- Transition.transition/3
  # already fully applies their token-set change to the returned
  # InstanceState before emitting them; only :sub_process_start leaves the
  # graph "unfinished" from replay's point of view.
  defp resolve_pending_events({:ok, %InstanceState{} = state, pending_events}) do
    new_tokens =
      Enum.reduce(pending_events, state.tokens, fn
        {:sub_process_start, token_id, _node_id}, tokens ->
          Enum.map(tokens, fn
            %Token{token_id: ^token_id} = token ->
              %Token{token | waiting_child_instance_id: @replay_pending_child_marker}

            other ->
              other
          end)

        _other_pending_event, tokens ->
          tokens
      end)

    {:ok, %InstanceState{state | tokens: new_tokens}}
  end

  defp resolve_pending_events({:error, _reason} = error), do: error

  # Same defensive hop-count formula Engine.create/2's own activate/2 and
  # complete_task/3's own dispatch_task_completion_hop_chain/5 already use
  # (engine.ex) -- a small, pure arithmetic expression with negligible
  # duplication risk, unlike advance_until_stable/4/tokens_needing_dispatch/3
  # themselves (kept as a single shared implementation, see moduledoc/OQ-2).
  defp hop_limit(graph), do: length(graph.nodes) * 4 + 10

  defp fetch_map_field(event, key) do
    case Map.get(event.payload, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      other -> {:error, {:malformed_payload, event.event_id, {key, other}}}
    end
  end

  defp fetch_string_field(event, key) do
    case Map.get(event.payload, key) do
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:malformed_payload, event.event_id, {key, other}}}
    end
  end

  # ---------------------------------------------------------------------
  # Step 3 (design doc §7) -- optional write-back. Never called on the
  # default (read-only) path (INV-RC-1) -- reconstruct_instance/2 only
  # invokes this when opts[:write_back] == true.
  # ---------------------------------------------------------------------

  @spec write_back(
          instance_id :: Ecto.UUID.t(),
          InstanceState.t(),
          opts :: [prefix: String.t(), last_sequence_number: non_neg_integer() | nil]
        ) :: {:ok, :written} | {:error, {:lock_contention, Ecto.UUID.t()}} | {:error, term()}
  defp write_back(instance_id, %InstanceState{} = instance_state, opts) do
    prefix = Keyword.get(opts, :prefix)
    last_sequence_number = Keyword.get(opts, :last_sequence_number)

    result =
      Repo.transaction(fn ->
        case lock_projection_nowait(instance_id, prefix) do
          {:ok, projection} ->
            upsert_projection(
              projection,
              instance_id,
              instance_state,
              last_sequence_number,
              prefix
            )

          {:error, :lock_contention} ->
            Repo.rollback({:lock_contention, instance_id})
        end
      end)

    case result do
      {:ok, {:ok, _projection}} -> {:ok, :written}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, {:lock_contention, _instance_id} = reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # `NOWAIT` (not plain `FOR UPDATE`) turns contention into an immediate,
  # distinct error instead of blocking (design doc §7). Postgres surfaces
  # NOWAIT contention as SQLSTATE 55P03 (`lock_not_available`), raised by
  # Postgrex as `%Postgrex.Error{postgres: %{code: :lock_not_available}}` --
  # rescued here specifically; any other Postgrex.Error re-raises unrescued
  # (design doc §7's own stated scope).
  defp lock_projection_nowait(instance_id, prefix) do
    query =
      InstanceProjection
      |> where([p], p.instance_id == ^instance_id)
      |> lock("FOR UPDATE NOWAIT")

    {:ok, Repo.one(query, prefix: prefix)}
  rescue
    error in Postgrex.Error ->
      if match?(%Postgrex.Error{postgres: %{code: :lock_not_available}}, error) do
        {:error, :lock_contention}
      else
        reraise error, __STACKTRACE__
      end
  end

  # Row absent (AC2/AC3's "projection deleted" scenario) -- inserts a fresh
  # row rather than erroring (design doc §7's own stated extension, this
  # module's OQ-4). definition_id is sourced from the instance's own
  # snapshot -- see this module's moduledoc, divergence 2.
  defp upsert_projection(nil, instance_id, instance_state, last_sequence_number, prefix) do
    with {:ok, snapshot} <- SnapshotStore.get_by_instance_id(instance_id, prefix: prefix) do
      attrs = %{
        instance_id: instance_id,
        status: instance_state.status,
        definition_id: snapshot.definition_id,
        current_nodes: Enum.map(instance_state.tokens, & &1.node_id),
        variables: instance_state.variables,
        last_event_seq: last_sequence_number || 0
      }

      %InstanceProjection{}
      |> InstanceProjection.insert_changeset(attrs)
      |> Repo.insert(prefix: prefix)
    end
  end

  defp upsert_projection(
         %InstanceProjection{} = projection,
         _instance_id,
         instance_state,
         last_sequence_number,
         prefix
       ) do
    attrs = %{
      status: instance_state.status,
      current_nodes: Enum.map(instance_state.tokens, & &1.node_id),
      variables: instance_state.variables,
      last_event_seq: last_sequence_number || projection.last_event_seq
    }

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> Repo.update(prefix: prefix)
  end
end
