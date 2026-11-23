defmodule Letflow.Instances.StepLog do
  @moduledoc """
  The STEP LOG of one instance (pilot gap G6 of the "Register a tenant" pilot,
  owner items 4 and 7): per node visit -- who ran it, when it started, when it
  ended, how it ended, how long it took, how many attempts it took and the
  failure kind of the last attempt.

  ## Derived, never stored

  There is NO step-log table and NO second write path. A step is what the
  engine already writes: the `NODE_ENTERED` event that opened the node visit
  and the event that closed it, plus the dispatch row of the attempt(s). The
  log is read back from those two sources, so it cannot disagree with the
  engine's own history and it costs no write on the hot path.

  The three dispatch tables are read because they are the three kinds of
  automatic step the engine has: an outbound/service call
  (`service_task_dispatches`), a Lua script step (`script_task_dispatches`)
  and a platform function step (`platform_step_dispatches`, the pilot's own
  kind).

  ## What a step NEVER carries (INV-4)

  A step row names the node, the function (or script) the node ran and the
  OUTCOME. It never carries a VALUE: no input, no output, no request body,
  no response body, no URL, no header, no free-text reason. Those live in
  the dispatch rows and in the event payloads, and a step row is rendered on
  a screen next to the event feed -- so it must not be able to carry a realm
  credential, a bearer token or a mail body.

  The read itself keeps that promise: the event query projects the FEW
  payload fields the log needs (`node_id`, `node_type`, `affected`) out of
  the JSON column in the database, so a payload body is never even loaded
  into the process. The dispatch SELECTs name only identifier/status
  columns -- never `inputs`, `outputs`, `config_snapshot` or
  `outcome_detail`.

  Two consequences are deliberate:

    * an HTTP service task's step carries NO name: its URL (and its
      `config_snapshot`, which holds the rendered body template) can carry a
      secret, so the row names the node type only;
    * a failed step carries the failure KIND (a closed vocabulary: a timeout,
      a network error, `http_non_2xx`, `script_rejected`, ...) and never the
      server's error text, which can echo a request body back.

  ## The pairing

  The events are read in sequence order and a step is opened by a
  `NODE_ENTERED` event and closed by the first of:

    * a completion event of the SAME node (`TASK_COMPLETED`,
      `SERVICE_TASK_COMPLETED`, `SCRIPT_TASK_COMPLETED`,
      `SUB_PROCESS_COMPLETED`, `TIMER_FIRED`) -- result `completed`;
    * an `EXECUTION_ERROR` of the same node -- result `failed`;
    * an `INSTANCE_CANCELLED` -- every open step becomes `cancelled`;
    * the next `NODE_ENTERED`, for a PASS-THROUGH node (START, END, a
      gateway): the token leaves such a node as soon as it arrives, so no
      completion event of its own ever closes it.

  Every one of those rules reads the node the way the WRITER of the event
  writes it -- the payload shapes below are the ones the engine really
  emits, not the ones this module would like them to have:

    * a completion event names the node in its own `node_id`
      (`SERVICE_TASK_COMPLETED`, `SCRIPT_TASK_COMPLETED`, `TASK_COMPLETED`,
      `TIMER_FIRED` and `SUB_PROCESS_COMPLETED` -- the last one since the
      parent node was named in it, `lib/letflow/engine/sub_process.ex`);
    * an `EXECUTION_ERROR` names the affected resource under `affected`
      (`{"kind": "node", "node_id": ...}` or `{"kind": "field", "key": ...}`),
      NOT in a top-level `node_id`
      (`lib/letflow/engine/execution_error.ex`).

  An `EXECUTION_ERROR` that names NO node (a field error) closes the OLDEST
  open visit: that is the step the engine was in. An error that names a
  node closes THAT node's visit and no other -- with a parallel branch open
  at the same time, the wrong step must not be marked failed.

  A step still open when the events run out is `running` -- unless its
  dispatch row says the attempts are exhausted (`given_up` / `failed`), which
  makes it `failed`.

  ## The bounds (the log is a screen, not an export)

  The event read is capped at the most recent `@max_events` events of the
  instance, and the answer holds at most the most recent `@max_steps`
  visits. Both caps are stated in the module attributes below. An instance
  with more history than that shows its recent steps only.

  ## The actor

  The actor of a step is the actor of the event that CLOSED it -- the person
  who completed a human task -- and, for a step that is still open, the actor
  of the event that opened it. Both are the engine's own `actor_id`: the
  server-resolved principal, never a value a caller supplied. The display
  name is resolved by the caller (`Letflow.Instances.timeline/3` shares one
  batched lookup between the event page and the step log), so this module
  returns the id and the metadata fallback only.

  ## Tenant scoping (INV-1)

  Every read passes the tenant `prefix` explicitly; the schema is never taken
  from the request. The dispatch tables are read only when they physically
  exist in the tenant's schema: a tenant provisioned before the newest
  dispatch migration has no `platform_step_dispatches` table, and a missing
  table must not become a 500 on the timeline route.
  """

  import Ecto.Query

  alias Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Event
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo

  @typedoc """
  One node visit. `actor_display_name` is filled in by the caller (the
  timeline route resolves the names of the whole page in one query).
  """
  @type step :: %{
          node_id: String.t(),
          node_type: String.t(),
          step: String.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          actor_metadata: map(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          duration_ms: integer() | nil,
          result: String.t(),
          attempts: non_neg_integer(),
          last_failure_kind: String.t() | nil
        }

  @typedoc "The options every function here takes: the tenant `prefix` (INV-1)."
  @type opts :: [prefix: String.t()]

  # The cap of events read for one instance. An instance with more events
  # than this shows its most RECENT steps only: the log is a screen, not an
  # export.
  @max_events 5_000

  # The cap of steps the answer holds. The most RECENT visits are kept, so
  # the answer's size does not grow with the length of the instance (the
  # timeline answer carries the step log beside every event page).
  @max_steps 200

  # The node kinds the token LEAVES as soon as it arrives: no completion
  # event of their own ever closes them, so the next NODE_ENTERED does.
  @pass_through_node_types ~w(START END EXCLUSIVE_GATEWAY PARALLEL_GATEWAY)

  # The event types that close the step of the SAME node.
  @completion_event_types ~w(
    TASK_COMPLETED
    SERVICE_TASK_COMPLETED
    SCRIPT_TASK_COMPLETED
    SUB_PROCESS_COMPLETED
    TIMER_FIRED
  )

  @doc """
  The event types this log reads as the completion of a step (each is
  written with a top-level `node_id`). A class test derives the list from the
  writers in `lib/`, so a new completion type cannot leave a visit open.
  """
  @spec completion_event_types() :: [String.t()]
  def completion_event_types, do: @completion_event_types

  # The dispatch tables, and whether they exist in the tenant's schema is
  # checked before they are read (a tenant provisioned before the newest
  # dispatch migration has no `platform_step_dispatches` table).
  @dispatch_tables ~w(service_task_dispatches script_task_dispatches platform_step_dispatches)

  @doc """
  The step log of one instance, oldest visit first.

  `opts` carries the tenant `:prefix` (INV-1). The answer is `{:ok, steps}`;
  it never fails: a tenant whose schema lacks one of the dispatch tables gets
  the steps those events alone describe.
  """
  @spec steps(Ecto.UUID.t(), opts()) :: {:ok, [step()]}
  def steps(instance_id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    events = fetch_events(instance_id, prefix)
    dispatches = fetch_dispatches(instance_id, prefix)

    {:ok, derive(events, dispatches)}
  end

  # ── the events ─────────────────────────────────────────────────────────────

  # The instance's own events, oldest first, hidden bookkeeping types
  # excluded (the same exclusion the history and the timeline apply). The
  # read is capped at the most recent `@max_events` events.
  #
  # The query projects the few payload fields the log needs OUT of the JSON
  # column (`node_id`, `node_type`, `affected`), so a payload body -- an
  # output, a decoded HTTP body, a variable map -- is never loaded into the
  # process (INV-4: the step log cannot carry a value, and here it cannot
  # even read one). The fragments are static strings with bound parameters
  # (INV-7: no SQL interpolation).
  defp fetch_events(instance_id, prefix) do
    hidden = [VariableMerge.sys_event_type()]

    query =
      Event
      |> where([e], e.instance_id == ^instance_id)
      |> where([e], e.event_type not in ^hidden)
      |> order_by([e], desc: e.sequence_number)
      |> limit(^@max_events)
      |> select([e], %{
        type: e.event_type,
        node_id: fragment("?->>'node_id'", e.payload),
        node_type: fragment("?->>'node_type'", e.payload),
        affected_kind: fragment("?->'affected'->>'kind'", e.payload),
        affected_node_id: fragment("?->'affected'->>'node_id'", e.payload),
        actor_id: e.actor_id,
        metadata: e.metadata,
        at: e.created_at
      })

    query
    |> Repo.all(prefix: prefix)
    |> Enum.reverse()
  end

  # ── the dispatch rows ───────────────────────────────────────────────────────

  # The dispatch rows of the instance, grouped by node id and ordered by the
  # time the row was written: the i-th visit of a node takes the i-th row.
  defp fetch_dispatches(instance_id, prefix) do
    existing = existing_dispatch_tables(prefix)

    rows =
      service_rows(instance_id, prefix, existing) ++
        script_rows(instance_id, prefix, existing) ++
        platform_rows(instance_id, prefix, existing)

    rows
    |> Enum.group_by(& &1.node_id, & &1)
    |> Map.new(fn {node_id, node_rows} ->
      {node_id, Enum.sort_by(node_rows, & &1.created_at)}
    end)
  end

  # The dispatch tables of the tenant schema that physically exist. A tenant
  # provisioned before the newest dispatch migration has no
  # `platform_step_dispatches` table; reading it would raise (INV-8).
  defp existing_dispatch_tables(prefix) do
    query = """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = $1 AND table_name = ANY($2)
    """

    %Postgrex.Result{rows: rows} = Repo.query!(query, [prefix, @dispatch_tables])
    MapSet.new(Enum.map(rows, &hd/1))
  end

  defp service_rows(instance_id, prefix, existing) do
    if MapSet.member?(existing, "service_task_dispatches") do
      ServiceTaskDispatch
      |> where([d], d.instance_id == ^instance_id)
      |> order_by([d], asc: d.created_at)
      |> select([d], {d.node_id, d.attempt_index, d.status, d.last_failure_kind, d.created_at})
      |> Repo.all(prefix: prefix)
      |> Enum.map(fn {node_id, attempt_index, status, failure_kind, created_at} ->
        %{
          node_id: node_id,
          step: nil,
          # The HTTP row counts the RETRIES after the first attempt, so the
          # number of attempts it records is one more than its index.
          attempts: attempt_index + 1,
          last_failure_kind: failure_kind,
          failed?: status == :given_up,
          created_at: created_at
        }
      end)
    else
      []
    end
  end

  defp script_rows(instance_id, prefix, existing) do
    if MapSet.member?(existing, "script_task_dispatches") do
      ScriptTaskDispatch
      |> where([d], d.instance_id == ^instance_id)
      |> order_by([d], asc: d.inserted_at)
      |> select([d], {d.node_id, d.script_key, d.attempt, d.status, d.outcome, d.inserted_at})
      |> Repo.all(prefix: prefix)
      |> Enum.map(fn {node_id, script_key, attempt, status, outcome, created_at} ->
        %{
          node_id: node_id,
          step: script_key,
          attempts: attempt,
          last_failure_kind: script_failure_kind(status, outcome),
          failed?: status == :failed,
          created_at: created_at
        }
      end)
    else
      []
    end
  end

  defp platform_rows(instance_id, prefix, existing) do
    if MapSet.member?(existing, "platform_step_dispatches") do
      StepDispatch
      |> where([d], d.instance_id == ^instance_id)
      |> order_by([d], asc: d.created_at)
      |> select(
        [d],
        {d.node_id, d.function_name, d.attempt_index, d.status, d.last_failure_kind, d.created_at}
      )
      |> Repo.all(prefix: prefix)
      |> Enum.map(fn {node_id, function_name, attempt_index, status, failure_kind, created_at} ->
        %{
          node_id: node_id,
          step: function_name,
          attempts: attempt_index,
          last_failure_kind: failure_kind,
          failed?: status == :given_up,
          created_at: created_at
        }
      end)
    else
      []
    end
  end

  # A script row names its failure kind in `outcome` (a closed vocabulary:
  # `script_rejected`, `apply_failed`, ...); a row that did not fail names
  # none.
  defp script_failure_kind(:failed, outcome) when is_binary(outcome), do: outcome
  defp script_failure_kind(_status, _outcome), do: nil

  # ── the derivation ──────────────────────────────────────────────────────────

  # The events, in sequence order, against the dispatch rows: one step per
  # node visit, in the order the visits STARTED.
  #
  # The steps are kept in ONE list, in start order, and a closing event
  # updates the step it closes in place. Two lists (open and closed) would
  # lose the start order: a step that starts first and closes last would
  # move to the end of the log.
  defp derive(events, dispatches) do
    events
    |> Enum.reduce([], &apply_event/2)
    |> Enum.map(&finalize_step/1)
    |> attach_dispatches(dispatches)
    |> cap_steps()
  end

  # The answer holds the most RECENT `@max_steps` visits: the timeline answer
  # carries the step log beside every event page, so its size must not grow
  # with the length of the instance.
  defp cap_steps(steps) when length(steps) <= @max_steps, do: steps
  defp cap_steps(steps), do: Enum.take(steps, -@max_steps)

  defp apply_event(%{type: "NODE_ENTERED"} = event, steps) do
    # A pass-through node is left as soon as it is entered, so the NEXT
    # NODE_ENTERED closes it. Every other open step stays open: a parallel
    # branch may enter another node while a human task is still pending.
    steps = close_pass_through(steps, event.at)

    steps ++
      [
        %{
          node_id: event.node_id || "",
          node_type: event.node_type || "",
          step: nil,
          actor_id: event.actor_id,
          actor_metadata: event.metadata || %{},
          started_at: event.at,
          ended_at: nil,
          duration_ms: nil,
          result: "running",
          open?: true,
          attempts: 0,
          last_failure_kind: nil
        }
      ]
  end

  defp apply_event(%{type: type} = event, steps) when type in @completion_event_types do
    close_visit(steps, event.node_id, "completed", event.at, event.actor_id, event.metadata)
  end

  defp apply_event(%{type: "EXECUTION_ERROR"} = event, steps) do
    index =
      if is_binary(event.affected_node_id) do
        # The error names the node it happened on (the engine writes the
        # affected resource under `affected`, `{"kind": "node", ...}`):
        # THAT visit is the failed one, even when another visit is open.
        open_index(steps, event.affected_node_id)
      else
        # An error that names no node (a field error) closes the OLDEST open
        # visit: that is the step the engine was in.
        steps
        |> Enum.with_index()
        |> Enum.find_value(fn {step, index} -> if step.open?, do: index end)
      end

    if index, do: close_at(steps, index, "failed", event.at, nil, nil), else: steps
  end

  defp apply_event(%{type: "INSTANCE_CANCELLED"} = event, steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce(steps, fn {step, index}, acc ->
      if step.open?, do: close_at(acc, index, "cancelled", event.at, nil, nil), else: acc
    end)
  end

  defp apply_event(_event, steps), do: steps

  # Every open PASS-THROUGH visit is closed by the node visit that follows it.
  defp close_pass_through(steps, at) do
    steps
    |> Enum.with_index()
    |> Enum.reduce(steps, fn {step, index}, acc ->
      if step.open? and step.node_type in @pass_through_node_types do
        close_at(acc, index, "completed", at, nil, nil)
      else
        acc
      end
    end)
  end

  # The LAST open visit of `node_id`: a node may be visited more than once
  # (a loop), and the completion closes the visit it belongs to.
  defp open_index(steps, node_id) do
    steps
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {step, index} ->
      if step.open? and step.node_id == node_id, do: index
    end)
  end

  defp close_visit(steps, node_id, result, at, actor_id, metadata) do
    case open_index(steps, node_id) do
      # A completion for a visit that is not open (the visit was closed by an
      # earlier event, or the log starts in the middle of the instance):
      # nothing to close.
      nil ->
        steps

      index ->
        close_at(steps, index, result, at, actor_id, metadata)
    end
  end

  # A step that closes: the end time, the duration and -- when the closing
  # event names a person -- that person as the actor of the step.
  defp close_at(steps, index, result, at, actor_id, metadata) do
    List.update_at(steps, index, fn step ->
      step
      |> Map.put(:ended_at, at)
      |> Map.put(:duration_ms, duration_ms(step.started_at, at))
      |> Map.put(:result, result)
      |> Map.put(:open?, false)
      |> put_actor(actor_id)
      |> put_actor_metadata(metadata)
    end)
  end

  defp put_actor(step, nil), do: step
  defp put_actor(step, actor_id), do: Map.put(step, :actor_id, actor_id)

  defp put_actor_metadata(step, nil), do: step
  defp put_actor_metadata(step, metadata), do: Map.put(step, :actor_metadata, metadata)

  # A step that was never closed is still running.
  defp finalize_step(step), do: Map.delete(step, :open?)

  defp duration_ms(%DateTime{} = from, %DateTime{} = to),
    do: DateTime.diff(to, from, :millisecond)

  defp duration_ms(_from, _to), do: nil

  # The dispatch rows of a node are attached to that node's visits in order:
  # the i-th visit takes the i-th row. A visit with no row (a human task, a
  # gateway) counts ONE attempt.
  defp attach_dispatches(steps, dispatches) do
    {steps, _used} =
      Enum.map_reduce(steps, %{}, fn step, used ->
        node_id = Map.get(step, :node_id)
        rows = Map.get(dispatches, node_id, [])
        index = Map.get(used, node_id, 0)
        row = Enum.at(rows, index)

        used = Map.put(used, node_id, index + 1)

        {merge_dispatch(step, row), used}
      end)

    steps
  end

  defp merge_dispatch(step, nil) do
    step
    |> Map.put(:attempts, 1)
    |> Map.put(:last_failure_kind, nil)
  end

  defp merge_dispatch(step, row) do
    attempts = Map.get(row, :attempts) || 0

    step
    |> Map.put(:attempts, attempts)
    |> Map.put(:step, Map.get(row, :step) || Map.get(step, :step))
    |> Map.put(:last_failure_kind, Map.get(row, :last_failure_kind))
    |> then(fn merged ->
      if Map.get(row, :failed?) and Map.get(merged, :result) == "running" do
        Map.put(merged, :result, "failed")
      else
        merged
      end
    end)
  end
end
