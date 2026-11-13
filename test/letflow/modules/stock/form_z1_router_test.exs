Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ1RouterTest do
  @moduledoc """
  T-1912: `GET /documents/:id/print?form=z1` through the full `Letflow.Router` with real OIDC
  bearer tokens on committed tenants (Sandbox `:auto`), the real HTTP path (D-098). `async: false`.

  Tests Z1-R1..R6 as described in the design.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.CatalogItems
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

  defp receipt_body(ctx, extra \\ %{}) do
    D.body(
      ctx.ma,
      nil,
      Map.merge(
        %{
          "supplier_document_ref" => "INV-77",
          "lines" => [
            %{
              "catalog_item_id" => ctx.ma.item,
              "catalog_uom_id" => ctx.ma.uom,
              "quantity" => "5.000000000",
              "unit_price" => "100.000000000",
              "line_value" => "500.000000000"
            }
          ]
        },
        extra
      )
    )
  end

  defp issued(ctx, extra \\ %{}) do
    P.issue!(ctx, receipt_body(ctx, extra))
  end

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
    {:ok, i} = CatalogItems.lookup(ctx.schema, ctx.ma.item)
    i
  end

  defp supplier(ctx) do
    {:ok, s} = CatalogItems.lookup(ctx.schema, ctx.ma.supplier)
    s
  end

  # Z1-R1: docx ru
  describe "R1 docx, ru" do
    test "the Z-1 file has the ru title, ru column labels, the item, legal entity, supplier, INV-77 and blank account",
         ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z1&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "content-disposition") =~ ~r/filename=".+_Z-1\.docx"/
      assert header(conn, "cache-control") == "no-store"

      text = docx_text(conn)
      le = entity(ctx)
      s = supplier(ctx)

      for t <- [
            "Приходный ордер ЗАПАСОВ",
            "Форма З-1",
            "Наименование поставщика",
            "Наименование, сорт, размер, марка",
            item(ctx)["name"],
            "5.000000000",
            "100.000000000",
            "500.000000000",
            le["name"],
            le["bin"],
            s["name"],
            "INV-77",
            "Корреспондирующий счет: ____________"
          ] do
        assert text =~ t, "missing #{t}"
      end
    end
  end

  # Z1-R2: docx kk
  describe "R2 docx, kk (Қ-1 from the official text)" do
    test "the kk title and kk labels, no ru title", ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z1&format=docx&lang=kk")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)

      for t <- [
            "Қорлардың КІРІС ОРДЕРІ",
            "Қ-1 нысаны",
            "Жеткізушінің атауы",
            "Қабылдаған",
            item(ctx)["name"],
            "5.000000000"
          ] do
        assert text =~ t, "missing #{t}"
      end

      refute text =~ "Приходный ордер"
    end
  end

  # Z1-R3: pdf ru and kk, default is ru pdf
  describe "R3 pdf" do
    test "ru and kk answer a non-empty application/pdf with the title of the language", ctx do
      doc = issued(ctx)

      for {lang, title} <- [
            {"ru", "Приходный ордер ЗАПАСОВ"},
            {"kk", "Қорлардың КІРІС ОРДЕРІ"}
          ] do
        conn = print(ctx, doc["id"], "form=z1&format=pdf&lang=#{lang}")
        assert conn.status == 200, conn.resp_body
        assert header(conn, "content-type") =~ "application/pdf"
        assert header(conn, "content-disposition") =~ ~r/_Z-1\.pdf"/
        assert byte_size(conn.resp_body) > 1000
        assert String.starts_with?(conn.resp_body, "%PDF")
        items = PdfProbe.items(conn.resp_body)
        assert title in items
        assert item(ctx)["name"] in items
      end

      # default: form=z1 alone gives a ru pdf
      default = print(ctx, doc["id"], "form=z1")
      assert default.status == 200 and header(default, "content-type") =~ "application/pdf"
    end
  end

  # Z1-R4: posted
  describe "R4 posted" do
    test "a posted receipt is also printable with form=z1", ctx do
      doc = issued(ctx)
      posted = P.post_and_complete!(ctx, doc["id"])
      assert posted["state"] == "posted"

      conn = print(ctx, doc["id"], "form=z1&format=pdf")
      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/pdf"
    end
  end

  # Z1-R5: refusals
  describe "R5 refusals" do
    test "bad lang, bad format, a draft, an issue with form=z1, a receipt with no form", ctx do
      doc = issued(ctx)

      for {q, reason} <- [
            {"form=z1&lang=en", "invalid_lang"},
            {"form=z1&format=odt", "invalid_format"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 422, q
        assert S.json(conn)["reason"] == reason
      end

      # Draft receipt: document_not_issued
      draft = P.save!(ctx, receipt_body(ctx))
      conn = print(ctx, draft["id"], "form=z1&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "document_not_issued"

      # Issued document of another kind (transfer): print_not_available
      {from, to} = {ctx.ma, T.b2!(ctx)}
      other = T.issue!(ctx, T.body("transfer", ctx.ma, from, to))
      conn = print(ctx, other["id"], "form=z1&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"

      # Receipt without form=z1: still print_not_available (plain print not available for receipt)
      conn = print(ctx, doc["id"], "")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"
    end
  end

  # Z1-R6: isolation (INV-1, INV-5, INV-10)
  describe "R6 isolation" do
    test "another tenant's receipt id is the same 404 as an unknown id", ctx do
      doc_b =
        D.request(:post, "/documents", ctx.tok_b, D.body(ctx.mb))
        |> P.status!(201)

      doc_b_issued =
        D.request(:post, "/documents/#{doc_b["id"]}/issue", ctx.tok_b) |> P.status!(200)

      got = print(ctx, doc_b_issued["id"], "form=z1&format=docx")
      want = print(ctx, Ecto.UUID.generate(), "form=z1&format=docx")
      strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
      assert got.status == 404
      assert strip.(got) == strip.(want)
      refute got.resp_body =~ "PK"

      # tenant B's token cannot read tenant A's receipt
      doc = issued(ctx)
      cross = print(ctx, doc["id"], "form=z1&format=docx", ctx.tok_b)
      assert cross.status == 404
    end
  end
end
