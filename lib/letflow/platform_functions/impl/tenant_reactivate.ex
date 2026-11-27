defmodule Letflow.PlatformFunctions.Impl.TenantReactivate do
  @moduledoc """
  The body of `tenant.reactivate` (T-2972, BP-PLATFORM-02 G1).

  It reactivates a tenant by slug exactly as `POST /tenants/:slug/reactivate` does
  (`Letflow.Identity.reactivate_tenant/1`). A purged tenant is never reactivated
  (`platform_call_tenant_purged`). Idempotent: reactivating an active tenant is a no-op.

  Failure vocabulary (fixed, no ids): `platform_call_arg_invalid`,
  `platform_call_tenant_not_found`, `platform_call_tenant_purged`,
  `platform_call_reactivate_failed`. It never raises (INV-8).
  """

  alias Letflow.Identity
  alias Letflow.PlatformFunctions.Impl.TenantCreate

  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    with :ok <- TenantCreate.bounded(Map.get(inputs, "slug")) do
      reactivate(Map.get(inputs, "slug"))
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp reactivate(slug) do
    case Identity.reactivate_tenant(slug) do
      {:ok, _tenant} -> {:ok, %{}}
      {:error, :not_found} -> {:error, :platform_call_tenant_not_found}
      {:error, :tenant_purged} -> {:error, :platform_call_tenant_purged}
      {:error, _other} -> {:error, :platform_call_reactivate_failed}
    end
  rescue
    _error -> {:error, :platform_call_reactivate_failed}
  end
end
