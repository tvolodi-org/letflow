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

  Language (T-1435): `build/4` with `lang` `:ru`, `:kk` or `:en` prints sheet names, header cells, role values and times
  in that language (the labels of `CountPrint`, the PDF, plus a small table of the xlsx-only keys); times are then
  `DD-MM-YYYY HH:MM` (`YYYY-MM-DD HH:MM` for `:en`) in the tenant zone, the `timezone` row keeps the zone name.
  Without `lang` (`nil`, `build/3`) the old output is unchanged: snake_case keys and ISO times with offset.

  Layout and English labels are an assumption, owner may change at GATE B (printed forms: phase E).
  """

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.XlsxStyle

  @type kind :: :order | :sheet | :differences

  @type lang :: :ru | :kk | :en | nil

  # xlsx-only keys (the others are read from `CountPrint.labels/0`, see `@shared`).
  @own %{
    "document" => %{en: "Document", ru: "Документ", kk: "Құжат"},
    "scope" => %{en: "Scope", ru: "Охват", kk: "Көлемі"},
    "lines" => %{en: "Lines", ru: "Строки", kk: "Жолдар"},
    "field" => %{en: "Field", ru: "Поле", kk: "Өріс"},
    "value" => %{en: "Value", ru: "Значение", kk: "Мәні"},
    "count_kind" => %{en: "Count kind", ru: "Вид инвентаризации", kk: "Түгендеу түрі"},
    "location_code" => %{en: "Location code", ru: "Код места", kk: "Орын коды"},
    "location_name" => %{en: "Location name", ru: "Название места", kk: "Орын атауы"},
    "item_code" => %{en: "Item code", ru: "Код номенклатуры", kk: "Номенклатура коды"},
    "item_name" => %{en: "Item name", ru: "Наименование номенклатуры", kk: "Номенклатура атауы"},
    "lot_code" => %{en: "Lot code", ru: "Код партии", kk: "Партия коды"},
    "responsible_full_name" => %{
      en: "Responsible",
      ru: "Ответственный (ФИО)",
      kk: "Жауапты (аты-жөні)"
    },
    "responsible_code" => %{
      en: "Responsible code",
      ru: "Табельный номер ответственного",
      kk: "Жауапты табель нөмірі"
    }
  }

  @shared %{
    "number" => :number,
    "version_no" => :version,
    "issued_at" => :issued_at,
    "org_unit" => :org_unit,
    "timezone" => :timezone,
    "planned_start" => :planned_start,
    "planned_end" => :planned_end,
    "cut_off_at" => :cut_off_at,
    "note" => :note,
    "role" => :role,
    "code" => :code,
    "name" => :name,
    "full_name" => :full_name,
    "personnel_code" => :personnel_code,
    "signature" => :signature,
    "date" => :date,
    "line_no" => :line_no,
    "location" => :location,
    "unit" => :unit,
    "book_quantity" => :book_qty,
    "counted_quantity" => :counted_qty,
    "difference" => :difference,
    "direction" => :direction,
    "signatures" => :signatures,
    "chair" => :role_chair,
    "member" => :role_member,
    "responsible" => :role_responsible,
    "order" => :title_order,
    "sheet" => :title_sheet,
    "differences" => :title_differences
  }

  # `nil` keeps the key text itself (the old output); a language prints the label.
  defp lb(nil, key), do: key

  defp lb(lang, key) do
    case Map.fetch(@shared, key) do
      {:ok, label} -> Letflow.Modules.Stock.CountPrint.labels()[label][lang]
      :error -> @own[key][lang]
    end
  end

  @doc "The workbook of one issued count document."
  @spec build(kind(), map(), map(), lang()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def build(kind, issued, names, lang \\ nil)
      when kind in [:order, :sheet, :differences] and lang in [nil, :ru, :kk, :en] do
    content = Map.get(issued, :content, %{})
    order = Map.get(issued, :order_content, content)

    sheets =
      case kind do
        :order ->
          [
            sheet(lb(lang, "document"), document_rows(kind, issued, names, lang)),
            sheet(lb(lang, "scope"), scope_rows(order, names, lang)),
            sheet(lb(lang, "signatures"), signature_rows(signer_rows(kind, order, []), lang))
            |> then(&resolve(&1, names, lang))
          ]

        _ ->
          lines = lines_of(kind, content)

          [
            sheet(lb(lang, "document"), document_rows(kind, issued, names, lang)),
            sheet(lb(lang, "lines"), line_rows(kind, lines, names, lang)),
            sheet(lb(lang, "signatures"), signature_rows(signer_rows(kind, order, lines), lang))
            |> then(&resolve(&1, names, lang))
          ]
      end

    write(sheets, "count-#{kind}.xlsx")
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp sheet(name, rows), do: %Sheet{name: name, rows: rows}

  # Same cells; bold frozen header, fitted widths (T-1555).
  # The first sheet (document) is key/value pairs, not a table: widths only.
  defp style_all([doc | tables]),
    do: [XlsxStyle.style(doc, false) | Enum.map(tables, &XlsxStyle.style/1)]

  # The signatures rows are built with employee ids and filled with names here.
  defp resolve(%Sheet{rows: rows} = sheet, names, lang) do
    employees = Map.get(names, :employees, %{})

    filled =
      Enum.map(rows, fn
        {:signer, role, id} ->
          emp = Map.get(employees, id)
          [lb(lang, role), text(emp && emp[:full_name]), text(emp && emp[:code]), "", ""]

        row ->
          row
      end)

    %{sheet | rows: filled}
  end

  defp write(sheets, name) do
    case XlsxStyle.write_to_memory(%Workbook{sheets: style_all(sheets)}, name) do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  end

  # -- document sheet -------------------------------------------------------------------------

  defp document_rows(kind, issued, names, lang) do
    t = fn value, key -> time(value, names, key, lang) end
    content = Map.get(issued, :content, %{})
    unit = Map.get(names, :org_unit)

    base = [
      [lb(lang, "document"), lb(lang, Atom.to_string(kind))],
      [lb(lang, "number"), text(issued[:number_label])],
      [lb(lang, "version_no"), issued[:version_no]],
      [lb(lang, "issued_at"), t.(issued[:issued_at], :issued_at)],
      [lb(lang, "org_unit"), unit_text(unit)],
      [lb(lang, "timezone"), text(Map.get(names, :timezone))]
    ]

    extra =
      case kind do
        :order ->
          [
            [lb(lang, "count_kind"), text(content["kind"])],
            [lb(lang, "planned_start"), t.(content["planned_start"], :planned_start)],
            [lb(lang, "planned_end"), t.(content["planned_end"], :planned_end)],
            [lb(lang, "note"), text(content["note"])]
          ]

        _ ->
          [[lb(lang, "cut_off_at"), t.(content["cut_off_at"], :cut_off_at)]]
      end

    [[lb(lang, "field"), lb(lang, "value")] | base ++ extra]
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
  def time(value, names, key), do: time(value, names, key, nil)

  @doc false
  def time(nil, _names, _key, _lang), do: ""

  def time(value, names, key, lang) do
    case to_utc(value) do
      {:ok, dt} ->
        offset = names |> Map.get(:offsets, %{}) |> Map.get(key, 0)
        shifted = DateTime.add(dt, offset, :second)
        if lang, do: format_local(shifted, lang), else: format(shifted, offset)

      :error ->
        text(value)
    end
  end

  @doc false
  # T-1555: the time of a printed act, localized like the UI plus the zone offset the stored
  # instant was shifted by: `04-11-2026 10:00 (UTC+05:00)` (ru/kk), `2026-11-04 10:00 (UTC+05:00)` (en).
  # A text that is not a time prints as stored.
  def print_time(nil, _names, _key, _lang), do: ""

  def print_time(value, names, key, lang) do
    case to_utc(value) do
      {:ok, dt} ->
        offset = names |> Map.get(:offsets, %{}) |> Map.get(key, 0)
        shifted = DateTime.add(dt, offset, :second)
        "#{format_local(shifted, lang)} (UTC#{offset_text(offset)})"

      :error ->
        text(value)
    end
  end

  defp offset_text(offset) do
    sign = if offset < 0, do: "-", else: "+"
    abs_off = abs(offset)
    "#{sign}#{abs_off |> div(3600) |> pad()}:#{abs_off |> rem(3600) |> div(60) |> pad()}"
  end

  @doc false
  # T-1555: a stored plain decimal text regrouped for print. ru/kk `49 360,500` (no-break space,
  # comma), en `49,360.500`. Digits are never rounded or dropped; anything else is returned as stored.
  def number(value, lang) do
    str = text(value)

    case Regex.run(~r/\A(-?)(\d+)(?:\.(\d+))?\z/, str) do
      [_, sign, int, frac] -> group_number(sign, int, frac, lang)
      [_, sign, int] -> group_number(sign, int, "", lang)
      _ -> str
    end
  end

  defp group_number(sign, int, frac, lang) do
    {group, point} = if lang == :en, do: {",", "."}, else: {"\u00A0", ","}

    grouped =
      int
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join()))
      |> Enum.reverse()
      |> Enum.join(group)

    sign <> grouped <> if(frac == "", do: "", else: point <> frac)
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

  # T-1435: the localized form, like the UI: ru/kk `DD-MM-YYYY HH:MM`, en `YYYY-MM-DD HH:MM`.
  defp format_local(%DateTime{} = shifted, lang) do
    pattern = if lang == :en, do: "%Y-%m-%d %H:%M", else: "%d-%m-%Y %H:%M"
    Calendar.strftime(shifted, pattern)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # -- lines sheet ----------------------------------------------------------------------------

  @doc false
  def lines_of(:differences, content),
    do: list(content["lines"] || content["items"])

  def lines_of(_, content), do: list(content["lines"])

  defp list(l) when is_list(l), do: Enum.sort_by(l, &(&1["line_no"] || 0))
  defp list(_), do: []

  defp line_rows(kind, lines, names, lang) do
    locations = Map.get(names, :locations, %{})
    items = Map.get(names, :items, %{})
    lots = Map.get(names, :lots, %{})
    units = Map.get(names, :units, %{})
    employees = Map.get(names, :employees, %{})

    header =
      Enum.map(
        ~w(line_no location_code location_name item_code item_name lot_code responsible_full_name
           responsible_code unit book_quantity counted_quantity) ++
          if(kind == :differences, do: ~w(difference direction), else: []),
        &lb(lang, &1)
      )

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

  defp scope_rows(order, names, lang) do
    locations = Map.get(names, :locations, %{})
    employees = Map.get(names, :employees, %{})

    location_rows =
      for id <- list_ids(order["location_ids"]) do
        loc = Map.get(locations, id) || %{}
        [lb(lang, "location"), text(loc[:code]), text(loc[:name])]
      end

    person = fn role, id ->
      emp = Map.get(employees, id) || %{}
      [role, text(emp[:code]), text(emp[:full_name])]
    end

    chair =
      if order["chair_employee_id"],
        do: [person.(lb(lang, "chair"), order["chair_employee_id"])],
        else: []

    members =
      for id <- list_ids(order["member_employee_ids"]), do: person.(lb(lang, "member"), id)

    [Enum.map(~w(role code name), &lb(lang, &1))] ++ location_rows ++ chair ++ members
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
  defp signature_rows(signers, lang) do
    [Enum.map(~w(role full_name personnel_code signature date), &lb(lang, &1)) | signers]
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
