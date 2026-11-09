defmodule Letflow.Routers.TenantRoleGrants do
  @moduledoc """
  T-1570 (D-097) -- the per-tenant storekeeper grant switch, mounted at `/tenant/role-grants` by
  `Letflow.Plugs.ApiPipeline`:

    * `GET /` (`:RoleGrantsRead`)  -> `{"storekeeper": [...], "grantable": {"storekeeper": [...]}}`;
    * `PUT /` (`:RoleGrantsManage`) -> body `{"storekeeper": ["AssetsRead", "AssetsPost"]}`, a whole-list
      replace (`[]` switches the grant off); an atom outside the closed list is 422.

  Both keys map to the existing `:UsersGroupsRolesManage`, which must be held TENANT-WIDE by an
  interactive credential (an API token is refused). The tenant is `scoped_opts[:prefix]` only
  (INV-1); the route takes no tenant identifier. The data lives in `Letflow.Api.TenantGrants`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.Api.TenantGrants
  alias Letflow.Identity.ScopedGrants

  authz_get "/", :RoleGrantsRead do
    with_admin(conn, fn conn ->
      overlay = TenantGrants.load(prefix(conn))
      Response.ok(conn, body(TenantGrants.storekeeper(overlay)))
    end)
  end

  authz_put "/", :RoleGrantsManage do
    with_admin(conn, fn conn -> handle_put(conn) end)
  end

  authz_unmatched(:ordinary)

  defp with_admin(conn, fun) do
    with {:ok, conn} <- Scope.require_tenant_wide(conn, :UsersGroupsRolesManage),
         {:ok, conn, %{kind: :user}} <- Scope.principal_from_conn(conn) do
      fun.(conn)
    else
      _refused -> Response.forbidden(conn, "insufficient permissions")
    end
  rescue
    _error -> Response.internal_error(conn)
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp handle_put(conn) do
    case conn.body_params do
      %{"storekeeper" => list} when is_list(list) ->
        actor = ScopedGrants.actor_from_conn(conn)

        case TenantGrants.put_storekeeper(prefix(conn), list, actor) do
          {:ok, saved} -> Response.ok(conn, body(saved))
          {:error, :invalid_grants} -> Response.unprocessable(conn, "invalid_grants")
          {:error, :not_installed} -> Response.not_found(conn)
          {:error, _server_fault} -> Response.internal_error(conn)
        end

      _other ->
        Response.unprocessable(conn, "invalid_body")
    end
  end

  defp body(storekeeper) do
    %{
      "storekeeper" => storekeeper,
      "grantable" => %{
        "storekeeper" =>
          Enum.map(Map.fetch!(Authorization.grantable(), :STOREKEEPER), &Atom.to_string/1)
      }
    }
  end
end
