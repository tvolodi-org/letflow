defmodule Letflow.Support.WriteHookProbe do
  @moduledoc """
  REQ-607 / GH #3413 part B test helpers: an all-process `[:letflow, :repo, :query]` collector
  (the existing `PlatformTenantFixture.capture_repo_queries/1` sees the calling process only), the
  per-attempt "hook phase" of a write, and pinned-connection writers for forced-overlap tests.

  Telemetry handlers run in the process that issued the query, after the query returned (a lock it
  took is held). A handler that blocks therefore pauses that writer while it holds its locks.
  Nothing here is production code and nothing needs a production seam.
  """

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Repo

  @event [:letflow, :repo, :query]

  # ── collecting ──────────────────────────────────────────────────────────────

  @doc false
  def handle_collect(_event, _measurements, metadata, {test_pid, ref}) do
    send(
      test_pid,
      {:probe, ref,
       %{
         pid: self(),
         at: System.monotonic_time(:microsecond),
         query: Map.get(metadata, :query),
         params: Map.get(metadata, :params) || [],
         result: Map.get(metadata, :result)
       }}
    )

    :ok
  end

  @doc """
  Runs `fun` and returns `{result, events}`: every query of EVERY process while it ran, in arrival
  order. Each event is `%{pid, at, query, params, result}` (`at` = monotonic microseconds taken after
  the query returned; `result` is the telemetry `:result`, so a Postgres error stays visible).
  """
  @spec capture_all((-> result)) :: {result, [map()]} when result: term()
  def capture_all(fun) when is_function(fun, 0) do
    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, @event, &__MODULE__.handle_collect/4, {self(), ref})

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {:probe, ^ref, event} -> drain(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The events of the given pid or pids."
  @spec by_pid([map()], pid() | [pid()]) :: [map()]
  def by_pid(events, pids), do: Enum.filter(events, &(&1.pid in List.wrap(pids)))

  @doc "The Postgres error codes (atoms) seen in `events`, in order."
  @spec errors([map()]) :: [atom()]
  def errors(events) do
    for %{result: {:error, %Postgrex.Error{postgres: %{code: code}}}} <- events, do: code
  end

  # ── recognising statements ──────────────────────────────────────────────────

  @doc "A `FOR UPDATE` read of the sequence table (the table is `instance_sequence`)."
  @spec lock?(map()) :: boolean()
  def lock?(%{query: q}), do: is_binary(q) and q =~ "instance_sequence" and q =~ "FOR UPDATE"

  @doc "A plain `SELECT` of the sequence table (the counter read, or `compare/4`)."
  @spec plain_sequence_select?(map()) :: boolean()
  def plain_sequence_select?(%{query: q}),
    do:
      is_binary(q) and String.starts_with?(q, "SELECT") and q =~ "instance_sequence" and
        not (q =~ "FOR UPDATE")

  @doc "An `INSERT` into the sequence table (the lock step inserts an absent row)."
  @spec sequence_insert?(map()) :: boolean()
  def sequence_insert?(%{query: q}),
    do: is_binary(q) and String.starts_with?(q, "INSERT") and q =~ "instance_sequence"

  @doc "An `INSERT` into the `events` table."
  @spec event_insert?(map()) :: boolean()
  def event_insert?(%{query: q}),
    do: is_binary(q) and String.starts_with?(q, "INSERT INTO") and q =~ ~s|."events"|

  @doc "The sequence-row locks of `events`, in order."
  @spec locks([map()]) :: [map()]
  def locks(events), do: Enum.filter(events, &lock?/1)

  @doc """
  One entry per hook attempt of ONE pid's events: the sequence-row `FOR UPDATE` events from the
  attempt's `SET LOCAL lock_timeout` up to the `compare/4` SELECT. The append-time lock of
  `EventStore.append_multi` (`assign_sequence`) comes after compare and belongs to no phase.
  """
  @spec hook_phases([map()]) :: [[map()]]
  def hook_phases(events) do
    {phases, open} =
      Enum.reduce(events, {[], nil}, fn event, {done, open} ->
        cond do
          is_binary(event.query) and event.query =~ "SET LOCAL lock_timeout" ->
            {done, []}

          open != nil and plain_sequence_select?(event) ->
            {done ++ [Enum.reverse(open)], nil}

          open != nil and lock?(event) ->
            {done, [event | open]}

          true ->
            {done, open}
        end
      end)

    if open == nil, do: phases, else: phases ++ [Enum.reverse(open)]
  end

  @doc "The instance ids of lock events (the id is the first bound parameter)."
  @spec lock_ids([map()]) :: [String.t()]
  def lock_ids(lock_events) do
    Enum.map(lock_events, fn %{params: [id | _]} ->
      if byte_size(id) == 16, do: Ecto.UUID.load!(id), else: id
    end)
  end

  @doc "Maps lock events to the type names in `types` (by registry id)."
  @spec lock_types([map()], String.t(), [String.t()]) :: [String.t() | :unknown]
  def lock_types(lock_events, schema, types) do
    by_id =
      Map.new(types, fn type ->
        {:ok, id} = EntityTypeInstance.get_or_create(type, schema)
        {id, type}
      end)

    lock_events |> lock_ids() |> Enum.map(&Map.get(by_id, &1, :unknown))
  end

  # ── blocking a writer at a chosen point ─────────────────────────────────────

  @doc false
  def handle_pause(_event, _measurements, metadata, %{pid: pid, n: n, test: test, key: key}) do
    if self() == pid and lock?(%{query: Map.get(metadata, :query)}) do
      count = Process.get(key, 0) + 1
      Process.put(key, count)

      if count == n do
        send(test, {:paused, pid})

        receive do
          :go -> :ok
        after
          15_000 -> :ok
        end
      end
    end

    :ok
  end

  @doc """
  Pauses `pid` (inside its transaction, locks held) right after its `n`th sequence-row lock query.
  The writer is resumed by sending it `:go`. Attach before the writer issues its first query.
  Returns a detach function.
  """
  @spec pause_after_nth_lock(pid(), pos_integer(), pid()) :: (-> :ok)
  def pause_after_nth_lock(pid, n, test_pid) do
    ref = make_ref()
    id = {__MODULE__, :pause, ref}
    state = %{pid: pid, n: n, test: test_pid, key: {__MODULE__, :locks, ref}}
    :telemetry.attach(id, @event, &__MODULE__.handle_pause/4, state)
    fn -> detach(id) end
  end

  @doc false
  def handle_counter(_event, _measurements, metadata, %{pid: pid, fun: fun, key: key}) do
    if self() == pid and Process.get(key) == nil and
         plain_sequence_select?(%{query: Map.get(metadata, :query)}) do
      Process.put(key, true)
      fun.()
    end

    :ok
  end

  @doc """
  Runs `fun` once, in `pid`, right after its first plain `SELECT` of the sequence table returns
  (the counter read of the read phase, before the record rows are read). Returns a detach function.
  """
  @spec after_counter_query(pid(), (-> term())) :: (-> :ok)
  def after_counter_query(pid, fun) do
    ref = make_ref()
    id = {__MODULE__, :counter, ref}
    state = %{pid: pid, fun: fun, key: {__MODULE__, :counter_done, ref}}
    :telemetry.attach(id, @event, &__MODULE__.handle_counter/4, state)
    fn -> detach(id) end
  end

  defp detach(id) do
    :telemetry.detach(id)
    :ok
  end

  # ── pinned writers and the blocked-wait proof ───────────────────────────────

  @doc """
  Starts a `Task` that pins one pool connection (`Repo.checkout/1`), reports
  `{:backend, task_pid, backend_pid}` to `test_pid`, waits for `:start`, then runs `fun`. The
  backend pid is the connection of every statement of `fun`, so `wait_blocked/1` proves that
  this writer is the one waiting on a lock.
  """
  @spec pinned_writer(pid(), (-> term())) :: Task.t()
  def pinned_writer(test_pid, fun) do
    Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(test_pid, {:backend, self(), backend})

        receive do
          :start -> fun.()
        after
          15_000 -> :never_started
        end
      end)
    end)
  end

  @doc "Polls (25 ms, up to 5 s) until the backend `backend_pid` waits on a lock. Bound parameter."
  @spec wait_blocked(integer()) :: :ok
  def wait_blocked(backend_pid) when is_integer(backend_pid), do: wait_blocked(backend_pid, 200)

  defp wait_blocked(backend_pid, 0),
    do: ExUnit.Assertions.flunk("backend #{backend_pid} never waited on a lock")

  defp wait_blocked(backend_pid, tries) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
        [backend_pid]
      )

    if rows == [] do
      Process.sleep(25)
      wait_blocked(backend_pid, tries - 1)
    else
      :ok
    end
  end
end
