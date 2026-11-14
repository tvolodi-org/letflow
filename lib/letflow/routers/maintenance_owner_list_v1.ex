defmodule Letflow.Routers.MaintenanceOwnerListV1 do
  @moduledoc """
  T-1963: the owner-list team mount, `/maintenance/v1/owner-list`, forwarded by `Letflow.Router` ABOVE
  `/maintenance/v1` and OUTSIDE `Letflow.Plugs.ApiPipeline`. Its credential is a hash-configured WRITE
  token of its own (`LETFLOW_OWNER_LIST_SHA256`, `Letflow.Plugs.ReportExportAuth` with
  `credential: :owner_list`); the export token of `MaintenanceV1` stays read-only and is 401 here.

  | Route | Answer |
  |---|---|
  | `POST /import` | 200 `{imported: [...], skipped: [...]}`; 422 `invalid_request` naming the item and path of the first bad field (never a value); 503 `unavailable` |
  | anything else | 404 `not_found` |

  The body is the JSON document of the lab list (`format: "letflow-owner-list"`, see
  `Letflow.ProblemReports.Review.import/1`). The body is read with an explicit 45 MB bound (413 above it) for this one credentialed
  mount, because one entry may carry up to six base64 screenshots of 5 MiB each. No tenant identifier is
  taken; this module never touches the database itself.
  """

  use Plug.Router

  import Plug.Conn

  alias Letflow.Plugs.ReportExportAuth
  alias Letflow.ProblemReports.Review

  @max_body_bytes 45_000_000

  plug(Letflow.Plugs.ReportExportAuth, credential: :owner_list)

  plug(:match)
  plug(:dispatch)

  post "/import" do
    case read_json(conn) do
      {:ok, conn, doc} ->
        import_document(conn, doc)

      {:error, conn, status, code, message} ->
        ReportExportAuth.send_error(conn, status, code, message)
    end
  end

  match _ do
    ReportExportAuth.send_error(conn, 404, "not_found", "not found")
  end

  defp import_document(conn, doc) do
    case Review.import(doc) do
      {:ok, body} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> Letflow.Api.Response.send_json(200, body)

      {:error, {:invalid_import, message}} ->
        ReportExportAuth.send_error(conn, 422, "invalid_request", message)

      {:error, :unavailable} ->
        ReportExportAuth.send_error(conn, 503, "unavailable", "owner list is not available")

      {:error, _} ->
        ReportExportAuth.send_error(conn, 500, "internal_error", "internal error")
    end
  end

  # Bounded read, JSON content type, Jason.decode, an object. No Plug.Parsers: the limit is explicit and
  # an oversized body answers a clear 413 (the lab list may carry up to six 5 MiB screenshots per entry).
  defp read_json(conn) do
    json? =
      conn
      |> get_req_header("content-type")
      |> Enum.any?(&String.starts_with?(&1, "application/json"))

    if json? do
      case read_body(conn, length: @max_body_bytes, read_length: 1_000_000) do
        {:ok, body, conn} ->
          case Jason.decode(body) do
            {:ok, %{} = doc} -> {:ok, conn, doc}
            _ -> {:error, conn, 422, "invalid_request", "the body must be a JSON object"}
          end

        {:more, _partial, conn} ->
          {:error, conn, 413, "payload_too_large",
           "the document is larger than 45 MB; export fewer items per request (--ids)"}

        {:error, _} ->
          {:error, conn, 400, "invalid_request", "the body could not be read"}
      end
    else
      {:error, conn, 415, "unsupported_media_type", "send application/json"}
    end
  end
end
