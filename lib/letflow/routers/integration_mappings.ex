defmodule Letflow.Routers.IntegrationMappings do
  @moduledoc """
  REQ-565 slice 1 (GH #3201) -- CRUD over the caller's tenant integration mappings. Mounted at
  `/integration-mappings` by `Letflow.Plugs.ApiPipeline`; all five routes are gated by
  `:IntegrationMappingsManage` (TENANT_ADMIN and PLATFORM_ADMIN only).

    * `POST /` -- 201 with the mapping; `GET /` -- 200 `{"items": [...]}` ordered by name.
    * `GET /:id`, `PUT /:id` (replaces name, direction and rules), `DELETE /:id` (204).

  The permission check runs before any handler, so a caller without it sees one identical 403 for an
  existing and an absent id (INV-5). A holder gets one fixed 404 for an absent, malformed or
  other-tenant id (a tenant id is only the schema prefix from `conn.assigns.scoped_opts`; the path,
  query and body carry none, INV-1, INV-10). Every validation failure is the same 422 body and
  echoes no value. The response carries no `tenant_id` and no credential: a const is public
  configuration, never a secret.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.IntegrationMappings

  authz_post "/", :IntegrationMappingsManage do
    case IntegrationMappings.create(conn.body_params, actor_id(conn), prefix(conn)) do
      {:ok, mapping} -> Response.created(conn, render(mapping))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_get "/", :IntegrationMappingsManage do
    items = prefix(conn) |> IntegrationMappings.list() |> Enum.map(&render/1)
    Response.ok(conn, %{"items" => items})
  end

  authz_get "/:id", :IntegrationMappingsManage do
    case IntegrationMappings.get(conn.params["id"], prefix(conn)) do
      {:ok, mapping} -> Response.ok(conn, render(mapping))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_put "/:id", :IntegrationMappingsManage do
    case IntegrationMappings.update(
           conn.params["id"],
           conn.body_params,
           actor_id(conn),
           prefix(conn)
         ) do
      {:ok, mapping} -> Response.ok(conn, render(mapping))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_delete "/:id", :IntegrationMappingsManage do
    case IntegrationMappings.delete(conn.params["id"], actor_id(conn), prefix(conn)) do
      {:ok, _mapping} -> Response.no_content(conn)
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_unmatched(:ordinary)

  defp error(conn, :not_found), do: Response.not_found(conn)

  defp error(conn, {:invalid, _code}),
    do: Response.unprocessable(conn, "invalid integration mapping")

  defp error(conn, :internal), do: Response.internal_error(conn)

  defp render(m) do
    %{
      "id" => m.id,
      "name" => m.name,
      "direction" => m.direction,
      "rules" => m.rules,
      "updated_by" => m.updated_by,
      "inserted_at" => m.inserted_at,
      "updated_at" => m.updated_at
    }
  end

  defp actor_id(conn), do: conn.assigns.auth_context.user_id
  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
