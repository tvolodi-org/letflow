defmodule Letflow.Modules.Stock.XlsxExport do
  @moduledoc """
  REQ-728 / GH #3772: `.xlsx` renderer of the stock read routes. It turns the body map the JSON route
  already built (the `stock_balance` / `stock_movement` views, so only allowlisted fields) into a workbook:
  the file and the JSON answer cannot hold different rows. Pure: maps in, bytes out; no database, no
  process, no clock.

  Sheets of both files:

    * `balances` / `movements`: row 1 is the header; `balances` has one row per balance row,
      `movements` one row per leg (the entry columns are repeated on each leg, legs in `leg_no`
      order). A masked leg (scoped reader) has empty slot and `document_line_id` cells and
      `masked` true.
    * `report`: header `key, value`, then the time basis (`basis`, `cutoff_seq`, `as_of`, `timezone`,
      `filters`, `ledger_seq`, `next_cursor`, and `coverage` when the body holds it) and a final
      `note` row. One page per file: the next page is fetched with `next_cursor`.

  A text cell is always a string cell (Elixlsx writes shared strings, never formulas), so a value
  starting with `=`, `+`, `-` or `@` is shown and not evaluated. A quantity is a number cell only when
  it has at most 15 significant digits; otherwise its text form is written (exact value: JSON).
  The movements file has no `ledger_seq` (the movements read returns no snapshot counter; GATE B
  open question). The movements timezone is the constant below (assumption, owner may change at GATE B).
  """

  alias Elixlsx.{Sheet, Workbook}

  @movements_timezone Letflow.Identity.TenantTimezone.default()

  @note "A balance as of an event time before an opening posting shows no opening quantity (decision 0079 D1)."

  @balance_header ~w(sku location org_unit responsible lot unit_ref quantity last_posting_seq)
  @movement_header ~w(entry_id posting_seq posting_time event_time cause reverses_entry_id reason_code
                      document_type document_id related_document_id correlation_id leg_no sku location
                      org_unit responsible lot quantity unit_ref document_line_id masked)

  @doc "The workbook of a `/balances` body."
  @spec balances(map()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def balances(body) when is_map(body) do
    rows =
      for row <- Map.get(body, :rows, []) do
        [
          text(row[:sku]),
          text(row[:location]),
          text(row[:org_unit]),
          text(row[:responsible]),
          text(row[:lot]),
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
      ] ++ coverage(body)

    write("stock-balances.xlsx", "balances", [@balance_header | rows], report)
  end

  @doc "The workbook of a `/movements` body; `filters` are the parsed query filters, `to_seq` is read from them."
  @spec movements(map(), map()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def movements(body, filters) when is_map(body) and is_map(filters) do
    rows =
      for entry <- Map.get(body, :rows, []), leg <- legs(entry), do: movement_row(entry, leg)

    report = [
      ["basis", "posting_seq"],
      ["cutoff_seq", Map.get(filters, "to_seq")],
      ["as_of", nil],
      ["timezone", @movements_timezone],
      ["filters", json(filters)],
      ["ledger_seq", nil],
      ["next_cursor", text(body[:next_cursor])]
    ]

    write("stock-movements.xlsx", "movements", [@movement_header | rows], report)
  end

  defp legs(entry), do: entry |> Map.get(:legs, []) |> Enum.sort_by(&Map.get(&1, :leg_no))

  defp movement_row(entry, leg) do
    masked = Map.get(leg, :masked) == true

    [
      text(entry[:entry_id]),
      entry[:posting_seq],
      text(entry[:posting_time]),
      text(entry[:event_time]),
      text(entry[:cause]),
      text(entry[:reverses_entry_id]),
      text(entry[:reason_code]),
      text(entry[:document_type]),
      text(entry[:document_id]),
      text(entry[:related_document_id]),
      text(entry[:correlation_id]),
      Map.get(leg, :leg_no),
      slot(leg, :sku, masked),
      slot(leg, :location, masked),
      slot(leg, :org_unit, masked),
      slot(leg, :responsible, masked),
      slot(leg, :lot, masked),
      quantity(Map.get(leg, :quantity)),
      text(Map.get(leg, :unit_ref)),
      slot(leg, :document_line_id, masked),
      masked
    ]
  end

  defp slot(_leg, _key, true), do: nil
  defp slot(leg, key, false), do: text(Map.get(leg, key))

  defp coverage(body) do
    if Map.has_key?(body, :coverage) and not is_nil(body.coverage),
      do: [["coverage", text(body.coverage)]],
      else: []
  end

  defp write(name, sheet_name, rows, report) do
    workbook = %Workbook{
      sheets: [
        %Sheet{name: sheet_name, rows: rows},
        %Sheet{name: "report", rows: [["key", "value"] | report] ++ [["note", @note]]}
      ]
    }

    case Elixlsx.write_to_memory(workbook, name) do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp text(nil), do: nil
  defp text(%DateTime{} = at), do: DateTime.to_iso8601(at)
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
