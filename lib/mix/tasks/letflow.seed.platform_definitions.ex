defmodule Mix.Tasks.Letflow.Seed.PlatformDefinitions do
  @shortdoc "Seeds the platform tenant's standard definitions (the pilot's platform.register_tenant)"

  @moduledoc """
  Seeds the definitions of the PLATFORM tenant -- today one: the pilot's
  `platform.register_tenant` (T-2595, gap G9 of the "Register a tenant"
  pilot).

  The definitions themselves live in `Letflow.PlatformProcesses.Definition`
  (the document) and `Letflow.PlatformProcesses.Seed` (the write). This task is
  the operator's way to run the write.

  ## Usage

      LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed.platform_definitions

  No arguments. The task writes into the PLATFORM tenant, the one
  `LETFLOW_PLATFORM_TENANT_ID` names; a platform tenant that is not
  configured is refused (`platform_tenant_not_configured`) and nothing is
  written.

  ## The activator

  A definition that calls a platform function may be switched on only by
  somebody who holds `:TenantsManage` in the platform tenant -- the signed
  `activated_by` document is the authority the run-time fence checks again.
  The seed cannot invent it, so it signs with a REAL platform administrator:

    * `LETFLOW_PLATFORM_ACTIVATOR_USER_ID` names the administrator (a user id
      of the platform tenant), and
    * without it, the first PLATFORM_ADMIN holder of the platform tenant is
      used (sorted by id, so the choice is the same on every run).

  A platform tenant with no such administrator is answered
  `no_platform_activator` and nothing is written.

  ## Idempotence

  Running the task twice changes nothing the second time: the seed answers
  `already_present` (the version of the key exists) or `newer_version_kept`
  (an administrator made a newer version, which stays the one that runs). It
  NEVER overwrites a newer version and never deprecates one.
  """

  use Mix.Task

  alias Letflow.PlatformProcesses.Seed

  @impl Mix.Task
  @spec run(args :: [String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")

    opts = opts(args)

    case Seed.seed(opts) do
      {:ok, %{outcome: outcome, version: version}} ->
        Mix.shell().info(
          "mix letflow.seed.platform_definitions: OK -- platform.register_tenant " <>
            "v#{version} (#{outcome})."
        )

      {:error, reason} ->
        Mix.raise(
          "mix letflow.seed.platform_definitions: FAILED -- " <>
            "#{inspect(reason)}. Nothing was written."
        )
    end
  end

  # The activator may be named in the environment. The task takes no
  # arguments: a seed that writes into the platform tenant is not something a
  # caller passes a tenant id to.
  defp opts(args) do
    case Enum.find(args, &String.starts_with?(&1, "--activator=")) do
      nil ->
        case System.get_env("LETFLOW_PLATFORM_ACTIVATOR_USER_ID") do
          user_id when is_binary(user_id) and user_id != "" ->
            [activator_user_id: user_id]

          _unset ->
            []
        end

      argument ->
        [activator_user_id: argument |> String.split("=", parts: 2) |> List.last()]
    end
  end
end
