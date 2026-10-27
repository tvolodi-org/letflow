defmodule Letflow.Routers.TenantConfigBundle do
  @moduledoc """
  REQ-552 slice 1 (GH #3177) -- export and import of the caller's own tenant configuration bundle
  (tenant settings and module settings). Mounted at `/tenant/config-bundle` by
  `Letflow.Plugs.ApiPipeline`.

  Two routes, both gated by `:TenantSettingsManage`:

    * `GET /` -- the bundle (`Letflow.TenantConfigBundle.export/3`, format v2, REQ-599). The
      `label_overrides` part needs `:LabelsManage` and `notification_templates` needs
      `:NotificationTemplatesManage`; a part the caller may not read is left out of the bundle.
    * `POST /import` -- applies a bundle. When it carries module settings the caller also needs
      `:ModulesManage`; a caller without it gets the same 403 body as the route-level check (INV-5).

  The tenant and the schema prefix come only from `conn.assigns` (token); the path, the query and
  the body carry no tenant identifier (INV-1, INV-10). Unknown `bundle_schema_version` and any
  violation are 422; a violation message names keys and module ids, not secret values.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.PlatformTenant
  alias Letflow.TenantConfigBundle

  authz_get "/", :TenantSettingsManage do
    handle_export(conn)
  end

  authz_post "/import", :TenantSettingsManage do
    handle_import(conn)
  end

  authz_unmatched(:ordinary)

  defp handle_export(conn) do
    case TenantConfigBundle.export(tenant_id(conn), prefix(conn), parts: export_parts(conn)) do
      {:ok, bundle} -> Response.ok(conn, bundle)
      {:error, :not_found} -> Response.internal_error(conn)
    end
  end

  defp handle_import(%Plug.Conn{body_params: body} = conn) do
    if modules_permitted?(conn, body) do
      run_import(conn, body)
    else
      Response.forbidden(conn, "insufficient permissions")
    end
  end

  defp run_import(conn, body) do
    case TenantConfigBundle.import(
           tenant_id(conn),
           prefix(conn),
           conn.assigns.auth_context.user_id,
           body,
           trace_id: conn.assigns[:trace_id]
         ) do
      {:ok, counts} ->
        Response.ok(conn, %{
          "tenant_settings_changed" => counts.tenant_settings_changed,
          "modules_changed" => counts.modules_changed,
          "modules_unchanged" => counts.modules_unchanged
        })

      {:error, {:unknown_schema_version, _v}} ->
        Response.unprocessable(
          conn,
          "unknown_bundle_schema_version: supported #{Enum.join(TenantConfigBundle.accepted_versions(), ", ")}"
        )

      {:error, {:invalid, violations}} ->
        Response.unprocessable(conn, Enum.join(violations, "; "))

      {:error, :internal} ->
        Response.internal_error(conn)
    end
  end

  @doc false
  # The module-part guard: `holds?` is `(permission -> boolean)`, defaulting to the recomputed
  # context check of `Letflow.Routers.Identity.users_groups_roles_manage?/1`.
  @spec modules_permitted?(Plug.Conn.t(), term(), (atom() -> boolean())) :: boolean()
  def modules_permitted?(conn, body, holds? \\ nil) do
    holds? = holds? || default_holds(conn)

    body
    |> TenantConfigBundle.required_permissions()
    |> Enum.all?(holds?)
  end

  @doc false
  # The optional export parts the caller may read: each needs its own manage permission, and a
  # part the caller lacks is left out of the bundle (no key, no 403). Same seam shape as
  # `modules_permitted?/3`.
  @spec export_parts(Plug.Conn.t(), (atom() -> boolean())) :: [atom()]
  def export_parts(conn, holds? \\ nil) do
    holds? = holds? || default_holds(conn)

    Enum.filter(
      [label_overrides: :LabelsManage, notification_templates: :NotificationTemplatesManage],
      fn {_part, permission} ->
        holds?.(permission)
      end
    )
    |> Enum.map(&elem(&1, 0))
  end

  defp default_holds(conn) do
    auth_context = conn.assigns.auth_context
    platform_tenant? = PlatformTenant.platform_tenant?(Map.get(auth_context, :tenant_id))
    roles = Authorization.effective_roles(Map.get(auth_context, :roles, []), platform_tenant?)

    fn permission ->
      Authorization.has_permission_in_scope?(roles, permission, platform_tenant?)
    end
  end

  defp tenant_id(conn), do: conn.assigns.auth_context.tenant_id
  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
