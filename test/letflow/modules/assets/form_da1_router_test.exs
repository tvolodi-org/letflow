Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa1RouterTest do
  @moduledoc """
  T-1921 (design tests R1..R8): `GET /documents/:id/print?form=da1` of the asset module through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.OrgFixture

  @moduletag timeout: 240_000
  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  @nbsp " "

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp print(ctx, id, q, tok \\ nil),
    do: D.request(:get, "/documents/#{id}/print?#{q}", tok || ctx.tok_a)

  defp docx_xml(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml
  end

  defp docx_text(conn),
    do: conn |> docx_xml() |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")

  # The cells (text) of the LAST table row that holds `needle` (the page-2 row: the card name on page 1 may
  # hold the inventory number too).
  defp row_cells(conn, needle, pick \\ :last) do
    row =
      conn
      |> docx_xml()
      |> String.split("</w:tr>")
      |> Enum.filter(&String.contains?(&1, needle))
      |> then(&if(pick == :last, do: List.last(&1), else: List.first(&1)))

    row
    |> String.split("</w:tc>")
    |> Enum.drop(-1)
    |> Enum.map(&(&1 |> String.replace(~r/<[^>]+>/, "") |> String.trim()))
  end

  defp strip(conn), do: M.strip_conn(conn)
  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()
  defp reason(conn, status), do: D.status!(conn, status)["reason"]

  defp entity(schema, unit) do
    {:ok, u} = Org.lookup(schema, unit)
    {:ok, le} = Org.lookup(schema, u["legal_entity_id"])
    le
  end

  defp employee_name(schema, id) do
    {:ok, e} = Org.lookup(schema, id)
    e["full_name"]
  end

  defp kzt_card!(ctx) do
    D.card!(ctx.schema, "fixed", ctx.ma.unit, %{
      "currency" => "KZT",
      "acquisition_date" => "2026-03-01",
      "acquisition_cost" => "1200000.000000000",
      "accumulated_depreciation" => "49360.500000000",
      "book_value" => "1150639.500000000"
    })
  end

  defp commission!(ctx) do
    card = kzt_card!(ctx)
    ma = %{ctx.ma | fixed: card}
    {D.issue!(ctx, D.body(ma)), card}
  end

  defp handover!(ctx) do
    D.commission!(ctx)
    to = D.place!(ctx.schema, "Beta Receiver LLP")
    {D.issue!(ctx, D.handover_body(ctx.ma, to)), to}
  end

  describe "R1 commission" do
    test "docx ru: the stored facts are on the form, the gap cells are empty", ctx do
      {doc, card} = commission!(ctx)
      conn = print(ctx, doc["id"], "form=da1&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "cache-control") == "no-store"

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="#{doc["number"]}_DA-1.docx")

      text = docx_text(conn)
      le = entity(ctx.schema, ctx.ma.unit)
      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      for t <- [
            "АКТ ПРИЕМКИ - ПЕРЕДАЧИ ДОЛГОСРОЧНЫХ АКТИВОВ",
            "Форма ДА-1",
            "Приложение 16 к приказу",
            le["name"],
            le["bin"],
            employee_name(ctx.schema, ctx.ma.employee),
            c["name"],
            c["inventory_number"],
            "01.03.2026",
            "1#{@nbsp}200#{@nbsp}000"
          ] do
        assert text =~ t, "missing #{t}"
      end

      cells = row_cells(conn, c["inventory_number"])
      assert length(cells) == 9

      # depr_life, factory, debit, credit, passport and sale (Q21) stay empty; depr and book are filled
      assert Enum.map([0, 4, 5, 6, 7, 8], &Enum.at(cells, &1)) == List.duplicate("", 6)
      assert Enum.at(cells, 1) == "49#{@nbsp}360,5"
      assert Enum.at(cells, 2) == "1#{@nbsp}150#{@nbsp}639,5"
      assert Enum.at(cells, 3) == c["inventory_number"]
    end
  end

  describe "R2 hand over" do
    test "docx ru: sender and receiver differ, signers, MOL column, receiving location", ctx do
      {doc, to} = handover!(ctx)
      conn = print(ctx, doc["id"], "form=da1&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)
      from_le = entity(ctx.schema, ctx.ma.unit)
      to_le = entity(ctx.schema, to.unit)
      assert from_le["name"] != to_le["name"] and to_le["name"] == "Beta Receiver LLP"

      giver = employee_name(ctx.schema, ctx.ma.employee)
      taker = employee_name(ctx.schema, to.employee)

      for t <- [from_le["name"], to_le["name"], giver, taker, from_le["bin"]],
          do: assert(text =~ t, "missing #{t}")

      refute text =~ to_le["bin"]

      {:ok, c} = ReadApi.lookup(ctx.schema, ctx.ma.fixed, ["assets_card"])
      assert Enum.any?(row_cells(conn, c["name"], :first), &(&1 == giver))
    end
  end

  describe "R3 formats and languages" do
    test "pdf ru (default) and kk carry their own titles", ctx do
      {doc, _} = commission!(ctx)

      for {q, title} <- [
            {"form=da1", "АКТ ПРИЕМКИ - ПЕРЕДАЧИ ДОЛГОСРОЧНЫХ АКТИВОВ"},
            {"form=da1&format=pdf&lang=kk", "ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ҚАБЫЛДАП АЛУ-БЕРУ АКТІСІ"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 200, q
        assert header(conn, "content-type") =~ "application/pdf"
        assert "%PDF-" <> _ = conn.resp_body
        assert Enum.any?(PdfProbe.items(conn.resp_body), &(&1 =~ title)), q
        assert header(conn, "content-disposition") =~ "#{doc["number"]}_DA-1.pdf"
      end
    end
  end

  describe "R4 states" do
    test "a posted and a reversed commission print too", ctx do
      {doc, _} = commission!(ctx)
      assert print(ctx, doc["id"], "form=da1").status == 200
      assert D.run_task!(ctx, doc["id"])["state"] == "posted"
      assert print(ctx, doc["id"], "form=da1").status == 200

      D.mark_reversed!(ctx, doc["id"], "assets_commission", ctx.ma.unit)
      assert D.get!(ctx, doc["id"])["state"] == "reversed"
      assert print(ctx, doc["id"], "form=da1").status == 200
    end
  end

  describe "R5 refusals" do
    test "bad query, other kinds and a draft are 422 and never bytes", ctx do
      {doc, _} = commission!(ctx)

      for {q, why} <- [
            {"form=z6", "invalid_form"},
            {"form[]=da1", "invalid_form"},
            {"form=da1&format=xlsx", "invalid_format"},
            {"form=da1&lang=en", "invalid_lang"},
            {"form=da1&lang=de", "invalid_lang"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert reason(conn, 422) == why, q
        refute String.starts_with?(conn.resp_body, "%PDF")
      end

      draft = D.save!(ctx)
      assert reason(print(ctx, draft["id"], "form=da1"), 422) == "document_not_issued"

      ctx2 = %{ctx | ma: %{ctx.ma | fixed: ctx.ma.fixed2}}
      D.commission!(ctx2)
      change = D.issue!(ctx2, D.change_body(ctx2.ma))
      assert reason(print(ctx, change["id"], "form=da1"), 422) == "print_not_available"

      writeoff =
        D.issue!(
          ctx2,
          D.writeoff_body(ctx2.ma, %{"reason_code" => "broken", "reason_text" => "x"})
        )

      assert reason(print(ctx, writeoff["id"], "form=da1"), 422) == "print_not_available"
    end

    test "without a form key the plain act is unchanged", ctx do
      {doc, _} = commission!(ctx)
      conn = print(ctx, doc["id"], "lang=ru")
      assert conn.status == 200

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="#{doc["number"]}.pdf")

      assert DocumentPrint.labels()[:title_commission][:ru] in PdfProbe.items(conn.resp_body)
    end
  end

  test "R6 another tenant's id is the same 404 as an unknown or malformed id, both ways", ctx do
    {doc, _} = commission!(ctx)
    q = "form=da1&format=pdf"
    assert print(ctx, doc["id"], q).status == 200

    got = print(ctx, doc["id"], q, ctx.tok_b)
    unknown = print(ctx, Ecto.UUID.generate(), q, ctx.tok_b)
    malformed = print(ctx, "not-a-uuid", q, ctx.tok_b)
    assert got.status == 404
    refute String.starts_with?(got.resp_body, "%PDF")
    assert strip(got) == strip(unknown) and strip(got) == strip(malformed)

    b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = D.issue!(b)
    assert print(b, doc_b["id"], q).status == 200
    back = print(ctx, doc_b["id"], q)
    assert back.status == 404 and strip(back) == strip(print(ctx, Ecto.UUID.generate(), q))
  end

  test "R7 a TASK_WORKER is forbidden", ctx do
    {doc, _} = commission!(ctx)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-da1")
    assert D.status!(print(ctx, doc["id"], "form=da1", tok), 403)["title"] == "Forbidden"
  end

  test "R8 a glyph the PDF font lacks is 422 and no bytes; the docx has no font limit", ctx do
    emp =
      OrgFixture.create!(
        ctx.schema,
        "org_employee",
        OrgFixture.values("org_employee", "ZH#{System.unique_integer([:positive])}", %{
          "org_unit_id" => ctx.ma.unit,
          "full_name" => "漢字"
        })
      ).record_id

    doc = D.issue!(ctx, D.body(ctx.ma, %{"material_responsible_id" => emp}))
    conn = print(ctx, doc["id"], "form=da1&format=pdf")
    assert reason(conn, 422) == "print_unsupported_character"
    refute String.starts_with?(conn.resp_body, "%PDF")
    assert print(ctx, doc["id"], "form=da1&format=docx").status == 200
  end
end
