Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ5RouterTest do
  @moduledoc """
  T-1417 (E5c), design tests T-Z5-2..T-Z5-4: `GET /documents/:id/print?form=z5` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`), the real
  HTTP path (D-098). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp print(ctx, id, q, tok \\ nil),
    do: D.request(:get, "/documents/#{id}/print?#{q}", tok || ctx.tok_a)

  defp transfer(ctx) do
    to = T.b2!(ctx)
    {T.issue!(ctx, T.body("transfer", ctx.ma, ctx.ma, to)), to}
  end

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "T-Z5-2 ru pdf of an issued transfer: title, item and both unit names", ctx do
    {doc, to} = transfer(ctx)
    conn = print(ctx, doc["id"], "form=z5&format=pdf&lang=ru")
    assert conn.status == 200, conn.resp_body
    assert header(conn, "content-type") =~ "application/pdf"
    assert header(conn, "content-disposition") =~ ~r/_Z-5\.pdf"/
    assert String.starts_with?(conn.resp_body, "%PDF")

    items = PdfProbe.items(conn.resp_body)
    {:ok, item} = CatalogItems.lookup(ctx.schema, ctx.ma.item)
    assert "Накладная на внутреннее перемещение запасов" in items
    assert item["name"] in items
    {:ok, from_unit} = Letflow.Modules.Org.lookup(ctx.schema, ctx.ma.unit)
    {:ok, to_unit} = Letflow.Modules.Org.lookup(ctx.schema, to.unit)
    text = Enum.join(items, "\n")
    assert text =~ from_unit["name"]
    assert text =~ to_unit["name"]
  end

  test "T-Z5-3 kk docx: official title and form code, no draft notice", ctx do
    {doc, _to} = transfer(ctx)
    conn = print(ctx, doc["id"], "form=z5&format=docx&lang=kk")
    assert conn.status == 200, conn.resp_body
    assert header(conn, "content-type") =~ @docx
    assert header(conn, "content-disposition") =~ ~r/_Z-5\.docx"/
    text = docx_text(conn)

    for t <- [
          "ҚОРЛАРДЫ ІШКІ АУЫСТЫРУҒА АРНАЛҒАН ЖҮКҚҰЖАТ",
          "Қ-5 нысаны",
          "Жөнелтуші құрылымдық бөлімше",
          "Алды"
        ] do
      assert text =~ t, "missing #{t}"
    end

    refute text =~ "Машиналық аударма"
    refute text =~ "Накладная"
  end

  test "T-Z5-4 refusals: another kind, a draft, a bad form, another tenant", ctx do
    {doc, _to} = transfer(ctx)

    for {q, reason} <- [
          {"form=z9", "invalid_form"},
          {"form=z5&format=odt", "invalid_format"},
          {"form=z5&lang=en", "invalid_lang"}
        ] do
      conn = print(ctx, doc["id"], q)
      assert conn.status == 422 and S.json(conn)["reason"] == reason, q
    end

    receipt = P.issue!(ctx)
    conn = print(ctx, receipt["id"], "form=z5&format=docx")
    assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"

    draft = P.save!(ctx, T.body("transfer", ctx.ma, ctx.ma, T.b2!(ctx)))
    conn = print(ctx, draft["id"], "form=z5&format=docx")
    assert conn.status == 422 and S.json(conn)["reason"] == "document_not_issued"

    got = print(ctx, doc["id"], "form=z5&format=docx", ctx.tok_b)
    want = print(ctx, Ecto.UUID.generate(), "form=z5&format=docx", ctx.tok_b)
    strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
    assert got.status == 404 and strip.(got) == strip.(want)
  end
end
