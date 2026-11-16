defmodule Letflow.Modules.Assets.CardPhotos do
  @moduledoc """
  The card photo gallery (T-2041, photos P2; `docs/design/photos.md`). Eight routes of
  `Letflow.Modules.Assets.Router`, all keyed `AssetsRead`, delegate here:

  | Method and path below `/cards/:id/photos` | Success | Write permission |
  |---|---|---|
  | `GET` | 200 list | — |
  | `POST` | 201 photo, or 200 on content replay | `PhotosAdd` |
  | `GET /:photo_id/original`, `GET /:photo_id/thumbnail` | 200 stored bytes | — |
  | `PATCH /:photo_id` (caption only) | 200 photo | `PhotosAdd` |
  | `POST /:photo_id/main` (empty body) | 200 photo | `PhotosAdd` |
  | `PUT /order` (the complete id list) | 200 list | `PhotosAdd` |
  | `DELETE /:photo_id` | 204 | `PhotosDelete`, or `PhotosAdd` for one's own photo |

  The route macro answers 403 when the roles lack `AssetsRead`. Every handler then requires the
  tenant-wide read guard and looks up an `assets_card`; a scoped/API principal, a malformed or
  unknown id, another record type and another tenant's card are the same 404. Only then is the write
  atom checked, so a card's existence is not revealed by a 403. A photo id is always resolved by
  `Letflow.Attachments` under that card owner, making another card's or tenant's photo the same 404.

  Uploads accept multipart `original`, optional `thumbnail` and `caption` only. File sizes are
  checked with `File.stat/1` before reading; `Attachments` then performs the one authoritative byte
  parse, metadata strip, scan, caps, quota, rate, replay and audit. The declared filename and content
  type are ignored. Responses carry photo ids and captions, never uploader ids.

  Refusals are problem bodies with a fixed `reason` (and `field` where applicable): missing write
  atoms and own-photo delete are 403; malformed input, image/cap/order refusals are 422; lock and
  storage quota are 409; upload rate is 429; scanner unavailability is 503; missing owners/photos
  are the plain 404; storage, audit and other unexpected service failures are 500 without detail.
  Byte responses use the stored type, `nosniff`, `inline` and `cache-control: private,
  max-age=86400`.
  """

  import Plug.Conn

  alias Letflow.Api.{Error, ModuleGuard, Response}
  alias Letflow.Attachments
  alias Letflow.Attachments.Owners
  alias Letflow.Modules.Assets.Access
  alias Letflow.Modules.ReadApi

  @owner_kind "assets_card"
  @purpose "photo"
  @upload_keys ["caption", "original", "thumbnail"]

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    with_card(conn, :read, fn conn, access, owner ->
      Response.ok(conn, list_body(conn, access, owner))
    end)
  end

  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    with_card(conn, :add, fn conn, access, owner ->
      with :ok <- only_keys(conn.body_params, @upload_keys),
           {:ok, original} <- required_upload(Map.get(conn.body_params, "original")),
           {:ok, thumbnail} <- optional_upload(Map.get(conn.body_params, "thumbnail")),
           {:ok, caption} <- upload_caption(Map.get(conn.body_params, "caption")),
           {:ok, original_bytes} <- read_upload(original, :original),
           {:ok, thumbnail_bytes} <- read_optional_upload(thumbnail) do
        attrs = %{
          purpose: @purpose,
          original: original_bytes,
          thumbnail: thumbnail_bytes,
          caption: caption
        }

        case Attachments.add(access.prefix, owner, attrs, ctx(conn, access)) do
          {:ok, link, tag} ->
            body = photo_view(link, access.actor_id, delete_mode(conn))
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
    with_card(conn, :read, fn conn, access, owner ->
      case Attachments.content(access.prefix, owner, Map.get(conn.params, "photo_id"), which) do
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

  @spec caption(Plug.Conn.t()) :: Plug.Conn.t()
  def caption(conn) do
    with_card(conn, :add, fn conn, access, owner ->
      case Map.keys(conn.body_params) do
        ["caption"] ->
          result =
            Attachments.set_caption(
              access.prefix,
              owner,
              Map.get(conn.params, "photo_id"),
              Map.get(conn.body_params, "caption"),
              ctx(conn, access)
            )

          render_photo(conn, result, access)

        keys ->
          extra_key(conn, keys -- ["caption"])
      end
    end)
  end

  @spec main(Plug.Conn.t()) :: Plug.Conn.t()
  def main(conn) do
    with_card(conn, :add, fn conn, access, owner ->
      case Map.keys(conn.body_params) do
        [] ->
          result =
            Attachments.set_main(
              access.prefix,
              owner,
              Map.get(conn.params, "photo_id"),
              ctx(conn, access)
            )

          render_photo(conn, result, access)

        keys ->
          extra_key(conn, keys)
      end
    end)
  end

  @spec order(Plug.Conn.t()) :: Plug.Conn.t()
  def order(conn) do
    with_card(conn, :add, fn conn, access, owner ->
      case Map.keys(conn.body_params) do
        ["photo_ids"] ->
          result =
            Attachments.reorder(
              access.prefix,
              owner,
              @purpose,
              Map.get(conn.body_params, "photo_ids"),
              ctx(conn, access)
            )

          case result do
            {:ok, _links} -> Response.ok(conn, list_body(conn, access, owner))
            {:error, reason} -> refuse(conn, reason)
          end

        keys ->
          case Enum.sort(keys -- ["photo_ids"]) do
            [] -> refuse(conn, :invalid_order)
            [field | _] -> refuse(conn, :field_not_allowed, field)
          end
      end
    end)
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    with_card(conn, :delete, fn conn, access, owner ->
      mode = delete_mode(conn)

      result =
        Attachments.delete(
          access.prefix,
          owner,
          Map.get(conn.params, "photo_id"),
          ctx(conn, access),
          mode == :any
        )

      case result do
        {:ok, _link} -> Response.no_content(conn)
        {:error, reason} -> refuse(conn, reason)
      end
    end)
  end

  @doc "Delete authority: `PhotosDelete` allows any photo; `PhotosAdd` alone only one's own."
  @spec delete_mode(boolean(), boolean()) :: :any | :own | :none
  def delete_mode(_can_add?, true), do: :any
  def delete_mode(true, false), do: :own
  def delete_mode(false, false), do: :none

  defp with_card(conn, action, fun) do
    case Access.check(conn, :read) do
      {:ok, access} ->
        case ReadApi.lookup(access.prefix, Map.get(conn.params, "id"), [@owner_kind]) do
          {:ok, card} ->
            owner = %{kind: @owner_kind, id: Map.fetch!(card, "record_id")}

            case authorize_write(conn, action) do
              :ok -> fun.(conn, access, owner)
              {:error, reason} -> refuse(conn, reason)
            end

          {:error, _} ->
            Response.not_found(conn)
        end

      :error ->
        Response.not_found(conn)
    end
  end

  defp authorize_write(_conn, :read), do: :ok

  defp authorize_write(conn, :add) do
    if can?(conn, :PhotosAdd), do: :ok, else: {:error, :photos_add_required}
  end

  defp authorize_write(conn, :delete) do
    if delete_mode(conn) == :none, do: {:error, :photos_delete_required}, else: :ok
  end

  defp can?(conn, permission), do: match?({:ok, _}, ModuleGuard.check(conn, permission))

  defp delete_mode(conn), do: delete_mode(can?(conn, :PhotosAdd), can?(conn, :PhotosDelete))

  defp render_photo(conn, {:ok, link}, access),
    do: Response.ok(conn, photo_view(link, access.actor_id, delete_mode(conn)))

  defp render_photo(conn, {:error, reason}, _access), do: refuse(conn, reason)

  defp list_body(conn, access, owner) do
    links = Attachments.list(access.prefix, owner, @purpose)
    mode = delete_mode(conn)

    %{
      "photos" => Enum.map(links, &photo_view(&1, access.actor_id, mode)),
      "can_add" => can?(conn, :PhotosAdd),
      "can_delete_any" => can?(conn, :PhotosDelete),
      "limits" => limits()
    }
  end

  defp photo_view(link, actor_id, mode) do
    locked = not is_nil(link.locked_at)

    %{
      "id" => link.id,
      "position" => link.position,
      "is_main" => link.is_main,
      "caption" => link.caption,
      "has_thumbnail" => not is_nil(link.thumb_blob_id),
      "inserted_at" => DateTime.to_iso8601(link.inserted_at),
      "locked" => locked,
      "can_delete" =>
        not locked and (mode == :any or (mode == :own and link.uploaded_by == actor_id))
    }
  end

  defp limits do
    caps = Attachments.limits()
    {:ok, entry} = Owners.fetch(@owner_kind)
    rules = Map.fetch!(Map.fetch!(entry, :purposes), @purpose)
    original = Map.fetch!(caps, :original)
    thumbnail = Map.fetch!(caps, :thumbnail)

    %{
      "max_photos" => Map.fetch!(rules, :max),
      "original_max_bytes" => Map.fetch!(original, :max_bytes),
      "original_max_px" => Map.fetch!(original, :max_px),
      "thumbnail_max_bytes" => Map.fetch!(thumbnail, :max_bytes),
      "thumbnail_max_px" => Map.fetch!(thumbnail, :max_px),
      "caption_max" => Map.fetch!(caps, :caption_max_code_points)
    }
  end

  defp ctx(conn, access),
    do: %{actor_id: access.actor_id, trace_id: conn.assigns[:trace_id]}

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

  defp extra_key(conn, keys) do
    case Enum.sort(keys) do
      [] -> refuse(conn, :caption_invalid)
      [field | _] -> refuse(conn, :field_not_allowed, field)
    end
  end

  defp refuse(conn, reason, field),
    do: problem(conn, 422, reason, %{"field" => field})

  defp refuse(conn, :not_found), do: Response.not_found(conn)
  defp refuse(conn, :actor_invalid), do: Response.not_found(conn)
  defp refuse(conn, :photos_add_required), do: problem(conn, 403, :photos_add_required)
  defp refuse(conn, :photos_delete_required), do: problem(conn, 403, :photos_delete_required)
  defp refuse(conn, :forbidden), do: problem(conn, 403, :photo_not_own)
  defp refuse(conn, :photo_locked), do: problem(conn, 409, :photo_locked)
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
              :invalid_order,
              :main_not_allowed,
              :original_required,
              :field_not_allowed,
              :field_invalid
            ],
       do: problem(conn, 422, reason)

  defp refuse(conn, _reason), do: Response.internal_error(conn)

  defp problem(conn, status, reason, extra \\ %{}) do
    base =
      case status do
        403 -> Error.forbidden("request refused")
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
