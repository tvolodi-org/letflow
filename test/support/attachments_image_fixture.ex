defmodule Letflow.AttachmentsImageFixture do
  @moduledoc """
  Builds small JPEG, PNG and WebP binaries from parts for the attachment tests (T-2040). No image
  tool exists on the host and no binary file is committed. The images are structurally valid for the
  walkers (markers, chunks, CRCs, RIFF sizes); they are not decodable pictures.
  """

  import Bitwise

  @sentinel "LETFLOW-GPS-SENTINEL"
  def sentinel, do: @sentinel

  # -- JPEG -------------------------------------------------------------------------------------

  @doc """
  `opts`: `:width`, `:height` (default 8), `:meta` (list of `:exif`, `:xmp`, `:app13`, `:com`, `:mpf`,
  `:icc`, `:adobe`, `:after_eoi`), `:pad` (extra entropy bytes, to reach a size).
  """
  def jpeg(opts \\ []) do
    w = Keyword.get(opts, :width, 8)
    h = Keyword.get(opts, :height, 8)
    meta = Keyword.get(opts, :meta, [])
    pad = Keyword.get(opts, :pad, 0)

    entropy = <<0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56>> <> :binary.copy(<<0x77>>, pad)

    IO.iodata_to_binary([
      <<0xFF, 0xD8>>,
      seg(0xE0, <<"JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>),
      for(m <- meta, m != :after_eoi, do: meta_segment(m)),
      seg(0xDB, <<0>> <> :binary.copy(<<16>>, 64)),
      seg(0xC0, <<8, h::16, w::16, 1, 1, 0x11, 0>>),
      seg(0xC4, <<0x00>> <> :binary.copy(<<0>>, 16)),
      seg(0xDA, <<1, 1, 0, 0, 63, 0>>),
      entropy,
      <<0xFF, 0xD9>>,
      if(:after_eoi in meta,
        do: [<<0xFF, 0xD8>>, meta_segment(:exif), <<0xFF, 0xD9>>],
        else: []
      )
    ])
  end

  def jpeg_entropy, do: <<0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56>>

  def seg(marker, payload), do: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>

  defp meta_segment(:exif),
    do:
      seg(
        0xE1,
        <<"Exif", 0, 0, "II*", 0, 8, 0, 0, 0>> <> <<0x25, 0x88>> <> "GPS " <> @sentinel
      )

  defp meta_segment(:xmp), do: seg(0xE1, "http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>")
  defp meta_segment(:app13), do: seg(0xED, "Photoshop 3.0\0" <> @sentinel)
  defp meta_segment(:com), do: seg(0xFE, "comment " <> @sentinel)
  defp meta_segment(:mpf), do: seg(0xE2, "MPF\0" <> @sentinel)
  defp meta_segment(:icc), do: seg(0xE2, "ICC_PROFILE\0" <> <<1, 1>> <> "profile-bytes")
  defp meta_segment(:adobe), do: seg(0xEE, "Adobe" <> <<0, 100, 0, 0, 0, 0, 1>>)

  # -- PNG --------------------------------------------------------------------------------------

  @png_sig <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  @doc "`opts`: `:width`, `:height`, `:chunks` (extra `{type, data}` placed after IHDR), `:pad` (IDAT bytes)."
  def png(opts \\ []) do
    w = Keyword.get(opts, :width, 8)
    h = Keyword.get(opts, :height, 8)
    extra = Keyword.get(opts, :chunks, [])
    pad = Keyword.get(opts, :pad, 0)
    idat = :zlib.compress(<<0, 1, 2, 3>>) <> :binary.copy(<<0>>, pad)

    IO.iodata_to_binary([
      @png_sig,
      png_chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>),
      for({t, d} <- extra, do: png_chunk(t, d)),
      png_chunk("IDAT", idat),
      png_chunk("IEND", <<>>)
    ])
  end

  def png_chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  def png_sentinel_chunks do
    [
      {"eXIf", "II*\0" <> @sentinel},
      {"tEXt", "Comment\0" <> @sentinel},
      {"zTXt", "Comment\0\0" <> :zlib.compress(@sentinel)},
      {"iTXt", "Comment\0\0\0\0\0" <> @sentinel},
      {"tIME", <<2026::16, 11, 16, 1, 2, 3>>}
    ]
  end

  # -- WebP -------------------------------------------------------------------------------------

  def riff(chunks) do
    body = IO.iodata_to_binary(for {t, d} <- chunks, do: riff_chunk(t, d))
    <<"RIFF", byte_size(body) + 4::32-little, "WEBP", body::binary>>
  end

  def riff_chunk(fourcc, data) do
    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>
    <<fourcc::binary, byte_size(data)::32-little, data::binary, pad::binary>>
  end

  def vp8_data(w, h),
    do: <<0x10, 0, 0, 0x9D, 0x01, 0x2A, w::16-little, h::16-little, 1, 2, 3, 4>>

  def vp8l_data(w, h) do
    bits = w - 1 ||| (h - 1) <<< 14
    <<0x2F, bits::32-little, 0, 0, 0, 0>>
  end

  @doc "`opts`: `:width`, `:height`, `:kind` (`:simple` | `:vp8l` | `:extended`), `:meta` (`:exif`, `:xmp`), `:animated`."
  def webp(opts \\ []) do
    w = Keyword.get(opts, :width, 8)
    h = Keyword.get(opts, :height, 8)
    meta = Keyword.get(opts, :meta, [])
    cw = w - 1
    ch = h - 1

    case Keyword.get(opts, :kind, :simple) do
      :simple ->
        riff([{"VP8 ", vp8_data(w, h)}])

      :vp8l ->
        riff([{"VP8L", vp8l_data(w, h)}])

      :extended ->
        flags =
          if(:exif in meta, do: 0x08, else: 0) ||| if(:xmp in meta, do: 0x04, else: 0) |||
            if Keyword.get(opts, :animated, false), do: 0x02, else: 0

        riff(
          [{"VP8X", <<flags, 0, 0, 0, cw::24-little, ch::24-little>>}] ++
            if(Keyword.get(opts, :animated, false),
              do: [{"ANIM", <<0, 0, 0, 0, 0, 0>>}],
              else: []
            ) ++
            [{"VP8 ", vp8_data(w, h)}] ++
            if(:exif in meta, do: [{"EXIF", "Exif\0\0" <> @sentinel}], else: []) ++
            if(:xmp in meta, do: [{"XMP ", "<x:xmpmeta>" <> @sentinel}], else: [])
        )
    end
  end
end
