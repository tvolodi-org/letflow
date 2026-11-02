defmodule Letflow.XlsxFixture do
  @moduledoc """
  Builds small `.xlsx` workbooks in memory for the xlsx import tests (GH #3603, REQ-650).
  Hand-written minimal OOXML parts zipped with OTP `:zip`; no file on disk, no dependency.

  A sheet is a list of rows, a row a list of cells. A cell is `nil` (no `<c>` element), a
  binary (shared string), a number, a boolean, `{:date, serial}` (date format) or
  `{:datetime, serial}` (date-and-time format), `{:formula, cached_value}` (a formula cell
  with a cached number) or `{:raw, xml}` for anything else.
  """

  @doc """
  The workbook bytes for `sheets` (a list of sheets; each sheet a list of rows).

  Options: `replace: %{part_name => binary}` swaps a part, `extra: [{part_name, binary}]` adds
  parts.
  """
  @spec build([[[term()]]], keyword()) :: binary()
  def build(sheets, opts \\ []) do
    strings = sheets |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.uniq()
    index = strings |> Enum.with_index() |> Map.new()
    count = length(sheets)

    sheet_parts =
      for {rows, i} <- Enum.with_index(sheets, 1) do
        {~c"xl/worksheets/sheet#{i}.xml", sheet_xml(rows, index)}
      end

    parts =
      [
        {~c"[Content_Types].xml", content_types(count)},
        {~c"_rels/.rels", root_rels()},
        {~c"xl/workbook.xml", workbook(count)},
        {~c"xl/_rels/workbook.xml.rels", workbook_rels(count)},
        {~c"xl/styles.xml", styles()},
        {~c"xl/sharedStrings.xml", shared_strings(strings)}
      ] ++ sheet_parts

    replace = Keyword.get(opts, :replace, %{})

    parts =
      Enum.map(parts, fn {name, body} -> {name, Map.get(replace, to_string(name), body)} end) ++
        for {name, body} <- Keyword.get(opts, :extra, []), do: {to_charlist(name), body}

    {:ok, {_name, zip}} = :zip.create(~c"book.xlsx", parts, [:memory])
    zip
  end

  defp content_types(count) do
    sheets =
      for i <- 1..count,
          do:
            ~s(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
      ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
      ~s(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>) <>
      ~s(<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>) <>
      Enum.join(sheets) <> "</Types>"
  end

  defp root_rels do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>) <>
      "</Relationships>"
  end

  defp workbook(count) do
    sheets =
      for i <- 1..count,
          do: ~s(<sheet name="Sheet#{i}" sheetId="#{i}" r:id="rId#{i}"/>)

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">) <>
      "<sheets>" <> Enum.join(sheets) <> "</sheets></workbook>"
  end

  defp workbook_rels(count) do
    sheets =
      for i <- 1..count,
          do:
            ~s(<Relationship Id="rId#{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i}.xml"/>)

    extra = [
      ~s(<Relationship Id="rId#{count + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>),
      ~s(<Relationship Id="rId#{count + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>)
    ]

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      Enum.join(sheets ++ extra) <> "</Relationships>"
  end

  # xf 0 general, xf 1 date (numFmt 14), xf 2 date and time (numFmt 22)
  defp styles do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
      ~s(<cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>) <>
      ~s(<cellXfs count="3"><xf numFmtId="0" xfId="0"/><xf numFmtId="14" xfId="0" applyNumberFormat="1"/><xf numFmtId="22" xfId="0" applyNumberFormat="1"/></cellXfs>) <>
      "</styleSheet>"
  end

  defp shared_strings(strings) do
    items = for s <- strings, do: ~s(<si><t xml:space="preserve">#{escape(s)}</t></si>)

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="#{length(strings)}" uniqueCount="#{length(strings)}">) <>
      Enum.join(items) <> "</sst>"
  end

  defp sheet_xml(rows, index) do
    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join(fn {cells, r} ->
        cells_xml =
          cells
          |> Enum.with_index()
          |> Enum.map_join(fn {cell, c} -> cell_xml(cell, ref(c, r), index) end)

        ~s(<row r="#{r}">#{cells_xml}</row>)
      end)

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>) <>
      body <> "</sheetData></worksheet>"
  end

  defp ref(c, r), do: <<?A + c>> <> Integer.to_string(r)

  defp cell_xml(nil, _ref, _index), do: ""

  defp cell_xml(text, ref, index) when is_binary(text),
    do: ~s(<c r="#{ref}" t="s"><v>#{Map.fetch!(index, text)}</v></c>)

  defp cell_xml(true, ref, _index), do: ~s(<c r="#{ref}" t="b"><v>1</v></c>)
  defp cell_xml(false, ref, _index), do: ~s(<c r="#{ref}" t="b"><v>0</v></c>)

  defp cell_xml(n, ref, _index) when is_number(n), do: ~s(<c r="#{ref}" s="0"><v>#{n}</v></c>)

  defp cell_xml({:date, serial}, ref, _index), do: ~s(<c r="#{ref}" s="1"><v>#{serial}</v></c>)

  defp cell_xml({:datetime, serial}, ref, _index),
    do: ~s(<c r="#{ref}" s="2"><v>#{serial}</v></c>)

  defp cell_xml({:formula, cached}, ref, _index),
    do: ~s(<c r="#{ref}"><f>1+2</f><v>#{cached}</v></c>)

  defp cell_xml({:raw, xml}, _ref, _index), do: xml

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
