defmodule Letflow.Readiness do
  @moduledoc """
  Readiness of the running node, per part (T-1607, BA batch 4 item 2).

  `GET /ready` (`Letflow.Router`) answers 200 when every part is `ok` and 503 when one is not,
  and names the failing parts, so a support person can tell which part is broken. `GET /health`
  stays the liveness signal and is unchanged.

  The part list is `@parts`, one place: `database`, `migrations`, `secrets_key`, `identity`.
  It is a UAT assumption of the BA (`docs/uat/ba-decisions/T-1595.md`, item 2), not an owner
  decision; changing it is a change to this attribute and to the web page's strings.

    * `database`    -- `SELECT 1` through `Letflow.Repo`.
    * `migrations`  -- no `:down` migration of the global schema. Per-tenant schemas are the
      rollout runner's business (REQ-374), not this check's.
    * `secrets_key` -- the configured master key is a 32-byte binary. Only its presence and
      size are tested; the key is never read into a result (INV-4).
    * `identity`    -- `Letflow.Oidc.RealmProbe.verify("master")` (decision 0072: no Keycloak
      admin client). Only `{:error, :unreachable}` fails; `:not_found` means the server answered.
      The URL comes from configuration only (INV-9). The result is cached for 10 seconds in
      `:persistent_term`, so an unauthenticated caller cannot use the route to amplify
      outbound requests. A failed result is cached too (same reason).

  The whole result is cached for 5 seconds (calls with injected functions bypass the cache).
  Every check is bounded by a 2 second timeout and never raises (INV-8): a crash, an exit or a
  timeout is `"fail"`. The result carries names from a fixed vocabulary only: no error text,
  host names or versions.

  `run/1` takes injectable functions (`:db_fun`, `:migrations_fun`, `:key_fun`) for tests.
  """

  @parts ~w(database migrations secrets_key identity)
  @check_timeout_ms 2_000
  @identity_ttl_ms 10_000
  @cache_key {__MODULE__, :identity}
  @result_ttl_ms 5_000
  @result_key {__MODULE__, :result}
  @db_query_timeout_ms 1_500

  @type part :: String.t()
  @type result :: %{ready: boolean(), failing: [part()], checks: %{part() => String.t()}}

  @doc "The fixed list of parts, in reporting order."
  @spec parts() :: [part()]
  def parts, do: @parts

  @doc "Runs every check and returns the per-part result."
  @spec run(keyword()) :: result()
  def run(opts \\ [])
  def run([]), do: result_cached()
  def run(opts), do: compute(opts)

  # The whole result is cached for a few seconds, so an unauthenticated caller cannot make
  # the route cost more than one database round per node per window (INV-8).
  defp result_cached do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@result_key, nil) do
      {at, result} when now - at < @result_ttl_ms ->
        result

      _stale ->
        result = compute([])
        :persistent_term.put(@result_key, {System.monotonic_time(:millisecond), result})
        result
    end
  end

  defp compute(opts) do
    checks =
      %{
        "database" => fn -> db_ok?(Keyword.get(opts, :db_fun, &default_db/0)) end,
        "migrations" => fn ->
          migrations_ok?(Keyword.get(opts, :migrations_fun, &default_migrations/0))
        end,
        "secrets_key" => fn -> key_ok?(Keyword.get(opts, :key_fun, &default_key/0)) end,
        "identity" => &identity_cached/0
      }
      |> Map.new(fn {part, fun} -> {part, if(guarded(fun), do: "ok", else: "fail")} end)

    failing = Enum.filter(@parts, &(Map.fetch!(checks, &1) != "ok"))
    %{ready: failing == [], failing: failing, checks: checks}
  end

  @doc "Drops the cached identity result (tests)."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@result_key)
    :ok
  end

  # ── checks ──────────────────────────────────────────────────────────

  defp default_db,
    do: Ecto.Adapters.SQL.query(Letflow.Repo, "SELECT 1", [], timeout: @db_query_timeout_ms)

  @doc """
  Options of the default migrations read: no `LOCK TABLE schema_migrations` and no
  `CREATE TABLE IF NOT EXISTS`, because this runs on an unauthenticated route and the lock
  would queue probes behind each other and behind a running deploy migration.
  """
  @spec migrations_opts() :: keyword()
  def migrations_opts, do: [migration_lock: false, skip_table_creation: true]

  defp default_migrations do
    Ecto.Migrator.migrations(
      Letflow.Repo,
      [Ecto.Migrator.migrations_path(Letflow.Repo)],
      migrations_opts()
    )
  end

  defp default_key, do: Application.get_env(:letflow, :secrets_master_key)

  defp db_ok?(fun) do
    match?({:ok, _}, fun.())
  end

  defp migrations_ok?(fun) do
    case fun.() do
      list when is_list(list) -> not Enum.any?(list, fn {status, _, _} -> status == :down end)
      _other -> false
    end
  end

  defp key_ok?(fun) do
    case fun.() do
      key when is_binary(key) -> byte_size(key) == 32
      _other -> false
    end
  end

  defp identity_cached do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {at, result} when now - at < @identity_ttl_ms ->
        result

      _stale ->
        result = identity_ok?()
        :persistent_term.put(@cache_key, {now, result})
        result
    end
  end

  defp identity_ok? do
    case Letflow.Oidc.RealmProbe.verify("master") do
      :ok -> true
      {:error, :not_found} -> true
      _other -> false
    end
  end

  # Runs one check in a task with a hard timeout; anything but `true` is a failure.
  defp guarded(fun) do
    task =
      Task.async(fn ->
        try do
          fun.() == true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      end)

    case Task.yield(task, @check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, true} -> true
      _other -> false
    end
  end
end
