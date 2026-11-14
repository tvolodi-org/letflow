Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa4RouterTest do
  @moduledoc """
  T-1922 (design tests H1..H7): `GET /documents/:id/print?form=da4` of the asset module through the full
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

  # A change of the responsible person of a card with a stored acquisition date.
  defp change!(ctx) do
    card = D.card!(ctx.schema, "fixed", ctx.ma.unit, %{"acquisition_date" => "2026-03-01"})
    ma = %{ctx.ma | fixed: card}
    ctx = %{ctx | ma: ma}
    D.commission!(ctx)
    {D.issue!(ctx, D.change_body(ma)), card, ctx}
  end

  defp handover!(ctx) do
    D.commission!(ctx)
    to = D.place!(ctx.schema, "Beta Receiver LLP")
    {D.issue!(ctx, D.handover_body(ctx.ma, to)), to}
  end

  describe "H1 change" do
    test "docx ru: the stored facts are on the form, the gap and Q22 cells are empty", ctx do
      {doc, card, _} = change!(ctx)
      conn = print(ctx, doc["id"], "form=da4&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "cache-control") == "no-store"

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="#{doc["number"]}_DA-4.docx")

      text = docx_text(conn)
      le = entity(ctx.schema, ctx.ma.unit)
      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      for t <- [
            "НАКЛАДНАЯ НА ВНУТРЕННЕЕ ПЕРЕМЕЩЕНИЕ ДОЛГОСРОЧНЫХ АКТИВОВ",
            "Форма ДА-4",
            "Приложение 19 к приказу",
            le["name"],
            le["bin"],
            employee_name(ctx.schema, ctx.ma.employee),
            employee_name(ctx.schema, ctx.ma.employee2),
            c["name"],
            c["inventory_number"],
            "01.03.2026",
            doc["number"]
          ] do
        assert text =~ t, "missing #{t}"
      end

      cells = row_cells(conn, c["inventory_number"])
      assert length(cells) == 10
      assert Enum.at(cells, 3) == c["inventory_number"]
      assert Enum.at(cells, 7) == "1"
      assert Enum.map([4, 5, 6, 8, 9], &Enum.at(cells, &1)) == List.duplicate("", 5)

      total = row_cells(conn, "Итого")
      assert Enum.at(total, 7) == "1" and Enum.at(total, 8) == "x" and List.last(total) == ""
    end
  end

  describe "H2 hand over" do
    test "docx ru: receiver unit, giving organisation only; ДА-1 is still offered", ctx do
      {doc, to} = handover!(ctx)
      conn = print(ctx, doc["id"], "form=da4&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)
      from_le = entity(ctx.schema, ctx.ma.unit)
      {:ok, to_unit} = Org.lookup(ctx.schema, to.unit)
      giver = employee_name(ctx.schema, ctx.ma.employee)
      taker = employee_name(ctx.schema, to.employee)

      for t <- [from_le["name"], to_unit["name"], giver, taker],
          do: assert(text =~ t, "missing #{t}")

      refute text =~ "Beta Receiver LLP"
      assert print(ctx, doc["id"], "form=da1&format=docx").status == 200
    end
  end

  describe "H3 formats and languages" do
    test "pdf ru (default) and kk carry their own titles", ctx do
      {doc, _, _} = change!(ctx)

      for {q, title} <- [
            {"form=da4", "ВНУТРЕННЕЕ ПЕРЕМЕЩЕНИЕ"},
            {"form=da4&format=pdf&lang=kk", "ІШКІ ӨТКІЗУГЕ"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert conn.status == 200, q
        assert header(conn, "content-type") =~ "application/pdf"
        assert "%PDF-" <> _ = conn.resp_body
        assert Enum.any?(PdfProbe.items(conn.resp_body), &(&1 =~ title)), q
        assert header(conn, "content-disposition") =~ "#{doc["number"]}_DA-4.pdf"
      end
    end
  end

  describe "H4 states" do
    test "an issued, a posted and a reversed change print", ctx do
      {doc, _, ctx} = change!(ctx)
      assert print(ctx, doc["id"], "form=da4").status == 200
      assert D.run_task!(ctx, doc["id"])["state"] == "posted"
      assert print(ctx, doc["id"], "form=da4").status == 200

      D.mark_reversed!(ctx, doc["id"], "assets_change", ctx.ma.unit)
      assert D.get!(ctx, doc["id"])["state"] == "reversed"
      assert print(ctx, doc["id"], "form=da4").status == 200
    end
  end

  describe "H5 refusals" do
    test "bad query, other kinds and a draft are 422 and never bytes", ctx do
      {doc, _, ctx} = change!(ctx)

      for {q, why} <- [
            {"form=da5", "invalid_form"},
            {"form=da4&format=xlsx", "invalid_format"},
            {"form=da4&lang=en", "invalid_lang"}
          ] do
        conn = print(ctx, doc["id"], q)
        assert reason(conn, 422) == why, q
        refute String.starts_with?(conn.resp_body, "%PDF")
        refute String.starts_with?(conn.resp_body, "PK")
      end

      draft = D.save!(ctx, D.change_body(ctx.ma))
      assert reason(print(ctx, draft["id"], "form=da4"), 422) == "document_not_issued"

      ctx2 = %{ctx | ma: %{ctx.ma | fixed: ctx.ma.fixed2}}
      commission = D.issue!(ctx2, D.body(ctx2.ma))
      assert reason(print(ctx, commission["id"], "form=da4"), 422) == "print_not_available"

      D.run_task!(ctx2, commission["id"])

      writeoff =
        D.issue!(
          ctx2,
          D.writeoff_body(ctx2.ma, %{"reason_code" => "broken", "reason_text" => "x"})
        )

      assert reason(print(ctx, writeoff["id"], "form=da4"), 422) == "print_not_available"
    end
  end

  test "H6 another tenant's id is the same 404 as an unknown or malformed id, both ways", ctx do
    {doc, _, _} = change!(ctx)
    q = "form=da4&format=pdf"
    assert print(ctx, doc["id"], q).status == 200

    got = print(ctx, doc["id"], q, ctx.tok_b)
    unknown = print(ctx, Ecto.UUID.generate(), q, ctx.tok_b)
    malformed = print(ctx, "not-a-uuid", q, ctx.tok_b)
    assert got.status == 404
    refute String.starts_with?(got.resp_body, "%PDF")
    assert strip(got) == strip(unknown) and strip(got) == strip(malformed)

    b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    D.commission!(b)
    doc_b = D.issue!(b, D.change_body(b.ma))
    assert print(b, doc_b["id"], q).status == 200
    back = print(ctx, doc_b["id"], q)
    assert back.status == 404 and strip(back) == strip(print(ctx, Ecto.UUID.generate(), q))
  end

  test "H7 a TASK_WORKER is forbidden", ctx do
    {doc, _, _} = change!(ctx)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-da4")
    assert D.status!(print(ctx, doc["id"], "form=da4", tok), 403)["title"] == "Forbidden"
  end
end
