Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ7RouterTest do
  @moduledoc """
  T-1925 (audit slice 9), design tests R1..R6: `GET /stock-sheet/print` (official form Z-7) through
  the full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  A receipt of 2 (and of a lot item, 10.5) is dated 48 hours back and an issue of 0.5 is posted now,
  so the opening balance, income and expense are all exercised. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.TenantTimezone
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    back = DateTime.utc_now() |> DateTime.add(-48 * 3600, :second) |> DateTime.to_iso8601()
    receipt = P.issue!(ctx, D.body(ctx.ma, back))
    P.post_and_complete!(ctx, receipt["id"])

    issue =
      ctx.ma
      |> D.body(nil, %{
        "kind" => "issue",
        "lines" => [
          %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "0.5"}
        ]
      })
      |> Map.delete("counterparty_id")
      |> then(&P.issue!(ctx, &1))

    P.post_and_complete!(ctx, issue["id"])
    {:ok, today} = TenantTimezone.today(CountPaperworkSource.zone(ctx.a.tenant_id))
    Map.put(ctx, :today, today)
  end

  defp print(ctx, q, tok \\ nil), do: S.get("/stock-sheet/print?#{q}", tok || ctx.tok_a)

  defp period(ctx, from_back, to_back \\ 0) do
    "location=#{ctx.ma.location}&from=#{Date.add(ctx.today, -from_back)}&to=#{Date.add(ctx.today, -to_back)}"
  end

  defp docx_xml(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml
  end

  defp docx_text(conn),
    do: conn |> docx_xml() |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")

  # The cells of the table row that holds `needle` (the lines table), in order.
  defp row_cells(conn, needle) do
    conn
    |> docx_xml()
    |> String.split("<w:tr>")
    |> Enum.concat(String.split(docx_xml(conn), "<w:tr "))
    |> Enum.find(&(&1 =~ needle and &1 =~ "<w:tc>"))
    |> String.split("</w:tc>")
    |> Enum.map(&(&1 |> String.replace(~r/<[^>]+>/, "") |> String.trim()))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "R1 ru pdf: numbers on the sheet, closing equals the /balances row; docx blank gaps",
       ctx do
    conn = print(ctx, period(ctx, 2) <> "&format=pdf&lang=ru")
    assert conn.status == 200, conn.resp_body
    assert header(conn, "content-type") =~ "application/pdf"
    assert header(conn, "content-disposition") =~ ~r/stock-sheet_.*_Z-7\.pdf"/
    assert header(conn, "cache-control") == "no-store"

    items = PdfProbe.items(conn.resp_body)
    {:ok, item} = CatalogItems.lookup(ctx.schema, ctx.ma.item)
    assert "Ведомость учета остатков запасов на складе" in items
    assert Enum.join(items, "\n") =~ item["name"]
    assert "2.000000000" in items
    assert "0.500000000" in items
    assert "1.500000000" in items

    %{"rows" => [row]} =
      S.get("/balances?sku=#{ctx.ma.item}&location=#{ctx.ma.location}", ctx.tok_a)
      |> P.status!(200)

    assert row["quantity"] == "1.500000000"

    docx = print(ctx, period(ctx, 2) <> "&format=docx&lang=ru")
    assert docx.status == 200 and header(docx, "content-type") =~ @docx
    cells = row_cells(docx, item["name"])
    assert length(cells) >= 14
    # columns 5, 6, 7 (qty, price, norm), 9, 11, 13 (sums) are blank; opening (8) is blank (zero)
    for i <- [4, 5, 6, 7, 8, 10, 12], do: assert(Enum.at(cells, i) == "", "cell #{i + 1}")
    assert Enum.at(cells, 9) == "2.000000000"
    assert Enum.at(cells, 11) == "0.500000000"
    assert Enum.at(cells, 13) == "1.500000000"
  end

  test "R2 the opening balance: a period after the receipt, and a period of the receipt day",
       ctx do
    {:ok, item} = CatalogItems.lookup(ctx.schema, ctx.ma.item)

    conn = print(ctx, period(ctx, 1) <> "&format=docx&lang=ru")
    assert conn.status == 200, conn.resp_body
    cells = row_cells(conn, item["name"])
    assert Enum.at(cells, 7) == "2.000000000"
    assert Enum.at(cells, 9) == ""
    assert Enum.at(cells, 11) == "0.500000000"
    assert Enum.at(cells, 13) == "1.500000000"

    day = print(ctx, period(ctx, 2, 2) <> "&format=docx&lang=ru")
    assert day.status == 200, day.resp_body
    cells = row_cells(day, item["name"])
    assert Enum.at(cells, 9) == "2.000000000"
    assert Enum.at(cells, 11) == ""
    assert Enum.at(cells, 13) == "2.000000000"
  end

  test "R3 kk docx: official title, form code and heads", ctx do
    conn = print(ctx, period(ctx, 2) <> "&format=docx&lang=kk")
    assert conn.status == 200, conn.resp_body
    text = docx_text(conn)

    for t <- [
          "ҚОЙМАДАҒЫ ҚОРЛАРДЫҢ ҚАЛДЫҚТАРЫН ЕСЕПКЕ АЛУ ТІЗІМДЕМЕСІ",
          "Қ-7 нысаны",
          "Кіріс",
          "Шығыс",
          "Қойма"
        ] do
      assert text =~ t, "missing #{t}"
    end

    refute text =~ "Машиналық аударма"
  end

  test "R4 another tenant's token and an unknown location are the same 404", ctx do
    q = period(ctx, 2)
    cross = print(ctx, q, ctx.tok_b)

    unknown =
      print(
        ctx,
        "location=#{Ecto.UUID.generate()}&" <> String.replace(q, ~r/^location=[^&]+&/, "")
      )

    assert cross.status == 404 and unknown.status == 404

    strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
    assert strip.(cross) == strip.(unknown)
    refute cross.resp_body =~ "%PDF" or cross.resp_body =~ "PK"
  end

  test "R5 refusals", ctx do
    ok = "from=#{Date.add(ctx.today, -2)}&to=#{ctx.today}"
    loc = "location=#{ctx.ma.location}"

    for {q, reason} <- [
          {ok, "invalid_filter"},
          {"location=nope&" <> ok, "invalid_filter"},
          {loc <> "&" <> ok <> "&extra=1", "invalid_filter"},
          {loc <> "&" <> ok <> "&tenant_id=#{ctx.a.tenant_id}", "invalid_filter"},
          {loc <> "&to=#{ctx.today}", "invalid_period"},
          {loc <> "&from=2026-02-30&to=#{ctx.today}", "invalid_period"},
          {loc <> "&from=#{ctx.today}&to=#{Date.add(ctx.today, -1)}", "invalid_period"},
          {loc <> "&from=#{ctx.today}&to=#{Date.add(ctx.today, 1)}", "period_in_future"},
          {loc <> "&" <> ok <> "&format=odt", "invalid_format"},
          {loc <> "&" <> ok <> "&lang=en", "invalid_lang"}
        ] do
      conn = print(ctx, q)
      assert conn.status == 422 and S.json(conn)["reason"] == reason, q
    end
  end

  test "R6 a token without StockRead is refused", ctx do
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "sheet-worker")
    assert print(ctx, period(ctx, 2), tok).status == 403
  end
end
