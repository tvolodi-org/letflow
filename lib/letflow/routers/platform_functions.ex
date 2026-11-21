defmodule Letflow.Routers.PlatformFunctions do
  @moduledoc """
  The platform function catalogue's read route (T-2588, pilot gap G2; decision
  record `docs/migration/decisions/0094-platform-call-authority.md`, decision (a)).

  | Route | Policy key -> permission |
  |---|---|
  | `GET /` (the catalogue) | `:TenantsManage` -> `:TenantsManage` |

  The catalogue is COMPILED (`Letflow.PlatformFunctions.Catalog`): there is no
  write route, no run-time registration and no table. This route only READS
  it, so the designer can offer the functions a definition may call. The
  permission is the platform atom the tenant family itself requires: the
  person who may run a platform function is the person who may read what they
  are.

  The answer shows only the entries the CALLER's tenant may use: an entry
  marked `platform_tenant_only` (the whole platform family today) is visible
  only in the platform tenant (INV-10). A caller from another tenant therefore
  cannot learn which platform functions exist.

  The platform tenant is derived from the DB-resolved tenant of the request
  (`conn.assigns.auth_context.tenant_id`), never from a request field.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformTenant

  authz_get "/", :TenantsManage do
    tenant_id = Map.get(conn.assigns.auth_context, :tenant_id)
    platform_tenant? = PlatformTenant.platform_tenant?(tenant_id)

    items =
      Catalog.list(platform_tenant?: platform_tenant?)
      |> Enum.map(&Catalog.entry_map/1)

    Response.ok(conn, %{"items" => items})
  end
end
