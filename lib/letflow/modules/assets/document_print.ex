defmodule Letflow.Modules.Assets.DocumentPrint do
  @moduledoc """
  T-1915 / GH #4443 (official forms audit D4): the printed act of an issued asset document
  (commission, change of holder, hand over, write-off) as an A4 PDF in ru, kk or en. Pure: issued
  content and names in, PDF bytes out; no database, no clock, no process. The layout is built in
  code and rendered by `Letflow.Documents.PrintLayout.render/4`, which is not changed.

  The input is the output of `Letflow.Modules.Assets.DocumentPrintSource.read/3`: the ISSUED
  version content (`"kind"`, `"header"`, `"lines"`), never the live records. The from and to side
  come from `Letflow.Modules.Assets.Documents.Kinds.sides/2`, the one place that maps the header
  fields of a kind to its sides, so the printed direction cannot disagree with posting.
  Commission and write-off have one side column; change and hand over have from and to.

  Every literal comes from `labels/0`, never from data; all data goes through the projection.
  Quantities are the stored decimal text regrouped, never rounded. A name that no longer resolves
  prints as empty text, never as a raw id.

  Not an official form: the Russian and Kazakh wording is a machine draft for the native check
  (UAT); ДА-1, ДА-4 and ДА-3 are built (T-1921, T-1922, T-1923), ДА-2 is a later slice.
  """

  alias Letflow.Documents.PrintLayout
  alias Letflow.Modules.Assets.Documents.Kinds

  @type lang :: :ru | :kk | :en

  @act_kinds ~w(commission change handover writeoff)

  @doc "Kinds with a plain issued act."
  @spec kinds() :: [String.t()]
  def kinds, do: @act_kinds

  @labels %{
    title_commission: %{
      en: "Act of commissioning",
      ru: "Акт ввода в эксплуатацию",
      kk: "Пайдалануға беру актісі"
    },
    title_change: %{
      en: "Act of change of holder",
      ru: "Акт смены держателя",
      kk: "Ұстаушыны ауыстыру актісі"
    },
    title_handover: %{en: "Act of hand over", ru: "Акт передачи", kk: "Тапсыру актісі"},
    title_writeoff: %{
      en: "Act of write-off",
      ru: "Акт списания",
      kk: "Есептен шығару актісі"
    },
    number: %{en: "Number", ru: "Номер", kk: "Нөмірі"},
    version: %{en: "Version", ru: "Версия", kk: "Нұсқа"},
    issued_at: %{en: "Issued at", ru: "Выдан", kk: "Берілген уақыты"},
    event_time: %{en: "Event time", ru: "Время операции", kk: "Операция уақыты"},
    note: %{en: "Note", ru: "Примечание", kk: "Ескертпе"},
    reason: %{en: "Reason", ru: "Причина", kk: "Себебі"},
    reason_text: %{en: "Details", ru: "Пояснение", kk: "Түсініктеме"},
    reason_disposed: %{en: "Disposed", ru: "Утилизирован", kk: "Жойылған"},
    reason_lost: %{en: "Lost", ru: "Утерян", kk: "Жоғалған"},
    reason_broken: %{en: "Broken", ru: "Сломан", kk: "Сынған"},
    reason_expired: %{en: "Expired", ru: "Срок истёк", kk: "Мерзімі өткен"},
    reason_other: %{en: "Other", ru: "Другое", kk: "Басқа"},
    what: %{en: "Party", ru: "Сторона", kk: "Тарап"},
    party: %{en: "Holder", ru: "Держатель", kk: "Ұстаушы"},
    from: %{en: "From", ru: "Откуда", kk: "Қайдан"},
    to: %{en: "To", ru: "Куда", kk: "Қайда"},
    org_unit: %{en: "Org unit", ru: "Подразделение", kk: "Бөлімше"},
    location: %{en: "Location", ru: "Место", kk: "Орын"},
    material_responsible: %{
      en: "Material responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
    actual_user: %{
      en: "Actual user",
      ru: "Фактический пользователь",
      kk: "Нақты пайдаланушы"
    },
    line_no: %{en: "No.", ru: "№", kk: "№"},
    inventory_number: %{
      en: "Inventory number",
      ru: "Инвентарный номер",
      kk: "Инвентарлық нөмірі"
    },
    asset: %{en: "Asset", ru: "Актив", kk: "Актив"},
    quantity: %{en: "Quantity", ru: "Количество", kk: "Саны"},
    signatures: %{en: "Signatures", ru: "Подписи", kk: "Қолдар"},
    role: %{en: "Role", ru: "Роль", kk: "Рөлі"},
    role_from: %{en: "Handed over by", ru: "Сдал", kk: "Тапсырған"},
    role_to: %{en: "Received by", ru: "Принял", kk: "Қабылдаған"},
    role_commissioned: %{
      en: "Commissioned by",
      ru: "Ввёл в эксплуатацию",
      kk: "Пайдалануға берген"
    },
    role_responsible: %{
      en: "Material responsible",
      ru: "Материально ответственное лицо",
      kk: "Материалдық жауапты тұлға"
    },
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
              col("inventory_number", l.(:inventory_number), 2),
              col("name", l.(:asset), 4),
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
      "doc" => doc_fields(kind, issued, header, names, lang, l),
      "sides" => side_rows(from, to, names, l),
      "lines" => line_rows(content, names, lang),
      "signers" => signer_rows(kind, from, to, names, l)
    }

    {layout, projection}
  end

  defp title_key("commission"), do: :title_commission
  defp title_key("change"), do: :title_change
  defp title_key("handover"), do: :title_handover
  defp title_key("writeoff"), do: :title_writeoff

  # -- document fields ------------------------------------------------------------------------

  defp doc_fields(kind, issued, header, names, lang, l) do
    reason =
      case header["reason_code"] do
        "disposed" -> l.(:reason_disposed)
        "lost" -> l.(:reason_lost)
        "broken" -> l.(:reason_broken)
        "expired" -> l.(:reason_expired)
        "other" -> l.(:reason_other)
        _ -> ""
      end

    %{
      "number" => text(issued[:number_label]),
      "version_no" => text(issued[:version_no]),
      "issued_at" => print_time(issued[:issued_at], names, :issued_at, lang),
      "event_time" => print_time(header["event_time"], names, :event_time, lang),
      "note" => text(header["note"]),
      "reason" => if(kind == "writeoff", do: reason, else: ""),
      "reason_text" => if(kind == "writeoff", do: text(header["reason_text"]), else: "")
    }
  end

  defp field_blocks(l) do
    for {f, key} <- [
          {"number", :number},
          {"version_no", :version},
          {"issued_at", :issued_at},
          {"event_time", :event_time},
          {"note", :note},
          {"reason", :reason},
          {"reason_text", :reason_text}
        ] do
      block = %{
        "type" => "field",
        "entity_type" => "doc",
        "field_name" => f,
        "label" => l.(key)
      }

      if f in ~w(note reason reason_text),
        do: Map.put(block, "show_if_nonempty", true),
        else: block
    end
  end

  # -- sides ----------------------------------------------------------------------------------

  defp side_rows(from, to, names, l) do
    for {key, getter} <- [
          {:org_unit, &unit_cell(&1, :org_units, names)},
          {:location, &unit_cell(&1, :locations, names)},
          {:material_responsible, &person_cell(&1, names)},
          {:actual_user, &person_cell(&1, names)}
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
    case lookup(names, group, id) do
      %{} = unit ->
        [unit[:code], unit[:name]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

      _ ->
        ""
    end
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
      card = lookup(names, :cards, line["asset_id"]) || %{}

      %{
        "line_no" => text(line["line_no"] || n),
        "inventory_number" => text(card[:inventory_number]),
        "name" => text(card[:name]),
        "quantity" => number(line["quantity"], lang)
      }
    end)
  end

  # -- signers --------------------------------------------------------------------------------

  defp signer_rows(kind, from, to, names, l) do
    parties =
      case kind do
        "commission" -> [{:role_to, to}, {:role_commissioned, nil}]
        "writeoff" -> [{:role_responsible, from}]
        _ -> [{:role_from, from}, {:role_to, to}]
      end

    for {role, side} <- parties do
      emp = lookup(names, :employees, side_value(side, :material_responsible)) || %{}

      %{
        "role" => l.(role),
        "full_name" => text(emp[:full_name]),
        "code" => text(emp[:code]),
        "signature" => "",
        "date" => ""
      }
    end
  end

  defp side_columns(kind, l) when kind in ~w(commission writeoff),
    do: [col("what", l.(:what), 2), col("side", l.(:party), 6)]

  defp side_columns(_, l),
    do: [col("what", l.(:what), 2), col("from", l.(:from), 3), col("to", l.(:to), 3)]

  defp row_fields("sides", kind) when kind in ~w(commission writeoff), do: ~w(what side)
  defp row_fields("sides", _), do: ~w(what from to)
  defp row_fields("lines", _), do: ~w(line_no inventory_number name quantity)
  defp row_fields("signers", _), do: ~w(role full_name code signature date)

  defp map(%{} = m), do: m
  defp map(_), do: %{}

  defp table(entity, columns),
    do: %{"type" => "table", "entity_type" => entity, "columns" => columns}

  defp col(field, header, width),
    do: %{"field_name" => field, "header" => header, "width" => width}

  # -- text, number and time (copies of the stock count paperwork helpers, see the source moduledoc)

  @doc false
  def text(nil), do: ""
  def text(v) when is_binary(v), do: v
  def text(v), do: to_string(v)

  @doc false
  # A stored plain decimal text regrouped for print: ru/kk `49 360,5` (no-break space, comma), en
  # `49,360.5`; trailing zeros of the fraction are dropped, a value is never rounded; anything else
  # is returned as stored.
  def number(value, lang) do
    str = text(value)

    case Regex.run(~r/\A(-?)(\d+)(?:\.(\d+))?\z/, str) do
      [_, sign, int, frac] -> group_number(sign, int, String.trim_trailing(frac, "0"), lang)
      [_, sign, int] -> group_number(sign, int, "", lang)
      _ -> str
    end
  end

  defp group_number(sign, int, frac, lang) do
    {group, point} = if lang == :en, do: {",", "."}, else: {" ", ","}

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

  @doc false
  # The time of a printed act, localized like the UI plus the zone offset the stored instant was
  # shifted by: `04-11-2026 10:00 (UTC+05:00)` (ru/kk), `2026-11-04 10:00 (UTC+05:00)` (en).
  # A text that is not a time prints as stored.
  def print_time(nil, _names, _key, _lang), do: ""

  def print_time(value, names, key, lang) do
    case to_utc(value) do
      {:ok, dt} ->
        offset = names |> Map.get(:offsets, %{}) |> Map.get(key, 0)
        shifted = DateTime.add(dt, offset, :second)
        pattern = if lang == :en, do: "%Y-%m-%d %H:%M", else: "%d-%m-%Y %H:%M"
        "#{Calendar.strftime(shifted, pattern)} (UTC#{offset_text(offset)})"

      :error ->
        text(value)
    end
  end

  defp offset_text(offset) do
    sign = if offset < 0, do: "-", else: "+"
    abs_off = abs(offset)
    "#{sign}#{abs_off |> div(3600) |> pad()}:#{abs_off |> rem(3600) |> div(60) |> pad()}"
  end

  defp to_utc(%DateTime{} = dt), do: {:ok, dt}

  defp to_utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp to_utc(_), do: :error

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc false
  # The download file name: the number label with unsafe characters replaced, plus `.pdf`.
  def file_name(label) do
    safe = label |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    if(safe == "", do: "document", else: safe) <> ".pdf"
  end
end
