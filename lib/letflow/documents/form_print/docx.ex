defmodule Letflow.Documents.FormPrint.Docx do
  @moduledoc """
  The `.docx` side of `Letflow.Documents.FormPrint`: a zip of WordprocessingML written with OTP
  `:zip` and string templates (no dependency; the repo has no docx library).

  Parts: `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/styles.xml`,
  `word/_rels/document.xml.rels`. A4 landscape, Times New Roman 10 pt, single-border table with
  the true merged group header (`w:gridSpan` / `w:vMerge`) and the numbers row. Every text goes
  through `escape/1` (`& < > " '`); the model's texts were already stripped of XML-illegal
  characters by `FormPrint.clean/1`, and labels come from the catalog, so no data can break the
  package. There is no `docProps` and the zip entries carry a fixed time, so equal inputs give
  equal bytes.
  """

  alias Letflow.Documents.FormPrint.Pdf

  @ns ~s(xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  @decl ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
  @fixed_time {{1980, 1, 1}, {0, 0, 0}}
  # Table header cells print small so a header word is not broken in a narrow column (T-1555).
  @head_size 14

  @spec render([tuple()]) :: {:ok, binary()}
  def render(model) do
    body = model |> Enum.map(&block/1) |> IO.iodata_to_binary()

    sect =
      ~s(<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>) <>
        ~s(<w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" w:header="360" w:footer="360" w:gutter="0"/></w:sectPr>)

    document = @decl <> "<w:document #{@ns}><w:body>" <> body <> sect <> "</w:body></w:document>"

    files = [
      {"[Content_Types].xml", content_types()},
      {"_rels/.rels", rels()},
      {"word/document.xml", document},
      {"word/styles.xml", styles()},
      {"word/_rels/document.xml.rels", doc_rels()}
    ]

    entries =
      Enum.map(files, fn {name, bin} -> {String.to_charlist(name), bin, file_info(bin)} end)

    {:ok, {_name, zip}} = :zip.create(~c"form.docx", entries, [:memory])
    {:ok, zip}
  end

  # {:file_info, size, type, access, atime, mtime, ctime, mode, links, major, minor, inode, uid, gid}
  defp file_info(bin) do
    {:file_info, byte_size(bin), :regular, :read_write, @fixed_time, @fixed_time, @fixed_time,
     0o644, 1, 0, 0, 0, 0, 0}
  end

  @doc "XML text escape."
  @spec escape(String.t()) :: String.t()
  def escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # -- blocks -----------------------------------------------------------------------------------

  defp block({:text, s}), do: para([run(s)])
  defp block({:title, s}), do: para([run(s, bold: true, size: 28)], center: true)
  defp block({:proxy, s}), do: para([run(s)])
  defp block({:notice, s}), do: para([run(s, italic: true)])

  defp block({:field, label, value}),
    do: para([run(label <> ": "), run(or_blank(value), bold: value != "")])

  defp block({:signature, label, values, captions, stamp}) do
    joined = values |> Enum.map(&or_blank/1) |> Enum.join(" / ")
    caption = Enum.join(Enum.reject([stamp | captions], &is_nil/1), " / ")
    [para([run(label <> " "), run(joined)], keep_next: true), para([run(caption, size: 16)])]
  end

  defp block({:table, %{columns: columns, rows: rows, total: total}}) do
    grouped? = Enum.any?(columns, & &1.group)
    chunks = chunk(columns)

    header =
      if grouped? do
        top =
          Enum.map(chunks, fn
            {nil, [c]} -> cell(c.label, merge: :restart, bold: true)
            {group, cs} -> cell(group, span: length(cs), bold: true)
          end)

        bottom =
          Enum.flat_map(chunks, fn
            {nil, [_]} -> [cell("", merge: :continue)]
            {_group, cs} -> Enum.map(cs, &cell(&1.label, bold: true))
          end)

        [row(top, :head), row(bottom, :head)]
      else
        [row(Enum.map(columns, &cell(&1.label, bold: true)), :head)]
      end

    numbers =
      row(Enum.map(columns, fn c -> cell(Integer.to_string(c.no), center: true) end), :head)

    keys = Enum.map(columns, & &1.key)

    data_rows =
      Enum.map(rows ++ List.wrap(total), fn r -> row(Enum.map(keys, &cell(r[&1] || ""))) end)

    grid = Enum.map(columns, fn c -> ~s(<w:gridCol w:w="#{col_width(c.no, columns)}"/>) end)

    [
      para([]),
      "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>",
      "<w:tblBorders>",
      for(
        side <- ~w(top left bottom right insideH insideV),
        do: ~s(<w:#{side} w:val="single" w:sz="4" w:space="0" w:color="000000"/>)
      ),
      "</w:tblBorders></w:tblPr><w:tblGrid>",
      grid,
      "</w:tblGrid>",
      header,
      numbers,
      data_rows,
      "</w:tbl>",
      para([])
    ]
  end

  # Consecutive columns with the same group label form one chunk; no group = a chunk of one.
  defp chunk(columns) do
    columns
    |> Enum.chunk_while(
      nil,
      fn
        c, nil -> {:cont, {c.group, [c]}}
        %{group: g} = c, {g, cs} when not is_nil(g) -> {:cont, {g, cs ++ [c]}}
        c, acc -> {:cont, acc, {c.group, [c]}}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  # By the official column number: 1 is the row number, 2 the name, the others share the rest.
  defp col_width(1, _columns), do: 900
  defp col_width(2, _columns), do: 3000

  defp col_width(_no, columns) do
    used = columns |> Enum.map(&fixed_width(&1.no)) |> Enum.sum()
    others = Enum.count(columns, &(fixed_width(&1.no) == 0))
    div(15400 - used, max(others, 1))
  end

  defp fixed_width(1), do: 900
  defp fixed_width(2), do: 3000
  defp fixed_width(_), do: 0

  defp or_blank(""), do: Pdf.blank()
  defp or_blank(v), do: v

  # -- xml helpers ------------------------------------------------------------------------------

  defp para(runs, opts \\ []) do
    inner =
      [
        if(opts[:keep_next], do: "<w:keepNext/>"),
        if(opts[:center], do: ~s(<w:jc w:val="center"/>))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    ppr = if inner == "", do: "", else: "<w:pPr>#{inner}</w:pPr>"
    ["<w:p>", ppr, runs, "</w:p>"]
  end

  defp run(text, opts \\ []) do
    rpr =
      [
        if(opts[:bold], do: "<w:b/>"),
        if(opts[:italic], do: "<w:i/>"),
        if(opts[:size], do: ~s(<w:sz w:val="#{opts[:size]}"/>))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    rpr = if rpr == "", do: "", else: "<w:rPr>#{rpr}</w:rPr>"
    ~s(<w:r>#{rpr}<w:t xml:space="preserve">#{escape(text)}</w:t></w:r>)
  end

  # A row never splits across pages; header rows repeat at the top of each page of the table.
  defp row(cells, kind \\ :data) do
    pr = if kind == :head, do: "<w:cantSplit/><w:tblHeader/>", else: "<w:cantSplit/>"
    ["<w:tr><w:trPr>", pr, "</w:trPr>", cells, "</w:tr>"]
  end

  defp cell(text, opts \\ []) do
    pr =
      [
        if(opts[:span], do: ~s(<w:gridSpan w:val="#{opts[:span]}"/>)),
        case opts[:merge] do
          :restart -> ~s(<w:vMerge w:val="restart"/>)
          :continue -> "<w:vMerge/>"
          _ -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    jc = if opts[:center] || opts[:span] || opts[:bold], do: [center: true], else: []

    [
      "<w:tc><w:tcPr>",
      pr,
      "</w:tcPr>",
      para([run(text, bold: opts[:bold], size: if(opts[:bold], do: @head_size))], jc),
      "</w:tc>"
    ]
  end

  # -- static parts -----------------------------------------------------------------------------

  defp content_types do
    @decl <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
      ~s(<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>) <>
      ~s(<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>) <>
      "</Types>"
  end

  defp rels do
    @decl <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>) <>
      "</Relationships>"
  end

  defp doc_rels do
    @decl <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>) <>
      "</Relationships>"
  end

  defp styles do
    @decl <>
      "<w:styles #{@ns}><w:docDefaults><w:rPrDefault><w:rPr>" <>
      ~s(<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>) <>
      ~s(<w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:rPrDefault>) <>
      ~s(<w:pPrDefault><w:pPr><w:spacing w:after="60"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>)
  end
end
