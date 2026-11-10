defmodule Letflow.Modules.Assets.XlsxExport do
  @moduledoc """
  REQ-763 / GH #3898: `.xlsx` renderer of `GET /api/v1/modules/assets/balances?format=xlsx`. It turns
  the body map the JSON route already built (the `asset_balance` view, so only allowlisted fields)
  into a workbook: the file and the JSON answer cannot hold different rows. Pure: maps in, bytes
  out; no database, no process, no clock. It adds no write path (reads only).

  Sheets:

    * `balances`: row 1 is the header (`asset, org_unit, location, material_responsible,
      actual_user, unit_ref, quantity, last_posting_seq`), then one row per balance row in the
      order of the JSON answer.
    * `report`: header `key, value`, then the time basis (`basis`, `cutoff_seq`, `as_of`,
      `timezone`, `filters`, `ledger_seq`, `next_cursor`, plus `coverage` and `as_of_date` when the
      body holds them). One page per file: the next page is fetched with `next_cursor`.

  A text cell is always a string cell (Elixlsx writes shared strings, never formulas), so a value
  starting with `=`, `+`, `-` or `@` is shown and not evaluated. A quantity is a number cell only
  when it has at most 15 significant digits; otherwise its text form is written (exact value: JSON).
  The module does not call the stock renderer (boundary Rule 4: assets does not depend on stock).
  """

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.XlsxStyle

  @file_name "asset-balances.xlsx"
  @balance_header ~w(asset org_unit location material_responsible actual_user unit_ref quantity last_posting_seq)

  @doc "The workbook of a `/balances` body."
  @spec balances(map()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def balances(body) when is_map(body) do
    build(body)
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp build(body) do
    rows =
      for row <- Map.get(body, :rows, []) do
        [
          text(row[:asset]),
          text(row[:org_unit]),
          text(row[:location]),
          text(row[:material_responsible]),
          text(row[:actual_user]),
          text(row[:unit_ref]),
          quantity(row[:quantity]),
          row[:last_posting_seq]
        ]
      end

    report =
      [
        ["basis", text(body[:basis])],
        ["cutoff_seq", body[:cutoff_seq]],
        ["as_of", text(body[:as_of])],
        ["timezone", text(body[:timezone])],
        ["filters", json(body[:filters])],
        ["ledger_seq", scalar(body[:ledger_seq])],
        ["next_cursor", text(body[:next_cursor])]
      ] ++ optional(body, :coverage) ++ optional(body, :as_of_date)

    write([@balance_header | rows], report)
  end

  defp optional(body, key) do
    case Map.get(body, key) do
      nil -> []
      value -> [[Atom.to_string(key), text(value)]]
    end
  end

  defp write(rows, report) do
    workbook = %Workbook{
      sheets: [
        XlsxStyle.style(%Sheet{name: "balances", rows: rows}),
        XlsxStyle.style(%Sheet{name: "report", rows: [["key", "value"] | report]})
      ]
    }

    case XlsxStyle.write_to_memory(workbook, @file_name) do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp text(nil), do: nil
  defp text(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp text(%Date{} = day), do: Date.to_iso8601(day)
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(value), do: Jason.encode!(value)

  defp scalar(nil), do: nil
  defp scalar(value) when is_integer(value), do: value
  defp scalar(value), do: text(value)

  defp json(nil), do: nil
  defp json(value), do: Jason.encode!(value)

  defp quantity(nil), do: nil

  defp quantity(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = d, ""} -> number_or_text(d, value)
      _ -> value
    end
  end

  defp quantity(%Decimal{} = d), do: number_or_text(d, Decimal.to_string(d, :normal))
  defp quantity(value) when is_integer(value), do: value
  defp quantity(value), do: text(value)

  defp number_or_text(%Decimal{coef: coef} = d, as_text) do
    digits = coef |> Integer.to_string() |> String.trim_trailing("0") |> byte_size()

    if Decimal.inf?(d) or Decimal.nan?(d) or digits > 15 or abs(d.exp) > 300,
      do: as_text,
      else: Decimal.to_float(d)
  rescue
    _ -> as_text
  end
end
