defmodule Letflow.Routers.MaintenanceV1 do
  @moduledoc """
  T-1948 (maintenance slice 1): the problem-report export mount, `/maintenance/v1`, forwarded by
  `Letflow.Router` BEFORE its catch-all and OUTSIDE `Letflow.Plugs.ApiPipeline`. The authentication is a
  hash-configured credential, not a role: `Letflow.Plugs.ReportExportAuth` is the first plug. It exists
  for the PM handoff (`docs/runbooks/problem-report-handoff.md`): the operator session polls it and
  forwards each new report.

  | Route | Answer |
  |---|---|
  | `GET /problem-reports?after=<seq>&limit=<1..100>` | 200 `{reports: [...], next_after: n}`; 400 `invalid_request` for a bad `after`/`limit`; 503 `unavailable` when no platform company is configured |
  | anything else | 404 `not_found` |

  GET only, no body is read, no tenant identifier is taken, no write route exists. Reports younger than
  the settle window are held back (`Letflow.ProblemReports.list_after/3`). Responses are `no-store`.
  Plug keeps the LAST value of a repeated query key; that is accepted. This module never touches the
  database itself: `Letflow.ProblemReports` does.
  """

  use Plug.Router

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.ReportExportAuth
  alias Letflow.ProblemReports

  plug(Letflow.Plugs.ReportExportAuth)
  plug(:match)
  plug(:dispatch)

  get "/problem-reports" do
    conn = fetch_query_params(conn)

    with {:ok, after_seq} <- int_param(conn.query_params["after"], 0, 0, nil),
         {:ok, limit} <- int_param(conn.query_params["limit"], 20, 1, 100) do
      case ProblemReports.list_after(after_seq, limit) do
        {:ok, %{reports: reports, next_after: next_after}} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> Response.send_json(200, %{reports: reports, next_after: next_after})

        {:error, :unavailable} ->
          ReportExportAuth.send_error(
            conn,
            503,
            "unavailable",
            "problem reports are not available"
          )
      end
    else
      :error ->
        ReportExportAuth.send_error(
          conn,
          400,
          "invalid_request",
          "after/limit must be integers"
        )
    end
  end

  match _ do
    ReportExportAuth.send_error(conn, 404, "not_found", "not found")
  end

  defp int_param(nil, default, _min, _max), do: {:ok, default}

  defp int_param(value, _default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= min and (is_nil(max) or int <= max) -> {:ok, int}
      _ -> :error
    end
  end

  defp int_param(_other, _default, _min, _max), do: :error
end
