defmodule Letflow.Routers.EntityTypeExtensions do
  @moduledoc """
  The tenant `x_` extension routes, mounted at `/entity-type-extensions` by
  `Letflow.Plugs.ApiPipeline` (REQ-609, GH #3417; decision 0067-tenant-x, slice I2).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `POST /` (body `entity_type`, `name`, `spec`) | `:EntitiesExtensionsManage` | `:tenant_wide` |
  | `GET /?entity_type=T` | `:EntitiesExtensionsManage` | `:tenant_wide` |
  | `DELETE /:id` (retire, the row stays) | `:EntitiesExtensionsManage` | `:tenant_wide` |

  `POST /` answers 201 with the row, `GET /` 200 `{"items": [...]}` ordered by position (retired
  rows included), `DELETE /:id` 200 with the retired row (also when it was retired already).

  The tenant comes only from the DB-resolved `auth_context` and `conn.assigns.scoped_opts`
  (INV-1); no route takes a tenant identifier, the body is reduced to three keys before it
  reaches the context, and a `tenant_id` in the body or query is never read (INV-10). The
  permission is checked first at `Letflow.Plugs.Authorize`, before the body is looked at, so a
  caller without it gets the same 403 for a valid and an invalid POST (INV-5). A type that is
  unknown, tenant-owned, append-only or restricted for the caller, and an unknown extension id,
  all answer the one `Response.not_found/1`. A refusal is a 422 with a fixed code that echoes no
  submitted value and writes neither a row nor an audit entry.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Entities.TypeExtensions

  @attr_keys ~w(entity_type name spec)

  authz_post "/", :EntitiesExtensionsManage, scope: :tenant_wide do
    attrs = Map.take(body(conn), @attr_keys)

    case TypeExtensions.create_extension_audited(attrs, actor(conn), prefix(conn)) do
      {:ok, row} -> Response.created(conn, render(row))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_get "/", :EntitiesExtensionsManage, scope: :tenant_wide do
    case Plug.Conn.fetch_query_params(conn).query_params["entity_type"] do
      type when is_binary(type) and type != "" ->
        case TypeExtensions.list_extensions(type, conn.assigns.auth_context.user_id, prefix(conn)) do
          {:ok, rows} -> Response.ok(conn, %{"items" => Enum.map(rows, &render/1)})
          {:error, reason} -> error(conn, reason)
        end

      _missing_or_malformed ->
        Response.unprocessable(conn, "invalid_input")
    end
  end

  authz_delete "/:id", :EntitiesExtensionsManage, scope: :tenant_wide do
    case TypeExtensions.retire_extension_audited(
           conn.path_params["id"],
           actor(conn),
           prefix(conn)
         ) do
      {:ok, row} -> Response.ok(conn, render(row))
      {:error, reason} -> error(conn, reason)
    end
  end

  authz_unmatched(:ordinary)

  # Fixed code per reason; none echoes a submitted value.
  defp error(conn, :not_found), do: Response.not_found(conn)

  defp error(conn, {:extension_key_invalid, _name}),
    do: Response.unprocessable(conn, "invalid_extension_key")

  defp error(conn, {:extension_key_reserved, _name}),
    do: Response.unprocessable(conn, "extension_key_reserved")

  defp error(conn, :extension_key_taken), do: Response.unprocessable(conn, "extension_key_taken")

  defp error(conn, :invalid_extension_spec),
    do: Response.unprocessable(conn, "invalid_extension_spec")

  defp error(conn, :extension_limit_reached),
    do: Response.unprocessable(conn, "extension_limit_reached")

  # Anything else (transaction failure, tenant lookup): the detail-free 500 (INV-8).
  defp error(conn, _other), do: Response.internal_error(conn)

  defp render(row) do
    %{
      "id" => row.id,
      "entity_type" => row.entity_type,
      "kind" => row.kind,
      "name" => row.name,
      "spec" => row.spec,
      "position" => row.position,
      "status" => row.status
    }
  end

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp actor(conn),
    do: %{user_id: conn.assigns.auth_context.user_id, trace_id: conn.assigns[:trace_id]}

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
