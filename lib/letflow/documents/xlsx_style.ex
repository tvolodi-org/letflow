defmodule Letflow.Documents.XlsxStyle do
  @moduledoc """
  T-1555: presentation of an `.xlsx` sheet so it reads and prints like a table: bold header row,
  the header frozen (the screen keeps it while scrolling), and a column width from the longest
  value. Pure; the cell values and their types are not changed, so a reader that parses the
  sheet sees the same data.

  T-1612: `write_to_memory/2` also gives a header sheet its print furniture. Elixlsx has no page
  setup, so the zip it returns is patched (OTP `:zip`): `_xlnm.Print_Titles` repeats row 1 on
  every printed page, and the sheet is landscape and fitted to the page width. If the patch
  cannot be applied the unpatched bytes are returned: print furniture never fails an export.
  """

  alias Elixlsx.{Sheet, Util}

  @fit_off ~s(<pageSetUpPr fitToPage="false"/>)
  @fit_on ~s(<pageSetUpPr fitToPage="true"/>)
  @page_setup ~s(<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>)

  @min_w 8
  @max_w 60
  @sample 200

  @doc """
  CORE S2: a cell value as text. nil stays nil, a `DateTime` is ISO 8601, a binary is kept, an atom
  or number is `to_string/1`, anything else is JSON. (Shared by the assets and stock exports.)
  """
  @spec cell_text(term()) :: String.t() | nil
  def cell_text(nil), do: nil
  def cell_text(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def cell_text(value) when is_binary(value), do: value
  def cell_text(value) when is_atom(value) or is_number(value), do: to_string(value)
  def cell_text(value), do: Jason.encode!(value)

  @doc "A cell value that keeps an integer as a number; otherwise `cell_text/1`."
  @spec cell_scalar(term()) :: integer() | String.t() | nil
  def cell_scalar(nil), do: nil
  def cell_scalar(value) when is_integer(value), do: value
  def cell_scalar(value), do: cell_text(value)

  @doc "A cell value as a JSON string; nil stays nil."
  @spec cell_json(term()) :: String.t() | nil
  def cell_json(nil), do: nil
  def cell_json(value), do: Jason.encode!(value)

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

  @doc """
  Like `Elixlsx.write_to_memory/2` (`{:ok, {name, binary}} | {:error, _}`), with print titles,
  landscape and fit-to-width added for every sheet whose header row `style/2` froze.
  """
  @spec write_to_memory(Elixlsx.Workbook.t(), String.t()) ::
          {:ok, {charlist() | String.t(), binary()}} | {:error, term()}
  def write_to_memory(%Elixlsx.Workbook{sheets: sheets} = workbook, name) do
    case Elixlsx.write_to_memory(workbook, name) do
      {:ok, {out_name, binary}} ->
        titled =
          for {%Sheet{pane_freeze: {1, 0}, name: sname}, i} <- Enum.with_index(sheets),
              do: {i, sname}

        {:ok, {out_name, patch_or_original(binary, titled)}}

      other ->
        other
    end
  end

  defp patch_or_original(binary, []), do: binary

  defp patch_or_original(binary, titled) do
    case patch(binary, titled) do
      {:ok, patched} -> patched
      :error -> binary
    end
  rescue
    _ -> binary
  end

  defp patch(binary, titled) do
    with {:ok, entries} <- :zip.unzip(binary, [:memory]),
         {:ok, entries} <- patch_entries(entries, titled),
         {:ok, {_, out}} <- :zip.create(~c"out.xlsx", entries, [:memory]) do
      {:ok, out}
    else
      _ -> :error
    end
  end

  defp patch_entries(entries, titled) do
    titled
    |> Enum.reduce_while({:ok, entries}, fn {i, _sname}, {:ok, acc} ->
      case update(acc, ~c"xl/worksheets/sheet#{i + 1}.xml", &patch_sheet/1) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> update(acc, ~c"xl/workbook.xml", &patch_workbook(&1, titled))
      :error -> :error
    end
  end

  defp update(entries, file, fun) do
    case List.keyfind(entries, file, 0) do
      {^file, xml} ->
        case fun.(xml) do
          {:ok, new} -> {:ok, List.keyreplace(entries, file, 0, {file, new})}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  defp patch_sheet(xml) do
    with true <- String.contains?(xml, @fit_off),
         [margins] <- Regex.run(~r{<pageMargins[^>]*/>}, xml) do
      {:ok,
       xml
       |> String.replace(@fit_off, @fit_on, global: false)
       |> String.replace(margins, margins <> @page_setup, global: false)}
    else
      _ -> :error
    end
  end

  defp patch_workbook(xml, titled) do
    names =
      Enum.map_join(titled, fn {i, sname} ->
        quoted = "'" <> String.replace(sname, "'", "''") <> "'"

        ~s(<definedName name="_xlnm.Print_Titles" localSheetId="#{i}">) <>
          xml_escape(quoted <> "!$1:$1") <> "</definedName>"
      end)

    if String.contains?(xml, "</sheets>"),
      do:
        {:ok,
         String.replace(xml, "</sheets>", "</sheets><definedNames>#{names}</definedNames>",
           global: false
         )},
      else: :error
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
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
