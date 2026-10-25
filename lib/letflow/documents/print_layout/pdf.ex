defmodule Letflow.Documents.PrintLayout.Pdf do
  @moduledoc """
  Hand-written PDF 1.4 serialiser for the print renderer (REQ-571). One Type0 font with a
  CIDFontType2 descendant, `Identity-H`, a `CIDToGIDMap` stream, a `W` array and a `ToUnicode`
  CMap; the whole bundled font is embedded as a Flate stream.

  Text is written as CIDs (assigned 1..n over the code points the document uses, ascending), so
  two code points that share a glyph still recover separately through `ToUnicode`.

  Nothing dynamic exists in the output: no `/Info`, no `/ID`, no metadata, no annotation, form,
  action or embedded-file object; equal input gives equal bytes (compressed bytes are stable per
  OTP/zlib build).
  """

  alias Letflow.Documents.PrintLayout.Font

  @font_obj 3
  @cid_font_obj 4
  @descriptor_obj 5
  @font_file_obj 6
  @cid_map_obj 7
  @to_unicode_obj 8
  @first_page_obj 9

  @doc "Serialises `%{pages: [[op]], cps: [code point], size: {w, h}}` into a PDF binary."
  @spec build(map) :: binary
  def build(%{pages: pages, cps: cps, size: {pw, ph}}) do
    cids = cps |> Enum.with_index(1) |> Map.new()
    page_count = length(pages)

    page_objs =
      pages
      |> Enum.with_index()
      |> Enum.flat_map(fn {ops, k} ->
        page_no = @first_page_obj + 2 * k
        content = flate(content_stream(ops, cids))

        [
          dict(page_no, [
            "/Type /Page /Parent 2 0 R /MediaBox [0 0 #{div(pw, 100)} #{div(ph, 100)}] ",
            "/Resources << /Font << /F1 #{@font_obj} 0 R >> >> /Contents #{page_no + 1} 0 R"
          ]),
          stream(page_no + 1, "", content)
        ]
      end)

    kids = Enum.map_join(0..(page_count - 1)//1, " ", &"#{@first_page_obj + 2 * &1} 0 R")
    [asc, desc] = [Font.ascent(), Font.descent()]
    [x0, y0, x1, y1] = Font.bbox()

    objects =
      [
        dict(1, "/Type /Catalog /Pages 2 0 R"),
        dict(2, "/Type /Pages /Kids [#{kids}] /Count #{page_count}"),
        dict(@font_obj, [
          "/Type /Font /Subtype /Type0 /BaseFont /DejaVuSans /Encoding /Identity-H ",
          "/DescendantFonts [#{@cid_font_obj} 0 R] /ToUnicode #{@to_unicode_obj} 0 R"
        ]),
        dict(@cid_font_obj, [
          "/Type /Font /Subtype /CIDFontType2 /BaseFont /DejaVuSans ",
          "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> ",
          "/FontDescriptor #{@descriptor_obj} 0 R /DW 0 /W #{widths(cps)} ",
          "/CIDToGIDMap #{@cid_map_obj} 0 R"
        ]),
        dict(@descriptor_obj, [
          "/Type /FontDescriptor /FontName /DejaVuSans /Flags 32 /FontBBox [#{x0} #{y0} #{x1} #{y1}] ",
          "/ItalicAngle 0 /Ascent #{asc} /Descent #{desc} /CapHeight #{asc} /StemV 80 ",
          "/FontFile2 #{@font_file_obj} 0 R"
        ]),
        stream(@font_file_obj, "/Length1 #{byte_size(Font.data())} ", Font.data_flate()),
        stream(@cid_map_obj, "", flate(cid_to_gid(cps))),
        stream(@to_unicode_obj, "", flate(to_unicode(cps)))
      ] ++ page_objs

    assemble(objects)
  end

  defp assemble(objects) do
    header = "%PDF-1.4\n%" <> <<0xE2, 0xE3, 0xCF, 0xD3>> <> "\n"

    {bodies, {offsets, pos}} =
      Enum.map_reduce(objects, {[], byte_size(header)}, fn obj, {offs, pos} ->
        {obj, {[pos | offs], pos + IO.iodata_length(obj)}}
      end)

    size = length(objects) + 1
    entries = Enum.map(Enum.reverse(offsets), &entry/1)

    IO.iodata_to_binary([
      header,
      bodies,
      "xref\n0 #{size}\n0000000000 65535 f \n",
      entries,
      "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{pos}\n%%EOF"
    ])
  end

  defp entry(offset), do: [String.pad_leading(Integer.to_string(offset), 10, "0"), " 00000 n \n"]

  defp dict(n, body), do: ["#{n} 0 obj\n<< ", body, " >>\nendobj\n"]

  defp stream(n, extra, payload) do
    [
      "#{n} 0 obj\n<< ",
      extra,
      "/Filter /FlateDecode /Length #{byte_size(payload)} >>\nstream\n",
      payload,
      "\nendstream\nendobj\n"
    ]
  end

  defp flate(bin), do: :zlib.compress(bin)

  # -- fonts -----------------------------------------------------------------------------------

  defp cid_to_gid(cps) do
    IO.iodata_to_binary([<<0::16>> | for(cp <- cps, do: <<Font.glyph_id(cp)::16>>)])
  end

  defp widths([]), do: "[]"

  defp widths(cps) do
    ws = Enum.map_join(cps, " ", &Integer.to_string(Font.advance(Font.glyph_id(&1))))
    "[1 [#{ws}]]"
  end

  defp to_unicode(cps) do
    pairs =
      cps
      |> Enum.with_index(1)
      |> Enum.map(fn {cp, cid} -> ["<", cid4(cid), "> <", utf16_hex(cp), ">\n"] end)

    chars =
      pairs
      |> Enum.chunk_every(100)
      |> Enum.map(fn chunk ->
        ["#{length(chunk)} beginbfchar\n", chunk, "endbfchar\n"]
      end)

    IO.iodata_to_binary([
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n",
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n",
      "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n",
      "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
      chars,
      "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    ])
  end

  @doc false
  # UTF-16BE hex of one code point (a surrogate pair above the BMP).
  def utf16_hex(cp) do
    cp |> then(&<<&1::utf16-big>>) |> Base.encode16()
  end

  defp cid4(cid), do: cid |> Integer.to_string(16) |> String.pad_leading(4, "0")

  # -- page content ----------------------------------------------------------------------------

  defp content_stream(ops, cids) do
    ops |> Enum.map(&op(&1, cids)) |> IO.iodata_to_binary()
  end

  defp op({:item, lines}, cids) do
    [
      "BT\n/F1 10 Tf\n",
      for {x, y, cps} <- lines do
        ["1 0 0 1 ", num(x), " ", num(y), " Tm\n<", hex_run(cps, cids), "> Tj\n"]
      end,
      "ET\n"
    ]
  end

  defp op({:rule, x1, x2, y}, _cids) do
    ["0.5 w ", num(x1), " ", num(y), " m ", num(x2), " ", num(y), " l S\n"]
  end

  defp hex_run(cps, cids) do
    for cp <- cps, do: cid4(Map.fetch!(cids, cp))
  end

  # Integers in 1/100 point written as decimals without float formatting.
  defp num(u) when u < 0, do: ["-", num(-u)]

  defp num(u) do
    frac = u |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    [Integer.to_string(div(u, 100)), ".", frac]
  end
end
