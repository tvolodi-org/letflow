defmodule Letflow.ModuleUpgrade.Capability do
  @moduledoc """
  The capability `Letflow.ModuleUpgrade.Writer` requires (REQ-683, decision 0055 D3).

  It names the tenant (and its schema prefix), the upgrade, the plan hash and the acting user of
  one module upgrade run. The writer takes every one of those values from here: it has no prefix,
  tenant id or actor argument, so a caller that holds a capability for tenant A cannot write
  into tenant B (INV-1).

  The struct is `@opaque`; `new/4` is the only constructor and nothing else in `lib/` builds
  it. The boundary rule 9 of `mix letflow.check_boundaries` keeps every file outside
  `lib/letflow/module_upgrade/` from referencing this module or the writer.
  """

  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @enforce_keys [:tenant_id, :prefix, :upgrade_id, :plan_hash, :actor_id]
  defstruct [:tenant_id, :prefix, :upgrade_id, :plan_hash, :actor_id]

  @opaque t :: %__MODULE__{
            tenant_id: Ecto.UUID.t(),
            prefix: String.t(),
            upgrade_id: String.t(),
            plan_hash: String.t(),
            actor_id: Ecto.UUID.t()
          }

  @doc false
  @spec new(Ecto.UUID.t(), String.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, t()} | {:error, :tenant_not_provisioned}
  def new(tenant_id, upgrade_id, plan_hash, actor_id)
      when is_binary(tenant_id) and is_binary(upgrade_id) and upgrade_id != "" and
             is_binary(plan_hash) and plan_hash != "" and is_binary(actor_id) and actor_id != "" do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      %Registration{schema_name: schema_name} ->
        {:ok,
         %__MODULE__{
           tenant_id: tenant_id,
           prefix: schema_name,
           upgrade_id: upgrade_id,
           plan_hash: plan_hash,
           actor_id: actor_id
         }}

      nil ->
        {:error, :tenant_not_provisioned}
    end
  end
end
