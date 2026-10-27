defmodule Letflow.Routers.EntityViews do
  @moduledoc """
  Saved list view definitions, mounted at `/entity-views` by `Letflow.Plugs.ApiPipeline`
  (REQ-555, GH #3157, decision 0066).

  | Route | Policy key -> permission | Success | Refusals |
  |---|---|---|---|
  | `GET /` (optional `?entity_type=`) | `:EntitiesQuery` | 200 `{"items": [view]}` | none |
  | `GET /:id` | `:EntitiesQuery` | 200 view | 404 |
  | `POST /` | `:EntitiesViewsManage` | 201 view | 400, 404, 409, 422 |
  | `PUT /:id` | `:EntitiesViewsManage` | 200 view | 400, 404, 409, 422 |
  | `DELETE /:id` | `:EntitiesViewsManage` | 204 | 404 |

  All five are `scope: :tenant_wide`: a view is tenant configuration and carries no row or node data.
  Under scope enforcement a caller whose `EntitiesQuery` grant is node-scoped therefore cannot read
  views either (a stated limit of this slice).

  No route returns a record value: replay is the ordinary `POST /entities/query`, which applies type
  access and field grants to the caller of the query (decision 0066 D3). Responses are built by
  `view_map/1`, an allowlist; `tenant_id` is not in it.

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1) and the actor only from the
  DB-resolved `auth_context` (INV-2); no route takes a tenant identifier and a body carrying
  `tenant_id` (or any key outside `entity_type, name, kind, columns, filter, sort, group_by,
  aggregates`) is a 422 `unknown_key`
  that changes nothing (INV-10). A caller without the permission is refused by
  `Letflow.Plugs.Authorize` before the handler, so the 403 is the same for an existing and an absent
  id. An absent, malformed, other-tenant or type-denied id (and an unknown or denied type on create)
  all go through the one `Response.not_found/1` (INV-5). Refusals write no audit entry.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Entities.Views
  alias Letflow.Entities.Views.View

  require Logger

  authz_get "/", :EntitiesQuery, scope: :tenant_wide do
    handle_list(conn)
  end

  authz_get "/:id", :EntitiesQuery, scope: :tenant_wide do
    handle_get(conn, conn.params["id"])
  end

  authz_post "/", :EntitiesViewsManage, scope: :tenant_wide do
    handle_write(conn, fn prefix, user_id, body -> Views.create(prefix, user_id, body) end, 201)
  end

  authz_put "/:id", :EntitiesViewsManage, scope: :tenant_wide do
    id = conn.params["id"]

    handle_write(
      conn,
      fn prefix, user_id, body -> Views.update(prefix, user_id, id, body) end,
      200
    )
  end

  authz_delete "/:id", :EntitiesViewsManage, scope: :tenant_wide do
    handle_delete(conn, conn.params["id"])
  end

  authz_unmatched(:ordinary)

  # ── handlers ───────────────────────────────────────────────────────────────

  defp handle_list(conn) do
    entity_type =
      case conn.params["entity_type"] do
        type when is_binary(type) and type != "" -> type
        _other -> nil
      end

    case Views.list(prefix!(conn), user_id(conn), entity_type) do
      {:ok, views} -> Response.ok(conn, %{"items" => Enum.map(views, &view_map/1)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp handle_get(conn, id) do
    case Views.get(prefix!(conn), user_id(conn), id) do
      {:ok, view} -> Response.ok(conn, view_map(view))
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp handle_write(conn, fun, success_status) do
    case conn.body_params do
      %{"_json" => _non_object} ->
        Response.bad_request(conn, "request body must be a JSON object")

      body when is_map(body) ->
        case fun.(prefix!(conn), user_id(conn), body) do
          {:ok, view} -> Response.send_json(conn, success_status, view_map(view))
          {:error, reason} -> render_error(conn, reason)
        end

      _other ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  defp handle_delete(conn, id) do
    case Views.delete(prefix!(conn), user_id(conn), id) do
      {:ok, _view} -> Response.no_content(conn)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # INV-1: the ONLY source of the tenant prefix.
  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp user_id(conn), do: conn.assigns.auth_context.user_id

  defp render_error(conn, :not_found), do: Response.not_found(conn)
  defp render_error(conn, :name_taken), do: Response.conflict(conn, "name_taken")
  defp render_error(conn, {:unprocessable, code}), do: Response.unprocessable(conn, code)

  # INV-8 terminal clause: logged server-side, detail-free on the wire.
  defp render_error(conn, reason) do
    Logger.warning("entity view request failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # INV-2 allowlist: never the struct, never `tenant_id`.
  defp view_map(%View{} = view) do
    %{
      "id" => view.id,
      "entity_type" => view.entity_type,
      "name" => view.name,
      "kind" => view.kind,
      "columns" => view.columns,
      "filter" => view.filter,
      "sort" => view.sort,
      "group_by" => view.group_by,
      "aggregates" => view.aggregates,
      "created_by" => view.created_by,
      "updated_by" => view.updated_by,
      "inserted_at" => view.inserted_at,
      "updated_at" => view.updated_at
    }
  end
end
