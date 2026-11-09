defmodule Letflow.TenantProvisioner.DefaultModules do
  @moduledoc """
  T-1580 / decision 0072 D8: installs the default modules of a tenant made by the provisioner, as the
  last step of `Letflow.TenantProvisioner.create/1`.

  The list is `Letflow.TenantProvisioner.Config.default_modules/0`; the plan is its dependency closure
  (a listed module whose dependency is not listed gets the dependency too), sorted so every module comes
  after its dependencies (ties by id, so the order is deterministic). Each module is installed by its own
  `Installs.install/3` call, so one failing install rolls back only itself; a module whose dependency
  failed is skipped (`dependency_failed`), independent modules still install. `:already_installed`
  counts as done (idempotent retry; a module an administrator uninstalled is never reactivated).

  The actor is a literal system id (the nil UUID, as in `Letflow.ModuleUpgrade.Boot`): not a user, no
  role row. This module builds no `auth_context` and calls no authorization, grant, role, credential or
  secret function. The tenant prefix is derived only from the tenant id by
  `TenantProvisioning.schema_name_for_tenant/1` (INV-1). Every raise, exit or error is reduced to a
  short `"<module_id>:<code>"` string (INV-4, INV-8): never SQL text and never an inspected changeset.
  """

  require Logger

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.TenantProvisioning

  @system_actor "00000000-0000-0000-0000-000000000000"
  @rationale "default modules on tenant creation"

  @doc """
  Pure: the install order for `ids`, dependencies first. Unknown ids stay in the plan (they fail at
  install time as `unknown_module`) and bring no dependencies.
  """
  @spec plan([String.t()]) :: [String.t()]
  def plan(ids) do
    ids
    |> Enum.sort()
    |> Enum.reduce({[], MapSet.new()}, fn id, acc -> visit(id, acc) end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp visit(id, {order, seen} = acc) do
    if MapSet.member?(seen, id) do
      acc
    else
      seen = MapSet.put(seen, id)

      {order, seen} =
        Enum.reduce(deps(id), {order, seen}, fn dep, inner -> visit(dep, inner) end)

      {[id | order], seen}
    end
  end

  defp deps(id) do
    case Catalog.fetch(id) do
      {:ok, entry} -> entry.manifest() |> Map.get(:depends_on, []) |> Enum.sort()
      {:error, _} -> []
    end
  end

  @doc """
  Installs the planned modules into the tenant. `{:ok, :done}` when every module is installed, else
  `{:error, "<module_id>:<code>"}` for the first failure. Never raises.
  """
  @spec ensure(Ecto.UUID.t(), [String.t()], keyword()) :: {:ok, :done} | {:error, String.t()}
  def ensure(tenant_id, ids, opts \\ []) do
    install = Keyword.get(opts, :install, &Installs.install/3)

    with {:ok, prefix} <- TenantProvisioning.schema_name_for_tenant(tenant_id) do
      run(plan(ids), prefix, install, tenant_id)
    else
      _ -> {:error, "-:tenant_prefix"}
    end
  rescue
    error -> fail(tenant_id, "-", error)
  catch
    kind, _ -> fail(tenant_id, "-", kind)
  end

  defp run(order, prefix, install, tenant_id) do
    {_status, first} =
      Enum.reduce(order, {%{}, nil}, fn id, {status, first} ->
        result =
          if Enum.any?(deps(id), &(Map.get(status, &1) == :failed)),
            do: {:error, :dependency_failed},
            else: install_one(id, prefix, install)

        case result do
          :ok ->
            {Map.put(status, id, :ok), first}

          {:error, :dependency_failed} ->
            {Map.put(status, id, :failed), first}

          {:error, code} ->
            log(tenant_id, id, code)
            {Map.put(status, id, :failed), first || {id, code}}
        end
      end)

    case first do
      nil -> {:ok, :done}
      {id, code} -> {:error, "#{id}:#{code}"}
    end
  end

  defp install_one(id, prefix, install) do
    case install.(id, @system_actor, prefix: prefix, rationale: @rationale) do
      {:ok, _tenant_module} -> :ok
      {:error, :already_installed} -> :ok
      {:error, reason} -> {:error, code(reason)}
      _other -> {:error, :unexpected_result}
    end
  rescue
    _error -> {:error, :exception}
  catch
    _kind, _value -> {:error, :exception}
  end

  defp code(:not_found), do: :unknown_module
  defp code(reason) when is_atom(reason), do: reason
  defp code({reason, _detail}) when is_atom(reason), do: reason
  defp code(_other), do: :install_failed

  defp fail(tenant_id, id, error) do
    code = if is_exception(error), do: :exception, else: :exit
    log(tenant_id, id, code)
    {:error, "#{id}:#{code}"}
  end

  defp log(tenant_id, id, code) do
    Logger.error(
      "provisioner: default module install failed (tenant_id=#{inspect(tenant_id)}, module_id=#{id}, code=#{code})"
    )
  end
end
