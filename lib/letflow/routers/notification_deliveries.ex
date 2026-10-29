defmodule Letflow.Routers.NotificationDeliveries do
  @moduledoc """
  The tenant notification delivery log read, mounted at `/notification-deliveries` by
  `Letflow.Plugs.ApiPipeline` (REQ-584 part 2, GH #3310).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `GET /` (optional `?status=sent\\|failed\\|skipped`) | `:NotificationTemplatesManage` | `:tenant_wide` |

  Newest first, at most 100 rows. The tenant comes only from `conn.assigns.scoped_opts`
  (INV-1); only `status` is read from the query, a `tenant_id` anywhere is ignored (INV-10). The
  permission is checked first at `Letflow.Plugs.Authorize`, so a caller without it gets the same
  403 whether or not rows exist (INV-5). An unknown `status` is a 422 with a fixed text. A row
  carries no recipient address, subject, body or error text (INV-4).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Notifications

  authz_get "/", :NotificationTemplatesManage, scope: :tenant_wide do
    status = Plug.Conn.fetch_query_params(conn).query_params["status"]

    case Notifications.list_deliveries(prefix(conn), status) do
      {:ok, rows} ->
        Response.ok(conn, %{"deliveries" => Enum.map(rows, &row/1)})

      {:error, :invalid_status} ->
        Response.unprocessable(conn, "status is invalid")
    end
  end

  authz_unmatched(:ordinary)

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp row(d) do
    %{
      "id" => d.id,
      "template_key" => d.template_key,
      "locale" => d.locale,
      "recipient_user_id" => d.recipient_user_id,
      "status" => d.status,
      "reason" => d.reason,
      "trigger_ref" => d.trigger_ref,
      "inserted_at" => d.inserted_at
    }
  end
end
