defmodule Letflow.Documents.XlsxStyle do
  @moduledoc """
  T-1555: presentation of an `.xlsx` sheet so it reads and prints like a table: bold header row,
  the header frozen (the screen keeps it while scrolling), and a column width from the longest
  value. Pure; the cell values and their types are not changed, so a reader that parses the
  sheet sees the same data. Elixlsx has no page setup (print titles, landscape, fit to width),
  so a printed sheet does not repeat the header: documented limit.
  """

  alias Elixlsx.{Sheet, Util}

  @min_w 8
  @max_w 60
  @sample 200

  @doc "The sheet with its first row as a bold, frozen header and widths fitted to the content."
  @spec style(Sheet.t(), boolean()) :: Sheet.t()
  def style(sheet, header? \\ true)
  def style(%Sheet{rows: []} = sheet, _header?), do: sheet

  def style(%Sheet{rows: [header | rest] = rows} = sheet, header?) do
    widths = widths(Enum.take(rows, @sample + 1))

    sheet = if header?, do: %{sheet | rows: [Enum.map(header, &bold/1) | rest]}, else: sheet

    sheet =
      widths
      |> Enum.with_index(1)
      |> Enum.reduce(sheet, fn {w, col}, sh ->
        Sheet.set_col_width(sh, Util.encode_col(col), w)
      end)

    if header?, do: Sheet.set_pane_freeze(sheet, 1, 0), else: sheet
  end

  defp bold([value | opts]), do: [value | Keyword.put(opts, :bold, true)]
  defp bold(value), do: [value, bold: true]

  defp widths(rows) do
    rows
    |> Enum.map(fn row -> Enum.map(row, &len/1) end)
    |> Enum.reduce([], fn lens, acc -> merge(acc, lens) end)
    |> Enum.map(&(&1 |> Kernel.+(2) |> max(@min_w) |> min(@max_w)))
  end

  defp merge(acc, lens) do
    n = max(length(acc), length(lens))
    pad = fn l -> l ++ List.duplicate(0, n - length(l)) end
    Enum.zip_with(pad.(acc), pad.(lens), &max/2)
  end

  defp len([value | _opts]), do: len(value)
  defp len(nil), do: 0

  defp len(value) when is_binary(value),
    do: value |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.max()

  defp len(value), do: value |> to_string() |> String.length()
end
