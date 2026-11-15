defmodule Letflow.Documents.FormTemplate.Sample do
  @moduledoc """
  Synthetic preview data from the shipped layout only, with no tenant input (0089 D3).
  Values show bracketed key names. Each table has two lines, with sum columns 1 and 2.
  """
  alias Letflow.Documents.FormPrint

  @spec data(String.t()) :: {:ok, map()} | :error
  def data(form) do
    with {:ok, layout} <- FormPrint.layout(form) do
      {:ok, Enum.reduce(layout["blocks"], %{}, &block/2)}
    end
  end

  defp block(%{"type" => "field", "key" => key}, data),
    do: Map.put(data, key, label(key))

  defp block(%{"type" => "boxed_pairs", "cells" => cells}, data),
    do:
      Enum.reduce(cells, data, fn cell, acc -> Map.put(acc, cell["key"], label(cell["key"])) end)

  defp block(%{"type" => type, "key" => key}, data)
       when type in ["signature", "signature_table"],
       do:
         data
         |> Map.put(key, label(key))
         |> Map.put(key <> "_position", label(key <> "_position"))

  defp block(%{"type" => "table"} = b, data) do
    sums = (b["totals"] || %{})["sum"] || []

    rows =
      for n <- 1..2 do
        Map.new(b["columns"], fn c ->
          key = c["key"]
          {key, if(key in sums, do: "#{n}.000000000", else: label("#{key} #{n}"))}
        end)
      end

    # DA-1 and DA-2 split the same rows across two tables. Keep both sets of columns.
    Map.update(data, b["rows"], rows, fn existing ->
      Enum.zip_with(existing, rows, &Map.merge/2)
    end)
  end

  defp block(_, data), do: data
  defp label(key), do: "[" <> key <> "]"
end
