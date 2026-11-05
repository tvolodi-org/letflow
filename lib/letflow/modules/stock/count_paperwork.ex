defmodule Letflow.Modules.Stock.CountPaperwork do
  @moduledoc """
  REQ-719 / GH #3762: the count paperwork as `.xlsx` with signer lines. Pure: issued content and
  names in, workbook bytes out; no database, no clock, no process.

  Three kinds: `:order` (sheets `document`, `scope`, `signatures`), `:sheet` and `:differences`
  (sheets `document`, `lines`, `signatures`). The file is rendered from the ISSUED document version
  content (D-062, 0056 D4), never from live records.

  Cell rule: every text is a string cell (Elixlsx writes shared strings, never formulas), so a value
  starting with `=`, `+`, `-` or `@` is shown and not evaluated. Unlike `XlsxExport`, a quantity is the
  stored decimal text as a string cell, never a float. `line_no` and `version_no` are numbers.

  Times are printed in the tenant time zone with their offset (`2026-11-04T10:00:00+05:00`); the
  UTC offset of a zone needs the database, so the caller passes `names.offsets` (seconds per instant).

  Signers (decision 0079 section 9): the order has the chair; the sheet and the differences have the
  chair, every member and every distinct responsible employee of the document's lines. One row per
  employee, role precedence chair > member > responsible. An employee hidden by scope (`nil` in
  `names.employees`) keeps the row with empty name and code cells.

  Layout and English labels are an assumption, owner may change at GATE B (printed forms: phase E).
  """

  alias Elixlsx.{Sheet, Workbook}

  @type kind :: :order | :sheet | :differences

  @doc "The workbook of one issued count document."
  @spec build(kind(), map(), map()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def build(kind, issued, names) when kind in [:order, :sheet, :differences] do
    content = Map.get(issued, :content, %{})
    order = Map.get(issued, :order_content, content)

    sheets =
      case kind do
        :order ->
          [
            sheet("document", document_rows(kind, issued, names)),
            sheet("scope", scope_rows(order, names)),
            sheet("signatures", signature_rows(signer_rows(kind, order, [])))
            |> then(&resolve(&1, names))
          ]

        _ ->
          lines = lines_of(kind, content)

          [
            sheet("document", document_rows(kind, issued, names)),
            sheet("lines", line_rows(kind, lines, names)),
            sheet("signatures", signature_rows(signer_rows(kind, order, lines)))
            |> then(&resolve(&1, names))
          ]
      end

    write(sheets, "count-#{kind}.xlsx")
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp sheet(name, rows), do: %Sheet{name: name, rows: rows}

  # The signatures rows are built with employee ids and filled with names here.
  defp resolve(%Sheet{rows: rows} = sheet, names) do
    employees = Map.get(names, :employees, %{})

    filled =
      Enum.map(rows, fn
        {:signer, role, id} ->
          emp = Map.get(employees, id)
          [role, text(emp && emp[:full_name]), text(emp && emp[:code]), "", ""]

        row ->
          row
      end)

    %{sheet | rows: filled}
  end

  defp write(sheets, name) do
    case Elixlsx.write_to_memory(%Workbook{sheets: sheets}, name) do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  end

  # -- document sheet -------------------------------------------------------------------------

  defp document_rows(kind, issued, names) do
    content = Map.get(issued, :content, %{})
    unit = Map.get(names, :org_unit)

    base = [
      ["document", Atom.to_string(kind)],
      ["number", text(issued[:number_label])],
      ["version_no", issued[:version_no]],
      ["issued_at", time(issued[:issued_at], names, :issued_at)],
      ["org_unit", unit_text(unit)],
      ["timezone", text(Map.get(names, :timezone))]
    ]

    extra =
      case kind do
        :order ->
          [
            ["count_kind", text(content["kind"])],
            ["planned_start", time(content["planned_start"], names, :planned_start)],
            ["planned_end", time(content["planned_end"], names, :planned_end)],
            ["note", text(content["note"])]
          ]

        _ ->
          [["cut_off_at", time(content["cut_off_at"], names, :cut_off_at)]]
      end

    [["field", "value"] | base ++ extra]
  end

  @doc false
  def unit_text(%{} = unit),
    do: [unit[:code], unit[:name]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  def unit_text(_), do: ""

  # The unit of measure shows its name; the raw reference only when the master record is not found.
  @doc false
  def unit_cell(nil, ref), do: text(ref)
  def unit_cell(unit, ref), do: with("" <- unit_text(unit), do: text(ref))

  @doc false
  def time(nil, _names, _key), do: ""

  def time(value, names, key) do
    case to_utc(value) do
      {:ok, dt} ->
        offset = names |> Map.get(:offsets, %{}) |> Map.get(key, 0)
        format(DateTime.add(dt, offset, :second), offset)

      :error ->
        text(value)
    end
  end

  defp to_utc(%DateTime{} = dt), do: {:ok, dt}

  defp to_utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp to_utc(_), do: :error

  defp format(%DateTime{} = shifted, offset) do
    sign = if offset < 0, do: "-", else: "+"
    abs_off = abs(offset)
    hh = abs_off |> div(3600) |> pad()
    mm = abs_off |> rem(3600) |> div(60) |> pad()

    shifted
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    |> Kernel.<>("#{sign}#{hh}:#{mm}")
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # -- lines sheet ----------------------------------------------------------------------------

  @doc false
  def lines_of(:differences, content),
    do: list(content["lines"] || content["items"])

  def lines_of(_, content), do: list(content["lines"])

  defp list(l) when is_list(l), do: Enum.sort_by(l, &(&1["line_no"] || 0))
  defp list(_), do: []

  defp line_rows(kind, lines, names) do
    locations = Map.get(names, :locations, %{})
    items = Map.get(names, :items, %{})
    lots = Map.get(names, :lots, %{})
    units = Map.get(names, :units, %{})
    employees = Map.get(names, :employees, %{})

    header =
      ~w(line_no location_code location_name item_code item_name lot_code responsible_full_name
         responsible_code unit book_quantity counted_quantity) ++
        if(kind == :differences, do: ~w(difference direction), else: [])

    rows =
      for line <- lines do
        loc = Map.get(locations, line["location_id"]) || %{}
        item = Map.get(items, line["catalog_item_id"]) || %{}
        emp = Map.get(employees, line["responsible_employee_id"]) || %{}

        [
          line["line_no"],
          text(loc[:code]),
          text(loc[:name]),
          text(item[:code]),
          text(item[:name]),
          text(Map.get(lots, line["catalog_lot_id"])),
          text(emp[:full_name]),
          text(emp[:code]),
          unit_cell(Map.get(units, line["unit_ref"]), line["unit_ref"]),
          text(line["book_quantity"]),
          text(line["counted_quantity"])
        ] ++
          if(kind == :differences,
            do: [text(line["difference"]), text(line["direction"])],
            else: []
          )
      end

    [header | rows]
  end

  # -- scope sheet (order) --------------------------------------------------------------------

  defp scope_rows(order, names) do
    locations = Map.get(names, :locations, %{})
    employees = Map.get(names, :employees, %{})

    location_rows =
      for id <- list_ids(order["location_ids"]) do
        loc = Map.get(locations, id) || %{}
        ["location", text(loc[:code]), text(loc[:name])]
      end

    person = fn role, id ->
      emp = Map.get(employees, id) || %{}
      [role, text(emp[:code]), text(emp[:full_name])]
    end

    chair =
      if order["chair_employee_id"], do: [person.("chair", order["chair_employee_id"])], else: []

    members = for id <- list_ids(order["member_employee_ids"]), do: person.("member", id)

    [~w(role code name)] ++ location_rows ++ chair ++ members
  end

  @doc false
  def list_ids(l) when is_list(l), do: l
  def list_ids(_), do: []

  @doc false
  def text(nil), do: ""
  def text(v) when is_binary(v), do: v
  def text(v), do: to_string(v)

  # -- signatures sheet -----------------------------------------------------------------------

  # `{:signer, role, employee_id}` placeholders are filled by `resolve/2`.
  defp signature_rows(signers) do
    [~w(role full_name personnel_code signature date) | signers]
  end

  defp signer_rows(kind, order, lines),
    do: kind |> signers(order, lines) |> Enum.map(fn {role, id} -> {:signer, role, id} end)

  @doc """
  The signers of a document as `{role, employee_id}` pairs, in print order: shared by the xlsx and
  the PDF (REQ-736) so both name the same people in the same order.
  """
  @spec signers(kind(), map(), [map()]) :: [{String.t(), term()}]
  def signers(kind, order, lines) do
    chair = if order["chair_employee_id"], do: [{"chair", order["chair_employee_id"]}], else: []

    {members, responsible} =
      if kind == :order do
        {[], []}
      else
        {Enum.map(list_ids(order["member_employee_ids"]), &{"member", &1}),
         lines
         |> Enum.filter(&(kind == :sheet or difference_line?(&1)))
         |> Enum.map(& &1["responsible_employee_id"])
         |> Enum.reject(&is_nil/1)
         |> Enum.map(&{"responsible", &1})}
      end

    (chair ++ members ++ responsible)
    |> Enum.uniq_by(fn {_role, id} -> id end)
  end

  # Every line of a differences document is a difference line (REQ-717); a zero difference is skipped.
  defp difference_line?(%{"difference" => d}) when is_binary(d), do: not zero?(d)
  defp difference_line?(_), do: true

  defp zero?(d), do: d |> String.replace(~r/[-+.0]/, "") == ""
end
