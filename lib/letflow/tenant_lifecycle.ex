defmodule Letflow.TenantLifecycle do
  @moduledoc """
  REQ-572 / decision 0072 D4: the runtime side of deactivating a tenant, in one place.

  `release_runtime/1` runs AFTER a tenant has been put in `:inactive` (by
  `Letflow.Routers.Tenants` deactivate, or by `Letflow.TenantProvisioner` suspend and expire):

    1. evicts the tenant from the two `Letflow.Admission` servers (ISS-0437, GH 2534 / 0053 D8) so it
       stops diluting every remaining tenant's fair-share cap;
    2. stops the tenant's realm key provider (GH 3252) so cached JWKS stop verifying.

  Both are node-local; the QA deployment is one node. The function never raises on a tenant without
  a realm.
  """

  alias Letflow.Admission
  alias Letflow.Identity
  alias Letflow.TenantProvisioning

  @doc "Evicts the tenant from admission and stops its realm key provider."
  @spec release_runtime(%{required(:id) => Ecto.UUID.t()}) :: :ok
  def release_runtime(%{id: tenant_id}) do
    {:ok, schema} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    :ok = Admission.forget_tenant(schema)
    :ok = Admission.forget_tenant(schema, Letflow.Engine.Lua.ScriptAdmission)
    :ok = stop_realm_provider(tenant_id)
  end

  defp stop_realm_provider(tenant_id) do
    case Identity.resolve_realm_by_tenant(tenant_id) do
      {:ok, realm} when is_binary(realm) and realm != "" ->
        Letflow.Oidc.ProviderRegistry.stop(realm)

      _no_realm ->
        :ok
    end
  end
end
