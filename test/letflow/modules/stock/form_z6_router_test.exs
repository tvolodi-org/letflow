Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ6RouterTest do
  @moduledoc """
  T-1914: `GET /documents/:id/print?form=z6` through the full `Letflow.Router` with real OIDC
  bearer tokens on committed tenants (Sandbox `:auto`). `async: false`. Tests Z6-R1..R6 of the design.
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

  defp write_off_body(m, extra \\ %{}) do
    m
    |> D.body(nil, %{
      "kind" => "write_off",
      "reason_code" => "damaged",
      "lines" => [
        %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "1"}
      ]
    })
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  defp issued(ctx), do: P.issue!(ctx, write_off_body(ctx.ma))

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

  describe "R1 docx, ru" do
    test "the Z-6 file has the title, the legal entity, the item, the reason and a blank commission",
         ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z6&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "content-disposition") =~ ~r/filename=".+_Z-6\.docx"/
      assert header(conn, "cache-control") == "no-store"

      text = docx_text(conn)
      le = entity(ctx)
      it = item(ctx)

      for t <- [
            "АКТ списания запасов",
            "Форма З-6",
            le["name"],
            le["bin"],
            it["name"],
            it["code"],
            "Повреждено",
            "Председатель комиссии"
          ] do
        assert text =~ t, "missing #{t}"
      end

      # The responsible person is printed in the header field and the MOL signature only: the
      # commission chair line is blank (REQ-776 not built).
      {:ok, emp} = Letflow.Modules.Org.lookup(ctx.schema, ctx.ma.employee)
      name = emp["full_name"]
      assert is_binary(name) and name != ""
      assert length(String.split(text, name)) - 1 == 2
    end
  end

  describe "R2 docx, kk" do
    test "the kk title and labels, no ru title", ctx do
      doc = issued(ctx)
      conn = print(ctx, doc["id"], "form=z6&format=docx&lang=kk")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)

      for t <- ["ҚОРЛАРДЫ ЕСЕПТЕН ШЫҒАРУ АКТІСІ", "Қ-6 нысаны", "Зақымдалған", item(ctx)["name"]] do
        assert text =~ t, "missing #{t}"
      end

      refute text =~ "АКТ списания запасов"
    end
  end

  describe "R3 pdf" do
    test "ru and kk answer a pdf with the title of the language; no lang is ru", ctx do
      doc = issued(ctx)

      for {lang, title} <- [
            {"ru", "АКТ списания запасов"},
            {"kk", "ҚОРЛАРДЫ ЕСЕПТЕН ШЫҒАРУ АКТІСІ"}
          ] do
        conn = print(ctx, doc["id"], "form=z6&format=pdf&lang=#{lang}")
        assert conn.status == 200, conn.resp_body
        assert header(conn, "content-type") =~ "application/pdf"
        assert header(conn, "content-disposition") =~ ~r/_Z-6\.pdf"/
        assert String.starts_with?(conn.resp_body, "%PDF")
        assert title in PdfProbe.items(conn.resp_body)
      end

      default = print(ctx, doc["id"], "form=z6")
      assert default.status == 200 and header(default, "content-type") =~ "application/pdf"
    end
  end

  describe "R4 posted" do
    @tag timeout: 120_000
    test "a posted write-off is printable with form=z6", ctx do
      T.receive!(ctx, ctx.ma, "10")
      doc = issued(ctx)
      posted = P.post_and_complete!(ctx, doc["id"])
      assert posted["state"] == "posted"

      conn = print(ctx, doc["id"], "form=z6&format=pdf")
      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/pdf"
    end
  end

  describe "R5 refusals" do
    test "bad lang or format, a draft, other kinds and other forms are refused; no form is the plain act",
         ctx do
      doc = issued(ctx)

      for {q, reason} <- [
            {"form=z6&lang=en", "invalid_lang"},
            {"form=z6&format=odt", "invalid_format"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 422, q
        assert S.json(conn)["reason"] == reason
      end

      draft = P.save!(ctx, write_off_body(ctx.ma))
      conn = print(ctx, draft["id"], "form=z6&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "document_not_issued"

      receipt = P.issue!(ctx, D.body(ctx.ma))
      conn = print(ctx, receipt["id"], "form=z6&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"

      conn = print(ctx, doc["id"], "form=z1&format=docx")
      assert conn.status == 422 and S.json(conn)["reason"] == "print_not_available"

      plain = print(ctx, doc["id"], "")
      assert plain.status == 200 and header(plain, "content-type") =~ "application/pdf"
    end
  end

  describe "R6 isolation" do
    test "another tenant's write-off id is the same 404 as an unknown id", ctx do
      doc_b = P.issue!(Map.put(ctx, :tok_a, ctx.tok_b), write_off_body(ctx.mb))

      got = print(ctx, doc_b["id"], "form=z6&format=docx")
      want = print(ctx, Ecto.UUID.generate(), "form=z6&format=docx")
      strip = fn c -> c |> S.json() |> Map.delete("trace_id") end
      assert got.status == 404
      assert strip.(got) == strip.(want)
      refute got.resp_body =~ "PK"

      doc = issued(ctx)
      cross = print(ctx, doc["id"], "form=z6&format=docx", ctx.tok_b)
      assert cross.status == 404
    end
  end
end
