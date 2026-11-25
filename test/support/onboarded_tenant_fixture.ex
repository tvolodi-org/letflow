defmodule Letflow.Support.OnboardedTenantFixture do
  @moduledoc """
  A tenant in the state the OLD `POST /api/v1/onboarding` left it in: the tenant row,
  its schema, the onboarding record, and optionally the pending first-administrator
  grant and the bound realm (T-2704, pilot gap G17b).

  `POST /api/v1/onboarding` no longer creates a tenant (it starts the
  `platform.register_tenant` process, whose steps do the work). The tests of the
  routes that act ON an onboarded tenant -- bind-realm, the pending-administrator
  list and revoke, the GET reads -- still need such a tenant, so they build it here,
  from the same primitives the process steps call. Test code only.
  """

  alias Letflow.Identity
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.PlatformFunctions.Impl.TenantBindRealm
  alias Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins
  alias Letflow.PlatformFunctions.Impl.TenantProvision
  alias Letflow.TenantProvisioning

  @doc """
  Creates the tenant for `body` (the keys of the old create request: `slug`,
  `display_name`, `hostname`, optional `idp_realm_id` and `admin_email`).

  `opts` is `[operator_id:, platform_prefix:]`, used for the grant and the bind.
  Returns `%{"id" => onboarding_id, "tenant_id" => ..., "slug" => ..., "hostname" => ...}`.
  """
  @spec onboard!(map(), keyword()) :: map()
  def onboard!(body, opts) do
    {:ok, tenant} =
      Identity.create_tenant(%{
        "slug" => Map.fetch!(body, "slug"),
        "display_name" => Map.fetch!(body, "display_name"),
        "status" => "migrating"
      })

    {:ok, _registration} = TenantProvision.provision_and_migrate(tenant.id)

    {:ok, record} =
      Identity.create_onboarding(%{
        tenant_id: tenant.id,
        slug: tenant.slug,
        hostname: String.trim(Map.fetch!(body, "hostname"))
      })

    grant_id = maybe_grant(body, tenant, record, opts)
    maybe_bind(body, tenant, opts)

    %{
      "id" => record.id,
      "tenant_id" => tenant.id,
      "slug" => tenant.slug,
      "hostname" => record.hostname,
      "grant_id" => grant_id
    }
  end

  defp maybe_grant(%{"admin_email" => email}, tenant, record, opts) when is_binary(email) do
    {:ok, email_key} = PendingAdminGrants.normalize_email(email)
    {:ok, prefix} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    {:ok, grant} =
      TenantGrantFirstAdmins.create_grant(
        email_key,
        %{user_id: Keyword.fetch!(opts, :operator_id)},
        prefix: prefix,
        platform_prefix: Keyword.fetch!(opts, :platform_prefix),
        trace_id: nil,
        onboarding_id: record.id
      )

    grant.id
  end

  defp maybe_grant(_body, _tenant, _record, _opts), do: nil

  defp maybe_bind(%{"idp_realm_id" => realm}, tenant, opts) when is_binary(realm) do
    {:ok, _bound} =
      TenantBindRealm.bind_tenant_realm(tenant.id, String.trim(realm),
        actor_id: Keyword.fetch!(opts, :operator_id),
        platform_prefix: Keyword.fetch!(opts, :platform_prefix),
        trace_id: nil
      )

    :ok
  end

  defp maybe_bind(_body, _tenant, _opts), do: :ok
end
