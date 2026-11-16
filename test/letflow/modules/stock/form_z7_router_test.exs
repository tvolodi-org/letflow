Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ7RouterTest do
  @moduledoc """
  T-1925 (audit slice 9), design tests R1..R7: `GET /stock-sheet/print` (official form Z-7) through
  the full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  A receipt of 2 (and of a lot item, 10.5) is dated 48 hours back and an issue of 0.5 is posted now,
  so the opening balance, income and expense are all exercised. `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.TenantTimezone
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.OrgFixture
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = P.setup!([:a, :b, :s])
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
    assert "2" in items
    assert "0.5" in items
    assert "1.5" in items

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
    assert Enum.at(cells, 9) == "2"
    assert Enum.at(cells, 11) == "0.5"
    assert Enum.at(cells, 13) == "1.5"
  end

  test "R2 the opening balance: a period after the receipt, and a period of the receipt day",
       ctx do
    {:ok, item} = CatalogItems.lookup(ctx.schema, ctx.ma.item)

    conn = print(ctx, period(ctx, 1) <> "&format=docx&lang=ru")
    assert conn.status == 200, conn.resp_body
    cells = row_cells(conn, item["name"])
    assert Enum.at(cells, 7) == "2"
    assert Enum.at(cells, 9) == ""
    assert Enum.at(cells, 11) == "0.5"
    assert Enum.at(cells, 13) == "1.5"

    day = print(ctx, period(ctx, 2, 2) <> "&format=docx&lang=ru")
    assert day.status == 200, day.resp_body
    cells = row_cells(day, item["name"])
    assert Enum.at(cells, 9) == "2"
    assert Enum.at(cells, 11) == ""
    assert Enum.at(cells, 13) == "2"
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

  test "R7 a scoped reader does not see the responsible of a hidden org-unit leg", ctx do
    # Fresh tenant bound to realm :s so scope manipulation does not pollute the shared setup.
    ts = S.tenant!("stk-z7sc", ctx.names.s)
    schema = ts.schema_name

    # Two org units, each with a named employee (the responsible written into the leg key).
    unit_a = D.unit!(schema)
    unit_b = D.unit!(schema)
    n = System.unique_integer([:positive])

    emp_a =
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values("org_employee", "Z7A#{n}", %{"org_unit_id" => unit_a})
      )

    emp_b =
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values("org_employee", "Z7B#{n}", %{"org_unit_id" => unit_b})
      )

    # employee full_names follow the OrgFixture convention: "Employee #{code}"
    emp_a_name = "Employee Z7A#{n}"
    emp_b_name = "Employee Z7B#{n}"

    # Both units post stock at the same location (ledger direct post, bypassing the document
    # workflow; no location-unit linking required at this layer).
    loc = Ecto.UUID.generate()
    sku_a = Ecto.UUID.generate()

    S.post!(schema, "receipt", %{
      document_id: "doc-z7a-#{n}",
      lines: [S.line(sku_a, "5", %{to: S.side(unit_a, loc, %{responsible: emp_a.record_id})})]
    })

    S.post!(schema, "receipt", %{
      document_id: "doc-z7b-#{n}",
      lines: [S.line(sku_a, "3", %{to: S.side(unit_b, loc, %{responsible: emp_b.record_id})})]
    })

    # Create a TENANT_ADMIN user and scope them to unit_a only (drops the group-wide grant).
    sub = "z7sc#{n}"
    scoped_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: sub)
    # First call creates the user row via the OIDC plug.
    P.status!(S.get("/balances", scoped_tok), 200)

    user = Repo.one!(from(u in User, where: u.username == ^sub), prefix: schema)
    group_id = RSG.group_of!(schema, "TENANT_ADMIN")
    RSG.raw_delete_rows!(schema, group_id, "TENANT_ADMIN")
    :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", unit_a)

    # Print the stock sheet for the shared location using the scoped token.
    {:ok, today} = TenantTimezone.today(CountPaperworkSource.zone(ts.tenant_id))
    q = "location=#{loc}&from=#{Date.add(today, -2)}&to=#{today}&format=docx&lang=ru"
    conn = S.get("/stock-sheet/print?#{q}", scoped_tok)

    assert conn.status == 200, conn.resp_body
    text = docx_text(conn)

    # Employee A is the sole visible responsible: they appear in the MOL header field.
    assert text =~ emp_a_name, "employee A should appear as the responsible"
    # Employee B's legs are masked by the scoped read; their name must not leak into the sheet.
    refute text =~ emp_b_name
  end
end
