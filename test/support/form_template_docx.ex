defmodule Letflow.FormTemplateDocx do
  @moduledoc false
  alias Letflow.Documents.FormTemplate.{Keys, Package}
  alias Letflow.Documents.FormPrint
  @w "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  @r "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @rels "http://schemas.openxmlformats.org/package/2006/relationships"
  @ct "http://schemas.openxmlformats.org/package/2006/content-types"
  @main "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
  def main_type, do: @main

  def namespaces,
    do:
      ~s(xmlns:w="#{@w}" xmlns:r="#{@r}" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006")

  def p(name), do: "<w:p>" <> run("{{#{name}}}") <> "</w:p>"
  def run(text), do: "<w:r><w:t>#{text}</w:t></w:r>"

  def cell(text, span \\ 1),
    do: "<w:tc><w:tcPr><w:gridSpan w:val=\"#{span}\"/></w:tcPr>#{p(text)}</w:tc>"

  def row(cells), do: "<w:tr>#{Enum.join(cells)}</w:tr>"

  def relationship(id, target, extras \\ ""),
    do: ~s(<Relationship Id="#{id}" Type="#{@r}/image" Target="#{target}" #{extras}/>)

  def rels(children), do: ~s(<Relationships xmlns="#{@rels}">#{children}</Relationships>)

  def valid(form \\ "z2") do
    {:ok, keys} = Keys.for_form(form)
    {:ok, layout} = FormPrint.layout(form)

    table_names =
      Enum.flat_map(keys.tables, fn t ->
        Enum.map(t.headings ++ t.totals, &elem(&1, 0)) ++
          t.lines ++ if(t.total, do: [t.total], else: [])
      end)

    flat = (keys.legal ++ keys.data) -- table_names

    tables =
      layout["blocks"]
      |> Enum.filter(&(&1["type"] == "table"))
      |> Enum.with_index(1)
      |> Enum.map(fn {b, t} -> table(b, t, Enum.at(keys.tables, t - 1)) end)

    body =
      Enum.map_join(flat, &p/1) <>
        Enum.join(tables) <>
        ~s(<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1276"/></w:sectPr>)

    %{
      "[Content_Types].xml" =>
        ~s(<Types xmlns="#{@ct}"><Override PartName="/word/document.xml" ContentType="#{@main}"/><Override PartName="/word/webSettings.xml" ContentType="x"/></Types>),
      "_rels/.rels" =>
        ~s(<Relationships xmlns="#{@rels}"><Relationship Id="rId1" Type="#{@r}/officeDocument" Target="word/document.xml"/></Relationships>),
      "word/document.xml" =>
        ~s(<w:document #{namespaces()}><w:body>#{body}</w:body></w:document>),
      "word/_rels/document.xml.rels" => rels(relationship("drop1", "webSettings.xml")),
      "word/styles.xml" =>
        ~s(<w:styles #{namespaces()}><w:rPr><w:rFonts w:ascii="Times New Roman"/></w:rPr></w:styles>),
      "word/settings.xml" =>
        ~s(<w:settings #{namespaces()}><w:footnotePr/><w:endnotePr/><w:rsids/></w:settings>),
      "word/webSettings.xml" => "<x/>",
      "word/footnotes.xml" => "<x/>",
      "word/endnotes.xml" => "<x/>",
      "docProps/core.xml" => "<author>private_marker</author>",
      "docProps/app.xml" => "<x/>"
    }
  end

  defp table(b, t, keys) do
    cols = b["columns"]
    paths = Enum.map(cols, &(&1["groups"] || List.wrap(&1["group"])))

    groups =
      paths
      |> Enum.flat_map(fn path ->
        path |> Enum.with_index(1) |> Enum.map(fn {_, level} -> Enum.take(path, level) end)
      end)
      |> Enum.uniq()

    headings = Enum.filter(keys.headings, &String.starts_with?(elem(&1, 0), "legal.col."))

    columns =
      for {c, n} <- Enum.with_index(cols, 1),
          do: %{
            label: headings |> Enum.filter(&(elem(&1, 1) < n)) |> List.last() |> elem(0),
            group: c["group"],
            groups: c["groups"] || [],
            span: c["span"] == true
          }

    cells = Letflow.Documents.FormPrint.header_cells(columns)
    depth = cells |> Enum.map(&(&1.row + &1.rowspan)) |> Enum.max()

    headers =
      for level <- 0..(depth - 1) do
        cells
        |> Enum.filter(&(&1.row <= level and &1.row + &1.rowspan > level))
        |> Enum.sort_by(& &1.start)
        |> Enum.map(fn c ->
          text =
            cond do
              c.row < level ->
                ""

              String.starts_with?(c.text, "legal.col.") ->
                c.text

              true ->
                prefix = Enum.at(paths, c.start) |> Enum.take(c.row + 1)
                "legal.group.#{t}.#{Enum.find_index(groups, &(&1 == prefix)) + 1}"
            end

          xml =
            if text == "",
              do: String.replace(cell(text, c.span), "{{}}", ""),
              else: cell(text, c.span)

          merge =
            cond do
              c.row < level -> "<w:vMerge/>"
              c.rowspan > 1 -> ~s(<w:vMerge w:val="restart"/>)
              true -> ""
            end

          String.replace(xml, "</w:tcPr>", merge <> "</w:tcPr>")
        end)
        |> row()
      end

    grid = "<w:tblGrid>" <> Enum.map_join(cols, fn _ -> "<w:gridCol/>" end) <> "</w:tblGrid>"
    numbers = for n <- 1..length(cols), do: cell("legal.colno.#{t}.#{n}")
    data = Enum.map(cols, &cell(b["rows"] <> "." <> &1["key"]))

    total =
      if b["totals"] do
        cols
        |> Enum.with_index()
        |> Enum.map(fn {_, i} ->
          name =
            if i == 1,
              do: keys.total,
              else: Enum.find_value(keys.totals, fn {name, start} -> if start == i, do: name end)

          if name, do: cell(name), else: String.replace(cell(""), "{{}}", "")
        end)
        |> row()
      else
        ""
      end

    "<w:tbl>" <>
      grid <>
      Enum.join(headers) <>
      row(numbers) <> row(data) <> total <> "</w:tbl>"
  end

  def edit(pkg, name, fun), do: Map.update!(pkg, name, fun)

  def body(pkg, xml),
    do: edit(pkg, "word/document.xml", &String.replace(&1, "<w:body>", "<w:body>" <> xml))

  def replace(pkg, old, new), do: edit(pkg, "word/document.xml", &String.replace(&1, old, new))
  def remove(pkg, name), do: replace(pkg, "{{#{name}}}", "")

  def split_runs(text, n) do
    size = div(byte_size(text), n)

    chunks =
      for i <- 0..(n - 1),
          do:
            binary_part(
              text,
              i * size,
              if(i == n - 1, do: byte_size(text) - i * size, else: size)
            )

    chunks
    |> Enum.with_index()
    |> Enum.map_join(fn {chunk, i} ->
      ~s(<w:r>#{if i == 0, do: "<w:rPr><w:b/></w:rPr>", else: ""}<w:t>#{chunk}</w:t></w:r>) <>
        if(i == 0,
          do:
            ~s(<w:proofErr w:type="spellStart"/><w:bookmarkStart w:id="1" w:name="x"/><w:bookmarkEnd w:id="1"/>),
          else: ""
        )
    end)
  end

  def zip(pkg, opts \\ []) do
    entries = pkg |> Enum.sort() |> Enum.map(fn {n, b} -> {String.to_charlist(n), b} end)
    mode = if Keyword.get(opts, :stored, false), do: [{:compress, []}], else: []
    {:ok, {_, bytes}} = :zip.create(~c"x.docx", entries, [:memory] ++ mode)
    bytes
  end

  def unpack(bytes) do
    {:ok, parts} = :zip.extract(bytes, [:memory])
    Map.new(parts, fn {n, b} -> {to_string(n), b} end)
  end

  def checked_bytes(parts) do
    {:ok, bytes} = Package.write(parts)
    bytes
  end
end
