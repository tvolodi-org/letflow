defmodule Letflow.Modules.Stock.DocumentPrint do
  @moduledoc """
  REQ-737 / GH #3860: the printed act of an issued stock document (receipt, issue, write-off, transfer, hand over, return)
  as an A4 PDF in ru, kk or en. Pure: issued content and names in, PDF bytes out; no database, no
  clock, no process. The layout is built in code and rendered by
  `Letflow.Documents.PrintLayout.render/4` (REQ-571), which is not changed.

  The input is the output of `Letflow.Modules.Stock.DocumentPrintSource.read/3`: the ISSUED version
  content (`"kind"`, `"header"`, `"lines"`), never the live records. The from and to side of the
  header come from `Letflow.Modules.Stock.Documents.Kinds.sides/2`, the one place that maps the
  header fields of a kind to its sides, so the printed direction cannot disagree with posting.
  One-sided documents use a single side column. Receipt and issue leave the counter-signature
  blank; write-off has one responsible signer. For two-sided documents the two signer rows are the responsible person of the from side (handed over by) and of the
  to side (received by), each with empty signature and date cells.

  Every literal comes from `labels/0`, never from data; all data goes through the projection.
  Quantities are the stored decimal text, unchanged. A name that no longer resolves prints as
  empty text, never as a raw id.

  Not an official form: the Russian and Kazakh wording is a machine draft for the native check
  (UAT); official wording is decision 0068 D6, not decided here.
  """

  alias Letflow.Documents.PrintLayout
  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.Documents.Kinds

  @type lang :: :ru | :kk | :en

  @act_kinds ~w(receipt issue write_off transfer hand_over return)

  @doc "Kinds with a plain issued act."
  @spec kinds() :: [String.t()]
  def kinds, do: @act_kinds

  @labels %{
    title_receipt: %{en: "Act of receipt", ru: "Акт приёма", kk: "Қабылдау актісі"},
    title_issue: %{en: "Act of issue", ru: "Акт отпуска", kk: "Босату актісі"},
    title_write_off: %{en: "Act of write-off", ru: "Акт списания", kk: "Есептен шығару актісі"},
    counterparty: %{en: "Supplier", ru: "Поставщик", kk: "Жеткізуші"},
    supplier_document_ref: %{
      en: "Supplier document",
      ru: "Документ поставщика",
      kk: "Жеткізуші құжаты"
    },
    reason: %{en: "Reason", ru: "Причина", kk: "Себебі"},
    reason_text: %{en: "Reason text", ru: "Текст причины", kk: "Себеп мәтіні"},
    party: %{en: "Place", ru: "Место", kk: "Орны"},
    role_responsible: %{
      en: "Responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
    reason_lost: %{en: "Lost", ru: "Утеряно", kk: "Жоғалған"},
    reason_damaged: %{en: "Damaged", ru: "Повреждено", kk: "Зақымдалған"},
    reason_used_up: %{en: "Used up", ru: "Израсходовано", kk: "Пайдаланылған"},
    reason_other: %{en: "Other", ru: "Другое", kk: "Басқа"},
    title_transfer: %{
      en: "Act of transfer",
      ru: "Акт перемещения",
      kk: "Орнын ауыстыру актісі"
    },
    title_hand_over: %{
      en: "Act of hand over",
      ru: "Акт передачи",
      kk: "Тапсыру актісі"
    },
    title_return: %{
      en: "Act of return",
      ru: "Акт возврата",
      kk: "Қайтару актісі"
    },
    number: %{en: "Number", ru: "Номер", kk: "Нөмірі"},
    version: %{en: "Version", ru: "Версия", kk: "Нұсқа"},
    issued_at: %{en: "Issued at", ru: "Выдан", kk: "Берілген уақыты"},
    event_time: %{en: "Event time", ru: "Время операции", kk: "Операция уақыты"},
    note: %{en: "Note", ru: "Примечание", kk: "Ескертпе"},
    what: %{en: "Party", ru: "Сторона", kk: "Тарап"},
    from: %{en: "From", ru: "Откуда", kk: "Қайдан"},
    to: %{en: "To", ru: "Куда", kk: "Қайда"},
    org_unit: %{en: "Organisation unit", ru: "Подразделение", kk: "Бөлімше"},
    location: %{en: "Location", ru: "Место хранения", kk: "Сақтау орны"},
    responsible: %{
      en: "Responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
    line_no: %{en: "No.", ru: "№", kk: "№"},
    item: %{en: "Item", ru: "Номенклатура", kk: "Номенклатура"},
    lot: %{en: "Lot", ru: "Партия", kk: "Партия"},
    unit: %{en: "Unit", ru: "Ед. изм.", kk: "Өлш. бірл."},
    quantity: %{en: "Quantity", ru: "Количество", kk: "Саны"},
    signatures: %{en: "Signatures", ru: "Подписи", kk: "Қолдар"},
    role: %{en: "Role", ru: "Роль", kk: "Рөлі"},
    role_from: %{en: "Handed over by", ru: "Сдал", kk: "Тапсырған"},
    role_to: %{en: "Received by", ru: "Принял", kk: "Қабылдаған"},
    full_name: %{en: "Full name", ru: "ФИО", kk: "Аты-жөні"},
    personnel_code: %{en: "Personnel code", ru: "Табельный номер", kk: "Табель нөмірі"},
    signature: %{en: "Signature", ru: "Подпись", kk: "Қолы"},
    date: %{en: "Date", ru: "Дата", kk: "Күні"}
  }

  @doc "All label keys with their texts per language (the test enumerates it)."
  @spec labels() :: %{atom() => %{ru: String.t(), kk: String.t(), en: String.t()}}
  def labels, do: @labels

  @doc """
  The PDF of one issued document. `{:error, :unsupported_glyph}` when a value has a character the
  font lacks; `{:error, {:render_failed, rules}}` for any other violation (rule atoms only,
  never a value).
  """
  @spec build(map(), map(), lang()) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def build(%{content: %{"kind" => kind}} = issued, names, lang)
      when kind in @act_kinds and lang in [:ru, :kk, :en] do
    {layout, projection} = layout(issued, names, lang)

    declared =
      Map.new(projection, fn
        {et, %{} = fields} -> {et, Map.keys(fields)}
        {et, rows} when is_list(rows) -> {et, row_fields(et, kind)}
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
    kind = content["kind"]
    header = map(content["header"])
    l = fn key -> Map.fetch!(@labels, key) |> Map.fetch!(lang) end
    {from, to} = Kinds.sides(Kinds.get(kind), header)

    doc = Map.merge(doc_fields(issued, header, names, lang), extra_fields(kind, header, names, l))

    layout = %{
      "layout_schema_version" => 1,
      "blocks" =>
        [
          %{"type" => "page", "size" => "A4", "margin_mm" => 15, "font" => "dejavu-sans"},
          %{"type" => "text", "text" => l.(title_key(kind))}
        ] ++
          field_blocks(l) ++
          [
            %{"type" => "spacer", "height_mm" => 4},
            table("sides", side_columns(kind, l)),
            %{"type" => "spacer", "height_mm" => 4},
            table("lines", [
              col("line_no", l.(:line_no), 0.5),
              col("item", l.(:item), 3),
              col("lot", l.(:lot), 1),
              col("unit", l.(:unit), 1),
              col("quantity", l.(:quantity), 1.5)
            ]),
            %{"type" => "spacer", "height_mm" => 6},
            %{"type" => "text", "text" => l.(:signatures)},
            table("signers", [
              col("role", l.(:role), 2),
              col("full_name", l.(:full_name), 3),
              col("code", l.(:personnel_code), 2),
              col("signature", l.(:signature), 2),
              col("date", l.(:date), 1)
            ])
          ]
    }

    projection = %{
      "doc" => doc,
      "sides" => side_rows(from, to, names, l),
      "lines" => line_rows(content, names, lang),
      "signers" => signer_rows(kind, from, to, names, l)
    }

    {layout, projection}
  end

  defp title_key("receipt"), do: :title_receipt
  defp title_key("issue"), do: :title_issue
  defp title_key("write_off"), do: :title_write_off
  defp title_key("transfer"), do: :title_transfer
  defp title_key("hand_over"), do: :title_hand_over
  defp title_key("return"), do: :title_return

  # -- document fields ------------------------------------------------------------------------

  defp doc_fields(issued, header, names, lang) do
    %{
      "number" => CountPaperwork.text(issued[:number_label]),
      "version_no" => CountPaperwork.text(issued[:version_no]),
      "issued_at" => CountPaperwork.print_time(issued[:issued_at], names, :issued_at, lang),
      "event_time" => CountPaperwork.print_time(header["event_time"], names, :event_time, lang),
      "note" => CountPaperwork.text(header["note"])
    }
  end

  defp extra_fields(kind, header, names, l) do
    supplier = lookup(names, :counterparties, header["counterparty_id"]) || %{}

    reason =
      case header["reason_code"] do
        "lost" -> l.(:reason_lost)
        "damaged" -> l.(:reason_damaged)
        "used_up" -> l.(:reason_used_up)
        "other" -> l.(:reason_other)
        _ -> ""
      end

    %{
      "counterparty" =>
        if(kind == "receipt",
          do:
            [supplier[:name], supplier[:tax_id]]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join(" "),
          else: ""
        ),
      "supplier_document_ref" =>
        if(kind == "receipt", do: CountPaperwork.text(header["supplier_document_ref"]), else: ""),
      "reason" => if(kind == "write_off", do: reason, else: ""),
      "reason_text" =>
        if(kind in ["issue", "write_off"],
          do: CountPaperwork.text(header["reason_text"]),
          else: ""
        )
    }
  end

  defp field_blocks(l) do
    for {f, key} <- [
          {"number", :number},
          {"version_no", :version},
          {"issued_at", :issued_at},
          {"event_time", :event_time},
          {"note", :note},
          {"counterparty", :counterparty},
          {"supplier_document_ref", :supplier_document_ref},
          {"reason", :reason},
          {"reason_text", :reason_text}
        ] do
      block = %{
        "type" => "field",
        "entity_type" => "doc",
        "field_name" => f,
        "label" => l.(key)
      }

      if f in ~w(note counterparty supplier_document_ref reason reason_text),
        do: Map.put(block, "show_if_nonempty", true),
        else: block
    end
  end

  # -- sides ----------------------------------------------------------------------------------

  defp side_rows(from, to, names, l) do
    for {key, getter} <- [
          {:org_unit, &unit_cell(&1, :org_units, names)},
          {:location, &unit_cell(&1, :locations, names)},
          {:responsible, &person_cell(&1, names)}
        ] do
      if is_nil(from) or is_nil(to) do
        %{"what" => l.(key), "side" => getter.(side_value(from || to, key))}
      else
        %{
          "what" => l.(key),
          "from" => getter.(side_value(from, key)),
          "to" => getter.(side_value(to, key))
        }
      end
    end
  end

  defp side_value(%{} = side, key), do: Map.get(side, key)
  defp side_value(_, _), do: nil

  defp unit_cell(id, group, names) do
    names |> lookup(group, id) |> CountPaperwork.unit_text()
  end

  defp person_cell(id, names) do
    emp = lookup(names, :employees, id) || %{}
    [emp[:full_name], emp[:code]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
  end

  defp lookup(names, group, id) when is_binary(id) do
    names |> Map.get(group, %{}) |> Map.get(id)
  end

  defp lookup(_names, _group, _id), do: nil

  # -- lines ----------------------------------------------------------------------------------

  defp line_rows(content, names, lang) do
    lines = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, n} ->
      lot = lookup(names, :lots, line["catalog_lot_id"])

      %{
        "line_no" => CountPaperwork.text(line["line_no"] || n),
        "item" => unit_cell(line["catalog_item_id"], :items, names),
        "lot" => CountPaperwork.text(lot),
        "unit" => unit_code(names, line["catalog_uom_id"]),
        "quantity" => CountPaperwork.number(line["quantity"], lang)
      }
    end)
  end

  # The unit prints its code only (a short column); its name when the code is missing.
  defp unit_code(names, id) do
    case lookup(names, :uoms, id) do
      %{} = uom -> CountPaperwork.text(uom[:code] || uom[:name])
      _ -> ""
    end
  end

  # -- signers --------------------------------------------------------------------------------

  defp signer_rows(kind, from, to, names, l) do
    parties =
      case kind do
        "receipt" -> [{:role_to, to}, {:role_from, nil}]
        "write_off" -> [{:role_responsible, from}]
        _ -> [{:role_from, from}, {:role_to, to}]
      end

    for {role, side} <- parties do
      emp = lookup(names, :employees, side_value(side, :responsible)) || %{}

      %{
        "role" => l.(role),
        "full_name" => CountPaperwork.text(emp[:full_name]),
        "code" => CountPaperwork.text(emp[:code]),
        "signature" => "",
        "date" => ""
      }
    end
  end

  defp side_columns(kind, l) when kind in ~w(receipt issue write_off),
    do: [col("what", l.(:what), 2), col("side", l.(:party), 6)]

  defp side_columns(_, l),
    do: [col("what", l.(:what), 2), col("from", l.(:from), 3), col("to", l.(:to), 3)]

  defp row_fields("sides", kind) when kind in ~w(receipt issue write_off), do: ~w(what side)
  defp row_fields("sides", _), do: ~w(what from to)
  defp row_fields("lines", _), do: ~w(line_no item lot unit quantity)
  defp row_fields("signers", _), do: ~w(role full_name code signature date)

  defp map(%{} = m), do: m
  defp map(_), do: %{}

  defp table(entity, columns),
    do: %{"type" => "table", "entity_type" => entity, "columns" => columns}

  defp col(field, header, width),
    do: %{"field_name" => field, "header" => header, "width" => width}
end
