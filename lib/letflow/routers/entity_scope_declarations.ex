defmodule Letflow.Routers.EntityScopeDeclarations do
  @moduledoc """
  The tenant scope declaration routes, mounted at `/entity-scope-declarations` by
  `Letflow.Plugs.ApiPipeline` (REQ-635, GH #3549; decision 0070 D3, slice B).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `PUT /:entity_type` (body `kind`, `field`) | `:EntitiesRestrictionsManage` | `:tenant_wide` |
  | `GET /` | `:EntitiesRestrictionsManage` | `:tenant_wide` |

  `PUT` sets or replaces the declaration of one tenant-owned type and answers 200 with it; `GET`
  answers 200 `{"items": [...]}` ordered by type. There is no DELETE. Refusals: 403
  `entity_type_managed` (a module-managed or manifest-named type, decided before existence), 404
  (no active definition, the same for another tenant's type), 422 `invalid_input` (fixed text, no
  echo).

  The tenant comes only from the DB-resolved `auth_context` (INV-1); the type comes from the path
  and the body is reduced to `kind` and `field`, so a `tenant_id` or `entity_type` in the body is
  never read (INV-10). The permission is checked at `Letflow.Plugs.Authorize` before the body is
  looked at (INV-5).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Entities.ScopeDeclarations

  authz_put "/:entity_type", :EntitiesRestrictionsManage, scope: :tenant_wide do
    attrs =
      conn
      |> body()
      |> Map.take(~w(kind field))
      |> Map.put("entity_type", conn.path_params["entity_type"])

    actor = %{user_id: conn.assigns.auth_context.user_id, trace_id: conn.assigns[:trace_id]}

    case ScopeDeclarations.put_audited(attrs, actor, prefix(conn)) do
      {:ok, declaration} -> Response.ok(conn, declaration)
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_get "/", :EntitiesRestrictionsManage, scope: :tenant_wide do
    Response.ok(conn, %{"items" => ScopeDeclarations.list(prefix(conn))})
  end

  authz_unmatched(:ordinary)

  defp error(conn, :entity_type_managed),
    do: Response.send_problem(conn, Error.entity_type_managed())

  defp error(conn, :not_found), do: Response.not_found(conn)
  defp error(conn, :invalid_input), do: Response.unprocessable(conn, "invalid_input")
  defp error(conn, _other), do: Response.internal_error(conn)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
