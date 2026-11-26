defmodule Letflow.PlatformFunctions.Impl.TenantInstallDefaultModules do
  @moduledoc """
  The body of `tenant.install_default_modules` (T-2590, pilot gap G1b of the
  "Register a tenant" pilot).

  It installs the new tenant's default modules -- the write that today sits
  in `Letflow.TenantProvisioner` (its last step of `create/1`). That code
  moved HERE, so the provisioner and the platform step call ONE
  implementation.

  The list of default modules is the platform's own configuration
  (`Letflow.TenantProvisioner.Config.default_modules/0`), and the plan is its
  dependency closure, sorted so every module comes after its dependencies.
  Each module is installed by its own call, so one failing install rolls back
  only itself.

  ## The idempotency

  Installing a module that is already installed is not an error: the install
  answers `:already_installed` and the step counts it as done. So a second
  run installs NOTHING and answers the same -- the step may be retried after
  a crash without installing the modules twice.

  ## The actor

  A module install is not a person's act: the actor is the system's literal
  id (the nil UUID, the same one `Letflow.TenantProvisioner.DefaultModules`
  uses), so no role row and no membership names it.

  ## What it never does

  It never raises (INV-8): every failure is an `{:error, code}` with a code
  of this module's own vocabulary -- never the installer's own text, which
  names a module id and would carry a value into the step's failure kind.
  """

  alias Letflow.Repo
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.DefaultModules
  alias Letflow.TenantProvisioner.Lifecycle

  @typedoc "The stable code of a refused install."
  @type refusal :: :platform_call_arg_invalid | :platform_call_default_modules_failed

  @doc """
  The install of the default modules, moved out of the provisioner: exactly
  what `Letflow.TenantProvisioner.DefaultModules.ensure/3` answers, with no
  change of shape.

  The installer's own call, when the platform configuration names one, is
  read from the application's own configuration -- the same place the
  provisioner read it from.
  """
  @spec ensure_default_modules(Ecto.UUID.t()) :: {:ok, :done} | {:error, String.t()}
  def ensure_default_modules(tenant_id) do
    DefaultModules.ensure(tenant_id, Config.default_modules(), install_opts())
  end

  @doc """
  Runs the step over the resolved arguments.

  `context` carries the resolved `inputs` (the entry's declared input names
  to their values). Returns `{:ok, %{}}` -- the entry declares no output --
  or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    tenant_id = Map.get(inputs, "tenant_id")

    with {:ok, tenant_id} <- cast_uuid(tenant_id) do
      run_for(tenant_id, Repo.get(Lifecycle, tenant_id))
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  # Design section 4 row 8. A tenant with a lifecycle row in `pending` or `failed` gets the install
  # and the row records `done` or `failed` (+ the failure text); an installation FAILURE never fails
  # the registration (the next repeat retries, as the provisioner's own last step does). A tenant
  # with no lifecycle row (operator routes) or a row in any other state (`done`, `not_applicable`)
  # installs nothing.
  defp run_for(tenant_id, %Lifecycle{default_modules_state: state} = lifecycle)
       when state in ["pending", "failed"] do
    changes =
      case ensure_default_modules(tenant_id) do
        {:ok, :done} -> [default_modules_state: "done", default_modules_failure: nil]
        {:error, text} -> [default_modules_state: "failed", default_modules_failure: text]
      end

    case lifecycle |> Ecto.Changeset.change(changes) |> Repo.update() do
      {:ok, _row} -> {:ok, %{}}
      {:error, _changeset} -> {:error, :platform_call_default_modules_failed}
    end
  rescue
    _error -> {:error, :platform_call_default_modules_failed}
  end

  defp run_for(_tenant_id, _lifecycle_or_nil), do: {:ok, %{}}

  # The installer's own call, when the platform configuration names one.
  defp install_opts do
    case Application.get_env(:letflow, Letflow.TenantProvisioner, [])[:default_modules_install] do
      nil -> []
      install -> [install: install]
    end
  end

  # The id is checked before it reaches the database: `Repo.get/2` casts it,
  # and a value that is not a UUID would raise out of the body (INV-8).
  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
