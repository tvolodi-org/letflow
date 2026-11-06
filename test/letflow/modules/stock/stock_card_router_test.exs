Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.StockCardRouterTest do
  @moduledoc """
  T-1417 (E5c), design tests T-Z3-2..T-Z3-5: `GET /stock-card/print` (official form Z-3) through the
  full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`), the real
  HTTP path (D-098). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    receipt = P.issue!(ctx)
    received = P.post_and_complete!(ctx, receipt["id"])

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

    issued = P.post_and_complete!(ctx, issue["id"])
    Map.merge(ctx, %{receipt_no: received["number"], issue_no: issued["number"]})
  end

  defp print(ctx, q, tok \\ nil),
    do: S.get("/stock-card/print?#{q}", tok || ctx.tok_a)

  defp base(ctx), do: "sku=#{ctx.ma.item}&location=#{ctx.ma.location}"

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "T-Z3-2 ru pdf after a receipt and an issue: numbers, and the closing balance is the /balances row",
       ctx do
    conn = print(ctx, base(ctx) <> "&format=pdf&lang=ru")
    assert conn.status == 200, conn.resp_body
    assert header(conn, "content-type") =~ "application/pdf"
    assert header(conn, "content-disposition") =~ ~r/stock-card_.+_Z-3\.pdf"/
    assert header(conn, "cache-control") == "no-store"

    items = PdfProbe.items(conn.resp_body)
    {:ok, item} = CatalogItems.lookup(ctx.schema, ctx.ma.item)
    text = Enum.join(items, "\n")
    assert "КАРТОЧКА УЧЕТА ЗАПАСОВ" in items
    assert text =~ item["name"]
    assert ctx.receipt_no in items
    assert ctx.issue_no in items

    %{"rows" => [row]} =
      S.get("/balances?sku=#{ctx.ma.item}&location=#{ctx.ma.location}", ctx.tok_a)
      |> P.status!(200)

    assert row["quantity"] == "1.500000000"
    assert "1.500000000" in items
    assert "2.000000000" in items
    assert "0.500000000" in items
  end

  test "T-Z3-3 kk docx: official title, form code and column heads", ctx do
    conn = print(ctx, base(ctx) <> "&format=docx&lang=kk")
    assert conn.status == 200, conn.resp_body
    assert header(conn, "content-type") =~ @docx
    text = docx_text(conn)

    for t <- [
          "ҚОРЛАРДЫ ЕСЕПКЕ АЛУ КАРТОЧКАСЫ",
          "Қ-3 нысаны",
          "Кіріс",
          "Шығыс",
          "Қалдық",
          ctx.receipt_no
        ] do
      assert text =~ t, "missing #{t}"
    end

    refute text =~ "Машиналық аударма"
  end

  test "T-Z3-4 refusals: bad parameters, unknown item, no movement, another tenant", ctx do
    for {q, reason} <- [
          {"location=#{ctx.ma.location}", "invalid_filter"},
          {"sku=#{ctx.ma.item}", "invalid_filter"},
          {"sku=nope&location=#{ctx.ma.location}", "invalid_filter"},
          {base(ctx) <> "&extra=1", "invalid_filter"},
          {base(ctx) <> "&format=odt", "invalid_format"},
          {base(ctx) <> "&lang=en", "invalid_lang"}
        ] do
      conn = print(ctx, q)
      assert conn.status == 422 and S.json(conn)["reason"] == reason, q
    end

    unknown = print(ctx, "sku=#{Ecto.UUID.generate()}&location=#{ctx.ma.location}")
    other_place = print(ctx, "sku=#{ctx.ma.item}&location=#{Ecto.UUID.generate()}")
    assert unknown.status == 404 and other_place.status == 404

    strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
    assert strip.(unknown) == strip.(other_place)

    # INV-10 style: tenant B's token with tenant A's ids sees no movement
    cross = print(ctx, base(ctx), ctx.tok_b)
    assert cross.status == 404
    refute cross.resp_body =~ "PK" or cross.resp_body =~ "%PDF"
  end

  test "T-Z3-5 a lot filter prints the lot mark; a lot without movement is 404", ctx do
    conn =
      print(
        ctx,
        "sku=#{ctx.ma.lot_item}&location=#{ctx.ma.location}&lot=#{ctx.ma.lot}&format=docx&lang=ru"
      )

    assert conn.status == 200, conn.resp_body
    {:ok, lot} = CatalogItems.lookup(ctx.schema, ctx.ma.lot)
    text = docx_text(conn)
    assert text =~ ctx.receipt_no
    if lot["mark"], do: assert(text =~ lot["mark"])

    none = print(ctx, base(ctx) <> "&lot=#{Ecto.UUID.generate()}")
    assert none.status == 404
  end
end
