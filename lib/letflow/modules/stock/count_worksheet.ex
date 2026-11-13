defmodule Letflow.Modules.Stock.CountWorksheet do
  @moduledoc """
  T-1905: the count worksheet, a print of a count order for the field: the commission takes it,
  writes the counted quantities in the empty boxes, and types them in later. Pure: input in, PDF or
  xlsx bytes out; no database, no clock, no process.

  It is NOT a document of record: no number sequence, no posting, no state change. The count sheet
  document stays the counted result (issued at close).

  The input is the output of `Letflow.Modules.Stock.CountPaperworkSource.read_worksheet/4`:
  `%{status, order, lines, names, as_of, as_of_key}`. Variants: BLANK (`expected? = false`: no
  expected column and no book quantity anywhere in the output, the blind-count paper) and WITH
  EXPECTED (an "Expected (book)" column).

  PDF: A4 landscape, 20 mm margin, black and white (no fills but the codes), the header table of the
  lines repeats on every page, footer "Page k of N". A Code 128 of the order number and a QR of the
  order id are drawn in the top margin of every page as vector marks (`PrintLayout.render/4`
  `marks:`). The xlsx has no image support, so the order number cell is the matching key there.

  Times use `CountPaperwork.print_time/4` with the same offset keys as the order print.
  Labels in Russian and Kazakh are a machine draft for the native check, like `CountPrint`.
  """

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.XlsxStyle
  alias Letflow.Modules.Codes.Code128
  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.CountPrint

  @type lang :: :ru | :kk | :en

  @max_rows 1000
  @margin_mm 20
  # A4 landscape in 1/100 pt, and the margin (20 mm = 5669 u).
  @page {84_200, 59_500}
  @margin_u 5669
  @box_u 4535
  @bar_h 2835
  @bar_mw 71
  @gap_u 567

  @own %{
    title_worksheet: %{
      en: "Count worksheet",
      ru: "Рабочий лист инвентаризации",
      kk: "Түгендеудің жұмыс парағы"
    },
    not_record: %{
      en: "Worksheet for counting; not a document of record",
      ru: "Рабочий лист для пересчёта; не является учётным документом",
      kk: "Санауға арналған жұмыс парағы; есепке алу құжаты емес"
    },
    preview: %{
      en: "Preview: the count sheet lines are fixed when the count is opened",
      ru: "Предварительный список: строки описи фиксируются при начале пересчёта",
      kk: "Алдын ала тізім: тізімдеме жолдары санау басталғанда бекітіледі"
    },
    book_as_of: %{
      en: "Book as of",
      ru: "Остатки по учёту на",
      kk: "Есеп бойынша қалдықтар уақыты"
    },
    order_number: %{en: "Count order", ru: "Приказ №", kk: "Бұйрық №"},
    order_date: %{en: "Order date", ru: "Дата приказа", kk: "Бұйрық күні"},
    organisation: %{en: "Organisation", ru: "Организация", kk: "Ұйым"},
    bin: %{en: "BIN/IIN", ru: "БИН/ИИН", kk: "БСН/ЖСН"},
    variant: %{en: "Variant", ru: "Вариант", kk: "Нұсқа"},
    variant_blank: %{
      en: "Blank (no expected quantities)",
      ru: "Без учётных количеств (слепой пересчёт)",
      kk: "Есеп бойынша санысыз (соқыр санау)"
    },
    variant_expected: %{
      en: "With expected quantities",
      ru: "С учётными количествами",
      kk: "Есеп бойынша санымен"
    },
    item_code: %{en: "Item code", ru: "Код", kk: "Коды"},
    expected_qty: %{
      en: "Expected (book)",
      ru: "Ожидается (по учёту)",
      kk: "Күтілетін (есеп бойынша)"
    },
    notes: %{en: "Notes", ru: "Примечание", kk: "Ескертпе"},
    page_word: %{en: "Page", ru: "Страница", kk: "Бет"},
    page_of: %{en: "of", ru: "из", kk: "/"}
  }

  @shared ~w(org_unit planned_start planned_end commission signatures role_chair role_member
             role_responsible role full_name personnel_code signature date line_no location name lot
             unit counted_qty cut_off_at)a

  @doc "All label keys with their texts per language (the test enumerates it)."
  @spec labels() :: %{atom() => %{ru: String.t(), kk: String.t(), en: String.t()}}
  def labels, do: Map.merge(Map.take(CountPrint.labels(), @shared), @own)

  @doc "The worksheet PDF. Errors as `CountPrint.build/4`."
  @spec build_pdf(map(), lang(), boolean()) ::
          {:ok, binary()} | {:error, :unsupported_glyph | {:render_failed, [atom()]}}
  def build_pdf(input, lang, expected?) when lang in [:ru, :kk, :en] and is_boolean(expected?) do
    {layout, projection} = layout(input, lang, expected?)

    declared =
      Map.new(projection, fn
        {et, %{} = fields} -> {et, Map.keys(fields)}
        {et, rows} when is_list(rows) -> {et, row_fields(et, expected?)}
      end)

    order = input.order
    l = fn key -> Map.fetch!(labels(), key) |> Map.fetch!(lang) end

    opts = [
      footer: %{word: l.(:page_word), of: l.(:page_of)},
      marks: marks(order[:number_label], order_id(input), @page, @margin_u)
    ]

    case PrintLayout.render(layout, projection, declared, opts) do
      {:ok, pdf} ->
        {:ok, pdf}

      {:error, violations} ->
        rules = Enum.map(violations, & &1.rule)

        if :unsupported_glyph in rules,
          do: {:error, :unsupported_glyph},
          else: {:error, {:render_failed, rules}}
    end
  end

  @doc "The worksheet workbook (sheets Document, Lines, Signatures)."
  @spec build_xlsx(map(), lang(), boolean()) :: {:ok, binary()} | {:error, :xlsx_write_failed}
  def build_xlsx(input, lang, expected?) when lang in [:ru, :kk, :en] and is_boolean(expected?) do
    l = lbl(lang)
    {_layout, projection} = layout(input, lang, expected?)
    doc = projection["doc"]

    doc_rows =
      [[l.(:title_worksheet), ""], [l.(:not_record), ""]] ++
        if(input.status == "ordered", do: [[l.(:preview), ""]], else: []) ++
        for({label, key} <- doc_fields(input.status), do: [l.(label), doc[key]])

    cols = line_cols(expected?)

    line_rows = [
      Enum.map(cols, fn {_f, label, _w} -> l.(label) end)
      | for row <- projection["lines"] do
          Enum.map(cols, fn {f, _label, _w} -> if f in ~w(counted notes), do: "", else: row[f] end)
        end
    ]

    sign_head = Enum.map(~w(role full_name personnel_code signature date)a, l)
    sign_body = for r <- projection["signers"], do: [r["role"], r["full_name"], r["code"], "", ""]
    sign_rows = [sign_head | sign_body]

    sheets = [
      %Sheet{name: sheet_name(lang, :document), rows: doc_rows},
      %Sheet{name: sheet_name(lang, :lines), rows: line_rows},
      %Sheet{name: l.(:signatures), rows: sign_rows}
    ]

    [d | rest] = sheets
    styled = [XlsxStyle.style(d, false) | Enum.map(rest, &XlsxStyle.style/1)]

    case XlsxStyle.write_to_memory(%Workbook{sheets: styled}, "count-worksheet.xlsx") do
      {:ok, {_name, binary}} -> {:ok, binary}
      _ -> {:error, :xlsx_write_failed}
    end
  rescue
    _ -> {:error, :xlsx_write_failed}
  end

  defp sheet_name(:ru, :document), do: "Документ"
  defp sheet_name(:kk, :document), do: "Құжат"
  defp sheet_name(:en, :document), do: "Document"
  defp sheet_name(:ru, :lines), do: "Строки"
  defp sheet_name(:kk, :lines), do: "Жолдар"
  defp sheet_name(:en, :lines), do: "Lines"

  defp lbl(lang), do: fn key -> Map.fetch!(labels(), key) |> Map.fetch!(lang) end

  defp order_id(input), do: input.order[:order_id] || input[:order_id]

  # -- layout ---------------------------------------------------------------------------------

  @doc false
  # Test seam: the layout and the projection `build_pdf/3` renders.
  @spec layout(map(), lang(), boolean()) :: {map(), map()}
  def layout(input, lang, expected?) do
    l = lbl(lang)
    %{order: order, lines: lines, names: names, status: status} = input
    content = Map.get(order, :content, %{})
    time = fn value, key -> CountPaperwork.print_time(value, names, key, lang) end

    entity =
      names
      |> Map.get(:legal_entities, %{})
      |> Map.get(content["org_unit_id"], %{})
      |> then(&(&1 || %{}))

    doc = %{
      "order_number" => CountPaperwork.text(order[:number_label]),
      "order_date" => time.(order[:issued_at], :issued_at),
      "organisation" => CountPaperwork.text(entity[:name]),
      "bin" => CountPaperwork.text(entity[:bin]),
      "org_unit" => CountPaperwork.unit_text(Map.get(names, :org_unit)),
      "planned_start" => time.(content["planned_start"], :planned_start),
      "planned_end" => time.(content["planned_end"], :planned_end),
      "as_of" => time.(input.as_of, :cut_off_at),
      "variant" => if(expected?, do: l.(:variant_expected), else: l.(:variant_blank))
    }

    rows = Enum.map(lines, &line_row(&1, names, lang, expected?))
    chunks = if rows == [], do: [[]], else: Enum.chunk_every(rows, @max_rows)
    named = chunks |> Enum.with_index() |> Enum.map(fn {c, i} -> {"lines_#{i}", c} end)

    line_blocks =
      for {name, _} <- named, do: table(name, Enum.map(line_cols(expected?), &col(&1, l)))

    blocks =
      [
        %{
          "type" => "page",
          "size" => "A4-landscape",
          "margin_mm" => @margin_mm,
          "font" => "dejavu-sans"
        },
        %{"type" => "text", "text" => l.(:title_worksheet)},
        %{"type" => "text", "text" => l.(:not_record)}
      ] ++
        if(status == "ordered", do: [%{"type" => "text", "text" => l.(:preview)}], else: []) ++
        for({label, key} <- doc_fields(status), do: field(l.(label), key)) ++
        [
          %{"type" => "spacer", "height_mm" => 3},
          %{"type" => "text", "text" => l.(:commission)},
          table("commission", [
            %{"field_name" => "role", "header" => l.(:role), "width" => 2},
            %{"field_name" => "full_name", "header" => l.(:full_name), "width" => 3},
            %{"field_name" => "code", "header" => l.(:personnel_code), "width" => 2}
          ]),
          %{"type" => "spacer", "height_mm" => 4}
        ] ++
        line_blocks ++
        [
          %{"type" => "spacer", "height_mm" => 6},
          %{"type" => "text", "text" => l.(:signatures)},
          table("signers", [
            %{"field_name" => "role", "header" => l.(:role), "width" => 2},
            %{"field_name" => "full_name", "header" => l.(:full_name), "width" => 3},
            %{"field_name" => "code", "header" => l.(:personnel_code), "width" => 2},
            %{"field_name" => "signature", "header" => l.(:signature), "width" => 2},
            %{"field_name" => "date", "header" => l.(:date), "width" => 1}
          ])
        ]

    projection =
      named
      |> Map.new()
      |> Map.put("doc", doc)
      |> Map.put("commission", commission_rows(content, names, l))
      |> Map.put("signers", signer_rows(content, lines, names, l))
      |> Map.put("lines", rows)

    {%{"layout_schema_version" => 1, "blocks" => blocks}, projection}
  end

  # The doc fields in print order; the as-of label depends on the status.
  defp doc_fields(status) do
    [
      {:order_number, "order_number"},
      {:order_date, "order_date"},
      {:organisation, "organisation"},
      {:bin, "bin"},
      {:org_unit, "org_unit"},
      {:planned_start, "planned_start"},
      {:planned_end, "planned_end"},
      {if(status == "ordered", do: :book_as_of, else: :cut_off_at), "as_of"},
      {:variant, "variant"}
    ]
  end

  defp field(label, key),
    do: %{"type" => "field", "entity_type" => "doc", "field_name" => key, "label" => label}

  defp table(entity, columns),
    do: %{"type" => "table", "entity_type" => entity, "columns" => columns}

  defp col({field, label, width}, l),
    do: %{"field_name" => field, "header" => l.(label), "width" => width}

  defp line_cols(expected?) do
    [
      {"line_no", :line_no, 0.5},
      {"location", :location, 2},
      {"item_code", :item_code, 1.2},
      {"item_name", :name, 3},
      {"lot", :lot, 1},
      {"unit", :unit, 1}
    ] ++
      if(expected?, do: [{"expected", :expected_qty, 1.4}], else: []) ++
      [{"counted", :counted_qty, 2}, {"notes", :notes, 2}]
  end

  defp row_fields("lines" <> _, expected?),
    do: line_cols(expected?) |> Enum.map(&elem(&1, 0))

  defp row_fields("commission", _), do: ~w(role full_name code)
  defp row_fields("signers", _), do: ~w(role full_name code signature date)

  defp line_row(line, names, lang, expected?) do
    loc = Map.get(Map.get(names, :locations, %{}), line["location_id"]) || %{}
    item = Map.get(Map.get(names, :items, %{}), line["catalog_item_id"]) || %{}

    base = %{
      "line_no" => CountPaperwork.text(line["line_no"]),
      "location" => CountPaperwork.unit_text(loc),
      "item_code" => CountPaperwork.text(item[:code]),
      "item_name" => CountPaperwork.text(item[:name]),
      "lot" => CountPaperwork.text(Map.get(Map.get(names, :lots, %{}), line["catalog_lot_id"])),
      "unit" =>
        CountPaperwork.unit_cell(
          Map.get(Map.get(names, :units, %{}), line["unit_ref"]),
          line["unit_ref"]
        ),
      # Two lines tall (Flow splits on the newline): room to write by hand.
      "counted" => "\n",
      "notes" => ""
    }

    if expected?,
      do: Map.put(base, "expected", CountPaperwork.number(line["book_quantity"], lang)),
      else: base
  end

  defp person(names, role, id) do
    emp = Map.get(Map.get(names, :employees, %{}), id) || %{}

    %{
      "role" => role,
      "full_name" => CountPaperwork.text(emp[:full_name]),
      "code" => CountPaperwork.text(emp[:code])
    }
  end

  defp commission_rows(order, names, l) do
    chair =
      if order["chair_employee_id"],
        do: [person(names, l.(:role_chair), order["chair_employee_id"])],
        else: []

    chair ++
      for id <- CountPaperwork.list_ids(order["member_employee_ids"]),
          do: person(names, l.(:role_member), id)
  end

  defp signer_rows(order, lines, names, l) do
    for {role, id} <- CountPaperwork.signers(:sheet, order, lines) do
      names
      |> person(l.(role_key(role)), id)
      |> Map.merge(%{"signature" => "", "date" => ""})
    end
  end

  defp role_key("chair"), do: :role_chair
  defp role_key("member"), do: :role_member
  defp role_key("responsible"), do: :role_responsible

  # -- marks ----------------------------------------------------------------------------------

  @doc false
  # Test seam: filled rectangles of the Code 128 (number label) and the QR (order id) in the top
  # margin. A symbol the encoder refuses is left out (the number is a header field anyway).
  @spec marks(term(), term(), {integer(), integer()}, integer()) :: [tuple()]
  def marks(number_label, order_id, {pw, ph}, margin) do
    {qr, box_left} = qr_marks(order_id, pw, ph, margin)
    qr ++ barcode_marks(number_label, ph, box_left)
  end

  defp qr_marks(id, pw, ph, margin) when is_binary(id) and id != "" do
    %{matrix: matrix} = EQRCode.encode(id, :m)
    side = tuple_size(matrix)
    qm = div(@box_u, side + 8)
    box_w = (side + 8) * qm
    box_left = pw - margin - box_w
    box_top = ph - 567
    left = box_left + 4 * qm
    top = box_top - 4 * qm

    rects =
      for {row, r} <- matrix |> Tuple.to_list() |> Enum.with_index(),
          {1, c} <- row |> Tuple.to_list() |> Enum.with_index() do
        {:rect, left + c * qm, top - (r + 1) * qm, qm, qm}
      end

    {rects, box_left}
  rescue
    _ -> {[], pw - margin}
  end

  defp qr_marks(_id, pw, _ph, margin), do: {[], pw - margin}

  defp barcode_marks(label, ph, qr_left) do
    with true <- is_binary(label),
         {:ok, widths} <- Code128.encode(label) do
      total = Enum.sum(widths)
      left = qr_left - @gap_u - (total + 10) * @bar_mw
      bottom = ph - 567 - @box_u

      if left < 0 do
        []
      else
        {rects, _} =
          widths
          |> Enum.with_index()
          |> Enum.reduce({[], left}, fn {w, idx}, {acc, x} ->
            acc =
              if rem(idx, 2) == 0,
                do: [{:rect, x, bottom, w * @bar_mw, @bar_h} | acc],
                else: acc

            {acc, x + w * @bar_mw}
          end)

        Enum.reverse(rects)
      end
    else
      _ -> []
    end
  end
end
