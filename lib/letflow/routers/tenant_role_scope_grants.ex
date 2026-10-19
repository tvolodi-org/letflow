defmodule Letflow.Routers.TenantRoleScopeGrants do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a (decision 0051 D1, D11; design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 3.2) -- the org-scoped
  role grant admin plane for the caller's own tenant, mounted at `/tenant/role-scope-grants`
  by `Letflow.Plugs.ApiPipeline`:

    * `POST   /`                  (`:RoleScopeGrantsManage`) -> create one scoped row;
    * `GET    /`                  (`:RoleScopeGrantsRead`)   -> list rows, cursor-paginated;
    * `DELETE /:id`               (`:RoleScopeGrantsManage`) -> delete one row;
    * `POST   /make-tenant-wide`  (`:RoleScopeGrantsManage`) -> replace a principal's scoped
      rows of a role by one tenant-wide row.

  Every key maps to the existing tenant-scope permission `:UsersGroupsRolesManage` (the
  plug's 403), and every handler then requires that permission to be held TENANT-WIDE
  (`Letflow.Api.Scope.require_tenant_wide/2`), answering the same 403 otherwise, before any
  lookup. The tenant comes ONLY from `auth_context.tenant_id` and `scoped_opts[:prefix]`
  (INV-1). Handlers are thin: parse, call `Letflow.Identity.ScopedGrants`, map errors;
  response bodies are built field by field (INV-2).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.Identity.ScopedGrants

  @default_limit 50
  @max_limit 200

  authz_post "/", :RoleScopeGrantsManage do
    with_tenant_wide(conn, fn conn -> handle_create(conn) end)
  end

  authz_get "/", :RoleScopeGrantsRead do
    with_tenant_wide(conn, fn conn -> handle_list(conn) end)
  end

  authz_post "/make-tenant-wide", :RoleScopeGrantsManage do
    with_tenant_wide(conn, fn conn -> handle_make_tenant_wide(conn) end)
  end

  authz_delete "/:id", :RoleScopeGrantsManage do
    with_tenant_wide(conn, fn conn -> handle_delete(conn, conn.params["id"]) end)
  end

  authz_unmatched(:ordinary)

  @spec with_tenant_wide(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  defp with_tenant_wide(conn, fun) do
    case Scope.require_tenant_wide(conn, :UsersGroupsRolesManage) do
      {:ok, conn} -> fun.(conn)
      {:error, conn, :not_tenant_wide} -> Response.forbidden(conn, "insufficient permissions")
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  # ── POST / ───────────────────────────────────────────────────────────────

  defp handle_create(conn) do
    with {:ok, attrs} <- ScopedGrants.parse_create(conn.body_params),
         {:ok, view} <-
           ScopedGrants.create(attrs, ScopedGrants.actor_from_conn(conn), prefix(conn)) do
      Response.created(conn, grant_map(view))
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # ── POST /make-tenant-wide ───────────────────────────────────────────────

  defp handle_make_tenant_wide(conn) do
    with {:ok, attrs} <- ScopedGrants.parse_make_tenant_wide(conn.body_params),
         {:ok, result} <-
           ScopedGrants.make_tenant_wide(
             attrs,
             ScopedGrants.actor_from_conn(conn),
             prefix(conn)
           ) do
      Response.ok(conn, %{
        "id" => result.id,
        "tenant_wide" => true,
        "removed_scoped_ids" => result.removed_scoped_ids
      })
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # ── DELETE /:id ──────────────────────────────────────────────────────────

  defp handle_delete(conn, raw_id) do
    case ScopedGrants.delete(raw_id, ScopedGrants.actor_from_conn(conn), prefix(conn)) do
      :ok -> Response.no_content(conn)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # ── GET / ────────────────────────────────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, limit} <- parse_limit(Map.get(query, "limit")),
         {:ok, page} <-
           ScopedGrants.list(query, limit, Map.get(query, "cursor"), prefix(conn)) do
      items = Enum.map(page.items, &grant_map/1)
      Response.ok(conn, Pagination.page_response(items, page.next_cursor))
    else
      {:error, :invalid_limit} -> Response.bad_request(conn, "invalid limit")
      {:error, :invalid_cursor} -> Response.bad_request(conn, "invalid cursor")
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {limit, ""} when limit >= 1 and limit <= @max_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_other), do: {:error, :invalid_limit}

  # ── bodies and error mapping ─────────────────────────────────────────────

  defp grant_map(view) do
    %{
      "id" => view.id,
      "principal_type" => Atom.to_string(view.principal_type),
      "principal_id" => view.principal_id,
      "role" => view.role,
      "scope_node_id" => view.scope_node_id,
      "tenant_wide" => view.tenant_wide,
      "effective" => view.effective
    }
  end

  @unprocessable [
    :invalid_body,
    :invalid_role,
    :invalid_principal,
    :no_binding,
    :invalid_scope_node
  ]
  @conflicts [
    :grant_exists,
    :tenant_wide_row_exists,
    :self_grant_refused,
    :last_scoped_row,
    :last_admin_binding_row,
    :last_tenant_wide_admin,
    :last_interactive_tenant_wide_admin
  ]

  defp error_response(conn, reason) when reason in @unprocessable,
    do: Response.unprocessable(conn, Atom.to_string(reason))

  defp error_response(conn, reason) when reason in @conflicts,
    do: Response.conflict(conn, Atom.to_string(reason))

  defp error_response(conn, :not_found), do: Response.not_found(conn)

  # Audit failures and transaction faults: a server fault, detail-free (INV-8).
  defp error_response(conn, _server_fault), do: Response.internal_error(conn)
end
