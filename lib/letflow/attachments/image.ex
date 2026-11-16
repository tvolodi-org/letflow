defmodule Letflow.Attachments.Image do
  @moduledoc """
  Byte-level image check for the attachment service (T-2040, photos.md 5.2/5.3). Pure.

  `check/2` decides the type by the first bytes only (a declared content type is never an input),
  walks the structure once with the format's walker, strips metadata (EXIF, GPS, XMP, text) by
  allowlist and returns the stripped bytes. Nothing is decoded to pixels; dimensions come from the
  headers. Never raises: a walker that does is mapped to `:photo_malformed` (INV-8).
  """

  alias Letflow.Attachments.Image.{JPEG, PNG, WebP}

  @caps %{
    original: %{max_bytes: 5_242_880, max_px: 4096},
    thumbnail: %{max_bytes: 102_400, max_px: 400}
  }

  @type kind :: :original | :thumbnail
  @type ok :: %{
          content_type: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          bytes: binary()
        }

  @doc "Caps by kind: `%{max_bytes, max_px}`."
  @spec caps(kind()) :: %{max_bytes: pos_integer(), max_px: pos_integer()}
  def caps(kind), do: Map.fetch!(@caps, kind)

  @spec check(term(), kind()) ::
          {:ok, ok()}
          | {:error, :photo_malformed | :photo_too_large | :photo_type_not_allowed}
  def check(bytes, kind) when kind in [:original, :thumbnail] do
    %{max_bytes: max_bytes, max_px: max_px} = Map.fetch!(@caps, kind)

    cond do
      not is_binary(bytes) or bytes == <<>> -> {:error, :photo_malformed}
      byte_size(bytes) > max_bytes -> {:error, :photo_too_large}
      true -> dispatch(bytes, max_px)
    end
  end

  defp dispatch(bytes, max_px) do
    with {:ok, type, walker} <- detect(bytes),
         {:ok, %{width: w, height: h, bytes: stripped}} <- walker.walk(bytes) do
      if w > max_px or h > max_px do
        {:error, :photo_too_large}
      else
        {:ok, %{content_type: type, width: w, height: h, bytes: stripped}}
      end
    end
  rescue
    _ -> {:error, :photo_malformed}
  end

  defp detect(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg", JPEG}
  defp detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png", PNG}
  defp detect(<<"RIFF", _::32, "WEBP", _::binary>>), do: {:ok, "image/webp", WebP}
  defp detect(_), do: {:error, :photo_type_not_allowed}
end
