defmodule Letflow.Modules.Stock.CountPrint do
  @moduledoc """
  REQ-736 / GH #3861: the count paperwork (order, sheet, differences) as an A4 PDF in ru, kk or en.
  Pure: issued content and names in, PDF bytes out; no database, no clock, no process. The
  layout is built in code and rendered by `Letflow.Documents.PrintLayout.render/4` (REQ-571),
  which is not changed.

  The input is the output of `Letflow.Modules.Stock.CountPaperworkSource.read/4`, the same read
  path as the xlsx (`CountPaperwork`), so scope, name hiding, the issued-version rule, the signer
  set and order (`CountPaperwork.signers/3`) and the time format (`CountPaperwork.time/3`) are the
  same code for both outputs.

  Every literal (title, labels, headers) comes from `labels/0`, never from data; all data goes
  through the projection. A table never holds more than 1000 rows: the lines are split into
  tables `lines_0`, `lines_1`, ... of at most 1000 rows each. Quantities are the stored decimal
  text, unchanged. An employee hidden by scope keeps the signer row with empty name and code.

  Not an official form: the titles and labels in Russian and Kazakh are a machine draft for the
  native check (UAT), and official wording is decision 0068 D6, not decided here.
  """

  alias Letflow.Documents.PrintLayout
  alias Letflow.Modules.Stock.CountPaperwork

  @type kind :: :order | :sheet | :differences
  @type lang :: :ru | :kk | :en

  @max_rows 1000

  @labels %{
    title_order: %{
      en: "Stock count order",
      ru: "Приказ о проведении инвентаризации",
      kk: "Түгендеу жүргізу туралы бұйрық"
    },
    title_sheet: %{
      en: "Count sheet",
      ru: "Инвентаризационная опись",
      kk: "Түгендеу тізімдемесі"
    },
    title_differences: %{
      en: "Differences sheet",
      ru: "Сличительная ведомость",
      kk: "Салыстыру ведомосы"
    },
    number: %{en: "Number", ru: "Номер", kk: "Нөмірі"},
    version: %{en: "Version", ru: "Версия", kk: "Нұсқа"},
    issued_at: %{en: "Issued at", ru: "Выдан", kk: "Берілген уақыты"},
    org_unit: %{en: "Organisation unit", ru: "Подразделение", kk: "Бөлімше"},
    timezone: %{en: "Time zone", ru: "Часовой пояс", kk: "Уақыт белдеуі"},
    cut_off_at: %{en: "Cut-off", ru: "Дата и время среза", kk: "Қиып алу уақыты"},
    planned_start: %{en: "Planned start", ru: "Начало (план)", kk: "Басталуы (жоспар)"},
    planned_end: %{en: "Planned end", ru: "Окончание (план)", kk: "Аяқталуы (жоспар)"},
    note: %{en: "Note", ru: "Примечание", kk: "Ескертпе"},
    locations: %{en: "Locations", ru: "Места хранения", kk: "Сақтау орындары"},
    commission: %{en: "Commission", ru: "Комиссия", kk: "Комиссия"},
    signatures: %{en: "Signatures", ru: "Подписи", kk: "Қолдар"},
    role_chair: %{en: "Chair", ru: "Председатель", kk: "Төраға"},
    role_member: %{en: "Member", ru: "Член комиссии", kk: "Комиссия мүшесі"},
    role_responsible: %{
      en: "Responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
    role: %{en: "Role", ru: "Роль", kk: "Рөлі"},
    code: %{en: "Code", ru: "Код", kk: "Коды"},
    name: %{en: "Name", ru: "Наименование", kk: "Атауы"},
    full_name: %{en: "Full name", ru: "ФИО", kk: "Аты-жөні"},
    personnel_code: %{en: "Personnel code", ru: "Табельный номер", kk: "Табель нөмірі"},
    signature: %{en: "Signature", ru: "Подпись", kk: "Қолы"},
    date: %{en: "Date", ru: "Дата", kk: "Күні"},
    line_no: %{en: "No.", ru: "№", kk: "№"},
    location: %{en: "Location", ru: "Место", kk: "Орын"},
    item: %{en: "Item", ru: "Номенклатура", kk: "Номенклатура"},
    lot: %{en: "Lot", ru: "Партия", kk: "Партия"},
    responsible: %{en: "Responsible", ru: "Ответственный", kk: "Жауапты"},
    unit: %{en: "Unit", ru: "Ед. изм.", kk: "Өлш. бірл."},
    book_qty: %{en: "Book qty", ru: "По учёту", kk: "Есеп бойынша"},
    counted_qty: %{en: "Counted qty", ru: "Фактически", kk: "Нақты"},
    difference: %{en: "Difference", ru: "Разница", kk: "Айырма"},
    direction: %{en: "Direction", ru: "Вид", kk: "Түрі"}
  }

  @doc "All label keys with their texts per language (the test enumerates it)."
  @spec labels() :: %{atom() => %{ru: String.t(), kk: String.t(), en: String.t()}}
  def labels, do: @labels

  @doc """
  The PDF of one issued count document. `{:error, :unsupported_glyph}` when a value has a
  character the font lacks; `{:error, {:render_failed, rules}}` for any other violation (rule
  atoms only, never a value).
  """
  @spec build(kind(), map(), map(), lang()) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def build(kind, issued, names, lang)
      when kind in [:order, :sheet, :differences] and lang in [:ru, :kk, :en] do
    {layout, projection} = layout(kind, issued, names, lang)

    declared =
      Map.new(projection, fn
        {et, %{} = fields} -> {et, Map.keys(fields)}
        {et, rows} when is_list(rows) -> {et, row_fields(et)}
      end)

    case PrintLayout.render(layout, projection, declared) do
      {:ok, pdf} ->
        {:ok, pdf}

      {:error, violations} ->
        rules = Enum.map(violations, & &1.rule)

        if :unsupported_glyph in rules,
          do: {:error, :unsupported_glyph},
          else: {:error, {:render_failed, rules}}
    end
  end

  @doc false
  # Test seam: the layout and the projection `build/4` renders.
  @spec layout(kind(), map(), map(), lang()) :: {map(), map()}
  def layout(kind, issued, names, lang) do
    content = Map.get(issued, :content, %{})
    order = Map.get(issued, :order_content, content)
    l = fn key -> Map.fetch!(@labels, key) |> Map.fetch!(lang) end

    doc = doc_fields(kind, issued, content, names)

    {blocks, tables} =
      case kind do
        :order -> order_part(order, names, l)
        _ -> lines_part(kind, content, names, l)
      end

    signer_rows = signer_rows(kind, order, content, names, l)

    layout = %{
      "layout_schema_version" => 1,
      "blocks" =>
        [
          %{"type" => "page", "size" => "A4", "margin_mm" => 15, "font" => "dejavu-sans"},
          %{"type" => "text", "text" => l.(title_key(kind))}
        ] ++
          field_blocks(kind, doc, l) ++
          [%{"type" => "spacer", "height_mm" => 4}] ++
          blocks ++
          [
            %{"type" => "spacer", "height_mm" => 6},
            %{"type" => "text", "text" => l.(:signatures)},
            table("signers", signer_columns(l))
          ]
    }

    projection = tables |> Map.new() |> Map.put("doc", doc) |> Map.put("signers", signer_rows)
    {layout, projection}
  end

  defp title_key(:order), do: :title_order
  defp title_key(:sheet), do: :title_sheet
  defp title_key(:differences), do: :title_differences

  # -- document fields ------------------------------------------------------------------------

  defp doc_fields(kind, issued, content, names) do
    unit = CountPaperwork.unit_text(Map.get(names, :org_unit))
    time = fn value, key -> CountPaperwork.time(value, names, key) end

    base = %{
      "number" => CountPaperwork.text(issued[:number_label]),
      "version_no" => CountPaperwork.text(issued[:version_no]),
      "issued_at" => time.(issued[:issued_at], :issued_at),
      "org_unit" => unit,
      "timezone" => CountPaperwork.text(Map.get(names, :timezone))
    }

    case kind do
      :order ->
        Map.merge(base, %{
          "planned_start" => time.(content["planned_start"], :planned_start),
          "planned_end" => time.(content["planned_end"], :planned_end),
          "note" => CountPaperwork.text(content["note"])
        })

      _ ->
        Map.put(base, "cut_off_at", time.(content["cut_off_at"], :cut_off_at))
    end
  end

  @optional ~w(planned_start planned_end note cut_off_at)

  defp field_blocks(kind, doc, l) do
    order = ~w(number version_no issued_at org_unit timezone) ++ extra_fields(kind)

    for f <- order, Map.has_key?(doc, f) do
      block = %{
        "type" => "field",
        "entity_type" => "doc",
        "field_name" => f,
        "label" => l.(label_key(f))
      }

      if f in @optional, do: Map.put(block, "show_if_nonempty", true), else: block
    end
  end

  defp extra_fields(:order), do: ~w(planned_start planned_end note)
  defp extra_fields(_), do: ~w(cut_off_at)

  defp label_key("version_no"), do: :version
  defp label_key("number"), do: :number
  defp label_key("issued_at"), do: :issued_at
  defp label_key("org_unit"), do: :org_unit
  defp label_key("timezone"), do: :timezone
  defp label_key("planned_start"), do: :planned_start
  defp label_key("planned_end"), do: :planned_end
  defp label_key("note"), do: :note
  defp label_key("cut_off_at"), do: :cut_off_at

  # -- order ----------------------------------------------------------------------------------

  defp order_part(order, names, l) do
    locations = Map.get(names, :locations, %{})
    employees = Map.get(names, :employees, %{})

    location_rows =
      for id <- CountPaperwork.list_ids(order["location_ids"]) do
        loc = Map.get(locations, id) || %{}
        %{"code" => CountPaperwork.text(loc[:code]), "name" => CountPaperwork.text(loc[:name])}
      end

    person = fn role, id ->
      emp = Map.get(employees, id) || %{}

      %{
        "role" => role,
        "full_name" => CountPaperwork.text(emp[:full_name]),
        "code" => CountPaperwork.text(emp[:code])
      }
    end

    chair =
      if order["chair_employee_id"],
        do: [person.(l.(:role_chair), order["chair_employee_id"])],
        else: []

    members =
      for id <- CountPaperwork.list_ids(order["member_employee_ids"]),
          do: person.(l.(:role_member), id)

    blocks = [
      %{"type" => "text", "text" => l.(:locations)},
      table("locations", [col("code", l.(:code), 1), col("name", l.(:name), 3)]),
      %{"type" => "spacer", "height_mm" => 4},
      %{"type" => "text", "text" => l.(:commission)},
      table("commission", [
        col("role", l.(:role), 2),
        col("full_name", l.(:full_name), 3),
        col("code", l.(:personnel_code), 1)
      ])
    ]

    {blocks, [{"locations", location_rows}, {"commission", chair ++ members}]}
  end

  # -- sheet and differences ------------------------------------------------------------------

  defp lines_part(kind, content, names, l) do
    lines = CountPaperwork.lines_of(kind, content)
    rows = Enum.map(lines, &line_row(kind, &1, names))
    chunks = if rows == [], do: [[]], else: Enum.chunk_every(rows, @max_rows)

    named = chunks |> Enum.with_index() |> Enum.map(fn {c, i} -> {"lines_#{i}", c} end)

    blocks =
      for {name, _} <- named do
        table(name, line_columns(kind, l))
      end

    {blocks, named}
  end

  defp line_row(kind, line, names) do
    loc = Map.get(Map.get(names, :locations, %{}), line["location_id"]) || %{}
    item = Map.get(Map.get(names, :items, %{}), line["catalog_item_id"]) || %{}
    emp = Map.get(Map.get(names, :employees, %{}), line["responsible_employee_id"]) || %{}
    text = &CountPaperwork.text/1

    base = %{
      "line_no" => text.(line["line_no"]),
      "location" => CountPaperwork.unit_text(loc),
      "item" => CountPaperwork.unit_text(item),
      "lot" => text.(Map.get(Map.get(names, :lots, %{}), line["catalog_lot_id"])),
      "responsible" => text.(emp[:full_name]),
      "unit" => text.(line["unit_ref"]),
      "book_qty" => text.(line["book_quantity"]),
      "counted_qty" => text.(line["counted_quantity"])
    }

    if kind == :differences,
      do:
        Map.merge(base, %{
          "difference" => text.(line["difference"]),
          "direction" => text.(line["direction"])
        }),
      else: base
  end

  defp line_columns(kind, l) do
    base = [
      col("line_no", l.(:line_no), 0.5),
      col("location", l.(:location), 2),
      col("item", l.(:item), 3),
      col("lot", l.(:lot), 1),
      col("responsible", l.(:responsible), 2),
      col("unit", l.(:unit), 1),
      col("book_qty", l.(:book_qty), 1.5),
      col("counted_qty", l.(:counted_qty), 1.5)
    ]

    if kind == :differences,
      do: base ++ [col("difference", l.(:difference), 1.5), col("direction", l.(:direction), 1)],
      else: base
  end

  @line_fields ~w(line_no location item lot responsible unit book_qty counted_qty)

  defp row_fields("locations"), do: ~w(code name)
  defp row_fields("commission"), do: ~w(role full_name code)
  defp row_fields("signers"), do: ~w(role full_name code signature date)
  defp row_fields("lines_" <> _), do: @line_fields ++ ~w(difference direction)

  # -- signers --------------------------------------------------------------------------------

  defp signer_columns(l) do
    [
      col("role", l.(:role), 2),
      col("full_name", l.(:full_name), 3),
      col("code", l.(:personnel_code), 1),
      col("signature", l.(:signature), 2),
      col("date", l.(:date), 1)
    ]
  end

  defp signer_rows(kind, order, content, names, l) do
    employees = Map.get(names, :employees, %{})
    lines = if kind == :order, do: [], else: CountPaperwork.lines_of(kind, content)

    for {role, id} <- CountPaperwork.signers(kind, order, lines) do
      emp = Map.get(employees, id) || %{}

      %{
        "role" => l.(role_key(role)),
        "full_name" => CountPaperwork.text(emp[:full_name]),
        "code" => CountPaperwork.text(emp[:code]),
        "signature" => "",
        "date" => ""
      }
    end
  end

  defp role_key("chair"), do: :role_chair
  defp role_key("member"), do: :role_member
  defp role_key("responsible"), do: :role_responsible

  # -- blocks ---------------------------------------------------------------------------------

  defp table(entity, columns),
    do: %{"type" => "table", "entity_type" => entity, "columns" => columns}

  defp col(field, header, width),
    do: %{"field_name" => field, "header" => header, "width" => width}
end
