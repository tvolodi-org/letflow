defmodule Letflow.Documents.FormTemplate.Filler do
  @moduledoc """
  Fills only the tree returned by the full S1 verification, never reparsing input.
  Values become text children; Package.write/1 escapes them once through Saxy,
  rather than also using Docx.escape/1 (0089 D2 would double-escape).
  Empty fields/signatures use Pdf.blank/0; empty table/total cells stay empty to
  match the platform DOCX, a second deliberate deviation from 0089 D2.
  """
  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.FormTemplate.{Package, Xml}
  @placeholder ~r/\{\{([a-z0-9_.]{1,64})\}\}/

  def fill(form, parts, keys, data, lang, opts) do
    {:ok, layout} = FormPrint.layout(form)
    catalog = Keyword.get(opts, :catalog, FormPrint.catalog())
    values = FormPrint.template_data(layout, data, lang, catalog)

    legal =
      Map.new(keys.sources, fn {name, source} ->
        {name,
         case source do
           {:text, s} -> s
           {:catalog, key} -> catalog |> Map.fetch!(key) |> Map.fetch!(lang)
         end}
      end)

    fields =
      Map.new(values.fields, fn {k, v} -> {k, if(v == "", do: FormPrint.Pdf.blank(), else: v)} end)

    all = Map.merge(legal, fields) |> Map.put(keys.logo, "")

    all =
      Enum.zip(keys.tables, values.tables)
      |> Enum.reduce(all, fn {t, v}, acc ->
        Enum.reduce(t.totals, acc, fn {name, i}, a ->
          Map.put(a, name, v.total[Enum.at(t.columns, i)["key"]])
        end)
      end)

    tree = expand(Map.fetch!(parts, "word/document.xml"), keys.tables, values.tables, all)
    tree = if values.notice, do: notice(tree, values.notice), else: tree
    Package.write(Map.put(parts, "word/document.xml", tree))
  end

  defp expand({n, a, children}, tables, values, all) do
    children =
      Enum.flat_map(children, fn
        {"w:tr", _, _} = row ->
          text = row |> Xml.named("w:t") |> Enum.map_join(&Xml.text/1)

          index =
            Enum.find_index(tables, fn t ->
              Enum.any?(t.lines, &String.contains?(text, "{{#{&1}}}"))
            end)

          if is_nil(index) do
            [expand(row, tables, values, all)]
          else
            t = Enum.at(tables, index)

            for data <- Enum.at(values, index).rows do
              line =
                Map.new(Enum.zip(t.lines, t.columns), fn {name, c} -> {name, data[c["key"]]} end)

              substitute(row, Map.merge(all, line))
            end
          end

        child when is_tuple(child) ->
          [expand(child, tables, values, all)]

        text ->
          [text]
      end)

    replace({n, a, children}, all)
  end

  defp substitute(tree, values), do: Xml.map(tree, &replace(&1, values))

  defp replace({"w:t", attrs, _children} = node, values) do
    text = Xml.text(node)

    if Regex.match?(@placeholder, text) do
      filled = Regex.replace(@placeholder, text, fn _, name -> Map.fetch!(values, name) end)
      {"w:t", List.keystore(attrs, "xml:space", 0, {"xml:space", "preserve"}), [filled]}
    else
      node
    end
  end

  defp replace(node, _), do: node

  defp notice(tree, text) do
    p = {"w:p", [], [{"w:r", [], [{"w:rPr", [], [{"w:i", [], []}]}, {"w:t", [], [text]}]}]}

    Xml.map(tree, fn
      {"w:body", a, children} ->
        {before, section} =
          Enum.split_while(children, fn c -> not (is_tuple(c) and elem(c, 0) == "w:sectPr") end)

        {"w:body", a, before ++ [p] ++ section}

      node ->
        node
    end)
  end
end
