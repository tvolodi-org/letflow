defmodule Letflow.Routers.NotificationTemplates do
  @moduledoc """
  The tenant notification template routes, mounted at `/notification-templates` by
  `Letflow.Plugs.ApiPipeline` (REQ-563, GH #3199).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `GET /` | `:NotificationTemplatesManage` | `:tenant_wide` |
  | `PUT /:template_key` (body `locale`, `subject`, `body`) | `:NotificationTemplatesManage` | `:tenant_wide` |
  | `DELETE /:template_key` (`?locale=`) | `:NotificationTemplatesManage` | `:tenant_wide` |
  | `POST /:template_key/preview` (body `locale`, optional `subject`, `body`, `values`) | `:NotificationTemplatesManage` | `:tenant_wide` |

  The tenant comes only from the DB-resolved `auth_context` and `conn.assigns.scoped_opts`
  (INV-1); a `tenant_id` in the query or body is never read (INV-10). The permission is checked
  first at `Letflow.Plugs.Authorize`, which does not look at the key, so a caller without it gets
  the same 403 whether or not a template exists (INV-5). For an admin, validity is checked
  before existence: a refused input is 422, an unregistered key or an absent template is the one
  fixed 404. Refusals write no audit event, and no response echoes submitted text in an error.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.NotificationTemplates

  authz_get "/", :NotificationTemplatesManage, scope: :tenant_wide do
    templates =
      conn
      |> prefix()
      |> NotificationTemplates.list(tenant_id(conn))
      |> Enum.map(fn t ->
        %{
          "template_key" => t.template_key,
          "locale" => t.locale,
          "subject" => t.subject,
          "body" => t.body,
          "updated_at" => t.updated_at
        }
      end)

    Response.ok(conn, %{"templates" => templates})
  end

  authz_put "/:template_key", :NotificationTemplatesManage, scope: :tenant_wide do
    handle_put(conn, conn.params["template_key"])
  end

  authz_delete "/:template_key", :NotificationTemplatesManage, scope: :tenant_wide do
    handle_delete(conn, conn.params["template_key"])
  end

  authz_post "/:template_key/preview", :NotificationTemplatesManage, scope: :tenant_wide do
    handle_preview(conn, conn.params["template_key"])
  end

  authz_unmatched(:ordinary)

  defp handle_put(conn, key) do
    body = body(conn)

    case NotificationTemplates.put(
           prefix(conn),
           tenant_id(conn),
           actor_id(conn),
           key,
           Map.get(body, "locale"),
           Map.get(body, "subject"),
           Map.get(body, "body")
         ) do
      {:ok, outcome, row} ->
        payload = %{
          "template_key" => row.template_key,
          "locale" => row.locale,
          "subject" => row.subject,
          "body" => row.body
        }

        if outcome == :created,
          do: Response.created(conn, payload),
          else: Response.ok(conn, payload)

      other ->
        reply_error(conn, other)
    end
  end

  defp handle_delete(conn, key) do
    case NotificationTemplates.delete(prefix(conn), actor_id(conn), key, locale_param(conn)) do
      {:ok, :deleted} -> Response.no_content(conn)
      other -> reply_error(conn, other)
    end
  end

  defp handle_preview(conn, key) do
    body = body(conn)
    locale = Map.get(body, "locale")

    case NotificationTemplates.preview(
           prefix(conn),
           key,
           locale,
           Map.get(body, "subject"),
           Map.get(body, "body"),
           Map.get(body, "values")
         ) do
      {:ok, result} ->
        Response.ok(conn, %{
          "template_key" => key,
          "locale" => locale,
          "subject" => result.subject,
          "body" => result.body,
          "source" => Atom.to_string(result.source)
        })

      other ->
        reply_error(conn, other)
    end
  end

  # Fixed text per reason: the submitted text is never echoed.
  defp reply_error(conn, {:error, :invalid_locale}),
    do: Response.unprocessable(conn, "locale is invalid")

  defp reply_error(conn, {:error, {:invalid_subject, reason}}),
    do: Response.unprocessable(conn, "subject " <> reason_text(reason, 200))

  defp reply_error(conn, {:error, {:invalid_body, reason}}),
    do: Response.unprocessable(conn, "body " <> reason_text(reason, 5000))

  defp reply_error(conn, {:error, {:invalid_values, :not_object}}),
    do: Response.unprocessable(conn, "values must be an object")

  defp reply_error(conn, {:error, {:invalid_values, :bad_value}}),
    do: Response.unprocessable(conn, "each value must be a string of at most 500 characters")

  defp reply_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  # Anything else (audit failure): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  defp reason_text(:empty, _max), do: "must not be empty"
  defp reason_text(:too_long, max), do: "must be at most #{max} characters"
  defp reason_text(:control_character, _max), do: "must not contain control characters"
  defp reason_text(:secret_reference, _max), do: "must not contain a secret reference"
  defp reason_text(:placeholder, _max), do: "uses a placeholder this template does not allow"
  defp reason_text(:markup, _max), do: "must be plain text with {name} placeholders only"

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
