defmodule Letflow.Documents.FormTemplate.Keys do
  @moduledoc """
  Closed placeholder vocabulary derived from the shipped FormPrint layouts.
  Group headings, signature captions, stamps and repeated catalog text are locked
  too: a company never has to type a legal word (0089 D1, tightening D2 in T-1981).
  Boxed fields, annex lines and signature tables use the same names as their
  plain counterparts; presentation does not change the legal vocabulary.
  """
  alias Letflow.Documents.FormPrint
  defstruct legal: [], data: [], tables: [], signatures: [], logo: "tenant.logo"

  def for_form(form) do
    with {:ok, layout} <- FormPrint.layout(form) do
      {keys, _seen} = Enum.reduce(layout["blocks"], {%__MODULE__{}, %{}}, &block/2)
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
    headings = for n <- 1..length(cols), do: {"legal.col.#{t}.#{n}", n - 1}
    numbers = for n <- 1..length(cols), do: {"legal.colno.#{t}.#{n}", n - 1}

    groups =
      cols
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> c["group"] end)
      |> Enum.uniq_by(fn {c, _} -> c["group"] end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{_, start}, g} -> {"legal.group.#{t}.#{g}", start} end)

    total = if b["totals"], do: "legal.total.#{t}", else: nil

    legal =
      Enum.map(headings ++ numbers ++ groups, &elem(&1, 0)) ++ if(total, do: [total], else: [])

    table = %{
      index: t,
      lines: lines,
      headings: headings ++ numbers ++ groups,
      total: total,
      columns: cols
    }

    {%{
       keys
       | legal: keys.legal ++ legal,
         data: keys.data ++ lines,
         tables: keys.tables ++ [table]
     }, seen}
  end
end
