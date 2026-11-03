defmodule Letflow.Entities.XlsxExportTest do
  @moduledoc """
  GH #3600 / REQ-653 (T-1154): a stored decimal too large for a float is written as a text cell and
  the rest of the export is kept; before, `Decimal.to_float` raised and the whole export was a 500.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.XlsxExport

  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "amount", "type" => "decimal"}
  ]
  @meta %{entity_type: "thing", exported_at: "2026-11-03T00:00:00Z", next_cursor: nil}

  defp row(title, amount),
    do: %{"deleted" => false, "field_values" => %{"title" => title, "amount" => amount}}

  defp shared_strings(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])

    files
    |> Enum.find_value(fn {name, content} ->
      if to_string(name) =~ "sharedStrings", do: content
    end)
  end

  test "X1: a decimal near the exponent cap is a text cell, other rows are kept" do
    rows = [row("big", "1E+6000"), row("small", "12.5")]

    assert {:ok, binary} = XlsxExport.build(@fields, rows, @meta)
    strings = shared_strings(binary)
    assert strings =~ "1E+6000"
    assert strings =~ "big"
    assert strings =~ "small"
  end
end
