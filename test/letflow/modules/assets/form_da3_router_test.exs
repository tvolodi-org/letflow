Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa3RouterTest do
  @moduledoc """
  T-1923 (design tests R1..R7): `GET /documents/:id/print?form=da3` of the asset module through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`). `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @moduletag timeout: 240_000
  @nbsp "\u00A0"
  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

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

  defp row_cells(conn, needle, pick \\ :first) do
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

  # A commissioned KZT card, then an issued write-off of it.
  defp writeoff!(ctx, extra \\ %{}) do
    card = kzt_card!(ctx)
    ctx = %{ctx | ma: %{ctx.ma | fixed: card}}
    D.commission!(ctx)
    {D.issue!(ctx, D.writeoff_body(ctx.ma, extra)), card, ctx}
  end

  describe "R1 docx" do
    test "ru: the stored facts are on the form, the gap cells are empty", ctx do
      {doc, card, _} = writeoff!(ctx, %{"reason_text" => "Corroded"})
      conn = print(ctx, doc["id"], "form=da3&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "cache-control") == "no-store"

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="#{doc["number"]}_DA-3.docx")

      text = docx_text(conn)
      le = entity(ctx.schema, ctx.ma.unit)
      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      for t <- [
            "АКТ НА ВЫБЫТИЕ (СПИСАНИЕ) ДОЛГОСРОЧНЫХ АКТИВОВ",
            "Форма № ДА-3",
            "Приложение 18 к приказу",
            le["name"],
            le["bin"],
            employee_name(ctx.schema, ctx.ma.employee),
            c["name"],
            c["inventory_number"],
            "01.03.2026",
            doc["number"],
            "Утилизирован: Corroded",
            "1#{@nbsp}200#{@nbsp}000"
          ] do
        assert text =~ t, "missing #{t}"
      end

      cells = row_cells(conn, c["inventory_number"])
      assert length(cells) == 10
      assert Enum.map([2, 4, 8], &Enum.at(cells, &1)) == ["", "", ""]
      assert Enum.at(cells, 9) == c["inventory_number"]
      assert Enum.at(cells, 5) == "1#{@nbsp}200#{@nbsp}000"
      assert Enum.at(cells, 6) != "" and Enum.at(cells, 7) != ""
    end
  end

  describe "R2 commission block" do
    test "prints blank: no employee name beside the chair and members, header-only tables", ctx do
      {doc, card, _} = writeoff!(ctx, %{"reason_text" => "Corroded"})
      conn = print(ctx, doc["id"], "form=da3&format=docx&lang=ru")
      text = docx_text(conn)
      assert text =~ "Комиссия, назначенная приказом"
      mol = employee_name(ctx.schema, ctx.ma.employee)
      other = employee_name(ctx.schema, ctx.ma.employee2)

      lines = String.split(text, "\n")

      for needle <- ["Председатель комиссии", "Члены комиссии"] do
        rows = Enum.filter(lines, &String.contains?(&1, needle))
        assert rows != [], needle
        for r <- rows, do: refute(r =~ mol or r =~ other, needle)
      end

      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      rows =
        conn
        |> docx_xml()
        |> String.split("</w:tr>")
        |> Enum.filter(&String.contains?(&1, c["inventory_number"]))

      assert length(rows) == 1
      assert text =~ "Вид работ"
      refute Enum.any?(row_cells(conn, "Вид работ"), &(&1 =~ "Corroded"))
    end
  end

  describe "R3 pdf" do
    test "ru (default) and kk carry their own titles", ctx do
      {doc, _, _} = writeoff!(ctx)

      for {q, title} <- [
            {"form=da3", "АКТ НА ВЫБЫТИЕ"},
            {"form=da3&format=pdf&lang=kk", "ІСТЕН ШЫҒАРУ"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 200, q
        assert header(conn, "content-type") =~ "application/pdf"
        assert "%PDF-" <> _ = conn.resp_body
        assert Enum.any?(PdfProbe.items(conn.resp_body), &(&1 =~ title)), q
        assert header(conn, "content-disposition") =~ "#{doc["number"]}_DA-3.pdf"
      end
    end
  end

  describe "R4 states" do
    test "an issued, a posted and a reversed write-off print", ctx do
      {doc, _, ctx} = writeoff!(ctx)
      assert print(ctx, doc["id"], "form=da3").status == 200
      assert D.run_task!(ctx, doc["id"])["state"] == "posted"
      assert print(ctx, doc["id"], "form=da3").status == 200

      D.mark_reversed!(ctx, doc["id"], "assets_writeoff", ctx.ma.unit)
      assert D.get!(ctx, doc["id"])["state"] == "reversed"
      assert print(ctx, doc["id"], "form=da3").status == 200
    end
  end

  describe "R5 refusals" do
    test "bad query, other kinds and a draft are 422 and never bytes", ctx do
      {doc, _, ctx} = writeoff!(ctx)

      for {q, why} <- [
            {"form=da5", "invalid_form"},
            {"form=da3&format=xlsx", "invalid_format"},
            {"form=da3&lang=en", "invalid_lang"},
            {"form=da1", "print_not_available"},
            {"form=da4", "print_not_available"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert reason(conn, 422) == why, q
        refute String.starts_with?(conn.resp_body, "%PDF")
        refute String.starts_with?(conn.resp_body, "PK")
      end

      draft = D.save!(ctx, D.writeoff_body(ctx.ma))
      assert reason(print(ctx, draft["id"], "form=da3"), 422) == "document_not_issued"

      ctx2 = %{ctx | ma: %{ctx.ma | fixed: ctx.ma.fixed2}}
      commission = D.issue!(ctx2, D.body(ctx2.ma))
      assert reason(print(ctx, commission["id"], "form=da3"), 422) == "print_not_available"

      D.run_task!(ctx2, commission["id"])
      change = D.issue!(ctx2, D.change_body(ctx2.ma))
      assert reason(print(ctx, change["id"], "form=da3"), 422) == "print_not_available"
    end
  end

  test "R6 another tenant's id is the same 404 as an unknown or malformed id, both ways", ctx do
    {doc, _, _} = writeoff!(ctx)
    q = "form=da3&format=pdf"
    assert print(ctx, doc["id"], q).status == 200

    got = print(ctx, doc["id"], q, ctx.tok_b)
    unknown = print(ctx, Ecto.UUID.generate(), q, ctx.tok_b)
    malformed = print(ctx, "not-a-uuid", q, ctx.tok_b)
    assert got.status == 404
    refute String.starts_with?(got.resp_body, "%PDF")
    assert strip(got) == strip(unknown) and strip(got) == strip(malformed)

    b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    {doc_b, _, _} = writeoff!(b)
    assert print(b, doc_b["id"], q).status == 200
    back = print(ctx, doc_b["id"], q)
    assert back.status == 404 and strip(back) == strip(print(ctx, Ecto.UUID.generate(), q))
  end

  test "R7 a TASK_WORKER is forbidden", ctx do
    {doc, _, _} = writeoff!(ctx)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-da3")
    assert D.status!(print(ctx, doc["id"], "form=da3", tok), 403)["title"] == "Forbidden"
  end
end
