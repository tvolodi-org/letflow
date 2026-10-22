defmodule Letflow.Api.Scope.ShadowEvidence do
  @moduledoc """
  Persisted shadow evidence of the scope-enforcement rollout (REQ-517 PR 2b / GH #2535, AC 22;
  design `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 4.7 and 4.8).

  `Letflow.Api.Scope.Shadow` records, for every authorized request of a tenant in `shadow`,
  one `requests` count and, for a would-deny, one count per reason (the closed six-value
  `Letflow.Api.Scope.deny_reason()` set). The counts live in a public named ETS table keyed
  `{tenant prefix, UTC day, metric}`; this GenServer flushes them every
  `:scope_shadow_flush_interval_ms` (default 30_000) and on shutdown into the tenant table
  `scope_shadow_counters` (`Letflow.Api.Scope.ShadowEvidence.Counter`). REQ-519's flip reads
  the persisted counts through `counts_between/3`.

  ## Never on the request path

  `record/2,3` is one `:ets.update_counter/4` in the CALLER's process: no GenServer call, no
  database, and it never raises (a missing table or any error is swallowed). The flush runs
  in this process only.

  ## Flush (INV-1, INV-7)

  Per distinct prefix in the table: the prefix is validated with
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (an ETS entry whose prefix fails it
  is DROPPED, never flushed), then ONE `Repo.insert_all(Counter, rows, prefix: prefix,
  on_conflict: ..., conflict_target: [:day, :metric])` upserts the snapshot additively
  (`count = count + EXCLUDED.count`). Ecto binds the tenant schema; the prefix string is never
  concatenated into SQL. On success exactly the flushed amount is subtracted from each ETS
  counter, so increments made during the flush are kept. On a transient failure the counters
  stay, one constant line `scope_shadow_flush_failed class=<kind>` is logged (no tenant, no
  ids) and the next tick retries; an `undefined_table` or invalid-schema error DISCARDS that
  prefix's counters (a dropped tenant cannot leak memory).

  ## Retention

  Once per UTC day, for each prefix this process flushed that day, rows older than
  `:scope_shadow_retention_days` (default 90) are deleted. The value must be at least the
  largest `:scope_shadow_min_days` REQ-519 may configure.

  ## Crash residual

  At most one flush interval of counts is lost on a crash (the ETS table dies with the
  process), which can only make REQ-519's gate more lenient, never stricter.
  """

  use GenServer, shutdown: 10_000

  import Ecto.Query

  require Logger

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.ShadowEvidence.Counter
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @table :letflow_scope_shadow_evidence
  @reasons Scope.deny_reasons()
  @metrics [:requests | @reasons]
  @metric_by_text Map.new(@metrics, &{Atom.to_string(&1), &1})
  @default_flush_interval_ms 30_000
  @default_retention_days 90

  @type metric :: unquote(Enum.reduce(tl(@metrics), hd(@metrics), &{:|, [], [&1, &2]}))

  @type state :: %{pruned: {Date.t(), MapSet.t(String.t())}}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one observation for tenant schema `prefix`, UTC today. Never raises, never blocks,
  never touches the database.
  """
  @spec record(prefix :: String.t(), metric()) :: :ok
  def record(prefix, metric), do: record(prefix, metric, Date.utc_today())

  @doc "As `record/2` with an explicit UTC `day` (tests and day-rollover handling)."
  @spec record(prefix :: String.t(), metric(), day :: Date.t()) :: :ok
  def record(prefix, metric, %Date{} = day) when is_binary(prefix) and metric in @metrics do
    increment({prefix, day, metric})
  end

  def record(_prefix, _metric, _day), do: :ok

  defp increment(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Flushes synchronously (shutdown and tests). Never raises into the caller;
  `{:error, :not_running}` when the process is down.
  """
  @spec flush() :: :ok | {:error, term()}
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc """
  The PERSISTED counts for tenant schema `prefix` over the UTC days `from..to` (inclusive),
  summed per metric; all seven metrics are present (0 when absent). Reads the table only:
  unflushed ETS counts are not included (call `flush/0` first for a live view). The prefix
  must be a tenant schema name (`ArgumentError` otherwise).
  """
  @spec counts_between(prefix :: String.t(), from :: Date.t(), to :: Date.t()) ::
          %{metric() => non_neg_integer()}
  def counts_between(prefix, %Date{} = from, %Date{} = to) when is_binary(prefix) do
    unless valid_prefix?(prefix), do: raise(ArgumentError, "invalid tenant schema prefix")

    sums =
      Repo.all(
        from(c in Counter,
          where: c.day >= ^from and c.day <= ^to,
          group_by: c.metric,
          select: {c.metric, sum(c.count)}
        ),
        prefix: prefix
      )

    Enum.reduce(sums, Map.new(@metrics, &{&1, 0}), fn {text, total}, acc ->
      case Map.fetch(@metric_by_text, text) do
        {:ok, metric} -> Map.put(acc, metric, to_count(total))
        :error -> acc
      end
    end)
  end

  @doc """
  REQ-519 2f-a (design 4.6, F11): the PERSISTED counts per UTC day for tenant schema `prefix`
  over `from..to` (inclusive), in ONE grouped query: `%{Date.t() => %{metric() => count}}`.
  Only dates that have at least one row appear (a caller treats an absent date as the
  all-zero map); every present date carries all seven metrics. Same prefix validation and
  `ArgumentError` as `counts_between/3`; reads the table only.
  """
  @spec counts_by_day(prefix :: String.t(), from :: Date.t(), to :: Date.t()) ::
          %{Date.t() => %{metric() => non_neg_integer()}}
  def counts_by_day(prefix, %Date{} = from, %Date{} = to) when is_binary(prefix) do
    unless valid_prefix?(prefix), do: raise(ArgumentError, "invalid tenant schema prefix")

    rows =
      Repo.all(
        from(c in Counter,
          where: c.day >= ^from and c.day <= ^to,
          group_by: [c.day, c.metric],
          select: {c.day, c.metric, sum(c.count)}
        ),
        prefix: prefix
      )

    zero = Map.new(@metrics, &{&1, 0})

    Enum.reduce(rows, %{}, fn {day, text, total}, acc ->
      case Map.fetch(@metric_by_text, text) do
        {:ok, metric} ->
          Map.update(
            acc,
            day,
            Map.put(zero, metric, to_count(total)),
            &Map.put(&1, metric, to_count(total))
          )

        :error ->
          acc
      end
    end)
  end

  @doc "The closed six-value would-deny reason set (every metric except `:requests`)."
  @spec reasons() :: [metric()]
  def reasons, do: @reasons

  defp valid_prefix?(prefix),
    do: match?({:ok, _tenant_id}, TenantProvisioning.tenant_id_for_schema_name(prefix))

  defp to_count(%Decimal{} = total), do: Decimal.to_integer(total)
  defp to_count(total) when is_integer(total), do: total
  defp to_count(_other), do: 0

  # -- GenServer ----------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:public, :named_table, :set, {:write_concurrency, true}])
    schedule_flush()
    {:ok, %{pruned: {Date.utc_today(), MapSet.new()}}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {result, state} = run_flush(state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {_result, state} = run_flush(state)
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = run_flush(state)
    :ok
  end

  defp schedule_flush do
    interval =
      Application.get_env(:letflow, :scope_shadow_flush_interval_ms, @default_flush_interval_ms)

    Process.send_after(self(), :flush, interval)
  end

  # Never raises: a failure is logged as one constant line and the counters are kept.
  @spec run_flush(state()) :: {:ok | {:error, term()}, state()}
  defp run_flush(state) do
    state = roll_prune_day(state)
    flushed = flush_all()
    {result(flushed), prune_flushed(flushed, state)}
  rescue
    _exception -> {note_failure(:error), state}
  catch
    kind, _reason -> {note_failure(kind), state}
  end

  defp result(flushed) do
    if Enum.all?(flushed, fn {_prefix, outcome} -> outcome in [:ok, :dropped] end),
      do: :ok,
      else: {:error, :flush_failed}
  end

  defp roll_prune_day(%{pruned: {day, _done}} = state) do
    today = Date.utc_today()
    if day == today, do: state, else: %{state | pruned: {today, MapSet.new()}}
  end

  defp flush_all do
    @table
    |> :ets.tab2list()
    |> Enum.group_by(fn {{prefix, _day, _metric}, _count} -> prefix end)
    |> Enum.map(fn {prefix, entries} -> {prefix, flush_prefix(prefix, entries)} end)
  end

  defp flush_prefix(prefix, entries) do
    if valid_prefix?(prefix) do
      upsert(prefix, entries)
    else
      # A hostile or malformed key is dropped, never flushed (INV-7).
      discard(entries)
      :dropped
    end
  end

  defp upsert(prefix, entries) do
    live = Enum.filter(entries, fn {_key, count} -> count > 0 end)
    now = DateTime.utc_now()

    rows =
      for {{_prefix, day, metric}, count} <- live,
          do: %{day: day, metric: Atom.to_string(metric), count: count, updated_at: now}

    if rows != [], do: insert_rows(prefix, rows)
    subtract(live)
    :ok
  rescue
    e in Postgrex.Error ->
      if discardable?(e) do
        discard(entries)
        :dropped
      else
        note_failure(:error)
      end

    _exception ->
      note_failure(:error)
  catch
    kind, _reason -> note_failure(kind)
  end

  defp insert_rows(prefix, rows) do
    Repo.insert_all(Counter, rows,
      prefix: prefix,
      on_conflict:
        from(c in Counter,
          update: [
            set: [
              count: fragment("? + EXCLUDED.count", c.count),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:day, :metric]
    )
  end

  defp discardable?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:undefined_table, :invalid_schema_name]

  defp discardable?(_other), do: false

  # Exactly the flushed amount: increments made during the flush are kept.
  defp subtract(entries) do
    for {key, count} <- entries do
      :ets.update_counter(@table, key, {2, -count})
      :ets.match_delete(@table, {key, 0})
    end

    :ok
  end

  defp discard(entries) do
    for {key, _count} <- entries, do: :ets.delete(@table, key)
    :ok
  end

  # Once per UTC day per prefix this process flushed successfully (moduledoc, Retention).
  defp prune_flushed(flushed, %{pruned: {day, done}} = state) do
    todo =
      for {prefix, :ok} <- flushed, not MapSet.member?(done, prefix), do: prefix

    pruned = Enum.filter(todo, &prune/1)
    %{state | pruned: {day, Enum.into(pruned, done)}}
  end

  defp prune(prefix) do
    retention =
      Application.get_env(:letflow, :scope_shadow_retention_days, @default_retention_days)

    cutoff = Date.add(Date.utc_today(), -retention)
    Repo.delete_all(from(c in Counter, where: c.day < ^cutoff), prefix: prefix)
    true
  rescue
    _exception ->
      note_failure(:error)
      false
  catch
    kind, _reason ->
      note_failure(kind)
      false
  end

  # One constant line (no tenant, no ids).
  defp note_failure(kind) do
    Logger.warning("scope_shadow_flush_failed class=#{kind}")
    {:error, kind}
  end
end
