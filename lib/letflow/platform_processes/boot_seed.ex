defmodule Letflow.PlatformProcesses.BootSeed do
  @moduledoc """
  Runs the platform-definition seed (`Letflow.PlatformProcesses.Seed`) without an
  operator (T-2739, gap G9b of the "Register a tenant" pilot).

  No new way to create anything: this only seeds the SHIPPED definition
  `platform.register_tenant` through the same idempotent seed the mix task uses.

  Two callers:

    * the application boot, a one-shot temporary Task after the repo is up, only
      when the setting `:seed_platform_definitions_on_boot` is exactly `true`
      (env `LETFLOW_SEED_PLATFORM_DEFINITIONS=true`, default OFF; QA and runner
      hosts set it, production keeps it off -- an owner step);
    * the QA deploy script, through the running app:
      `bin/letflow rpc 'Letflow.PlatformProcesses.BootSeed.run(force: true)'`
      (a bare `bin/letflow eval` has no started repo), then
      `bin/letflow rpc 'Letflow.PlatformProcesses.BootSeed.check()'`.

  Idempotent: a second run answers `:already_present` or `:newer_version_kept`
  and never overwrites or deprecates a newer version. A platform tenant that is
  not configured (`LETFLOW_PLATFORM_TENANT_ID`) logs one clear line and writes
  nothing. Never raises (INV-8). Logs outcomes only, no ids of users, no secrets.
  """

  require Logger

  alias Letflow.Definitions
  alias Letflow.PlatformProcesses.Seed
  alias Letflow.PlatformTenant

  @key "platform.register_tenant"

  @doc "True only when the setting is exactly `true`."
  @spec flag_on?() :: boolean()
  def flag_on?,
    do: Application.get_env(:letflow, :seed_platform_definitions_on_boot, false) == true

  @doc """
  Runs the seed when the setting is on (or `force: true`). Returns
  `:skipped`, `{:ok, outcome}` or `{:error, reason}`; never raises.
  """
  @spec run(keyword()) :: :skipped | {:ok, Seed.outcome()} | {:error, term()}
  def run(opts \\ []) do
    if flag_on?() or Keyword.get(opts, :force, false) == true do
      do_run()
    else
      :skipped
    end
  rescue
    error ->
      Logger.error("platform definitions seed crashed: #{inspect(error.__struct__)}")
      {:error, :seed_crashed}
  catch
    kind, _reason ->
      Logger.error("platform definitions seed aborted: #{inspect(kind)}")
      {:error, :seed_crashed}
  end

  defp do_run do
    case PlatformTenant.platform_prefix() do
      :error ->
        Logger.warning(
          "platform definitions seed skipped: LETFLOW_PLATFORM_TENANT_ID is not configured; nothing written"
        )

        {:error, :platform_tenant_not_configured}

      {:ok, _prefix} ->
        case Seed.seed([]) do
          {:ok, %{outcome: outcome}} ->
            Logger.info("platform definitions seed: #{@key} #{inspect(outcome)}")
            {:ok, outcome}

          {:error, reason} ->
            Logger.error("platform definitions seed failed: #{inspect(reason)}; nothing written")
            {:error, reason}
        end
    end
  end

  @doc """
  The smoke check of the deploy: `:ok` when `platform.register_tenant` has an
  ACTIVE version in the platform tenant, else `{:error, reason}`. Read-only.
  """
  @spec check() :: :ok | {:error, term()}
  def check do
    with {:ok, prefix} <- platform_prefix(),
         {:ok, definition} <- Definitions.get_active_by_name(@key, prefix: prefix),
         true <- definition.status == :active do
      :ok
    else
      {:error, :not_found} -> {:error, :definition_missing}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :definition_not_active}
    end
  rescue
    _error -> {:error, :check_crashed}
  end

  defp platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :platform_tenant_not_configured}
    end
  end
end
