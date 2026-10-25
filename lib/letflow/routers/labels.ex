defmodule Letflow.Routers.Labels do
  @moduledoc """
  The tenant label override routes, mounted at `/labels` by `Letflow.Plugs.ApiPipeline`
  (REQ-551, GH #3180).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `GET /` (`?locale=`) | `:MyAccessRead` (role-agnostic) | `:self_service` (ruling `SEC-551-labels`) |
  | `PUT /:message_id` (body `locale`, `text`) | `:LabelsManage` | `:tenant_wide` |
  | `DELETE /:message_id` (`?locale=`) | `:LabelsManage` | `:tenant_wide` |

  The tenant comes only from the DB-resolved `auth_context` and `conn.assigns.scoped_opts`
  (INV-1); no route takes a tenant identifier and a `tenant_id` in the query or body is never
  read (INV-10). The permission is checked first at `Letflow.Plugs.Authorize`, which does not
  look at the id, so a caller without `:LabelsManage` gets the same 403 whether or not an
  override exists (INV-5). For an admin, validity (id, locale, text) is checked before
  existence: a refused input is 422, an absent override is the one fixed 404.

  Override values are public UI wording, not secrets (see `Letflow.Labels`). Refusals write no
  audit event.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Labels

  authz_get "/", :MyAccessRead, scope: :self_service do
    handle_get(conn)
  end

  authz_put "/:message_id", :LabelsManage, scope: :tenant_wide do
    handle_put(conn, conn.params["message_id"])
  end

  authz_delete "/:message_id", :LabelsManage, scope: :tenant_wide do
    handle_delete(conn, conn.params["message_id"])
  end

  authz_unmatched(:ordinary)

  defp handle_get(conn) do
    tenant_id = tenant_id(conn)

    case Identity.get_tenant(tenant_id) do
      {:ok, tenant} ->
        requested = locale_param(conn)
        catalog = Labels.catalog(prefix(conn), tenant_id, tenant.settings, requested)
        Response.ok(conn, %{"locale" => catalog.locale, "messages" => catalog.messages})

      {:error, :not_found} ->
        Response.internal_error(conn)
    end
  end

  defp handle_put(conn, message_id) do
    body = body(conn)

    with {:ok, tenant} <- Identity.get_tenant(tenant_id(conn)),
         {:ok, row} <-
           Labels.put_override(
             prefix(conn),
             tenant_id(conn),
             tenant.settings,
             actor_id(conn),
             message_id,
             Map.get(body, "locale"),
             Map.get(body, "text")
           ) do
      Response.ok(conn, %{
        "message_id" => row.message_id,
        "locale" => row.locale,
        "text" => row.text
      })
    else
      other -> reply_error(conn, other)
    end
  end

  defp handle_delete(conn, message_id) do
    with {:ok, tenant} <- Identity.get_tenant(tenant_id(conn)),
         {:ok, :deleted} <-
           Labels.delete_override(
             prefix(conn),
             tenant.settings,
             actor_id(conn),
             message_id,
             locale_param(conn)
           ) do
      Response.no_content(conn)
    else
      other -> reply_error(conn, other)
    end
  end

  # Fixed text per reason: the submitted text is never echoed.
  defp reply_error(conn, {:error, :invalid_id}),
    do: Response.unprocessable(conn, "label id is not overridable")

  defp reply_error(conn, {:error, :invalid_locale}),
    do: Response.unprocessable(conn, "locale is not available for this tenant")

  defp reply_error(conn, {:error, {:invalid_text, :empty}}),
    do: Response.unprocessable(conn, "text must not be empty")

  defp reply_error(conn, {:error, {:invalid_text, :too_long}}),
    do: Response.unprocessable(conn, "text must be at most 500 characters")

  defp reply_error(conn, {:error, {:invalid_text, :control_character}}),
    do: Response.unprocessable(conn, "text must not contain control characters")

  defp reply_error(conn, {:error, {:invalid_text, :placeholder}}),
    do: Response.unprocessable(conn, "text uses a placeholder the default message does not have")

  defp reply_error(conn, {:error, {:invalid_text, :markup}}),
    do: Response.unprocessable(conn, "text must be plain text with {name} placeholders only")

  defp reply_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  # Anything else (audit failure, tenant row missing): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp locale_param(conn), do: Plug.Conn.fetch_query_params(conn).query_params["locale"]

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp tenant_id(conn), do: conn.assigns.auth_context.tenant_id
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
