defmodule Letflow.Documents.PrintLayout.MergedHeaderTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.PrintLayout.Flow

  @page %{"type" => "page", "size" => "A4", "margin_mm" => 20, "font" => "dejavu-sans"}
  @cells [
    %{"text" => "Results", "start" => 0, "span" => 2, "row" => 0, "rowspan" => 1},
    %{"text" => "Quantity", "start" => 0, "span" => 1, "row" => 1, "rowspan" => 1},
    %{"text" => "Sum", "start" => 1, "span" => 1, "row" => 1, "rowspan" => 1}
  ]
  @table %{
    "type" => "table",
    "entity_type" => "lines",
    "header_cells" => @cells,
    "columns" => [
      %{"field_name" => "q", "header" => "Quantity", "width" => 1},
      %{"field_name" => "s", "header" => "Sum", "width" => 1}
    ]
  }
  @declared %{"lines" => ["q", "s"]}
  defp layout(t), do: %{"layout_schema_version" => 1, "blocks" => [@page, t]}

  test "MH1 rejects malformed, overlapping, incomplete and excessive headers" do
    assert :ok = PrintLayout.validate(layout(@table), @declared)

    for cells <- [
          nil,
          [],
          [%{}],
          [Enum.at(@cells, 1)],
          @cells ++ [Enum.at(@cells, 1)],
          List.replace_at(@cells, 0, Map.put(hd(@cells), "start", -1)),
          List.replace_at(@cells, 0, Map.put(hd(@cells), "span", 3)),
          List.replace_at(@cells, 0, Map.put(hd(@cells), "rowspan", "2")),
          List.replace_at(@cells, 0, Map.put(hd(@cells), "text", <<255>>)),
          List.replace_at(@cells, 0, Map.put(hd(@cells), "text", String.duplicate("x", 501))),
          List.replace_at(@cells, 0, Map.put(hd(@cells), "url", "bad"))
        ] do
      assert {:error, _} =
               PrintLayout.validate(layout(Map.put(@table, "header_cells", cells)), @declared)
    end

    assert {:error, _} =
             PrintLayout.validate(layout(Map.put(@table, "header_position", "bottom")), @declared)
  end

  test "MH2 headers repeat, rows stay once, and the parent has no internal vertical rule" do
    rows = for i <- 1..90, do: %{"q" => "Q#{i}", "s" => "S#{i}"}
    assert {:ok, doc} = Flow.run(layout(@table), %{"lines" => rows})
    assert length(doc.pages) > 1

    texts =
      for page <- doc.pages do
        for {:item, runs} <- page,
            do: Enum.map_join(runs, fn {_, _, cps} -> List.to_string(cps) end)
      end

    for page <- texts, do: assert(Enum.take(page, 3) == ["Results", "Quantity", "Sum"])

    assert texts |> List.flatten() |> Enum.reject(&(&1 in ~w(Results Quantity Sum))) ==
             Enum.flat_map(rows, &[&1["q"], &1["s"]])

    # First parent cell spans the full content width; only its two edges reach the top.
    top = 84_200 - doc.margin
    rules = for {:vrule, x, _, ^top} <- hd(doc.pages), do: x
    assert Enum.uniq(rules) |> Enum.sort() == [doc.margin, 59_500 - doc.margin]

    assert {:ok, <<"%PDF", _::binary>>} =
             PrintLayout.render(layout(@table), %{"lines" => rows}, @declared)
  end

  test "MH4 table font size controls wrapping and PDF text operators" do
    t = Map.put(@table, "font_pt", 8)
    assert {:ok, doc} = Flow.run(layout(t), %{"lines" => [%{"q" => "14", "s" => "26"}]})
    assert Enum.any?(hd(doc.pages), &match?({:item, _, 8}, &1))

    assert {:ok, <<"%PDF", _::binary>>} =
             PrintLayout.render(layout(t), %{"lines" => []}, @declared)

    assert {:ok, large} = Flow.run(layout(Map.put(t, "font_pt", 24)), %{"lines" => []})
    assert Enum.any?(hd(large.pages), &match?({:item, _, 24}, &1))
    # A 24pt line needs at least its font height, rather than the default 12pt leading.
    heights = for {:vrule, _, bottom, top} <- hd(large.pages), do: top - bottom
    assert Enum.min(heights) >= 2400

    for size <- [nil, "8", 0, 25] do
      assert {:error, _} = PrintLayout.validate(layout(Map.put(t, "font_pt", size)), @declared)
    end
  end

  test "MH5 wider merged tables remain bounded and preserve field restrictions" do
    for n <- [14, 15, 16] do
      t =
        @table
        |> Map.put("columns", List.duplicate(hd(@table["columns"]), n))
        |> Map.put("header_cells", [
          %{"text" => "Results", "start" => 0, "span" => n, "row" => 0, "rowspan" => 1}
        ])

      if n <= 15 do
        assert :ok = PrintLayout.validate(layout(t), @declared)

        assert {:error, vs} =
                 PrintLayout.validate(layout(t), @declared, restricted: [{"lines", "q"}])

        assert Enum.any?(vs, &(&1.rule == :field_restricted))
      else
        assert {:error, vs} = PrintLayout.validate(layout(t), @declared)
        assert Enum.any?(vs, &(&1.rule == :too_many_columns))
      end
    end
  end

  test "MH3 oversized merged headers and unsupported glyphs fail without crashing" do
    for {text, rule} <- [{String.duplicate("W", 500), :row_too_tall}, {"􏿿", :unsupported_glyph}] do
      table =
        @table
        |> put_in(["columns", Access.at(0), "width"], 0.001)
        |> put_in(["header_cells", Access.at(1), "text"], text)

      # A narrow column forces a tall header even at the 500-character literal cap.
      l = layout(table)
      assert {:error, vs} = PrintLayout.render(l, %{"lines" => []}, @declared)
      assert Enum.any?(vs, &(&1.rule == rule))
    end
  end
end
