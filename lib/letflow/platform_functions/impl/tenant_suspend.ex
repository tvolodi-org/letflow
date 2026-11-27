defmodule Letflow.PlatformFunctions.Impl.TenantSuspend do
  @moduledoc """
  The body of `tenant.suspend` (T-2972, BP-PLATFORM-02 G1).

  It deactivates a tenant by slug exactly as `POST /tenants/:slug/deactivate` does:
  `Letflow.Identity.deactivate_tenant/1`, then `Letflow.TenantLifecycle.release_runtime/1`
  (eviction from admission and the realm provider). The platform tenant is protected by
  `Identity` itself and answers `platform_call_tenant_not_allowed`. Idempotent: suspending a
  suspended tenant is the same suspend.

  Failure vocabulary (fixed, no ids): `platform_call_arg_invalid`,
  `platform_call_tenant_not_found`, `platform_call_tenant_not_allowed`,
  `platform_call_suspend_failed`. It never raises (INV-8).
  """

  alias Letflow.Identity
  alias Letflow.PlatformFunctions.Impl.TenantCreate

  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    with :ok <- TenantCreate.bounded(Map.get(inputs, "slug")) do
      suspend(Map.get(inputs, "slug"))
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp suspend(slug) do
    case Identity.deactivate_tenant(slug) do
      {:ok, tenant} ->
        :ok = Letflow.TenantLifecycle.release_runtime(tenant)
        {:ok, %{}}

      {:error, :not_found} ->
        {:error, :platform_call_tenant_not_found}

      {:error, :platform_tenant_protected} ->
        {:error, :platform_call_tenant_not_allowed}

      {:error, _other} ->
        {:error, :platform_call_suspend_failed}
    end
  rescue
    _error -> {:error, :platform_call_suspend_failed}
  end
end
