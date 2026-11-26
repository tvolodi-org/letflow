defmodule Letflow.Routers.OutboundDestinations do
  @moduledoc """
  The per-tenant OUTBOUND ALLOW-LIST routes, mounted at `/outbound-destinations` by
  `Letflow.Plugs.ApiPipeline` (T-2597, pilot gap G14).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `GET /` | `:OutboundDestinationsManage` | `:tenant_wide` |
  | `POST /` (body `channel`, optional `destination`) | `:OutboundDestinationsManage` | `:tenant_wide` |
  | `DELETE /` (query `channel`, optional `destination`) | `:OutboundDestinationsManage` | `:tenant_wide` |

  The list says where the tenant's own definitions may reach: the CHANNELS it
  may use (the mail channel, the file channel, the HTTP channel) and the
  DESTINATIONS it may reach on them (a recipient domain, a host). A new
  tenant's list is empty, so it may reach nothing outside.

  Only the holder of `:OutboundDestinationsManage` may read or change it --
  `TENANT_ADMIN` and `PLATFORM_ADMIN`, never a `PROCESS_DESIGNER` (decision
  record G2 (c)). The permission is checked first at `Letflow.Plugs.Authorize`,
  which does not look at the key, so a caller without it gets the same 403
  whether or not the list exists (INV-5).

  The tenant comes only from the DB-resolved `auth_context` and
  `conn.assigns.scoped_opts` (INV-1); a `tenant_id` in the query or the body is
  never read (INV-10). The list holds no address of a person (INV-4): a
  destination is a domain or a host.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.OutboundDestinations

  authz_get "/", :OutboundDestinationsManage do
    case OutboundDestinations.list(prefix(conn)) do
      {:ok, entries} -> Response.ok(conn, %{"entries" => Enum.map(entries, &entry_json/1)})
      {:error, _reason} -> Response.internal_error(conn)
    end
  end

  authz_post "/", :OutboundDestinationsManage do
    body = body(conn)

    case OutboundDestinations.add(
           prefix(conn),
           actor_id(conn),
           Map.get(body, "channel"),
           Map.get(body, "destination")
         ) do
      {:ok, entry} -> Response.created(conn, entry_json(entry))
      other -> reply_error(conn, other)
    end
  end

  authz_delete "/", :OutboundDestinationsManage do
    query = Plug.Conn.fetch_query_params(conn).query_params

    case OutboundDestinations.remove(
           prefix(conn),
           actor_id(conn),
           Map.get(query, "channel"),
           Map.get(query, "destination")
         ) do
      {:ok, :removed} -> Response.no_content(conn)
      {:ok, :absent} -> Response.not_found(conn)
      other -> reply_error(conn, other)
    end
  end

  authz_unmatched(:ordinary)

  defp entry_json(entry) do
    %{
      "channel" => entry.channel,
      "destination" => entry.destination,
      "inserted_by" => entry.inserted_by,
      "definition_id" => entry.definition_id,
      "reason" => entry.reason,
      "inserted_at" => entry.inserted_at
    }
  end

  # Fixed text per reason: the submitted value is never echoed (INV-4).
  defp reply_error(conn, {:error, :invalid_channel}),
    do: Response.unprocessable(conn, "channel is invalid")

  defp reply_error(conn, {:error, :invalid_destination}),
    do: Response.unprocessable(conn, "destination is invalid")

  defp reply_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  # Anything else (an audit failure): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
