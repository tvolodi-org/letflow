defmodule Letflow.Documents.FormPrint.Pdf do
  @moduledoc """
  The PDF side of `Letflow.Documents.FormPrint`: compiles the resolved document model to a closed
  `Letflow.Documents.PrintLayout` layout plus projection and renders it with
  `PrintLayout.render/3` (E1a/E1b code, unchanged; embeds DejaVu Sans, which has the Kazakh
  letters).

  The closed layout has one header row per table and no merged cells, so a grouped column header
  is flattened to `group: label` and the column number is a prefix (`5. ...`); the `.docx` has
  the true two-row header. Same words, two shapes. Values come only through the projection; every
  literal is a catalog label. Render errors keep the E1b mapping: `:unsupported_glyph` or
  `{:render_failed, rule_atoms}` (rule atoms only, never a value).
  """

  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.PrintLayout

  @blank "____________"

  @doc "The blank line printed for a value Letflow does not hold."
  @spec blank() :: String.t()
  def blank, do: @blank

  # The layout's `page` decides the paper: orientation from it, and `PrintLayout` takes one margin
  # for all four sides, so the widest of the four margins is used. The font is the bundled DejaVu
  # Sans at the renderer's fixed size: the font set has no serif face and `PrintLayout` has no size
  # option (see the moduledoc of `FormPrint`).
  @spec render([tuple()], %{word: String.t(), of: String.t()} | nil, map() | nil) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def render(model, footer \\ nil, page \\ nil) do
    {blocks, doc, tables} = compile(model)
    page = page || FormPrint.page(%{})

    size = if page.orientation == "landscape", do: "A4-landscape", else: "A4"
    margin = page.margins_mm |> Enum.max() |> margin_mm()

    layout = %{
      "layout_schema_version" => 1,
      "blocks" => [
        %{"type" => "page", "size" => size, "margin_mm" => margin, "font" => "dejavu-sans"}
        | blocks
      ]
    }

    projection = Map.new(tables, fn {et, {rows, _keys}} -> {et, rows} end) |> Map.put("doc", doc)

    declared =
      Map.new(tables, fn {et, {_rows, keys}} -> {et, keys} end) |> Map.put("doc", Map.keys(doc))

    case PrintLayout.render(layout, projection, declared, footer: footer) do
      {:ok, pdf} ->
        {:ok, pdf}

      {:error, violations} ->
        rules = Enum.map(violations, & &1.rule)

        if :unsupported_glyph in rules,
          do: {:error, :unsupported_glyph},
          else: {:error, {:render_failed, rules}}
    end
  end

  defp margin_mm(m) when is_float(m), do: if(m == trunc(m), do: trunc(m), else: m)
  defp margin_mm(m), do: m

  @max_chunk 12

  @doc false
  # Test seam: the blocks, document fields and the tables, `entity_type => {rows, declared keys}`.
  # Every table of the model gets its own entity types `t<i>c<j>` (table item index `i`, column
  # chunk `j`): the closed layout allows 12 columns per table, a wider table is cut into chunks
  # that repeat column 1 so a reader can match the rows. Header numbers stay the official ones.
  def compile(model) do
    {rev, doc, tables} =
      model
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, %{}}, fn {item, i}, {blocks, doc, tables} ->
        case item do
          {:text, s} ->
            {[text(s) | blocks], doc, tables}

          {:title, s} ->
            {[text(s), spacer(3) | blocks], doc, tables}

          {:proxy, s} ->
            {[text(s) | blocks], doc, tables}

          {:notice, s} ->
            {[text(s), spacer(3) | blocks], doc, tables}

          {:annex_line, s} ->
            {[Map.put(text(s), "align", "right") | blocks], doc, tables}

          {:boxed_pairs, cells} ->
            {block, entry} = cell_table(cells, "b#{i}")
            {[spacer(3), block | blocks], doc, Map.put(tables, "b#{i}", entry)}

          {:signature_table, label, values, captions, stamp} ->
            {block, entry} = cell_table(Enum.zip(captions, values), "s#{i}")
            block = Map.put(block, "header_position", "bottom")
            tail = if stamp, do: [text(stamp)], else: []

            {tail ++ [spacer(3), block, text(label) | blocks], doc,
             Map.put(tables, "s#{i}", entry)}

          {:field, label, value} ->
            name = "f#{i}"
            {[field(label, name) | blocks], Map.put(doc, name, or_blank(value)), tables}

          {:signature, label, values, captions, stamp} ->
            name = "f#{i}"
            joined = values |> Enum.map(&or_blank/1) |> Enum.join(" / ")
            caption = Enum.join(Enum.reject([stamp | captions], &is_nil/1), " / ")

            {[text(caption), field(label, name) | blocks], Map.put(doc, name, joined), tables}

          {:table, %{columns: tcols, rows: rows, total: total}} ->
            chunks = chunks(tcols)

            {tbl_blocks, tables} =
              chunks
              |> Enum.with_index()
              |> Enum.reduce({[], tables}, fn {cols, j}, {bl, tabs} ->
                et = "t#{i}c#{j}"
                keys = Enum.map(cols, fn {c, _n} -> c.key end)
                entry = {chunk_rows(rows, total, keys), keys}
                {[spacer(3), table(cols, et), spacer(3) | bl], Map.put(tabs, et, entry)}
              end)

            {tbl_blocks ++ blocks, doc, tables}
        end
      end)

    {Enum.reverse(rev), doc, tables}
  end

  # [{column, official_number}] cut into chunks of at most @max_chunk; chunk 2+ repeats column 1.
  defp chunks(tcols) do
    numbered = Enum.map(tcols, &{&1, &1.no})

    if length(numbered) <= @max_chunk do
      [numbered]
    else
      [first | _] = numbered
      {head, tail} = Enum.split(numbered, @max_chunk)
      [head | tail |> Enum.chunk_every(@max_chunk - 1) |> Enum.map(&[first | &1])]
    end
  end

  # The rows restricted to the chunk's keys, the totals row last; a totals row with every cell of
  # this chunk blank (a chunk of columns that are not summed) is left out.
  defp chunk_rows(rows, total, keys) do
    rows = Enum.map(rows, &Map.take(&1, keys))
    total = total && Map.take(total, keys)

    if total && Enum.any?(total, fn {_k, v} -> v != "" end), do: rows ++ [total], else: rows
  end

  defp text(s), do: %{"type" => "text", "text" => s}

  defp cell_table(cells, et) do
    indexed = Enum.with_index(cells)

    columns =
      Enum.map(indexed, fn {{label, _}, i} ->
        %{"field_name" => "c#{i}", "header" => label, "width" => 1}
      end)

    row = Map.new(indexed, fn {{_, value}, i} -> {"c#{i}", or_blank(value)} end)

    {%{"type" => "table", "entity_type" => et, "columns" => columns},
     {[row], Enum.map(columns, & &1["field_name"])}}
  end

  defp spacer(mm), do: %{"type" => "spacer", "height_mm" => mm}

  defp field(label, name),
    do: %{"type" => "field", "entity_type" => "doc", "field_name" => name, "label" => label}

  defp or_blank(""), do: @blank
  defp or_blank(v), do: v

  defp table(cols, entity_type) do
    columns =
      Enum.map(cols, fn {c, n} ->
        header = if c.group, do: c.group <> ": " <> c.label, else: c.label

        %{"field_name" => c.key, "header" => "#{n}. " <> header, "width" => width(n)}
      end)

    %{"type" => "table", "entity_type" => entity_type, "columns" => columns}
  end

  # By the official column number: 1 is the row number, 2 the name, the rest equal.
  defp width(1), do: 0.6
  defp width(2), do: 3
  defp width(_), do: 1.2
end
