defmodule Letflow.Attachments.Image.JPEG do
  @moduledoc """
  JPEG structure walker and metadata stripper (T-2040, photos.md 5.2/5.3). Pure, no pixel decoding.

  One pass over the marker segments. Kept verbatim: SOFn (exactly one), DHT, DAC, DQT, DRI, SOS and
  its entropy-coded data, APP0, APP2 only when it is an ICC profile, APP14 only when it is "Adobe".
  Dropped: every other APPn (EXIF/XMP/MPF/vendor), COM. Everything after the first EOI is dropped
  (MPF secondary images carry their own EXIF/GPS). Anything structurally wrong is `:photo_malformed`.
  The walk is linear, binary-match bounded, and creates no atoms.
  """

  @sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  @always_kept [0xC4, 0xCC, 0xDB, 0xDD, 0xE0]

  @spec walk(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer(), bytes: binary()}}
          | {:error, :photo_malformed}
  def walk(<<0xFF, 0xD8, rest::binary>>) do
    segments(rest, [<<0xFF, 0xD8>>], %{dims: nil, sos?: false})
  end

  def walk(_), do: {:error, :photo_malformed}

  # Fill bytes before a marker.
  defp segments(<<0xFF, 0xFF, rest::binary>>, acc, st),
    do: segments(<<0xFF, rest::binary>>, acc, st)

  defp segments(<<0xFF, 0xD9, _after_eoi::binary>>, acc, %{dims: {w, h}, sos?: true}) do
    {:ok,
     %{width: w, height: h, bytes: IO.iodata_to_binary(Enum.reverse([<<0xFF, 0xD9>> | acc]))}}
  end

  defp segments(<<0xFF, 0xD9, _::binary>>, _acc, _st), do: {:error, :photo_malformed}

  defp segments(<<0xFF, m, len::16, rest::binary>>, acc, st) when len >= 2 and m not in [0, 1] do
    plen = len - 2

    case rest do
      <<payload::binary-size(^plen), after_seg::binary>> ->
        segment(m, len, payload, after_seg, acc, st)

      _ ->
        {:error, :photo_malformed}
    end
  end

  defp segments(_, _acc, _st), do: {:error, :photo_malformed}

  defp segment(m, len, payload, rest, acc, st) when m in @sof_markers do
    case {st.dims, payload} do
      {nil, <<_precision, h::16, w::16, _::binary>>} when h > 0 and w > 0 ->
        segments(rest, [raw(m, len, payload) | acc], %{st | dims: {w, h}})

      _ ->
        {:error, :photo_malformed}
    end
  end

  defp segment(m, len, payload, rest, acc, st) when m in @always_kept do
    segments(rest, [raw(m, len, payload) | acc], st)
  end

  defp segment(0xE2, len, payload, rest, acc, st) do
    case payload do
      <<"ICC_PROFILE", 0, _::binary>> -> segments(rest, [raw(0xE2, len, payload) | acc], st)
      _ -> segments(rest, acc, st)
    end
  end

  defp segment(0xEE, len, payload, rest, acc, st) do
    case payload do
      <<"Adobe", _::binary>> -> segments(rest, [raw(0xEE, len, payload) | acc], st)
      _ -> segments(rest, acc, st)
    end
  end

  # SOS: header kept, then entropy-coded data up to the next real marker.
  defp segment(0xDA, len, payload, rest, acc, %{dims: {_, _}} = st) do
    case scan(rest, 0) do
      {:ok, entropy_len} ->
        <<entropy::binary-size(^entropy_len), tail::binary>> = rest
        segments(tail, [entropy, raw(0xDA, len, payload) | acc], %{st | sos?: true})

      :error ->
        {:error, :photo_malformed}
    end
  end

  # Dropped: APP1, APP3..APP13, APP15 and COM.
  defp segment(m, _len, _payload, rest, acc, st) when m in 0xE1..0xEF or m == 0xFE do
    segments(rest, acc, st)
  end

  # Reserved, unknown, RSTn, SOI, hierarchical, SOS before SOF, JPGn.
  defp segment(_m, _len, _payload, _rest, _acc, _st), do: {:error, :photo_malformed}

  defp raw(m, len, payload), do: <<0xFF, m, len::16, payload::binary>>

  # Offset of the first marker that ends the entropy data (FF followed by neither 00, RSTn nor FF).
  defp scan(bin, offset) do
    case :binary.match(bin, <<0xFF>>, scope: {offset, byte_size(bin) - offset}) do
      :nomatch ->
        :error

      {pos, 1} ->
        case bin do
          <<_::binary-size(^pos), 0xFF, 0x00, _::binary>> -> scan(bin, pos + 2)
          <<_::binary-size(^pos), 0xFF, b, _::binary>> when b in 0xD0..0xD7 -> scan(bin, pos + 2)
          <<_::binary-size(^pos), 0xFF, 0xFF, _::binary>> -> scan(bin, pos + 1)
          <<_::binary-size(^pos), 0xFF, _b, _::binary>> -> {:ok, pos}
          _ -> :error
        end
    end
  end
end
