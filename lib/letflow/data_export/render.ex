defmodule Letflow.DataExport.Render do
  @moduledoc """
  Pure machine-id export rendering. Text is never an xlsx formula; CSV guards
  text cells while keeping numeric negatives numeric. Quantities exceeding Excel's
  15 significant digits stay text. All times and file dates are UTC.
  """
  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.XlsxStyle

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @notes %{
    "en" => "Truncated: the row cap was reached. Export a narrower selection.",
    "ru" => "Данные усечены: достигнут предел строк. Уточните фильтры выгрузки.",
    "kk" => "Деректер қысқартылды: жолдар шегіне жетті. Жүктеу сүзгілерін нақтылаңыз."
  }
  @yes %{"en" => "yes", "ru" => "да", "kk" => "иә"}
  @no %{"en" => "no", "ru" => "нет", "kk" => "жоқ"}

  @doc "Renders collected datasets, bundling multiple files with a manifest."
  def render(exports, lang, now) do
    results = Enum.map(exports, &file(&1, lang, now))

    with false <- Enum.any?(results, &match?({:error, _}, &1)) do
      files = Enum.map(results, fn {:ok, file} -> file end)
      bundle(files, exports, now)
    else
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp file(export, lang, now) do
    data = %{
      dataset: export.id,
      ids: "machine",
      lang: lang,
      generated_at: DateTime.to_iso8601(now),
      filters: export.filters,
      meta: Map.new(export.meta),
      cap: export.cap,
      truncated: export.truncated,
      rows_total_written: length(export.rows),
      columns: Enum.map(export.columns, & &1.key),
      rows: export.rows
    }

    {body, type} =
      case export.format do
        "json" -> {Jason.encode!(data), "application/json"}
        "csv" -> {csv(export), "text/csv; charset=utf-8"}
        "xlsx" -> {xlsx(export, lang), @xlsx}
      end

    name = String.replace(export.id, "_", "-") <> "-" <> stamp(now) <> "." <> export.format
    {:ok, %{body: body, type: type, name: name}}
  end

  defp bundle([file], _exports, _now), do: {:ok, file}

  defp bundle(files, exports, now) do
    manifest =
      Enum.zip_with(files, exports, fn file, export ->
        %{
          id: export.id,
          file: file.name,
          format: export.format,
          rows: length(export.rows),
          truncated: export.truncated,
          cap: export.cap
        }
      end)

    entries =
      Enum.map(files, &{String.to_charlist(&1.name), &1.body}) ++
        [{~c"manifest.json", Jason.encode!(manifest)}]

    {:ok, {_, bytes}} = :zip.create(~c"export.zip", entries, [:memory])

    {:ok,
     %{body: bytes, type: "application/zip", name: "letflow-export-" <> stamp(now) <> ".zip"}}
  end

  defp stamp(now), do: now |> DateTime.to_date() |> Date.to_iso8601() |> String.replace("-", "")

  defp csv(export) do
    header = Enum.map(export.columns, &Atom.to_string(&1.key))

    rows =
      Enum.map(export.rows, fn row ->
        Enum.map(export.columns, fn col -> csv_cell(Map.get(row, col.key), col.kind) end)
      end)

    Enum.map_join([header | rows], "\r\n", &Enum.join(&1, ",")) <> "\r\n"
  end

  defp csv_cell(value, kind) do
    text = text(value)

    guarded =
      if kind not in [:number, :integer] and
           String.starts_with?(text, ["=", "+", "-", "@", "\t", "\r"]),
         do: "'" <> text,
         else: text

    if String.contains?(guarded, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(guarded, "\"", "\"\"") <> "\"",
      else: guarded
  end

  defp xlsx(export, lang) do
    rows =
      Enum.map(export.rows, fn row ->
        Enum.map(export.columns, fn col -> cell(Map.get(row, col.key), col.kind) end)
      end)

    report =
      [
        ["key", "value"],
        ["ids", "machine"],
        ["timezone", "UTC"],
        ["filters", Jason.encode!(export.filters)],
        ["cap", export.cap],
        ["rows_total_written", length(export.rows)],
        ["truncated", Map.fetch!(if(export.truncated, do: @yes, else: @no), lang)]
      ] ++
        Enum.map(export.meta, fn {k, v} -> [k, scalar(v)] end) ++
        [["note", if(export.truncated, do: Map.fetch!(@notes, lang), else: "")]]

    workbook = %Workbook{
      sheets: [
        %Sheet{name: "data", rows: [Enum.map(export.columns, &Atom.to_string(&1.key)) | rows]},
        %Sheet{name: "report", rows: report}
      ]
    }

    {:ok, {_, bytes}} = Elixlsx.write_to_memory(workbook, "export.xlsx")
    bytes
  end

  defp cell(nil, _), do: nil

  defp cell(value, :number), do: XlsxStyle.cell_quantity(value)

  defp cell(value, kind) when kind in [:integer, :bool], do: value
  defp cell(value, _), do: text(value)
  defp scalar(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp scalar(value), do: cell(value, :text)
  defp text(nil), do: ""
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp text(%Date{} = value), do: Date.to_iso8601(value)
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp text(value), do: to_string(value)
end
