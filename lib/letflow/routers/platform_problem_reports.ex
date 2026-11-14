defmodule Letflow.Routers.PlatformProblemReports do
  @moduledoc """
  T-1949: platform-company owner inbox. All reads and decisions require the platform-scope
  `ProblemReportsManage` atom, including the uniform refusal on unknown sub-paths. Customer ids
  and prefixes are never accepted from the request. Responses are not cacheable.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.ProblemReports.Inbox

  authz_get "/", :ProblemReportsManage do
    conn = fetch_query_params(conn)
    respond(conn, Inbox.list(conn.query_params))
  end

  authz_get "/:id", :ProblemReportsManage do
    respond(conn, Inbox.get(conn.params["id"]))
  end

  authz_post "/:id/decision", :ProblemReportsManage do
    respond(
      conn,
      Inbox.decide(conn.params["id"], conn.body_params, conn.assigns.auth_context.user_id)
    )
  end

  authz_unmatched(:platform_prefix)

  defp respond(conn, result) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case result do
      {:ok, body} ->
        Response.ok(conn, body)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :unavailable} ->
        Response.service_unavailable(conn, "Problem reports are not available.")

      {:error, :invalid_query} ->
        Response.bad_request(conn, "Invalid report filter or page.")

      {:error, :report_closed} ->
        Response.conflict(conn, "report_closed")

      {:error, {:invalid, field}} ->
        Response.unprocessable(conn, "Invalid #{field}.")

      {:error, :summary_copies_report} ->
        Response.unprocessable(
          conn,
          "The summary must be in your own words: it copies the report text or a name."
        )

      {:error, _} ->
        Response.internal_error(conn)
    end
  end
end
