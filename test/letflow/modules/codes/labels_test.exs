defmodule Letflow.Modules.Codes.LabelsTest do
  @moduledoc "GH #4017 / REQ-779: the label sheet renderer (L2-1..L2-13)."

  use ExUnit.Case, async: true

  alias Letflow.Modules.Codes.{Code128, Labels}

  @box_w 19_833
  @box_h 10_488
  @margin 567

  defp code(value, kind \\ "barcode", status \\ "not_assigned"),
    do: %{"value" => value, "kind" => kind, "status" => status}

  defp codes(n, kind \\ "barcode"), do: for(i <- 1..n, do: code("C#{i}", kind))

  defp rects(page), do: Enum.filter(page, &match?({:rect, _, _, _, _}, &1))
  defp texts(page), do: page |> Enum.find(&match?({:item, _}, &1)) |> elem(1)

  @tag timeout: 120_000
  test "L2-1 page counts" do
    for {n, pages} <- [{24, 1}, {25, 2}, {1000, 42}] do
      assert length(Labels.layout(codes(n)).pages) == pages
      {:ok, pdf} = Labels.render(codes(n))
      assert String.starts_with?(pdf, "%PDF-1.4")
    end
  end

  test "L2-2 label i sits at its column and row" do
    page = hd(Labels.layout(codes(25)).pages)
    xs = page |> texts() |> Enum.map(fn {x, y, _} -> {x, y} end)

    for i <- [0, 1, 3, 23] do
      {x, y} = Enum.at(xs, i)
      x0 = rem(i, 3) * @box_w
      y0 = 84_200 - 142 - (div(i, 3) + 1) * @box_h
      assert x >= x0 + @margin
      assert x <= x0 + @box_w
      assert y == y0 + @margin + 300
    end

    assert length(texts(Enum.at(Labels.layout(codes(25)).pages, 1))) == 1
  end

  test "L2-3 every rect and text stays inside its box with the margin" do
    for kind <- ["barcode", "qr"] do
      doc = Labels.layout([code("ABC-12345", kind), code("X", kind)])
      [page] = doc.pages
      y0 = 84_200 - 142 - @box_h

      for {:rect, x, y, w, h} <- rects(page), x < @box_w do
        assert x >= @margin and x + w <= @box_w - @margin
        assert y >= y0 + @margin and y + h <= y0 + @box_h - @margin
      end
    end
  end

  test "L2-4 qr: one rect per dark cell, quiet zone of 4 modules" do
    matrix = EQRCode.encode("QR-1", :m).matrix
    side = tuple_size(matrix)

    dark =
      matrix
      |> Tuple.to_list()
      |> Enum.map(&(&1 |> Tuple.to_list() |> Enum.count(fn c -> c == 1 end)))
      |> Enum.sum()

    [page] = Labels.layout([code("QR-1", "qr")]).pages
    rs = rects(page)
    assert length(rs) == dark
    qm = elem(hd(rs), 3)
    left = rs |> Enum.map(&elem(&1, 1)) |> Enum.min()
    right = rs |> Enum.map(&(elem(&1, 1) + elem(&1, 3))) |> Enum.max()
    assert left >= 4 * qm
    assert @box_w - right >= 4 * qm
    assert side > 0
  end

  test "L2-5 barcode: one rect per bar, 10 empty modules each side" do
    {:ok, widths} = Code128.encode("AB12")
    bars = widths |> Enum.take_every(2) |> length()
    [page] = Labels.layout([code("AB12")]).pages
    rs = rects(page)
    assert length(rs) == bars
    mw = rs |> hd() |> elem(3) |> div(hd(widths))
    left = rs |> Enum.map(&elem(&1, 1)) |> Enum.min()
    right = rs |> Enum.map(&(elem(&1, 1) + elem(&1, 3))) |> Enum.max()
    assert left >= 10 * mw
    assert @box_w - right >= 10 * mw
  end

  test "L2-6 equal input gives equal bytes" do
    input = [code("A1"), code("Q1", "qr")]
    assert Labels.render(input) == Labels.render(input)
  end

  test "L2-7 kind not printable" do
    for kind <- ["epc", "tid"] do
      assert Labels.render([code("A", kind)]) ==
               {:error, {:entry_invalid, 0, :kind_not_printable}}
    end
  end

  test "L2-8 retired" do
    assert Labels.render([code("A"), code("B", "barcode", "retired")]) ==
             {:error, {:entry_invalid, 1, :code_retired}}
  end

  test "L2-9 not encodable and unsupported glyph" do
    assert Labels.render([code("a\tb")]) == {:error, {:entry_invalid, 0, :value_not_encodable}}
    assert Labels.render([code("Қод")]) == {:error, {:entry_invalid, 0, :value_not_encodable}}
    assert Labels.render([code("", "qr")]) == {:error, {:entry_invalid, 0, :value_not_encodable}}

    assert Labels.render([code("a\u{10FFFD}", "qr")]) ==
             {:error, {:entry_invalid, 0, :unsupported_glyph}}

    assert {:ok, _} = Labels.render([code("Қод-1", "qr")])
  end

  test "L2-10 length and width limits" do
    assert {:ok, _} = Labels.render([code(String.duplicate("1", 20))])

    assert Labels.render([code(String.duplicate("1", 21))]) ==
             {:error, {:entry_invalid, 0, :value_too_long}}

    assert Labels.render([code(String.duplicate("W", 20), "qr")]) ==
             {:error, {:entry_invalid, 0, :value_too_long}}
  end

  test "L2-12 first failing index wins and checks are ordered" do
    assert Labels.render([code("A"), code("x", "epc", "retired"), code("\t")]) ==
             {:error, {:entry_invalid, 1, :kind_not_printable}}

    assert Labels.render([code("A"), code("\t", "barcode", "retired")]) ==
             {:error, {:entry_invalid, 1, :code_retired}}
  end

  test "L2-13 empty list" do
    assert Labels.render([]) == {:error, :no_codes}
  end

  test "non-map entries are refused without raising" do
    assert Labels.render([nil]) == {:error, {:entry_invalid, 0, :value_not_encodable}}
  end
end
