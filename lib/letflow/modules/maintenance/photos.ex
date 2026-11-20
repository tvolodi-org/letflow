defmodule Letflow.Modules.Maintenance.Photos do
  @moduledoc """
  REQ-895 / GH #4805 (CMMS slice 1 part 3): photos on a work request through the shared attachment
  service (`Letflow.Attachments`), in the shape of `Letflow.Modules.Assets.CardPhotos` (read it for
  the upload and refusal conventions). Four routes of `Letflow.Modules.Maintenance.Router`:

  | Route below `/requests/:id/photos` | Permission | Ok |
  |---|---|---|
  | `POST` (multipart `original`, optional `thumbnail`, `caption`) | `MaintenanceRequestCreate` | 201 photo, 200 on content replay |
  | `GET` | `MaintenanceRead` | 200 `photos` |
  | `GET /:photo_id/original`, `GET /:photo_id/thumbnail` | `MaintenanceRead` | 200 stored bytes |

  Guards, in this order: the release flag, the `authz_*` permission check (403), then
  `Letflow.Modules.Maintenance.Access.check/2` (interactive, tenant-wide holder). The request is
  looked up first (`Requests.photo_owner/2`): a malformed, unknown or other tenant's id is the plain
  404. A photo id is resolved by `Letflow.Attachments` under that request, so another request's or
  tenant's photo is the same 404. A photo is added only while the request is `new`
  (409 `request_not_new`); reads work in every status. Owner kind `maintenance_work_request`,
  purpose `photo`, at most 5, no main photo (`Letflow.Attachments.Owners`). There is no delete,
  reorder or caption change in slice 1.

  `Attachments` does the one byte parse, metadata strip, scan, caps, quota, rate, replay and audit.
  Refusals: 422 for image and cap reasons, 409 for the storage quota, 429 for the upload rate,
  503 when the scanner is unavailable, 500 without detail for anything else. A photo view carries
  its id, position, caption, thumbnail flag and time, never the uploader's id. Byte responses use
  the stored type, `nosniff`, `inline` and `cache-control: private, max-age=86400`.

  A reject that commits between the status check and the attachment write can leave one photo on a
  just-rejected request; it is not a data-isolation matter and the photo is read-only afterwards.
  """

  import Plug.Conn

  alias Letflow.Api.{Error, Response}
  alias Letflow.Attachments
  alias Letflow.Modules.Maintenance
  alias Letflow.Modules.Maintenance.Access
  alias Letflow.Modules.Maintenance.Requests

  @purpose "photo"
  @upload_keys ["caption", "original", "thumbnail"]

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    with_request(conn, :read, fn conn, access, found ->
      links = Attachments.list(access.prefix, found.owner, @purpose)
      Response.ok(conn, %{"photos" => Enum.map(links, &photo_view/1)})
    end)
  end

  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    with_request(conn, :create, fn conn, access, found ->
      with true <- found.new? or {:error, :request_not_new},
           body = conn.body_params,
           true <- is_map(body) or {:error, :original_required},
           :ok <- only_keys(body, @upload_keys),
           {:ok, original} <- required_upload(Map.get(body, "original")),
           {:ok, thumbnail} <- optional_upload(Map.get(body, "thumbnail")),
           {:ok, caption} <- upload_caption(Map.get(body, "caption")),
           {:ok, original_bytes} <- read_upload(original, :original),
           {:ok, thumbnail_bytes} <- read_optional_upload(thumbnail) do
        attrs = %{
          purpose: @purpose,
          original: original_bytes,
          thumbnail: thumbnail_bytes,
          caption: caption
        }

        ctx = %{actor_id: access.actor_id, trace_id: conn.assigns[:trace_id]}

        case Attachments.add(access.prefix, found.owner, attrs, ctx) do
          {:ok, link, tag} ->
            body = photo_view(link)
            if tag == :created, do: Response.created(conn, body), else: Response.ok(conn, body)

          {:error, reason} ->
            refuse(conn, reason)
        end
      else
        {:error, reason} -> refuse(conn, reason)
        {:error, reason, field} -> refuse(conn, reason, field)
      end
    end)
  end

  @spec content(Plug.Conn.t(), :original | :thumbnail) :: Plug.Conn.t()
  def content(conn, which) when which in [:original, :thumbnail] do
    with_request(conn, :read, fn conn, access, found ->
      case Attachments.content(
             access.prefix,
             found.owner,
             Map.get(conn.params, "photo_id"),
             which
           ) do
        {:ok, blob} ->
          conn
          |> put_resp_content_type(Map.fetch!(blob, :content_type), nil)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-disposition", "inline")
          |> put_resp_header("cache-control", "private, max-age=86400")
          |> send_resp(200, Map.fetch!(blob, :bytes))

        {:error, reason} ->
          refuse(conn, reason)
      end
    end)
  end

  # The flag, the tenant-wide guard and the request lookup are one 404 (no existence signal).
  defp with_request(conn, purpose, fun) do
    with true <- Maintenance.enabled?(),
         {:ok, access} <- Access.check(conn, purpose),
         {:ok, found} <- Requests.photo_owner(access.prefix, Map.get(conn.params, "id")) do
      fun.(conn, access, found)
    else
      _ -> Response.not_found(conn)
    end
  end

  defp photo_view(link) do
    %{
      "id" => link.id,
      "position" => link.position,
      "caption" => link.caption,
      "has_thumbnail" => not is_nil(link.thumb_blob_id),
      "inserted_at" => DateTime.to_iso8601(link.inserted_at)
    }
  end

  defp only_keys(body, allowed) do
    case Enum.sort(Map.keys(body) -- allowed) do
      [] -> :ok
      [field | _] -> {:error, :field_not_allowed, field}
    end
  end

  defp required_upload(%Plug.Upload{} = upload), do: {:ok, upload}
  defp required_upload(_), do: {:error, :original_required}

  defp optional_upload(nil), do: {:ok, nil}
  defp optional_upload(%Plug.Upload{} = upload), do: {:ok, upload}
  defp optional_upload(_), do: {:error, :field_invalid, "thumbnail"}

  defp upload_caption(nil), do: {:ok, nil}
  defp upload_caption(caption) when is_binary(caption), do: {:ok, caption}
  defp upload_caption(_), do: {:error, :caption_invalid}

  # File sizes are checked with File.stat/1 before reading; Attachments is the authority on bytes.
  defp read_upload(%Plug.Upload{path: path}, kind) do
    max_bytes = Attachments.limits() |> Map.fetch!(kind) |> Map.fetch!(:max_bytes)

    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- within_cap(size, max_bytes),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:error, :photo_too_large} = error -> error
      _ -> {:error, :io_error}
    end
  end

  defp read_optional_upload(nil), do: {:ok, nil}
  defp read_optional_upload(upload), do: read_upload(upload, :thumbnail)

  defp within_cap(size, max) when size <= max, do: :ok
  defp within_cap(_size, _max), do: {:error, :photo_too_large}

  defp refuse(conn, reason, field), do: problem(conn, 422, reason, %{"field" => field})

  defp refuse(conn, :not_found), do: Response.not_found(conn)
  defp refuse(conn, :actor_invalid), do: Response.not_found(conn)
  defp refuse(conn, :request_not_new), do: problem(conn, 409, :request_not_new)
  defp refuse(conn, :storage_quota_exceeded), do: problem(conn, 409, :storage_quota_exceeded)
  defp refuse(conn, :upload_rate_exceeded), do: problem(conn, 429, :upload_rate_exceeded)
  defp refuse(conn, :scan_unavailable), do: problem(conn, 503, :scan_unavailable)

  defp refuse(conn, reason)
       when reason in [
              :caption_invalid,
              :photo_too_large,
              :photo_type_not_allowed,
              :photo_malformed,
              :photo_infected,
              :owner_cap_reached,
              :original_required,
              :field_not_allowed,
              :field_invalid
            ],
       do: problem(conn, 422, reason)

  defp refuse(conn, _reason), do: Response.internal_error(conn)

  defp problem(conn, status, reason, extra \\ %{}) do
    base =
      case status do
        409 -> Error.conflict("request refused")
        429 -> Error.rate_limited("request refused")
        503 -> Error.service_unavailable("request refused")
        _ -> Error.unprocessable("request refused")
      end

    Response.send_problem(conn, %{
      base
      | extensions: Map.merge(extra, %{"reason" => Atom.to_string(reason)})
    })
  end
end
