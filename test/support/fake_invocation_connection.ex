defmodule Letflow.Test.FakeInvocationConnection do
  @moduledoc """
  Test helper for the `TenantSchemaReaper` concurrent-invocation-guard tests
  (`service_catalog_reaper_test.exs`, `template_build_reaper_test.exs`,
  `tenant_schema_reaper_test.exs`): opens a real, separate Postgres connection
  tagged with a fake `application_name`, standing in for "another `mix test`
  invocation", and closes it again deterministically (Q-1037 / GH #2364).

  Two CI flake classes this module removes. The guard miss of GH #2441 is NOT removed
  here: `capture/2` diagnoses it and `assert_visible!/3` pre-checks it, see below:

  1. **Shed first query.** The fake connection was a plain `Postgrex.start_link/1`
     with DBConnection's default overload-shedding queue options (`:queue_target`
     50 ms / `:queue_interval` 2 s). `start_link/1` returns before the handshake
     completes, so on a slow runner the first query was dropped with
     `DBConnection.ConnectionError: connection not available and request was
     dropped from queue after 4000ms`. `opts/1` therefore reuses
     `Letflow.Support.BpmDefaultRealmDisplacement.dedicated_connection_opts/0`
     (the single source of truth for a private, never-shedding connection), and
     `start!/2` does not return until the connection itself has answered a
     `pg_stat_activity` query listing its own tag.
  2. **Late-leaving backend.** After `GenServer.stop/1` the server-side backend
     leaves `pg_stat_activity` slightly LATER, so an immediate second sweep could
     still see the tag and defer. `stop_and_wait_gone!/3` polls, bounded, until the
     tag is really gone.

  The polls (`start!/2`, `stop_and_wait_gone!/3`, `assert_visible!/3`) default to
  100 attempts x 50 ms and are overridable with the `:attempts` and `:interval_ms`
  options. `assert_visible!/3` checks through `Letflow.Repo` (the sweeper's session
  type), and `capture/2` gathers failure-time evidence for a guard miss.
  """

  alias Letflow.Repo
  alias Letflow.Support.BpmDefaultRealmDisplacement

  @default_attempts 100
  @default_interval_ms 50
  @query_timeout_ms 5_000

  @tag_sql "SELECT 1 FROM pg_stat_activity WHERE application_name = $1"

  @type poll_opts :: [attempts: pos_integer(), interval_ms: non_neg_integer()]

  @doc """
  Returns the `Postgrex.start_link/1` options for a connection tagged `tag`: the
  never-shedding dedicated-connection options (queue options, connect and query
  timeouts) with `parameters: [application_name: tag]` set.
  """
  @spec opts(String.t()) :: keyword()
  def opts(tag) when is_binary(tag) do
    BpmDefaultRealmDisplacement.dedicated_connection_opts()
    |> Keyword.put(:parameters, application_name: tag)
  end

  @doc """
  Starts the fake-tagged connection (linked to the caller) and blocks until it is
  connected and visible in `pg_stat_activity` under `tag`, polling through the new
  connection itself. Registers an `ExUnit.Callbacks.on_exit/1` stop that tolerates
  the process already being gone (ISS-0452). Returns the connection.

  Must be called from a test or setup process. Raises, naming `tag`, if the
  connection never shows up within the bounded poll.
  """
  @spec start!(String.t(), poll_opts()) :: pid()
  def start!(tag, poll_opts \\ []) when is_binary(tag) do
    {:ok, conn} = Postgrex.start_link(opts(tag))

    # ISS-0452: tolerate the connection process already being gone -- it is linked
    # to the test process, and on_exit runs after that process exits, so
    # check-then-act races its own shutdown.
    ExUnit.Callbacks.on_exit(fn ->
      try do
        GenServer.stop(conn)
      catch
        :exit, _ -> :ok
      end
    end)

    {attempts, interval_ms} = poll_config(poll_opts)

    case poll_visible(conn, tag, attempts, interval_ms) do
      :ok ->
        conn

      {:error, last} ->
        raise "fake-tagged connection #{tag} not visible in pg_stat_activity " <>
                "after #{attempts} attempts; last result: #{inspect(last)}"
    end
  end

  @doc """
  Stops `conn` and blocks until no backend carries `tag` in `pg_stat_activity`
  (queried through `Letflow.Repo`). Raises, naming `tag`, on timeout. Returns `:ok`.
  """
  @spec stop_and_wait_gone!(pid(), String.t(), poll_opts()) :: :ok
  def stop_and_wait_gone!(conn, tag, poll_opts \\ []) when is_binary(tag) do
    GenServer.stop(conn)

    {attempts, interval_ms} = poll_config(poll_opts)

    unless poll_gone?(tag, attempts, interval_ms) do
      raise "fake-tagged connection #{tag} still in pg_stat_activity after #{attempts} attempts"
    end

    :ok
  end

  @doc """
  Asserts that `tag` is visible in `pg_stat_activity` through `Letflow.Repo`, polling
  until the first sighting or the bound (ISS-1083 / GH #2441). It uses the sweeper's
  session type. An exact-tag match here means the sweeper's own `LIKE` query can see
  the tag too; the sweeper's group exclusion concerns other tags and is not re-checked.

  `start!/2` proves visibility once, through the fake connection itself, at setup time.
  That proof does not carry to the sweep. This check narrows the window between the
  proof and the sweep, but it does NOT close it: the sweep's own read is a separate
  read after this one, and the backend can still drop in between. Callers must put the
  Repo session in `:auto` mode first (`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
  :auto)`): a sandboxed transaction caches the `pg_stat_activity` snapshot until it
  ends. Polls, bounded, and returns `:ok` at the first sighting; otherwise raises,
  naming `tag` and carrying `capture/2`'s failure-time evidence. A Repo error during the
  poll (a raised error or a query timeout) propagates unchanged and does not name the
  tag.
  """
  @spec assert_visible!(pid(), String.t(), poll_opts()) :: :ok
  def assert_visible!(conn, tag, poll_opts \\ []) when is_binary(tag) do
    {attempts, interval_ms} = poll_config(poll_opts)

    case poll_repo_visible(tag, attempts, interval_ms) do
      :ok ->
        :ok

      :error ->
        raise "fake-tagged connection #{tag} is not visible through Letflow.Repo before the " <>
                "sweep (after #{attempts} attempts)\n" <> capture(conn, tag)
    end
  end

  defp poll_repo_visible(tag, attempts, interval_ms) do
    %{rows: rows} = Repo.query!(@tag_sql, [tag], timeout: @query_timeout_ms)

    cond do
      rows != [] ->
        :ok

      attempts <= 1 ->
        :error

      true ->
        Process.sleep(interval_ms)
        poll_repo_visible(tag, attempts - 1, interval_ms)
    end
  end

  @doc """
  Failure-time evidence for a guard miss (ISS-1083 / GH #2441): the `letflow_mixtest_*`
  backends visible in `pg_stat_activity` (pid, application_name, state, backend_start),
  whether `conn` is still alive, and the backend pid `conn` itself reports. Never raises
  (a raised error or an exit from either query is reported as text), and each query is
  bounded by `@query_timeout_ms`. Call it only on an assertion-failure path so a passing
  run pays nothing. Under the sandbox's `:manual` mode the Repo read can see a cached
  snapshot, so a caller that wants a fresh listing sets `:auto` first.
  """
  @spec capture(pid(), String.t()) :: String.t()
  def capture(conn, tag) when is_binary(tag) do
    backends =
      try do
        %{rows: rows} =
          Repo.query!(
            "SELECT pid, application_name, state, backend_start FROM pg_stat_activity " <>
              "WHERE application_name LIKE 'letflow_mixtest_%' OR application_name = $1 " <>
              "ORDER BY backend_start",
            [tag],
            timeout: @query_timeout_ms
          )

        Enum.map_join(rows, "\n", &("    " <> inspect(&1)))
      rescue
        exception -> "    pg_stat_activity query failed: #{Exception.message(exception)}"
      catch
        :exit, reason -> "    pg_stat_activity query exited: #{inspect(reason)}"
      end

    conn_info =
      try do
        case Postgrex.query(conn, "SELECT pg_backend_pid()", [], timeout: @query_timeout_ms) do
          {:ok, %{rows: [[pid]]}} -> "answers as backend pid #{pid}"
          other -> "query returned #{inspect(other)}"
        end
      rescue
        exception -> "query raised: #{Exception.message(exception)}"
      catch
        :exit, reason -> "query exited: #{inspect(reason)}"
      end

    "failure-time capture for tag #{tag}:\n" <>
      "  connection alive? #{Process.alive?(conn)}; #{conn_info}\n" <>
      "  mix-test backends in pg_stat_activity:\n#{backends}"
  end

  defp poll_config(poll_opts) do
    {Keyword.get(poll_opts, :attempts, @default_attempts),
     Keyword.get(poll_opts, :interval_ms, @default_interval_ms)}
  end

  # Returns :ok once visible, else {:error, last_result} (the last query result or
  # error, so a timeout names what the connection actually answered).
  defp poll_visible(conn, tag, attempts, interval_ms) do
    case Postgrex.query(conn, @tag_sql, [tag], timeout: @query_timeout_ms) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      other ->
        if attempts <= 1 do
          {:error, other}
        else
          Process.sleep(interval_ms)
          poll_visible(conn, tag, attempts - 1, interval_ms)
        end
    end
  end

  defp poll_gone?(tag, attempts, interval_ms) do
    %{rows: rows} = Repo.query!(@tag_sql, [tag])

    if rows == [] do
      true
    else
      retry(attempts, interval_ms, fn a -> poll_gone?(tag, a, interval_ms) end)
    end
  end

  defp retry(attempts, _interval_ms, _fun) when attempts <= 1, do: false

  defp retry(attempts, interval_ms, fun) do
    Process.sleep(interval_ms)
    fun.(attempts - 1)
  end
end
