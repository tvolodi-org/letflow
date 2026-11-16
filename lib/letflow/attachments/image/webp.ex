defmodule Letflow.Attachments.Image.WebP do
  @moduledoc """
  WebP (RIFF) walker and metadata stripper (T-2040, photos.md 5.2/5.3). Pure, no pixel decoding.

  Simple files (`VP8 ` / `VP8L` first) keep only that chunk. Extended files (`VP8X`) keep VP8X (with
  the EXIF and XMP flags cleared), ICCP, ALPH and exactly one VP8/VP8L; EXIF, XMP and unknown chunks
  are dropped. Animated files are `:photo_type_not_allowed`. The RIFF size is recomputed.
  """

  import Bitwise

  @spec walk(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer(), bytes: binary()}}
          | {:error, :photo_malformed | :photo_type_not_allowed}
  def walk(<<"RIFF", size::32-little, "WEBP", _::binary>> = bin) when size >= 4 do
    body_len = size - 4

    case bin do
      <<_::binary-size(12), body::binary-size(^body_len), _trailer::binary>> -> walk_body(body)
      _ -> {:error, :photo_malformed}
    end
  end

  def walk(_), do: {:error, :photo_malformed}

  defp walk_body(
         <<"VP8X", 10::32-little, flags, _::24, cw::24-little, ch::24-little, _::binary>> = body
       ) do
    if (flags &&& 0x02) != 0 do
      {:error, :photo_type_not_allowed}
    else
      case read_chunks(body, []) do
        {:ok, chunks} -> assemble_extended(chunks, cw + 1, ch + 1)
        :error -> {:error, :photo_malformed}
      end
    end
  end

  defp walk_body(<<fourcc::binary-4, size::32-little, data::binary-size(size), _::binary>>)
       when fourcc in ["VP8 ", "VP8L"] do
    case bitstream_dims(fourcc, data) do
      {:ok, w, h} -> {:ok, %{width: w, height: h, bytes: riff([chunk(fourcc, data)])}}
      :error -> {:error, :photo_malformed}
    end
  end

  defp walk_body(_), do: {:error, :photo_malformed}

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(<<fourcc::binary-4, size::32-little, rest::binary>>, acc) do
    pad = rem(size, 2)

    case rest do
      <<data::binary-size(^size), _pad::binary-size(^pad), after_chunk::binary>> ->
        read_chunks(after_chunk, [{fourcc, data} | acc])

      _ ->
        :error
    end
  end

  defp read_chunks(_, _acc), do: :error

  defp assemble_extended(chunks, cw, ch) do
    if Enum.any?(chunks, fn {f, _} -> f in ["ANIM", "ANMF"] end) do
      {:error, :photo_type_not_allowed}
    else
      images = Enum.filter(chunks, fn {f, _} -> f in ["VP8 ", "VP8L"] end)

      with [{fourcc, data}] <- images,
           {:ok, bw, bh} <- bitstream_dims(fourcc, data) do
        kept =
          chunks
          |> Enum.filter(fn {f, _} -> f in ["VP8X", "ICCP", "ALPH", "VP8 ", "VP8L"] end)
          |> Enum.map(&rewrite_vp8x/1)

        {:ok, %{width: max(cw, bw), height: max(ch, bh), bytes: riff(kept)}}
      else
        _ -> {:error, :photo_malformed}
      end
    end
  end

  # EXIF (0x08) and XMP (0x04) flags are cleared along with their chunks.
  defp rewrite_vp8x({"VP8X", <<flags, rest::binary>>}),
    do: chunk("VP8X", <<band(flags, bnot(0x0C)), rest::binary>>)

  defp rewrite_vp8x({fourcc, data}), do: chunk(fourcc, data)

  defp chunk(fourcc, data) do
    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>
    <<fourcc::binary, byte_size(data)::32-little, data::binary, pad::binary>>
  end

  defp riff(chunks) do
    body = IO.iodata_to_binary(chunks)
    <<"RIFF", byte_size(body) + 4::32-little, "WEBP", body::binary>>
  end

  defp bitstream_dims(
         "VP8 ",
         <<b0, _b1, _b2, 0x9D, 0x01, 0x2A, w::16-little, h::16-little, _::binary>>
       )
       when (b0 &&& 1) == 0 do
    w = w &&& 0x3FFF
    h = h &&& 0x3FFF
    if w > 0 and h > 0, do: {:ok, w, h}, else: :error
  end

  defp bitstream_dims("VP8L", <<0x2F, bits::32-little, _::binary>>) do
    {:ok, (bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}
  end

  defp bitstream_dims(_, _), do: :error
end
