defmodule Letflow.Documents.PrintLayout.RenderTest.PdfProbe do
  @moduledoc false
  # Test-side reader of the renderer's PDF: streams, ToUnicode, recovered text items.

  def streams(bin) do
    for [{s, l}, {ns, nl}, {ds, dl}] <-
          Regex.scan(~r/(\d+) 0 obj\n<< ([^>]*)>>\nstream\n/, bin, return: :index) do
      n = bin |> binary_part(ns, nl) |> String.to_integer()
      [_, len] = Regex.run(~r/\/Length (\d+)/, binary_part(bin, ds, dl))
      payload = binary_part(bin, s + l, String.to_integer(len))
      {n, :zlib.uncompress(payload), payload}
    end
  end

  def cmap(bin) do
    {8, text, _} = bin |> streams() |> List.keyfind(8, 0)

    ~r/<([0-9A-F]{4})> <([0-9A-F]+)>/
    |> Regex.scan(text)
    |> Map.new(fn [_, cid, hex] ->
      {String.to_integer(cid, 16),
       :unicode.characters_to_binary(Base.decode16!(hex), {:utf16, :big})}
    end)
  end

  # Recovered text of every BT/ET group, in page order (runs of a group joined with no separator).
  def items(bin) do
    cmap = cmap(bin)

    bin
    |> streams()
    |> Enum.filter(fn {n, _, _} -> n >= 10 and rem(n, 2) == 0 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_, text, _} ->
      for [_, group] <- Regex.scan(~r/BT\n(.*?)ET\n/s, text) do
        for [_, hex] <- Regex.scan(~r/<([0-9A-F]*)> Tj/, group), into: "" do
          for <<cid::binary-4 <- hex>>, into: "", do: Map.fetch!(cmap, String.to_integer(cid, 16))
        end
      end
    end)
  end

  def page_count(bin), do: length(Regex.scan(~r/\/Type \/Page \//, bin))
end

defmodule Letflow.Documents.PrintLayout.RenderTest do
  @moduledoc """
  REQ-571 / GH #3250 (decision 0068 D8 S1, part 2): `Letflow.Documents.PrintLayout.render/4`.
  Design: state/tasks/T-0570/design.md, tests R-*. Pure, no database.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.PrintLayout.{Flow, Font}
  alias Letflow.Documents.PrintLayout.RenderTest.PdfProbe

  @declared %{"order" => ["number", "total", "secret"], "line" => ["sku", "name"], "x" => ["y"]}
  @page %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"}
  @sentinel "QZXJWKVQ"

  defp layout(blocks, page \\ @page),
    do: %{"layout_schema_version" => 1, "blocks" => [page | blocks]}

  defp text(t), do: %{"type" => "text", "text" => t}

  defp field(name, extra \\ %{}),
    do: Map.merge(%{"type" => "field", "entity_type" => "order", "field_name" => name}, extra)

  defp col(name, header \\ "h", width \\ 40),
    do: %{"field_name" => name, "header" => header, "width" => width}

  defp table(cols), do: %{"type" => "table", "entity_type" => "line", "columns" => cols}

  defp render(l, proj \\ %{}, opts \\ []), do: PrintLayout.render(l, proj, @declared, opts)

  defp ok!(result) do
    assert {:ok, bin} = result
    bin
  end

  @ru for(cp <- Enum.to_list(0x410..0x44F) ++ [0x401, 0x451], into: "", do: <<cp::utf8>>)
  @kk for(
        cp <- [
          0x4D8,
          0x4D9,
          0x492,
          0x493,
          0x49A,
          0x49B,
          0x4A2,
          0x4A3,
          0x4E8,
          0x4E9,
          0x4B0,
          0x4B1,
          0x4AE,
          0x4AF,
          0x4BA,
          0x4BB,
          0x406,
          0x456
        ],
        into: "",
        do: <<cp::utf8>>
      )

  describe "validation first" do
    test "R-valid an invalid layout returns the validator's violations; a valid one a PDF" do
      bad = layout([%{"type" => "text", "text" => "x", "url" => "y"}])
      assert {:error, vs} = PrintLayout.validate(bad, @declared, [])
      assert render(bad) == {:error, vs}
      assert <<"%PDF-", _::binary>> = ok!(render(layout([text("hello")])))
    end

    test "R-locked a locked pair that no field references is refused" do
      l = layout([field("number")])

      assert {:error, [%{rule: :locked_field_missing, path: ["blocks"]}]} =
               render(l, %{}, locked: [{"order", "total"}])

      assert {:ok, _} = render(l, %{}, locked: [{"order", "number"}])
    end
  end

  describe "text" do
    test "R-literal URLs and placeholders are ordinary text; nothing is substituted" do
      l = layout([text("http://example.test"), text("{{x.y}}")])
      bin = ok!(render(l, %{"x" => %{"y" => "SUBST"}}))
      assert PdfProbe.items(bin) == ["http://example.test", "{{x.y}}"]
    end

    test "R-glyph-ru-kk RU and KK letters in both cases come back exactly, in a literal and a field" do
      sample = @ru <> " " <> @kk <> " test sample"
      l = layout([text(sample), field("number", %{"label" => "lbl"})])
      bin = ok!(render(l, %{"order" => %{"number" => sample}}))
      assert PdfProbe.items(bin) == [sample, "lbl: " <> sample]
      refute Enum.any?(PdfProbe.items(bin), &(&1 =~ "?"))
    end

    test "R-nbsp a space and a no-break space recover separately" do
      s = "a b c"
      assert PdfProbe.items(ok!(render(layout([text(s)])))) == [s]
    end

    test "R-wrap wrapped text recovers exactly at several widths" do
      words = String.duplicate("lorem  ipsum dolor ", 25)
      long = String.duplicate("W", 200)

      for page <- [
            @page,
            %{@page | "margin_mm" => 50},
            %{@page | "size" => "Letter", "margin_mm" => 50}
          ],
          s <- [words, long, "one two three four"] do
        assert PdfProbe.items(ok!(render(layout([text(s)], page)))) == [s]
      end

      assert PdfProbe.items(ok!(render(layout([text("a\nb\r\nc")])))) == ["abc"]
    end

    test "R-show-if hides label and value when empty" do
      l = layout([field("number", %{"label" => "lbl", "show_if_nonempty" => true})])

      for v <- ["", nil, "  "] do
        assert PdfProbe.items(ok!(render(l, %{"order" => %{"number" => v}}))) == []
      end

      assert PdfProbe.items(ok!(render(l, %{"order" => %{"number" => "7"}}))) == ["lbl: 7"]
      assert PdfProbe.items(ok!(render(l, %{}))) == []
    end

    test "numbers, booleans and decimals are printed as text" do
      l = layout([field("number"), field("total"), field("secret")])
      proj = %{"order" => %{"number" => 12, "total" => Decimal.new("1.50"), "secret" => true}}
      assert PdfProbe.items(ok!(render(l, proj))) == ["12", "1.50", "true"]
    end
  end

  describe "active content and structure" do
    @names ~w(/JS /JavaScript /OpenAction /AA /Launch /URI /GoTo /GoToR /SubmitForm /Annots
              /AcroForm /EmbeddedFile /CreationDate /ModDate /Producer /Info)

    test "R-text-only no action, form, embedded file, date or producer marker" do
      l =
        layout(
          [
            "/JavaScript",
            "/JS (alert(1))",
            "/Launch",
            "/URI (http://example.test)",
            "/OpenAction"
          ]
          |> Enum.map(&text/1)
        )

      bin = ok!(render(l))
      streams = PdfProbe.streams(bin)

      for name <- @names do
        refute bin =~ name, "raw bytes contain #{name}"

        for {n, inflated, _} <- streams do
          refute inflated =~ name, "stream #{n} contains #{name}"
        end
      end
    end

    test "R-determinism equal inputs give equal bytes" do
      l = layout([text("same"), field("number")])
      p1 = %{"order" => %{"number" => "1", "total" => "2"}}
      p2 = Map.new(Enum.reverse(Map.to_list(p1)))
      assert ok!(render(l, p1)) == ok!(render(l, p2))
      assert ok!(render(l, p1)) == ok!(render(l, p1))
    end

    test "R-font-objects the CID font, its maps and the whole font are embedded" do
      bin = ok!(render(layout([text("Привет")])))

      for part <- ~w(/Type0 /Identity-H /CIDFontType2 /CIDToGIDMap /W /ToUnicode /FontFile2) do
        assert bin =~ part
      end

      {6, font, _} = bin |> PdfProbe.streams() |> List.keyfind(6, 0)
      assert font == File.read!(Path.join(["priv", "fonts", "DejaVuSans.ttf"]))
      assert File.exists?(Path.join(["priv", "fonts", "DejaVuSans.LICENSE"]))
    end

    test "R-xref every offset points at its object; Size and trailer are right" do
      bin = ok!(render(layout([text("x"), table([col("sku")])]), %{"line" => [%{"sku" => "a"}]}))
      assert binary_part(bin, byte_size(bin), -5) == "%%EOF"
      [_, start] = Regex.run(~r/startxref\n(\d+)\n%%EOF$/, bin)
      assert binary_part(bin, String.to_integer(start), 4) == "xref"

      [_, size, rest] = Regex.run(~r/xref\n0 (\d+)\n(.*)trailer/s, bin)
      size = String.to_integer(size)
      entries = rest |> String.split("\n", trim: true)
      assert length(entries) == size
      assert bin =~ "/Size #{size} "

      for {entry, n} <- Enum.with_index(entries), n > 0 do
        assert byte_size(entry) == 19
        [off, "00000", "n", ""] = String.split(entry, " ")
        assert binary_part(bin, String.to_integer(off), byte_size("#{n} 0 obj")) == "#{n} 0 obj"
      end
    end

    test "R-pagesize A4 and Letter media boxes" do
      assert ok!(render(layout([]))) =~ "/MediaBox [0 0 595 842]"
      assert ok!(render(layout([], %{@page | "size" => "Letter"}))) =~ "/MediaBox [0 0 612 792]"
    end
  end

  describe "unsupported glyphs" do
    test "R-unsupported no glyph is an error, never a '?' or an empty box; no value in the error" do
      cp = Enum.find(0x3400..0x4DBF, &(Font.glyph_id(&1) == nil))
      bad = "TOPSECRET" <> <<cp::utf8>> <> "TAIL"
      proj = %{"order" => %{"number" => bad}, "line" => [%{"sku" => bad}]}

      cases = [
        {layout([field("number")]), proj, ["blocks", 1, "field_name"]},
        {layout([text(bad)]), proj, ["blocks", 1, "text"]},
        {layout([field("number", %{"label" => bad})]), proj, ["blocks", 1, "label"]},
        {layout([table([col("sku", bad)])]), %{}, ["blocks", 1, "columns", 0, "header"]},
        {layout([table([col("sku")])]), proj, ["blocks", 1, "columns", 0, "field_name"]}
      ]

      for {l, p, path} <- cases do
        assert {:error, [%{rule: :unsupported_glyph, path: ^path}] = err} = render(l, p)
        out = inspect(err)
        refute out =~ <<cp::utf8>>
        refute out =~ "TOPSECRET"
        refute out =~ "TAIL"
      end

      ctl = %{"order" => %{"number" => "a\u0007b"}}
      assert {:error, [%{rule: :unsupported_glyph}]} = render(layout([field("number")]), ctl)
    end
  end

  describe "projection reads" do
    @sentinel_encodings [
      {"utf8", @sentinel},
      {"utf16", :unicode.characters_to_binary(@sentinel, :utf8, {:utf16, :big})},
      {"latin1", :unicode.characters_to_binary(@sentinel, :utf8, :latin1)},
      {"gid", for(<<c <- @sentinel>>, into: <<>>, do: <<Font.glyph_id(c)::16>>)}
    ]

    defp assert_no_sentinel(bin, extra) do
      streams = if bin == "", do: [], else: PdfProbe.streams(bin)

      for {name, enc} <- @sentinel_encodings do
        refute extra =~ enc, "#{name} in output"
        refute bin =~ enc, "#{name} in raw bytes"

        for {n, inflated, _} <- streams, not (name == "gid" and n == 6) do
          refute inflated =~ enc, "#{name} in stream #{n}"
        end
      end

      if bin != "",
        do: refute(Enum.any?(Map.values(PdfProbe.cmap(bin)), &String.contains?(@sentinel, &1)))
    end

    test "R-sentinel-a a layout naming an excluded pair never reads it" do
      proj = %{"order" => %{"number" => "n", "secret" => @sentinel, "hidden" => @sentinel}}
      l = layout([field("secret"), field("hidden"), field("number")])

      log =
        capture_log(fn ->
          send(self(), {:res, render(l, proj, restricted: [{"order", "secret"}])})
        end)

      assert_received {:res, {:error, vs} = err}
      assert [%{rule: :field_restricted}, %{rule: :field_not_projected}] = vs
      assert_no_sentinel("", inspect(err) <> log)
    end

    test "R-sentinel-b a valid layout over a wider projection leaves the extra values out" do
      proj = %{
        "order" => %{"number" => "n1", "secret" => @sentinel, "extra" => @sentinel},
        "line" => [%{"sku" => "s1", "name" => @sentinel, "other" => @sentinel}],
        "other" => %{"a" => @sentinel}
      }

      l = layout([text("order doc"), field("number"), table([col("sku", "sku")])])
      log = capture_log(fn -> send(self(), {:res, render(l, proj)}) end)
      assert_received {:res, {:ok, bin}}
      assert_no_sentinel(bin, log)
      assert PdfProbe.items(bin) == ["order doc", "n1", "sku", "s1"]
    end

    test "R-projection-shape a projection that is not a map, or a wrong-shaped entry, is a violation" do
      l = layout([field("number")])

      for p <- [nil, [], "x"] do
        assert render(l, p) == {:error, [%{rule: :invalid_projection, path: []}]}
      end

      assert render(l, %{"order" => [1]}) ==
               {:error, [%{rule: :invalid_projection, path: ["blocks", 1]}]}

      t = layout([table([col("sku")])])

      assert render(t, %{"line" => %{}}) ==
               {:error, [%{rule: :invalid_projection, path: ["blocks", 1]}]}

      assert render(t, %{"line" => [1]}) ==
               {:error, [%{rule: :invalid_projection, path: ["blocks", 1]}]}

      assert render(layout([field("number")]), %{"order" => %{"number" => self()}}) ==
               {:error, [%{rule: :unrenderable_value, path: ["blocks", 1, "field_name"]}]}
    end
  end

  describe "tables" do
    @tag timeout: 20_000
    test "R-narrow-col columns narrower than a glyph still terminate" do
      cols = for j <- 0..11, do: col("sku", "h", if(rem(j, 2) == 0, do: 1, else: 100))
      l = layout([table(cols)])

      assert {:ok, _} = render(l, %{"line" => [%{"sku" => "ab"}]})

      assert render(l, %{"line" => [%{"sku" => String.duplicate("x", 400)}]}) ==
               {:error, [%{rule: :row_too_tall, path: ["blocks", 1]}]}

      input = String.to_charlist("some words here")

      for w <- [0, -500] do
        assert Enum.concat(Flow.wrap(input, w)) == input
      end
    end

    test "R-tiny-weights weights that round to zero do not divide by zero" do
      l = layout([table([col("sku", "a", 0.0001), col("name", "b", 0.0001)])])
      p = %{"line" => [%{"sku" => "s", "name" => "n"}]}
      assert PdfProbe.items(ok!(render(l, p))) == ["a", "b", "s", "n"]
    end

    test "R-row-tall a cell longer than a page is a violation without the value" do
      l = layout([table([col("sku", "h", 100)])])

      assert {:error, [%{rule: :row_too_tall, path: ["blocks", 1]}] = err} =
               render(l, %{"line" => [%{"sku" => String.duplicate("QQ", 20_000)}]})

      refute inspect(err) =~ "QQ"
    end

    @tag timeout: 120_000
    test "R-rows-1000 / R-multipage 1000 rows render over several pages, 1001 are refused" do
      rows = for i <- 1..1000, do: %{"sku" => "S#{i}", "name" => "n#{i}"}
      l = layout([table([col("sku", "SKU"), col("name", "Name")])])
      bin = ok!(render(l, %{"line" => rows}))
      assert <<"%PDF-", _::binary>> = bin
      assert binary_part(bin, byte_size(bin), -5) == "%%EOF"

      pages = PdfProbe.page_count(bin)
      assert pages > 1
      assert bin =~ "/Count #{pages} "

      expected = ["SKU", "Name"] ++ Enum.flat_map(rows, &[&1["sku"], &1["name"]])
      assert PdfProbe.items(bin) == expected

      assert render(l, %{"line" => [%{"sku" => "x"} | rows]}) ==
               {:error, [%{rule: :too_many_rows, path: ["blocks", 1]}]}
    end
  end

  describe "documentation" do
    test "R-doc the moduledoc states the rules and cites the records" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(PrintLayout)

      for part <- [
            "pure function",
            "0068 D2",
            "0068 D5",
            "0033",
            "ISS-0679",
            "certificate_document.ex",
            "Q2",
            "Q5",
            "DejaVuSans.LICENSE",
            "the first renderer with a Unicode font path"
          ] do
        assert doc =~ part, "moduledoc lacks #{part}"
      end
    end
  end
end
