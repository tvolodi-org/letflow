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

  alias Letflow.Documents.PrintLayout

  @blank "____________"

  @doc "The blank line printed for a value Letflow does not hold."
  @spec blank() :: String.t()
  def blank, do: @blank

  @spec render([tuple()]) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def render(model) do
    {blocks, doc, lines, columns} = compile(model)

    layout = %{
      "layout_schema_version" => 1,
      "blocks" => [
        %{"type" => "page", "size" => "A4", "margin_mm" => 12, "font" => "dejavu-sans"} | blocks
      ]
    }

    projection = %{"doc" => doc, "lines" => lines}
    declared = %{"doc" => Map.keys(doc), "lines" => columns}

    case PrintLayout.render(layout, projection, declared) do
      {:ok, pdf} ->
        {:ok, pdf}

      {:error, violations} ->
        rules = Enum.map(violations, & &1.rule)

        if :unsupported_glyph in rules,
          do: {:error, :unsupported_glyph},
          else: {:error, {:render_failed, rules}}
    end
  end

  @doc false
  # Test seam: the blocks, document fields, table rows and declared column keys.
  def compile(model) do
    {rev, doc, lines, columns} =
      model
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, [], []}, fn {item, i}, {blocks, doc, lines, cols} ->
        case item do
          {:text, s} ->
            {[text(s) | blocks], doc, lines, cols}

          {:title, s} ->
            {[text(s), spacer(3) | blocks], doc, lines, cols}

          {:proxy, s} ->
            {[text(s) | blocks], doc, lines, cols}

          {:notice, s} ->
            {[text(s), spacer(3) | blocks], doc, lines, cols}

          {:field, label, value} ->
            name = "f#{i}"
            {[field(label, name) | blocks], Map.put(doc, name, or_blank(value)), lines, cols}

          {:signature, label, values, captions, stamp} ->
            name = "f#{i}"
            joined = values |> Enum.map(&or_blank/1) |> Enum.join(" / ")
            caption = Enum.join(Enum.reject([stamp | captions], &is_nil/1), " / ")

            {[text(caption), field(label, name) | blocks], Map.put(doc, name, joined), lines,
             cols}

          {:table, %{columns: tcols, rows: rows, total: total}} ->
            keys = Enum.map(tcols, & &1.key)
            all = if total, do: rows ++ [total], else: rows
            {[spacer(3), table(tcols), spacer(3) | blocks], doc, all, keys}
        end
      end)

    {Enum.reverse(rev), doc, lines, columns}
  end

  defp text(s), do: %{"type" => "text", "text" => s}
  defp spacer(mm), do: %{"type" => "spacer", "height_mm" => mm}

  defp field(label, name),
    do: %{"type" => "field", "entity_type" => "doc", "field_name" => name, "label" => label}

  defp or_blank(""), do: @blank
  defp or_blank(v), do: v

  defp table(tcols) do
    columns =
      tcols
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        header = if c.group, do: c.group <> ": " <> c.label, else: c.label

        %{
          "field_name" => c.key,
          "header" => "#{i + 1}. " <> header,
          "width" => width(i)
        }
      end)

    %{"type" => "table", "entity_type" => "lines", "columns" => columns}
  end

  defp width(0), do: 0.6
  defp width(1), do: 3
  defp width(_), do: 1.2
end
