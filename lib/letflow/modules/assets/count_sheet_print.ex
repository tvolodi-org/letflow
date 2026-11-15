defmodule Letflow.Modules.Assets.CountSheetPrint do
  @moduledoc """
  T-1932 (REQ-821, asset count K6): the plain printed count sheet of an issued `assets_count.sheet`
  as an A4 PDF in ru, kk or en, for the count team to take along. Pure: the output of
  `CountPrintSource.read/3` in, PDF bytes out; no database, no clock, no process. The layout is built in
  code and rendered by `Letflow.Documents.PrintLayout.render/3`, which is not changed (the pattern of
  `Letflow.Modules.Assets.DocumentPrint`). The official form is `FormCountInv8`.

  Every literal comes from `labels/0`, never from data; all data goes through the projection. Quantities
  are the stored decimal text regrouped, never rounded. A name that no longer resolves prints as empty
  text, never as a raw id. The book value prints only on a book line of a KZT card (same rule as the
  official form). The lines go into tables of at most 1000 rows each (`PrintLayout` refuses more; a sheet
  has at most 2000 lines). The signers table has one empty signature and date cell per required signer.

  Not an official form: the Russian and Kazakh wording is a machine draft for the native check (UAT).
  """

  alias Letflow.Documents.PrintLayout
  alias Letflow.Modules.Assets.CountPrintSource
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.FormCountInv8
  alias Letflow.Modules.Assets.FormDa1

  @type lang :: :ru | :kk | :en

  @table_rows 1000

  @labels %{
    title: %{
      en: "Asset count sheet",
      ru: "Опись инвентаризации активов",
      kk: "Активтерді түгендеу тізімдемесі"
    },
    organisation: %{en: "Organisation", ru: "Организация", kk: "Ұйым"},
    bin: %{en: "BIN", ru: "БИН", kk: "БСН"},
    org_unit: %{en: "Org unit", ru: "Подразделение", kk: "Бөлімше"},
    number: %{en: "Number", ru: "Номер", kk: "Нөмірі"},
    issued_at: %{en: "Issued at", ru: "Выдан", kk: "Берілген уақыты"},
    order_no: %{en: "Count order", ru: "Приказ на инвентаризацию", kk: "Түгендеу бұйрығы"},
    order_date: %{en: "Order date", ru: "Дата приказа", kk: "Бұйрық күні"},
    cut_off: %{en: "Cut-off", ru: "Дата среза", kk: "Есеп күні"},
    location: %{en: "Location", ru: "Местонахождение", kk: "Орналасқан жері"},
    line_no: %{en: "No.", ru: "№", kk: "№"},
    name: %{en: "Name", ru: "Наименование", kk: "Атауы"},
    inventory_number: %{
      en: "Inventory number",
      ru: "Инвентарный номер",
      kk: "Инвентарлық нөмірі"
    },
    acquisition_date: %{en: "Acquired", ru: "Дата приобретения", kk: "Сатып алынған күні"},
    counted: %{en: "Counted", ru: "Фактически", kk: "Іс жүзінде"},
    book_quantity: %{en: "Book quantity", ru: "По учёту", kk: "Есеп бойынша"},
    book_value: %{
      en: "Book value, KZT",
      ru: "Балансовая стоимость, теңге",
      kk: "Баланстық құны, теңге"
    },
    total_lines: %{en: "Lines", ru: "Строк", kk: "Жолдар саны"},
    total_counted: %{en: "Total counted", ru: "Всего фактически", kk: "Барлығы іс жүзінде"},
    signatures: %{en: "Signatures", ru: "Подписи", kk: "Қолдар"},
    role: %{en: "Role", ru: "Роль", kk: "Рөлі"},
    chair: %{en: "Commission chair", ru: "Председатель комиссии", kk: "Комиссия төрағасы"},
    member: %{en: "Commission member", ru: "Член комиссии", kk: "Комиссия мүшесі"},
    responsible: %{
      en: "Material responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
    full_name: %{en: "Full name", ru: "ФИО", kk: "Аты-жөні"},
    position: %{en: "Position", ru: "Должность", kk: "Лауазымы"},
    signature: %{en: "Signature", ru: "Подпись", kk: "Қолы"},
    date: %{en: "Date", ru: "Дата", kk: "Күні"}
  }

  @doc "All label keys with their texts per language (the test enumerates it)."
  @spec labels() :: %{atom() => %{ru: String.t(), kk: String.t(), en: String.t()}}
  def labels, do: @labels

  @doc """
  The PDF of one issued sheet. `{:error, :unsupported_glyph}` when a value has a character the font
  lacks; `{:error, {:render_failed, rules}}` for any other violation (rule atoms only, never a value).
  """
  @spec build(map(), map(), lang()) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def build(issued, names, lang) when lang in [:ru, :kk, :en] do
    {layout, projection} = layout(issued, names, lang)

    declared =
      Map.new(projection, fn
        {et, %{} = fields} ->
          {et, Map.keys(fields)}

        {"signers", rows} when is_list(rows) ->
          {"signers", ~w(role full_name position signature date)}

        {et, rows} when is_list(rows) ->
          {et, ~w(line_no name inventory_number acquired counted book_quantity book_value)}
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
  # Test seam: the layout and the projection `build/3` renders.
  @spec layout(map(), map(), lang()) :: {map(), map()}
  def layout(issued, names, lang) do
    content = Map.get(issued, :content, %{})
    l = fn key -> Map.fetch!(@labels, key) |> Map.fetch!(lang) end
    rows = content |> CountPrintSource.lines() |> Enum.map(&line_row(&1, names, lang))
    chunks = if rows == [], do: [[]], else: Enum.chunk_every(rows, @table_rows)
    tables = chunks |> Enum.with_index() |> Enum.map(fn {c, i} -> {"lines_#{i}", c} end)

    layout = %{
      "layout_schema_version" => 1,
      "blocks" =>
        [
          %{"type" => "page", "size" => "A4", "margin_mm" => 15, "font" => "dejavu-sans"},
          %{"type" => "text", "text" => l.(:title)}
        ] ++
          field_blocks(l) ++
          [%{"type" => "spacer", "height_mm" => 4}] ++
          Enum.map(tables, fn {entity, _} -> table(entity, line_columns(l)) end) ++
          [
            %{"type" => "spacer", "height_mm" => 2},
            field("total_lines", l.(:total_lines)),
            field("total_counted", l.(:total_counted)),
            %{"type" => "spacer", "height_mm" => 6},
            %{"type" => "text", "text" => l.(:signatures)},
            table("signers", [
              col("role", l.(:role), 2),
              col("full_name", l.(:full_name), 3),
              col("position", l.(:position), 2),
              col("signature", l.(:signature), 2),
              col("date", l.(:date), 1)
            ])
          ]
    }

    projection =
      Map.merge(
        %{
          "doc" => doc_fields(issued, content, names, lang, rows),
          "signers" => signers(content, names, l)
        },
        Map.new(tables)
      )

    {layout, projection}
  end

  # -- header ---------------------------------------------------------------------------------

  defp doc_fields(issued, content, names, lang, rows) do
    entity = FormDa1.lookup(names, :legal_entities, content["org_unit_id"])
    unit = FormDa1.lookup(names, :org_units, content["org_unit_id"])
    order = Map.get(names, :order) || %{}

    order_no =
      case text(order[:number_label]) do
        "" -> text(content["order_number"])
        label -> label
      end

    %{
      "organisation" => text(entity[:name]),
      "bin" => text(entity[:bin]),
      "org_unit" =>
        [unit[:code], unit[:name]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" "),
      "number" => text(issued[:number_label]),
      "issued_at" => DocumentPrint.print_time(issued[:issued_at], names, :issued_at, lang),
      "order_no" => order_no,
      "order_date" => DocumentPrint.print_time(order[:issued_at], names, :order_issued_at, lang),
      "cut_off" => DocumentPrint.print_time(content["cut_off_at"], names, :cut_off_at, lang),
      "location" => location(content, names),
      "total_lines" => Integer.to_string(length(rows)),
      "total_counted" =>
        content
        |> CountPrintSource.lines()
        |> Enum.map(& &1["counted_quantity"])
        |> FormCountInv8.sum_text()
        |> number(lang)
    }
  end

  defp location(content, names) do
    case List.wrap(content["location_ids"]) do
      [id] -> text(FormDa1.lookup(names, :locations, id)[:name])
      _ -> ""
    end
  end

  defp field_blocks(l) do
    for {f, key} <- [
          {"organisation", :organisation},
          {"bin", :bin},
          {"org_unit", :org_unit},
          {"number", :number},
          {"issued_at", :issued_at},
          {"order_no", :order_no},
          {"order_date", :order_date},
          {"cut_off", :cut_off},
          {"location", :location}
        ] do
      block = field(f, l.(key))
      if f == "location", do: Map.put(block, "show_if_nonempty", true), else: block
    end
  end

  defp field(name, label),
    do: %{"type" => "field", "entity_type" => "doc", "field_name" => name, "label" => label}

  # -- lines ----------------------------------------------------------------------------------

  defp line_columns(l) do
    [
      col("line_no", l.(:line_no), 0.5),
      col("name", l.(:name), 4),
      col("inventory_number", l.(:inventory_number), 2),
      col("acquired", l.(:acquisition_date), 1.5),
      col("counted", l.(:counted), 1.2),
      col("book_quantity", l.(:book_quantity), 1.2),
      col("book_value", l.(:book_value), 1.5)
    ]
  end

  defp line_row(line, names, lang) do
    kzt? = names |> Map.get(:card_currency, %{}) |> Map.get(line["asset_id"]) == "KZT"
    name = if text(line["name"]) == "", do: text(line["description"]), else: text(line["name"])

    %{
      "line_no" => text(line["line_no"]),
      "name" => name,
      "inventory_number" => text(line["inventory_number"]),
      "acquired" => acquired(line["acquisition_date"], lang),
      "counted" => number(text(line["counted_quantity"]), lang),
      "book_quantity" => number(text(line["book_quantity"]), lang),
      "book_value" =>
        if(line["kind"] == "book" and kzt?, do: number(text(line["book_value"]), lang), else: "")
    }
  end

  # `DD-MM-YYYY` in ru/kk, `YYYY-MM-DD` in en.
  defp acquired(value, lang) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})-(\d{2})-(\d{2})/, value) do
      [_, y, m, d] -> if lang == :en, do: "#{y}-#{m}-#{d}", else: "#{d}-#{m}-#{y}"
      _ -> value
    end
  end

  defp acquired(_, _), do: ""

  defp number(value, lang), do: DocumentPrint.number(value, lang)

  # -- signers --------------------------------------------------------------------------------

  defp signers(content, names, l) do
    chair = content["chair_employee_id"]
    members = content["member_employee_ids"] |> List.wrap() |> Enum.reject(&(&1 == chair))
    responsible = CountPrintSource.responsible_ids(content) -- ([chair] ++ members)

    ([{:chair, chair}] ++
       Enum.map(members, &{:member, &1}) ++ Enum.map(responsible, &{:responsible, &1}))
    |> Enum.filter(fn {_, id} -> is_binary(id) end)
    |> Enum.map(fn {role, id} ->
      {position, name} = FormDa1.person(names, id)

      %{
        "role" => l.(role),
        "full_name" => name,
        "position" => position,
        "signature" => "",
        "date" => ""
      }
    end)
  end

  defp table(entity, columns),
    do: %{"type" => "table", "entity_type" => entity, "columns" => columns}

  defp col(field, header, width),
    do: %{"field_name" => field, "header" => header, "width" => width}

  defp text(v), do: DocumentPrint.text(v)
end
