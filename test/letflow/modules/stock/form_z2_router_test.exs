Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ2RouterTest do
  @moduledoc """
  T-1416 (E5b), design tests R1..R6: `GET /documents/:id/print?form=z2` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`), the real
  HTTP path (D-098). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Org
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

  defp issue_body(ctx, extra \\ %{}) do
    ctx.ma
    |> D.body(nil, %{
      "kind" => "issue",
      "lines" => [
        %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "4"}
      ]
    })
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  defp issued(ctx), do: P.issue!(ctx, issue_body(ctx))

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  defp entity(ctx) do
    {:ok, unit} = Org.lookup(ctx.schema, ctx.ma.unit)
    {:ok, le} = Org.lookup(ctx.schema, unit["legal_entity_id"])
    le
  end

  defp item(ctx) do
    {:ok, i} = Letflow.Modules.CatalogItems.lookup(ctx.schema, ctx.ma.item)
    i
  end

  describe "R1 docx, ru" do
    test "the Z-2 file has the ru title, the table header, the line and the legal entity", ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z2&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "content-disposition") =~ ~r/filename=".+_Z-2\.docx"/
      assert header(conn, "cache-control") == "no-store"

      text = docx_text(conn)
      le = entity(ctx)

      for t <- [
            "Накладная на отпуск запасов на сторону",
            "Форма З-2",
            "Номенклатурный номер",
            item(ctx)["name"],
            "4.000000000",
            le["name"],
            le["bin"],
            "Организация (индивидуальный предприниматель) - получатель: ____________"
          ] do
        assert text =~ t, "missing #{t}"
      end
    end
  end

  describe "R2 docx, kk (Q-2 from the official text)" do
    test "the kk title and kk labels", ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z2&format=docx&lang=kk")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)

      for t <- [
            "ҚОРЛАРДЫ ШЕТКЕ БЕРУГЕ АРНАЛҒАН ЖҮКҚҰЖАТ",
            "Қ-2 нысаны",
            "Номенклатуралық нөмірі",
            "Алушы ұйым (жеке кәсіпкер)",
            item(ctx)["name"],
            "4.000000000"
          ] do
        assert text =~ t, "missing #{t}"
      end

      refute text =~ "Накладная"
    end
  end

  describe "R3 pdf" do
    test "ru and kk answer a non-empty application/pdf with the title of the language", ctx do
      doc = issued(ctx)

      for {lang, title} <- [
            {"ru", "Накладная на отпуск запасов на сторону"},
            {"kk", "ҚОРЛАРДЫ ШЕТКЕ БЕРУГЕ АРНАЛҒАН ЖҮКҚҰЖАТ"}
          ] do
        conn = print(ctx, doc["id"], "form=z2&format=pdf&lang=#{lang}")
        assert conn.status == 200, conn.resp_body
        assert header(conn, "content-type") =~ "application/pdf"
        assert header(conn, "content-disposition") =~ ~r/_Z-2\.pdf"/
        assert byte_size(conn.resp_body) > 1000
        assert String.starts_with?(conn.resp_body, "%PDF")
        items = PdfProbe.items(conn.resp_body)
        assert title in items
        assert item(ctx)["name"] in items
      end

      default = print(ctx, doc["id"], "form=z2")
      assert default.status == 200 and header(default, "content-type") =~ "application/pdf"
    end
  end

  describe "R4 refusals" do
    test "bad parameters, a draft and another kind", ctx do
      doc = issued(ctx)

      for {q, reason} <- [
            {"form=z9", "invalid_form"},
            {"form=z2&format=odt", "invalid_format"},
            {"form=z2&lang=en", "invalid_lang"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 422, q
        assert S.json(conn)["reason"] == reason
      end

      draft = P.save!(ctx, issue_body(ctx))
      conn = print(ctx, draft["id"], "form=z2&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "document_not_issued"

      {from, to} = {ctx.ma, T.b2!(ctx)}
      other = T.issue!(ctx, T.body("transfer", ctx.ma, from, to))
      conn = print(ctx, other["id"], "form=z2&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"
    end
  end

  describe "R5 isolation" do
    test "another tenant's document is the same 404 as an unknown id", ctx do
      doc_b = D.request(:post, "/documents", ctx.tok_b, D.body(ctx.mb)) |> P.status!(201)
      got = print(ctx, doc_b["id"], "form=z2&format=docx")
      want = print(ctx, Ecto.UUID.generate(), "form=z2&format=docx")
      strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
      assert got.status == 404
      assert strip.(got) == strip.(want)
      refute got.resp_body =~ "PK"

      # tenant B cannot read tenant A's issue either
      doc = issued(ctx)
      cross = print(ctx, doc["id"], "form=z2&format=docx", ctx.tok_b)
      assert cross.status == 404
    end
  end

  describe "R6 without form" do
    test "an issue without form is still print_not_available; a transfer prints as before", ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"

      {from, to} = {ctx.ma, T.b2!(ctx)}
      t = T.issue!(ctx, T.body("transfer", ctx.ma, from, to))
      ok = print(ctx, t["id"], "lang=en")
      assert ok.status == 200 and header(ok, "content-type") =~ "application/pdf"
    end
  end
end
