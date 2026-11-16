defmodule Letflow.Attachments.Image.PNG do
  @moduledoc """
  PNG chunk walker and metadata stripper (T-2040, photos.md 5.2/5.3). Pure, no pixel decoding.

  Every chunk's CRC is verified (kept or dropped). Kept: IHDR, PLTE, IDAT, IEND and the colour/
  geometry ancillary chunks listed in `@kept`. Dropped: eXIf, text and time chunks, the APNG chunks
  (the result is the still default image) and every other ancillary chunk. An unknown critical
  chunk, a bad CRC, a missing IHDR/IDAT/IEND or a truncated chunk is `:photo_malformed`. Bytes after
  IEND are dropped.
  """

  @signature <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @kept ~w(IHDR PLTE IDAT IEND tRNS cHRM gAMA iCCP sBIT sRGB cICP bKGD pHYs)

  @spec walk(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer(), bytes: binary()}}
          | {:error, :photo_malformed}
  def walk(<<@signature, rest::binary>>) do
    case rest do
      <<13::32, "IHDR", w::32, h::32, _::binary>> when w > 0 and h > 0 ->
        case chunks(rest, [@signature], false) do
          {:ok, bytes} -> {:ok, %{width: w, height: h, bytes: bytes}}
          :error -> {:error, :photo_malformed}
        end

      _ ->
        {:error, :photo_malformed}
    end
  end

  def walk(_), do: {:error, :photo_malformed}

  defp chunks(<<len::32, rest::binary>> = bin, acc, idat?) when len <= 0x7FFFFFFF do
    n = len + 4

    with <<data_and_type::binary-size(^n), crc::32, after_chunk::binary>> <- rest,
         <<type::binary-4, data::binary>> <- data_and_type,
         true <- :erlang.crc32(:erlang.crc32(type), data) == crc do
      chunk = binary_part(bin, 0, len + 12)
      handle(type, chunk, after_chunk, acc, idat?)
    else
      _ -> :error
    end
  end

  defp chunks(_, _acc, _idat?), do: :error

  defp handle("IEND", chunk, _after, acc, true) do
    {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc]))}
  end

  defp handle("IEND", _chunk, _after, _acc, false), do: :error
  # A second IHDR is not valid.
  defp handle("IHDR", chunk, after_chunk, acc, idat?) do
    if acc == [@signature], do: chunks(after_chunk, [chunk | acc], idat?), else: :error
  end

  defp handle("IDAT", chunk, after_chunk, acc, _idat?),
    do: chunks(after_chunk, [chunk | acc], true)

  defp handle(type, chunk, after_chunk, acc, idat?) when type in @kept do
    chunks(after_chunk, [chunk | acc], idat?)
  end

  # Ancillary (bit 5 of the first byte set = lowercase): dropped. Critical and unknown: refused.
  defp handle(<<first, _::binary>>, _chunk, after_chunk, acc, idat?) when first in ?a..?z do
    chunks(after_chunk, acc, idat?)
  end

  defp handle(_type, _chunk, _after, _acc, _idat?), do: :error
end
