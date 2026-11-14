defmodule Letflow.Routers.DataExport do
  @moduledoc """
  Data export discovery and synchronous download. Both routes require DataExport
  and are tenant-wide; each dataset additionally enforces its own read scope.
  Tenant authority comes only from the authenticated conn, never the body.
  """
  use Letflow.Api.AuthorizedRouter
  require Logger
  alias Letflow.Api.{Error, Response}
  alias Letflow.DataExport

  authz_get "/datasets", :DataExport, scope: :tenant_wide do
    Response.ok(conn, %{datasets: DataExport.datasets(conn)})
  end

  authz_post "/", :DataExport, scope: :tenant_wide do
    case DataExport.export(conn, conn.body_params) do
      {:ok, file} ->
        conn
        |> Plug.Conn.put_resp_content_type(file.type, nil)
        |> Plug.Conn.put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{file.name}")
        )
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> Plug.Conn.put_resp_header("x-export-truncated", Enum.join(file.truncated, ","))
        |> Plug.Conn.send_resp(200, file.body)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  authz_unmatched(:ordinary)

  defp refuse(conn, :rate_limited),
    do:
      conn
      |> Plug.Conn.put_resp_header("retry-after", "600")
      |> problem(Error.rate_limited("request refused"), "rate_limited")

  defp refuse(conn, :ledger_read_timeout),
    do: problem(conn, Error.service_unavailable("request refused"), "ledger_read_timeout")

  defp refuse(conn, reason)
       when reason in [
              :invalid_body,
              :invalid_format,
              :dataset_unknown,
              :invalid_filter,
              :as_of_date_in_future,
              :invalid_timezone
            ],
       do: problem(conn, Error.unprocessable("request refused"), Atom.to_string(reason))

  defp refuse(conn, :xlsx_write_failed) do
    Logger.error("data export render failed")
    Response.internal_error(conn)
  end

  defp refuse(conn, _), do: Response.internal_error(conn)

  defp problem(conn, problem, reason),
    do:
      Response.send_problem(conn, %{
        problem
        | extensions: %{"reason" => reason}
      })
end
