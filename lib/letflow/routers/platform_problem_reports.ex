defmodule Letflow.Routers.PlatformProblemReports do
  @moduledoc """
  T-1949: platform-company owner inbox. All reads and decisions require the platform-scope
  `ProblemReportsManage` atom, including the uniform refusal on unknown sub-paths. Customer ids
  and prefixes are never accepted from the request. Responses are not cacheable.

  T-1963: the same atom guards the owner list (class `review`): `GET /?class=review`, `GET /:id` (with the
  thread), `POST /:id/comments` (JSON, or multipart with `images[]`), `POST /:id/state` and
  `GET /:id/images/:image_id`. A review row is a 404 on `/:id/decision`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.ProblemReports.{Inbox, Review}

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

  authz_post "/:id/comments", :ProblemReportsManage do
    respond(
      conn,
      Review.add_owner_entry(
        conn.params["id"],
        conn.body_params,
        conn.assigns.auth_context.user_id
      ),
      201
    )
  end

  authz_post "/:id/state", :ProblemReportsManage do
    respond(
      conn,
      Review.set_owner_state(
        conn.params["id"],
        conn.body_params,
        conn.assigns.auth_context.user_id
      )
    )
  end

  authz_get "/:id/images/:image_id", :ProblemReportsManage do
    case Review.image(conn.params["id"], conn.params["image_id"]) do
      {:ok, %{content_type: type, bytes: bytes}} ->
        conn
        |> put_resp_header("content-type", type)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", "inline")
        |> put_resp_header("content-security-policy", "default-src 'none'")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, bytes)

      error ->
        respond(conn, error)
    end
  end

  authz_unmatched(:platform_prefix)

  defp respond(conn, result, ok_status \\ 200) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case result do
      {:ok, body} ->
        Response.send_json(conn, ok_status, body)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :unavailable} ->
        Response.service_unavailable(conn, "Problem reports are not available.")

      {:error, :invalid_query} ->
        Response.bad_request(conn, "Invalid report filter or page.")

      {:error, :report_closed} ->
        Response.conflict(conn, "report_closed")

      {:error, :item_closed} ->
        Response.conflict(conn, "item_closed")

      {:error, :secret} ->
        Response.unprocessable(
          conn,
          "The text looks like it holds a secret; write the login name and say where the secret is kept."
        )

      {:error, :bad_image_type} ->
        Response.unprocessable(conn, "Only PNG or JPEG screenshots.")

      {:error, :image_too_large} ->
        Response.payload_too_large(conn, "A screenshot is larger than 5 MB.")

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
