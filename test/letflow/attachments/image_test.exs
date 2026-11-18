defmodule Letflow.Attachments.ImageTest do
  @moduledoc "T-2040 I-*, O-1: the pure byte checks and the owner registry (no database)."
  use ExUnit.Case, async: true

  alias Letflow.Attachments.{Image, Owners}
  alias Letflow.AttachmentsImageFixture, as: Fx

  @sentinel Fx.sentinel()

  describe "I-T type by first bytes" do
    test "I-T1 JPEG, PNG and WebP are detected by their bytes" do
      assert {:ok, %{content_type: "image/jpeg"}} = Image.check(Fx.jpeg(), :original)
      assert {:ok, %{content_type: "image/png"}} = Image.check(Fx.png(), :original)
      assert {:ok, %{content_type: "image/webp"}} = Image.check(Fx.webp(), :original)
    end

    test "I-T2 GIF, SVG, HEIC and PDF are refused by bytes" do
      for bytes <- [
            "GIF89a" <> <<1, 0, 1, 0>>,
            "<svg xmlns='http://www.w3.org/2000/svg'/>",
            <<0, 0, 0, 24>> <> "ftypheic" <> <<0, 0, 0, 0>>,
            "%PDF-1.4\n"
          ] do
        assert {:error, :photo_type_not_allowed} = Image.check(bytes, :original)
      end
    end
  end

  describe "I-M malformed input never raises" do
    test "I-M1..M8" do
      jpeg = Fx.jpeg()
      png = Fx.png()
      webp = Fx.webp()

      cases = [
        # truncated JPEG segment, length past the end
        binary_part(jpeg, 0, 12),
        <<0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 1, 2, 3>>,
        # missing EOI
        binary_part(jpeg, 0, byte_size(jpeg) - 2),
        # second SOF
        <<0xFF, 0xD8>> <>
          Fx.seg(0xC0, <<8, 1::16, 1::16, 1, 1, 0x11, 0>>) <>
          Fx.seg(0xC0, <<8, 1::16, 1::16, 1, 1, 0x11, 0>>) <> <<0xFF, 0xD9>>,
        # PNG bad CRC
        flip_last_crc(png),
        # PNG without IHDR / without IEND
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> Fx.png_chunk("IDAT", <<1>>),
        binary_part(png, 0, byte_size(png) - 12),
        # unknown critical chunk
        Fx.png(chunks: [{"ABCD", "x"}]),
        # RIFF size past the end
        binary_part(webp, 0, byte_size(webp) - 4),
        # not a binary / empty / short
        nil,
        <<>>,
        <<0xFF, 0xD8, 0xFF>>,
        123
      ]

      for bytes <- cases do
        assert {:error, :photo_malformed} = Image.check(bytes, :original)
      end
    end

    @tag timeout: 20_000
    test "I-M9 a 5 MiB run of fill bytes is refused in linear time" do
      bytes = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 5_242_878)
      task = Task.async(fn -> Image.check(bytes, :original) end)

      assert {:ok, {:error, :photo_malformed}} =
               Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
    end

    test "I-M10 a short run of fill bytes before a marker is still accepted" do
      <<soi::binary-size(2), rest::binary>> = Fx.jpeg()
      bytes = soi <> :binary.copy(<<0xFF>>, 40) <> rest

      assert {:ok, %{content_type: "image/jpeg"}} = Image.check(bytes, :original)
    end

    test "garbage after a valid prefix does not raise" do
      for n <- 0..40 do
        bytes = binary_part(Fx.jpeg(meta: [:exif]), 0, n)
        assert {:error, _} = Image.check(bytes, :original)
      end
    end
  end

  describe "I-D dimensions" do
    test "from SOF, IHDR, VP8, VP8L and VP8X" do
      assert {:ok, %{width: 30, height: 20}} =
               Image.check(Fx.jpeg(width: 30, height: 20), :original)

      assert {:ok, %{width: 31, height: 21}} =
               Image.check(Fx.png(width: 31, height: 21), :original)

      assert {:ok, %{width: 32, height: 22}} =
               Image.check(Fx.webp(width: 32, height: 22), :original)

      assert {:ok, %{width: 33, height: 23}} =
               Image.check(Fx.webp(kind: :vp8l, width: 33, height: 23), :original)

      assert {:ok, %{width: 34, height: 24}} =
               Image.check(Fx.webp(kind: :extended, width: 34, height: 24), :original)
    end
  end

  describe "I-A animation" do
    test "animated WebP is refused, APNG becomes a still PNG" do
      assert {:error, :photo_type_not_allowed} =
               Image.check(Fx.webp(kind: :extended, animated: true), :original)

      apng =
        Fx.png(chunks: [{"acTL", <<0, 0, 0, 2, 0, 0, 0, 0>>}, {"fcTL", :binary.copy(<<0>>, 26)}])

      assert {:ok, %{bytes: out}} = Image.check(apng, :original)
      refute out =~ "acTL"
      refute out =~ "fcTL"
    end
  end

  describe "I-S strip" do
    test "I-S1 JPEG: every metadata carrier is gone, image segments are kept in order" do
      jpeg = Fx.jpeg(meta: [:exif, :xmp, :app13, :com, :mpf, :icc, :adobe, :after_eoi])
      assert {:ok, %{bytes: out}} = Image.check(jpeg, :original)

      refute out =~ @sentinel
      refute out =~ "Exif\0\0"
      refute out =~ "http://ns.adobe.com/xap"
      refute out =~ "Photoshop"
      # nothing after the first EOI
      assert binary_part(out, byte_size(out) - 2, 2) == <<0xFF, 0xD9>>
      assert length(:binary.matches(out, <<0xFF, 0xD8>>)) == 1
      # kept: APP0, ICC APP2, Adobe APP14, DQT, SOF, DHT, SOS, entropy bytes in order
      assert out =~ "JFIF"
      assert out =~ "ICC_PROFILE"
      assert out =~ "Adobe"
      assert out =~ Fx.jpeg_entropy()

      markers = markers(out)
      assert markers == [0xE0, 0xE2, 0xEE, 0xDB, 0xC0, 0xC4, 0xDA]
    end

    test "I-S2 PNG: text, time and exif chunks gone, kept chunks identical, CRCs valid" do
      png = Fx.png(chunks: Fx.png_sentinel_chunks() ++ [{"gAMA", <<0, 1, 0, 0>>}])
      assert {:ok, %{bytes: out}} = Image.check(png, :original)

      refute out =~ @sentinel
      for t <- ~w(eXIf tEXt zTXt iTXt tIME), do: refute(out =~ t)
      assert chunk_types(out) == ["IHDR", "gAMA", "IDAT", "IEND"]
      assert Enum.all?(chunk_crcs(out), & &1)
      assert out =~ Fx.png_chunk("gAMA", <<0, 1, 0, 0>>)
    end

    test "I-S3 WebP: EXIF and XMP chunks gone, flags cleared, RIFF size right" do
      webp = Fx.webp(kind: :extended, meta: [:exif, :xmp])
      assert <<_, _, _, _, _, _, _, _, _, _, _, _, "VP8X", _::32, flags, _::binary>> = webp
      assert Bitwise.band(flags, 0x0C) == 0x0C

      assert {:ok, %{bytes: out}} = Image.check(webp, :original)
      refute out =~ @sentinel
      refute out =~ "EXIF"
      refute out =~ "XMP "
      assert <<"RIFF", size::32-little, "WEBP", "VP8X", _::32, flags2, _::binary>> = out
      assert Bitwise.band(flags2, 0x0C) == 0
      assert size == byte_size(out) - 8
    end

    test "I-S4 stripping is idempotent" do
      for img <- [
            Fx.jpeg(meta: [:exif, :xmp, :icc, :after_eoi]),
            Fx.png(chunks: Fx.png_sentinel_chunks()),
            Fx.webp(kind: :extended, meta: [:exif, :xmp])
          ] do
        assert {:ok, %{bytes: once}} = Image.check(img, :original)
        assert {:ok, %{bytes: twice}} = Image.check(once, :original)
        assert once == twice
      end
    end
  end

  describe "I-C caps" do
    test "I-C1 original: exact limits pass, one over fails" do
      limit = Image.caps(:original).max_bytes
      at_limit = pad_to(limit)
      assert {:ok, _} = Image.check(at_limit, :original)
      assert {:error, :photo_too_large} = Image.check(at_limit <> <<0>>, :original)

      assert {:ok, _} = Image.check(Fx.jpeg(width: 4096, height: 4096), :original)
      assert {:error, :photo_too_large} = Image.check(Fx.jpeg(width: 4097, height: 8), :original)
      assert {:error, :photo_too_large} = Image.check(Fx.png(width: 8, height: 4097), :original)
    end

    test "I-C2 thumbnail: 102 401 bytes and 401 px refused" do
      assert {:ok, _} = Image.check(Fx.jpeg(width: 400, height: 400), :thumbnail)
      assert {:error, :photo_too_large} = Image.check(Fx.jpeg(width: 401, height: 8), :thumbnail)
      assert {:ok, _} = Image.check(pad_to(102_400), :thumbnail)
      assert {:error, :photo_too_large} = Image.check(pad_to(102_401), :thumbnail)
    end
  end

  test "O-1 registry holds asset photos, master-kind photos and retained problem-report screenshots" do
    assert Owners.kinds() == [
             "assets_card",
             "catalog_item",
             "catalog_lot",
             "location_node",
             "problem_report"
           ]

    for kind <- ["assets_card", "catalog_item", "catalog_lot", "location_node"] do
      assert {:ok, %{purposes: %{"photo" => %{max: 10, main: true}}}} = Owners.fetch(kind)
    end

    assert {:ok, %{purposes: %{"screenshot" => %{max: 3, main: false, retain_days: 30}}}} =
             Owners.fetch("problem_report")

    assert :error = Owners.fetch("catalog_counterparty")
    assert :error = Owners.fetch(nil)
  end

  # -- helpers -----------------------------------------------------------------------------------

  defp pad_to(size) do
    base = byte_size(Fx.jpeg())
    Fx.jpeg(pad: size - base)
  end

  defp flip_last_crc(png) do
    head = binary_part(png, 0, byte_size(png) - 1)
    <<head::binary, Bitwise.bxor(:binary.last(png), 0xFF)>>
  end

  # Marker bytes of the segments of a JPEG up to SOS (headers only).
  defp markers(<<0xFF, 0xD8, rest::binary>>), do: markers(rest, [])

  defp markers(<<0xFF, 0xDA, _::binary>>, acc), do: Enum.reverse([0xDA | acc])

  defp markers(<<0xFF, m, len::16, rest::binary>>, acc) do
    plen = len - 2
    <<_::binary-size(^plen), tail::binary>> = rest
    markers(tail, [m | acc])
  end

  defp chunk_types(<<_sig::binary-8, rest::binary>>), do: chunk_types(rest, [])
  defp chunk_types(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_types(<<len::32, type::binary-4, rest::binary>>, acc) do
    <<_::binary-size(^len), _crc::32, tail::binary>> = rest
    chunk_types(tail, [type | acc])
  end

  defp chunk_crcs(<<_sig::binary-8, rest::binary>>), do: chunk_crcs(rest, [])
  defp chunk_crcs(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_crcs(<<len::32, type::binary-4, rest::binary>>, acc) do
    <<data::binary-size(^len), crc::32, tail::binary>> = rest
    chunk_crcs(tail, [:erlang.crc32(type <> data) == crc | acc])
  end
end
