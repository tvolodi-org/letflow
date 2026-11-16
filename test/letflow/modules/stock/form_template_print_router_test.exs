Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormTemplatePrintRouterTest do
  @moduledoc """
  T-1985 (0089 S3), design tests R1-R4: `GET /documents/:id/print?form=z2` prints from the company's
  active template through the full `Letflow.Router` (real tokens, committed tenants). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CompanyTemplateFixture, as: C
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp print(ctx, id, q, tok \\ nil),
    do: D.request(:get, "/documents/#{id}/print?#{q}", tok || ctx.tok_a)

  defp issued(ctx, side \\ :a) do
    {tctx, m} = if side == :a, do: {ctx, ctx.ma}, else: {%{ctx | tok_a: ctx.tok_b}, ctx.mb}

    body =
      m
      |> D.body(nil, %{
        "kind" => "issue",
        "lines" => [%{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "4"}]
      })
      |> Map.delete("counterparty_id")

    P.issue!(tctx, body)
  end

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  test "R1 an active template is printed and filled with the document's data", ctx do
    C.active!(ctx.schema, "z2", "ru")
    conn = print(ctx, issued(ctx)["id"], "form=z2&format=docx&lang=ru")
    assert conn.status == 200, conn.resp_body
    text = docx_text(conn)
    assert text =~ C.marker()
    {:ok, item} = Letflow.Modules.CatalogItems.lookup(ctx.schema, ctx.ma.item)
    assert text =~ item["name"]
  end

  test "R2 the PDF stays the platform layout", ctx do
    C.active!(ctx.schema, "z2", "ru")
    conn = print(ctx, issued(ctx)["id"], "form=z2&format=pdf&lang=ru")
    assert conn.status == 200
    refute Enum.join(PdfProbe.items(conn.resp_body), "\n") =~ C.marker()
  end

  test "R3 an outdated active template answers 422 and no text; the PDF still prints", ctx do
    C.outdated!(ctx.schema, ctx.a.tenant_id, "z2", "ru")
    id = issued(ctx)["id"]
    conn = print(ctx, id, "form=z2&format=docx&lang=ru")
    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["reason"] == "form_template_outdated"
    assert body["detail"] =~ "out of date"
    refute conn.resp_body =~ "SKIN"
    assert print(ctx, id, "form=z2&format=pdf&lang=ru").status == 200
  end

  test "R4 another tenant's template is not used", ctx do
    C.active!(ctx.schema, "z2", "ru")
    id = issued(ctx, :b)["id"]
    conn = print(ctx, id, "form=z2&format=docx&lang=ru", ctx.tok_b)
    assert conn.status == 200, conn.resp_body
    refute docx_text(conn) =~ C.marker()
  end
end
