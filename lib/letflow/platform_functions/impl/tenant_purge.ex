defmodule Letflow.PlatformFunctions.Impl.TenantPurge do
  @moduledoc """
  The body of `tenant.purge` (T-2972, BP-PLATFORM-02 G1): the DESTRUCTIVE step.

  ## The destructive guard (checked here, in this order, before `Letflow.TenantPurge`)

    1. `confirm` must equal `slug` exactly (a typed confirmation): else
       `platform_call_purge_unconfirmed`;
    2. the tenant exists and is not the platform tenant: else `platform_call_tenant_not_found`
       (unknown and platform are the one answer, INV-5);
    3. a tenant already purged is `ok` (idempotent, nothing written);
    4. the tenant must be SUSPENDED (`status == :inactive`): else
       `platform_call_purge_not_suspended`;
    5. a production tenant (`tenants.tenant_type == "production"`) is never purged by a process:
       `platform_call_purge_production_refused`. This is the same QA/production marker the
       route's no-lifecycle-row path reads (T-2747: only `tenant_type == "test"` is eligible);
    6. `Letflow.TenantPurge.purge/3` then applies its own eligibility (lifecycle, retention):
       `{:error, :not_eligible}` is `platform_call_purge_not_eligible`.

  The id used for the purge is the one the slug resolves to; no id is taken from a variable.
  Failure vocabulary (fixed, no ids): the codes above plus `platform_call_arg_invalid` and
  `platform_call_purge_failed`. It never raises (INV-8).
  """

  alias Letflow.Identity
  alias Letflow.PlatformFunctions.Impl.TenantCreate
  alias Letflow.TenantPurge

  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    slug = Map.get(inputs, "slug")
    confirm = Map.get(inputs, "confirm")

    with :ok <- TenantCreate.bounded(slug),
         :ok <- confirmed(slug, confirm) do
      purge(slug)
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp confirmed(slug, confirm) when is_binary(confirm) do
    if confirm == slug, do: :ok, else: {:error, :platform_call_purge_unconfirmed}
  end

  defp confirmed(_slug, _confirm), do: {:error, :platform_call_purge_unconfirmed}

  defp purge(slug) do
    with {:ok, tenant} <- fetch(slug),
         :ok <- guard(tenant) do
      do_purge(tenant)
    end
  rescue
    _error -> {:error, :platform_call_purge_failed}
  end

  defp fetch(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        if Letflow.PlatformTenant.platform_tenant?(tenant.id),
          do: {:error, :platform_call_tenant_not_found},
          else: {:ok, tenant}

      {:error, :not_found} ->
        {:error, :platform_call_tenant_not_found}
    end
  end

  defp guard(tenant) do
    cond do
      Identity.tenant_purged?(tenant.id) -> :ok
      tenant.tenant_type == "production" -> {:error, :platform_call_purge_production_refused}
      tenant.status != :inactive -> {:error, :platform_call_purge_not_suspended}
      true -> :ok
    end
  end

  defp do_purge(tenant) do
    case TenantPurge.purge(tenant.id, :platform_admin, []) do
      {:ok, _outcome} -> {:ok, %{}}
      {:error, :not_found} -> {:error, :platform_call_tenant_not_found}
      {:error, :not_eligible} -> {:error, :platform_call_purge_not_eligible}
      {:error, _other} -> {:error, :platform_call_purge_failed}
    end
  end
end
