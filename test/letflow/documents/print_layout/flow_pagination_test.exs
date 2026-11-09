defmodule Letflow.Documents.PrintLayout.FlowPaginationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  T-1555 (BA batch 2, item 3): page breaks of `PrintLayout.Flow`. Tables repeat their header on
  every page (F1, F3), a heading and a short table are kept together (F4), no header word is broken
  in the middle (F5, F6), a row taller than a page is still refused (F2). Pure, no database.
  """

  alias Letflow.Documents.PrintLayout.Flow

  @page %{"type" => "page", "size" => "A4", "margin_mm" => 12, "font" => "dejavu-sans"}

  defp col(field, header, width \\ 1),
    do: %{"field_name" => field, "header" => header, "width" => width}

  defp table(cols), do: %{"type" => "table", "entity_type" => "line", "columns" => cols}

  defp run(blocks, rows, page \\ @page),
    do: Flow.run(%{"blocks" => [page | blocks]}, %{"line" => rows})

  # Per page: the text of every item (one cell = one item, its lines joined).
  defp page_texts({:ok, %{pages: pages}}) do
    for page <- pages do
      for {:item, lines} <- page,
          do: lines |> Enum.map(fn {_x, _y, l} -> List.to_string(l) end) |> Enum.join()
    end
  end

  defp rows(n), do: for(i <- 1..n, do: %{"a" => "a#{i}", "b" => "b#{i}"})

  test "F1 90 rows run over several pages, each row once and in order" do
    texts = [table([col("a", "Code"), col("b", "Name")])] |> run(rows(90)) |> page_texts()
    assert length(texts) > 1
    data = texts |> List.flatten() |> Enum.reject(&(&1 in ["Code", "Name"]))
    assert data == Enum.flat_map(rows(90), &[&1["a"], &1["b"]])
  end

  test "F3 every page of a table starts with the header cells" do
    texts = [table([col("a", "Code"), col("b", "Name")])] |> run(rows(90)) |> page_texts()
    assert length(texts) > 1
    for page <- texts, do: assert(Enum.take(page, 2) == ["Code", "Name"])
  end

  test "F2 a row taller than a page is still refused" do
    big = [%{"a" => String.duplicate("QQ ", 20_000), "b" => "x"}]

    assert {:error, [%{rule: :row_too_tall, path: ["blocks", 1]}]} =
             run([table([col("a", "Code"), col("b", "Name")])], big)
  end

  test "F4 a heading and its short table are never split across pages" do
    # leaves about 3100 u on the page: the heading (1400) fits, the heading and the table (6200) do not
    blocks = [
      %{"type" => "spacer", "height_mm" => 262},
      %{"type" => "text", "text" => "Signatures"},
      table([col("a", "Role"), col("b", "Name")])
    ]

    [p1, p2] = blocks |> run(rows(2)) |> page_texts()
    refute "Signatures" in p1
    assert Enum.take(p2, 3) == ["Signatures", "Role", "Name"]
    assert Enum.drop(p2, 3) == ["a1", "b1", "a2", "b2"]
  end

  test "F4b when the heading and table fit, they stay on the page" do
    blocks = [
      %{"type" => "text", "text" => "Signatures"},
      table([col("a", "Role"), col("b", "Name")])
    ]

    assert [page] = blocks |> run(rows(2)) |> page_texts()
    assert hd(page) == "Signatures"
  end

  test "F4c a header is never left alone at the foot of a page" do
    # a long table starting with only room for the header: header and first row move together
    blocks = [
      %{"type" => "spacer", "height_mm" => 265},
      table([col("a", "Code"), col("b", "Name")])
    ]

    [p1, p2 | _] = blocks |> run(rows(30)) |> page_texts()
    assert p1 == []
    assert Enum.take(p2, 4) == ["Code", "Name", "a1", "b1"]
  end

  test "F5 no header word is broken in the middle when the columns can hold their words" do
    cols = [
      col("a", "No", 0.05),
      col("b", "Personnel number", 0.1),
      col("c", "Nomenclature", 0.1),
      col("d", "Description", 0.75)
    ]

    {:ok, %{pages: [page]}} =
      run([table(cols)], [%{"a" => "1", "b" => "2", "c" => "3", "d" => "4"}])

    whole = ["No", "Personnel", "number", "Nomenclature", "Description"]

    for {:item, lines} <- Enum.take(page, 4), {_x, _y, l} <- lines do
      assert l |> List.to_string() |> String.split() |> Enum.all?(&(&1 in whole))
    end
  end

  test "F5b the same holds for Cyrillic and Kazakh header words" do
    cols = [
      col("a", "Табельный номер", 0.02),
      col("b", "Номенклатуралық нөмірі", 0.02),
      col("c", "x", 0.96)
    ]

    {:ok, %{pages: [page]}} = run([table(cols)], [%{"a" => "1", "b" => "2", "c" => "3"}])
    whole = ["Табельный", "номер", "Номенклатуралық", "нөмірі", "x"]

    for {:item, lines} <- Enum.take(page, 3), {_x, _y, l} <- lines do
      assert l |> List.to_string() |> String.split() |> Enum.all?(&(&1 in whole))
    end
  end

  test "F6 minimum widths that cannot all fit keep the proportional widths (no crash)" do
    cols = for i <- 1..12, do: col("c#{i}", String.duplicate("W", 40), 1)
    row = Map.new(1..12, &{"c#{&1}", "v"})
    assert {:ok, %{pages: [_ | _]}} = run([table(cols)], [row])
  end

  test "A4-landscape is a page size" do
    assert Flow.page_size("A4-landscape") == {84_200, 59_500}
    assert {:ok, %{size: {84_200, 59_500}}} = run([], [], %{@page | "size" => "A4-landscape"})
  end
end
