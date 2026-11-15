defmodule Letflow.Documents.FormTemplate.Keys do
  @moduledoc """
  Closed placeholder vocabulary derived from the shipped FormPrint layouts.
  Group headings, signature captions, stamps and repeated catalog text are locked
  too: a company never has to type a legal word (0089 D1, tightening D2 in T-1981).
  Boxed fields, annex lines and signature tables use the same names as their
  plain counterparts; presentation does not change the legal vocabulary.
  Each block owns its names and every legal name records its catalog or literal
  source. Adjacent span leaves share the first column's heading name; totals
  require one data name for each summed or marked column (S2).
  """
  alias Letflow.Documents.FormPrint

  defstruct legal: [],
            data: [],
            tables: [],
            signatures: [],
            blocks: [],
            sources: %{},
            logo: "tenant.logo"

  def for_form(form) do
    with {:ok, layout} <- FormPrint.layout(form) do
      {keys, _seen} =
        Enum.reduce(layout["blocks"], {%__MODULE__{}, %{}}, fn b, {before, seen} ->
          {after_keys, seen} = block(b, {before, seen})
          legal = after_keys.legal -- before.legal
          data = after_keys.data -- before.data
          sources = sources(b, legal, after_keys)

          {%{
             after_keys
             | blocks: before.blocks ++ [%{legal: legal, data: data}],
               sources: Map.merge(before.sources, sources)
           }, seen}
        end)

      {:ok, keys}
    end
  end

  defp block(%{"type" => type, "label" => label}, {keys, seen})
       when type in ["text", "title", "proxy", "annex_line"] do
    n = Map.get(seen, label, 0) + 1
    suffix = label |> String.split(".", parts: 2) |> List.last()
    name = "legal." <> suffix <> if(n == 1, do: "", else: ".#{n}")
    {%{keys | legal: keys.legal ++ [name]}, Map.put(seen, label, n)}
  end

  defp block(%{"type" => "field", "key" => key}, {keys, seen}),
    do: {%{keys | legal: keys.legal ++ ["legal.label." <> key], data: keys.data ++ [key]}, seen}

  defp block(%{"type" => "page_break"}, acc), do: acc

  defp block(%{"type" => "boxed_pairs", "cells" => cells}, acc) do
    Enum.reduce(cells, acc, fn cell, acc -> block(Map.put(cell, "type", "field"), acc) end)
  end

  defp block(%{"type" => type, "key" => key, "parts" => parts} = b, {keys, seen})
       when type in ["signature", "signature_table"] do
    legal =
      ["legal.sig." <> key] ++
        Enum.map(parts, &("legal.cap.#{key}." <> &1)) ++
        if(b["stamp"], do: ["legal.stamp." <> key], else: [])

    {%{
       keys
       | legal: keys.legal ++ legal,
         data: keys.data ++ Enum.map(parts, &("sig.#{key}." <> &1)),
         signatures: keys.signatures ++ [b]
     }, seen}
  end

  defp block(%{"type" => "table", "columns" => cols, "rows" => rows} = b, {keys, seen}) do
    t = length(keys.tables) + 1
    lines = Enum.map(cols, &(rows <> "." <> &1["key"]))

    headings =
      cols
      |> Enum.with_index()
      |> Enum.chunk_by(fn {c, i} ->
        path = (c["groups"] || List.wrap(c["group"])) ++ [c["label"]]
        if c["span"] == true, do: {:leaf_span, path}, else: {:leaf, i}
      end)
      |> Enum.map(fn chunk ->
        {_, i} = hd(chunk)
        {"legal.col.#{t}.#{i + 1}", i}
      end)

    numbers = for n <- 1..length(cols), do: {"legal.colno.#{t}.#{n}", n - 1}

    groups =
      cols
      |> Enum.with_index()
      |> Enum.flat_map(fn {c, start} ->
        path = c["groups"] || List.wrap(c["group"])

        path
        |> Enum.with_index(1)
        |> Enum.map(fn {_, level} -> {Enum.take(path, level), start} end)
      end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, start}, g} ->
        %{name: "legal.group.#{t}.#{g}", start: start, path: path}
      end)

    group_headings = Enum.map(groups, &{&1.name, &1.start})

    total = if b["totals"], do: "legal.total.#{t}", else: nil

    totals =
      if b["totals"],
        do:
          cols
          |> Enum.with_index()
          |> Enum.filter(fn {c, _} ->
            c["key"] in ((b["totals"]["sum"] || []) ++ (b["totals"]["mark"] || []))
          end)
          |> Enum.map(fn {c, i} -> {"total.#{t}.#{c["key"]}", i} end),
        else: []

    legal =
      Enum.map(headings ++ numbers ++ group_headings, &elem(&1, 0)) ++
        if(total, do: [total], else: [])

    table = %{
      index: t,
      lines: lines,
      headings: headings ++ numbers ++ group_headings,
      groups: groups,
      total: total,
      totals: totals,
      columns: cols
    }

    {%{
       keys
       | legal: keys.legal ++ legal,
         data: keys.data ++ lines ++ Enum.map(totals, &elem(&1, 0)),
         tables: keys.tables ++ [table]
     }, seen}
  end

  defp sources(%{"type" => "page_break"}, _, _), do: %{}

  defp sources(%{"type" => "boxed_pairs", "cells" => cells}, names, _) do
    Map.new(Enum.zip(names, cells), fn {name, c} -> {name, {:catalog, c["label"]}} end)
  end

  defp sources(%{"type" => type} = b, names, _) when type in ["signature", "signature_table"] do
    refs = [b["label"]] ++ Enum.map(b["parts"], &("cap." <> &1)) ++ List.wrap(b["stamp"])
    Map.new(Enum.zip(names, refs), fn {name, ref} -> {name, {:catalog, ref}} end)
  end

  defp sources(%{"type" => "table"} = b, _, keys) do
    t = List.last(keys.tables)

    Map.new(t.headings, fn {name, i} ->
      col = Enum.at(t.columns, i)

      source =
        cond do
          String.starts_with?(name, "legal.colno.") ->
            {:text, to_string(col["no"] || i + 1)}

          String.starts_with?(name, "legal.group.") ->
            group = Enum.find(t.groups, &(&1.name == name))
            {:catalog, List.last(group.path)}

          col["label"] ->
            {:catalog, col["label"]}

          true ->
            {:text, ""}
        end

      {name, source}
    end)
    |> Map.merge(if(t.total, do: %{t.total => {:catalog, b["totals"]["label"]}}, else: %{}))
  end

  defp sources(b, [name], _), do: %{name => {:catalog, b["label"]}}
end
