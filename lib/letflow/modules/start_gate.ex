defmodule Letflow.Modules.StartGate do
  @moduledoc """
  The start side of module uninstall (REQ-627, decision 0066 D4/D8 slice 2).

  `Letflow.Engine.create/2` asks here whether the module that owns a definition (its
  `owner_module` stamp) is `:uninstalled`; if so the start answers `:definition_not_found`, the answer
  for an unknown definition. This is a separate file, not part of `Letflow.Modules.Installs`, so the
  engine has no compile edge to the pack installer.

  The tenant is identified only by the `prefix` the caller was given (INV-1). A missing
  `tenant_modules` row blocks nothing: only status `:uninstalled` does.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @doc "Advisory, plain read: is the module's row `:uninstalled`?"
  @spec uninstalled?(String.t(), String.t()) :: boolean()
  def uninstalled?(module_id, prefix) when is_binary(module_id) do
    Repo.exists?(
      from(m in TenantModule, where: m.module_id == ^module_id and m.status == :uninstalled),
      prefix: prefix
    )
  end

  @doc """
  Authoritative check inside the start transaction: reads the module row `FOR SHARE`, so a concurrent
  uninstall (which holds it `FOR UPDATE`) either waits for this start or is seen here. The read has no
  status filter: under READ COMMITTED it sees the committed status after the wait.
  """
  @spec lock_live_for_share(Ecto.Repo.t() | module(), String.t(), String.t()) ::
          {:ok, :live} | {:error, :definition_not_found}
  def lock_live_for_share(repo, module_id, prefix) when is_binary(module_id) do
    status =
      repo.one(
        from(m in TenantModule,
          where: m.module_id == ^module_id,
          select: m.status,
          lock: "FOR SHARE"
        ),
        prefix: prefix
      )

    if status == :uninstalled, do: {:error, :definition_not_found}, else: {:ok, :live}
  end
end
