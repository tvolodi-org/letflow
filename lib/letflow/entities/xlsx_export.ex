defmodule Letflow.Entities.XlsxExport do
  @moduledoc """
  `.xlsx` renderer of the record export (GH #3600, REQ-653, decision 0077 D8): turns the page
  `POST /entities/records/:entity_type/export` already built, redacted and paginated into a
  workbook, so `?format=xlsx` answers the same rows as the JSON document. Pure: field
  definitions and export record maps in, bytes out. No database, no process, no clock.

  Sheets:

    * `records`: row 1 is the field names in definition order; then one row per record that is
      not deleted, in the page's order. A string is a text cell, an integer or decimal a number
      cell, a boolean a boolean cell, a date a date cell (`yyyy-mm-dd`). Every other type is its
      stored text (an enum, a reference or a datetime string as it is) or, for a list or an
      object, its JSON text. A missing key, `nil` or a redacted field is an empty cell; the
      column stays.
    * `export`: two columns, no header, rows `entity_type`, `exported_at`, `next_cursor`
      (an empty cell when there is no next page).

  A text cell is always a string cell, never a formula, so a value starting with `=`, `+`, `-`
  or `@` is shown and not evaluated. Known limit: a text of more than 32767 characters is
  written as it is and Excel may refuse it; the page size is already capped by the export route.
  A decimal goes through a float (a number cell has no more precision); the exact value is in
  the JSON export. A decimal too large for a float is written as its text form (T-1154).
  """

  alias Elixlsx.{Sheet, Workbook}

  @type meta :: %{
          entity_type: String.t(),
          exported_at: String.t(),
          next_cursor: String.t() | nil
        }

  @doc "The workbook bytes for `fields` (definition field maps), export record `rows` and `meta`."
  @spec build([map()], [map()], meta()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def build(fields, rows, meta) when is_list(fields) and is_list(rows) and is_map(meta) do
    names = for %{"name" => name} <- fields, do: name
    types = for %{"name" => name} = f <- fields, do: {name, Map.get(f, "type")}

    data =
      for %{"deleted" => false} = row <- rows do
        values = Map.get(row, "field_values") || %{}
        for {name, type} <- types, do: cell(Map.get(values, name), type)
      end

    workbook = %Workbook{
      sheets: [
        %Sheet{name: "records", rows: [names | data]},
        %Sheet{
          name: "export",
          rows: [
            ["entity_type", meta.entity_type],
            ["exported_at", meta.exported_at],
            ["next_cursor", meta.next_cursor]
          ]
        }
      ]
    }

    case Elixlsx.write_to_memory(workbook, "export.xlsx") do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  # A redaction sentinel or any other atom but a boolean is an empty cell.
  defp cell(nil, _type), do: nil
  defp cell(value, _type) when is_atom(value) and not is_boolean(value), do: nil

  defp cell(value, "string") when is_binary(value), do: value
  defp cell(value, "integer") when is_integer(value), do: value
  defp cell(value, "boolean") when is_boolean(value), do: value

  defp cell(value, "decimal") do
    case value |> to_string_safe() |> Decimal.parse() do
      {%Decimal{} = d, ""} ->
        if Decimal.inf?(d) or Decimal.nan?(d), do: text(value), else: decimal_number(d, value)

      _ ->
        text(value)
    end
  end

  defp cell(value, "date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: y, month: m, day: d}} -> [{{y, m, d}, {0, 0, 0}}, yyyymmdd: true]
      _ -> value
    end
  end

  defp cell(value, _type), do: text(value)

  # A decimal beyond the float range (exponent near the 6144 cap) has no number cell: its text
  # form is written instead (a string cell, never a formula) and the rest of the export stays.
  defp decimal_number(%Decimal{} = d, value) do
    Decimal.to_float(d)
  rescue
    _ -> text(to_string_safe(value))
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_number(value), do: to_string(value)
  defp to_string_safe(_value), do: ""

  defp text(value) when is_binary(value), do: value
  defp text(value), do: Jason.encode!(value)
end
