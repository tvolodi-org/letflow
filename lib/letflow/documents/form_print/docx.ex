defmodule Letflow.Documents.FormPrint.Docx do
  @moduledoc """
  The `.docx` side of `Letflow.Documents.FormPrint`: a zip of WordprocessingML written with OTP
  `:zip` and string templates (no dependency; the repo has no docx library).

  Parts: `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/styles.xml`,
  `word/_rels/document.xml.rels`. A4 portrait or landscape, margins, body and table size from the layout's `page` (default portrait, Times New Roman 12 / table 10 pt), a footer part with a page field, single-border table with
  the true merged group header (`w:gridSpan` / `w:vMerge`) and the numbers row. Every text goes
  through `escape/1` (`& < > " '`); the model's texts were already stripped of XML-illegal
  characters by `FormPrint.clean/1`, and labels come from the catalog, so no data can break the
  package. There is no `docProps` and the zip entries carry a fixed time, so equal inputs give
  equal bytes.
  """

  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.FormPrint.Pdf

  @ns ~s(xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main")
  @decl ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
  @rns ~s(xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  @fixed_time {{1980, 1, 1}, {0, 0, 0}}
  # Table header cells print small so a header word is not broken in a narrow column (T-1555).
  @head_size 14

  @a4 {11_906, 16_838}

  @spec render([tuple()], %{word: String.t(), of: String.t()} | nil, map() | nil) ::
          {:ok, binary()}
  def render(model, footer \\ nil, page \\ nil) do
    page = page || FormPrint.page(%{})
    {w, h} = page_dims(page.orientation)
    [mt, mr, mb, ml] = Enum.map(page.margins_mm, &twips/1)
    pg = %{page_w: w - mr - ml, ts: round(page.table_font_pt * 2)}
    body = model |> Enum.map(&block(&1, pg)) |> IO.iodata_to_binary()

    orient = if page.orientation == "landscape", do: ~s( w:orient="landscape"), else: ""

    sect =
      ~s(<w:sectPr><w:footerReference w:type="default" r:id="rId2"/>) <>
        ~s(<w:pgSz w:w="#{w}" w:h="#{h}"#{orient}/>) <>
        ~s(<w:pgMar w:top="#{mt}" w:right="#{mr}" w:bottom="#{mb}" w:left="#{ml}" w:header="#{div(mt, 2)}" w:footer="#{div(mb, 2)}" w:gutter="0"/></w:sectPr>)

    document =
      @decl <> "<w:document #{@ns} #{@rns}><w:body>" <> body <> sect <> "</w:body></w:document>"

    files = [
      {"[Content_Types].xml", content_types()},
      {"_rels/.rels", rels()},
      {"word/document.xml", document},
      {"word/styles.xml", styles(page)},
      {"word/footer1.xml", footer_part(footer)},
      {"word/_rels/document.xml.rels", doc_rels()}
    ]

    entries =
      Enum.map(files, fn {name, bin} -> {String.to_charlist(name), bin, file_info(bin)} end)

    {:ok, {_name, zip}} = :zip.create(~c"form.docx", entries, [:memory])
    {:ok, zip}
  end

  defp page_dims("landscape"), do: {elem(@a4, 1), elem(@a4, 0)}
  defp page_dims(_), do: @a4

  defp twips(mm), do: round(mm * 56.6929)

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

  defp block({:text, s}, _pg), do: para([run(s)])
  defp block({:page_break}, _pg), do: "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
  defp block({:title, s}, _pg), do: para([run(s, bold: true, size: 28)], center: true)
  defp block({:proxy, s}, _pg), do: para([run(s)])
  defp block({:notice, s}, _pg), do: para([run(s, italic: true)])
  defp block({:annex_line, s}, _pg), do: para([run(s)], right: true)

  defp block({:boxed_pairs, cells}, pg) do
    headers = row(Enum.map(cells, fn {label, _} -> cell(label, ts: pg.ts) end))
    values = row(Enum.map(cells, fn {_, value} -> cell(or_blank(value), ts: pg.ts) end))
    small_table(length(cells), [headers, values], pg)
  end

  defp block({:signature_table, label, values, captions, stamp}, pg) do
    cells =
      Enum.zip_with(values, captions, fn value, caption ->
        [
          "<w:tc><w:tcPr/>",
          para([run(or_blank(value), size: pg.ts)], ruled: true),
          para([run(caption, size: 16)], center: true),
          "</w:tc>"
        ]
      end)

    [
      para([run(label)], keep_next: true),
      small_table(length(cells), row(cells), pg),
      if(stamp, do: para([run(stamp)]), else: [])
    ]
  end

  defp block({:field, label, value}, _pg),
    do: para([run(label <> ": "), run(or_blank(value), bold: value != "")])

  defp block({:signature, label, values, captions, stamp}, _pg) do
    joined = values |> Enum.map(&or_blank/1) |> Enum.join(" / ")
    caption = Enum.join(Enum.reject([stamp | captions], &is_nil/1), " / ")
    [para([run(label <> " "), run(joined)], keep_next: true), para([run(caption, size: 16)])]
  end

  defp block({:table, %{columns: columns, rows: rows, total: total}}, pg) do
    compact? = Enum.any?(columns, &(Map.get(&1, :groups, []) != []))
    cells = FormPrint.header_cells(columns)
    depth = cells |> Enum.map(&(&1.row + &1.rowspan)) |> Enum.max()

    header =
      for level <- 0..(depth - 1) do
        cells
        |> Enum.filter(&(&1.row <= level and &1.row + &1.rowspan > level))
        |> Enum.sort_by(& &1.start)
        |> Enum.map(fn c ->
          merge =
            cond do
              c.row < level -> :continue
              c.rowspan > 1 -> :restart
              true -> nil
            end

          cell(if(c.row < level, do: "", else: c.text),
            span: if(c.span > 1, do: c.span),
            merge: merge,
            bold: true,
            compact: compact?,
            ts: pg.ts
          )
        end)
        |> row(:head)
      end

    numbers =
      row(
        Enum.map(columns, fn c ->
          cell(Map.get(c, :no_text) || Integer.to_string(c.no),
            center: true,
            ts: pg.ts,
            no_wrap: compact?,
            compact: compact?
          )
        end),
        :head
      )

    keys = Enum.map(columns, & &1.key)

    data_rows =
      Enum.map(rows ++ List.wrap(total), fn r ->
        row(Enum.map(keys, &cell(r[&1] || "", ts: pg.ts, compact: compact?)))
      end)

    grid = Enum.map(col_widths(columns, pg.page_w), fn w -> ~s(<w:gridCol w:w="#{w}"/>) end)

    [
      para([]),
      "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>",
      if(Enum.all?(columns, & &1.width), do: "<w:tblLayout w:type=\"fixed\"/>", else: ""),
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

  defp small_table(n, rows, pg) do
    borders =
      for side <- ~w(top left bottom right insideH insideV),
          do: ~s(<w:#{side} w:val="single" w:sz="4"/>)

    [
      "<w:tbl><w:tblPr><w:tblW w:w=\"#{pg.page_w}\" w:type=\"dxa\"/>",
      "<w:tblLayout w:type=\"fixed\"/><w:tblBorders>",
      borders,
      "</w:tblBorders></w:tblPr><w:tblGrid>",
      List.duplicate(~s(<w:gridCol w:w="#{div(pg.page_w, n)}"/>), n),
      "</w:tblGrid>",
      rows,
      "</w:tbl>",
      para([])
    ]
  end

  # Column widths (twips) of one table: 1 is the row number (900), 2 the name (3000 while the other
  # columns fit), every other column at least the width of its longest header word, and the
  # leftover shared equally, so a long header word is never broken inside a cell.
  @name_floor 1800
  # a narrow column still has to hold a number
  @min_col 800

  defp col_widths(columns, page_w) do
    if Enum.all?(columns, & &1.width),
      do: weighted_widths(columns, page_w),
      else: auto_widths(columns, page_w)
  end

  # Widths given by the layout (the reference template's grid) as weights, scaled to the text area.
  defp weighted_widths(columns, page_w) do
    total = columns |> Enum.map(& &1.width) |> Enum.sum()
    Enum.map(columns, &trunc(&1.width * page_w / total))
  end

  defp auto_widths(columns, page_w) do
    need =
      Map.new(columns, fn c -> {c.no, word_need(c.label)} end)

    fixed = fn no -> if no == 1, do: 900, else: 3000 end
    others = Enum.reject(columns, &(&1.no in [1, 2]))
    min_sum = others |> Enum.map(&Map.fetch!(need, &1.no)) |> Enum.sum()

    named = Enum.filter(columns, &(&1.no in [1, 2]))
    name_w = if Enum.any?(named, &(&1.no == 2)), do: 3000, else: 0
    row_w = if Enum.any?(named, &(&1.no == 1)), do: 900, else: 0

    name_w =
      if name_w > 0 and row_w + name_w + min_sum > page_w,
        do: max(page_w - row_w - min_sum, @name_floor),
        else: name_w

    free = page_w - row_w - name_w
    extra = if others == [], do: 0, else: max(div(free - min_sum, length(others)), 0)
    scale = if min_sum > free, do: free / min_sum, else: 1

    widths =
      Enum.map(columns, fn c ->
        case c.no do
          1 -> fixed.(1)
          2 -> name_w
          no -> trunc((Map.fetch!(need, no) + extra) * scale)
        end
      end)

    # never wider than the text area: scale the whole row down (a narrow portrait page)
    total = Enum.sum(widths)
    if total > page_w, do: Enum.map(widths, &trunc(&1 * page_w / total)), else: widths
  end

  # 7 pt bold header: about 80 twips a character plus the cell margins.
  defp word_need(label) do
    longest =
      label |> to_string() |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.length/1)

    max(Enum.max([1 | longest]) * 80 + 220, @min_col)
  end

  defp or_blank(""), do: Pdf.blank()
  defp or_blank(v), do: v

  # -- xml helpers ------------------------------------------------------------------------------

  defp para(runs, opts \\ []) do
    inner =
      [
        if(opts[:keep_next], do: "<w:keepNext/>"),
        if(opts[:right], do: ~s(<w:jc w:val="right"/>)),
        if(opts[:ruled], do: ~s(<w:pBdr><w:bottom w:val="single" w:sz="4"/></w:pBdr>)),
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

  defp cell(text, opts) do
    pr =
      [
        if(opts[:span], do: ~s(<w:gridSpan w:val="#{opts[:span]}"/>)),
        case opts[:merge] do
          :restart -> ~s(<w:vMerge w:val="restart"/>)
          :continue -> "<w:vMerge/>"
          _ -> nil
        end,
        if(opts[:no_wrap], do: "<w:noWrap/>")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    jc = if opts[:center] || opts[:span] || opts[:bold], do: [center: true], else: []

    [
      "<w:tc><w:tcPr>",
      pr,
      if(opts[:compact],
        do:
          "<w:tcMar><w:top w:w=\"15\" w:type=\"dxa\"/><w:left w:w=\"15\" w:type=\"dxa\"/><w:bottom w:w=\"15\" w:type=\"dxa\"/><w:right w:w=\"15\" w:type=\"dxa\"/></w:tcMar>",
        else: []
      ),
      "</w:tcPr>",
      para([run(text, bold: opts[:bold], size: cell_size(opts))], jc),
      "</w:tc>"
    ]
  end

  # Header cells print small (`@head_size`); data cells at the layout's table size.
  defp cell_size(opts), do: if(opts[:bold], do: @head_size, else: opts[:ts])

  # -- static parts -----------------------------------------------------------------------------

  defp content_types do
    @decl <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
      ~s(<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>) <>
      ~s(<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>) <>
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
      ~s(<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>) <>
      "</Relationships>"
  end

  # Footer: "Page N of M" with the catalog's words and live fields (just the page number when the
  # catalog has no words), centred.
  defp footer_part(footer) do
    field = fn instr ->
      ~s(<w:fldSimple w:instr=" #{instr} "><w:r><w:t>1</w:t></w:r></w:fldSimple>)
    end

    runs =
      case footer do
        %{word: word, of: of} ->
          [run(word <> " "), field.("PAGE"), run(" " <> of <> " "), field.("NUMPAGES")]

        _ ->
          [field.("PAGE")]
      end

    @decl <>
      "<w:ftr #{@ns}>" <>
      IO.iodata_to_binary(para(runs, center: true)) <> "</w:ftr>"
  end

  defp styles(page) do
    @decl <>
      "<w:styles #{@ns}><w:docDefaults><w:rPrDefault><w:rPr>" <>
      ~s(<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>) <>
      ~s(<w:sz w:val="#{round(page.font_pt * 2)}"/><w:szCs w:val="#{round(page.font_pt * 2)}"/></w:rPr></w:rPrDefault>) <>
      ~s(<w:pPrDefault><w:pPr><w:spacing w:after="60"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>)
  end
end
