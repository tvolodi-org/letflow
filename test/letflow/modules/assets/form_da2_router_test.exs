Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa2RouterTest do
  @moduledoc """
  T-1924 (design tests R1..R8): `GET /cards/:id/print?form=da2` of the asset module through the full
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
  @nbsp " "
  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp print(ctx, id, q, tok \\ nil),
    do: D.request(:get, "/cards/#{id}/print?#{q}", tok || ctx.tok_a)

  defp docx_xml(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml
  end

  defp docx_text(conn),
    do: conn |> docx_xml() |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")

  # The table row holding `needle` that has `size` cells (the title block is one cell holding the card name).
  defp row_cells(conn, needle, size) do
    conn
    |> docx_xml()
    |> String.split("</w:tr>")
    |> Enum.filter(&String.contains?(&1, needle))
    |> Enum.map(fn row ->
      row
      |> String.split("</w:tc>")
      |> Enum.drop(-1)
      |> Enum.map(&(&1 |> String.replace(~r/<[^>]+>/, "") |> String.trim()))
    end)
    |> Enum.find(&(length(&1) == size)) || []
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

  defp kzt_card!(ctx, extra \\ %{}) do
    D.card!(
      ctx.schema,
      "fixed",
      ctx.ma.unit,
      Map.merge(
        %{
          "currency" => "KZT",
          "acquisition_date" => "2026-03-01",
          "acquisition_cost" => "1200000.000000000",
          "accumulated_depreciation" => "49360.500000000",
          "book_value" => "1150639.500000000"
        },
        extra
      )
    )
  end

  # A commissioned KZT card: one non-zero register row of the master unit and employee.
  defp commissioned!(ctx) do
    card = kzt_card!(ctx)
    ctx = %{ctx | ma: %{ctx.ma | fixed: card}}
    D.commission!(ctx)
    {card, ctx}
  end

  # The same sanitising as the route's file name: one `_` per non-ASCII byte.
  defp safe_name(inventory, ext),
    do: String.replace(inventory <> "_DA-2", ~r/[^A-Za-z0-9._-]/, "_") <> "." <> ext

  describe "R1 docx" do
    test "ru: the stored facts are on the form", ctx do
      {card, ctx} = commissioned!(ctx)
      conn = print(ctx, card, "form=da2&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      assert header(conn, "content-type") =~ @docx
      assert header(conn, "cache-control") == "no-store"
      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="#{safe_name(c["inventory_number"], "docx")}")

      text = docx_text(conn)
      le = entity(ctx.schema, ctx.ma.unit)
      {:ok, unit} = Org.lookup(ctx.schema, ctx.ma.unit)

      for t <- [
            "ИНВЕНТАРНАЯ КАРТОЧКА",
            "Форма ДА-2",
            "Приложение 17 к приказу",
            le["name"],
            le["bin"],
            unit["name"],
            employee_name(ctx.schema, ctx.ma.employee),
            c["name"],
            c["inventory_number"],
            "01.03.2026",
            "1#{@nbsp}200#{@nbsp}000"
          ] do
        assert text =~ t, "missing #{t}"
      end
    end
  end

  describe "R2 blanks" do
    test "gap cells are empty and the back side holds headers only", ctx do
      {card, ctx} = commissioned!(ctx)
      conn = print(ctx, card, "form=da2&format=docx&lang=ru")
      {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])

      cells = row_cells(conn, c["inventory_number"], 10)
      assert length(cells) == 10
      assert Enum.map([2, 3, 5, 6, 7, 8], &Enum.at(cells, &1)) == List.duplicate("", 6)
      assert Enum.at(cells, 0) == c["name"] and Enum.at(cells, 4) == c["inventory_number"]
      assert Enum.at(cells, 1) == "1#{@nbsp}200#{@nbsp}000"
      assert Enum.at(cells, 9) == "01.03.2026"

      cells2 = row_cells(conn, "1#{@nbsp}150#{@nbsp}639", 9)
      assert length(cells2) == 9
      assert Enum.map([0, 2, 3, 4, 5, 6, 7], &Enum.at(cells2, &1)) == List.duplicate("", 7)
      assert Enum.at(cells2, 1) != "" and Enum.at(cells2, 8) != ""

      for size <- [8, 3, 5],
          do: assert(row_cells(conn, c["inventory_number"], size) == [], "back table #{size}")

      filled =
        conn |> docx_text() |> String.split("\n") |> Enum.filter(&(&1 =~ "Карточку заполнил"))

      assert filled != []
      mol = employee_name(ctx.schema, ctx.ma.employee)
      for r <- filled, do: refute(r =~ mol)
    end
  end

  describe "R3 pdf" do
    test "ru (default) and kk carry their own titles", ctx do
      {card, ctx} = commissioned!(ctx)

      for {q, title, ext} <- [
            {"", "ИНВЕНТАРНАЯ КАРТОЧКА", "pdf"},
            {"form=da2&format=pdf&lang=kk", "ТҮГЕНДЕУ КАРТОЧКАСЫ", "pdf"}
          ] do
        conn = print(ctx, card, q)
        assert conn.status == 200, q
        assert header(conn, "content-type") =~ "application/pdf"
        assert "%PDF-" <> _ = conn.resp_body
        assert Enum.any?(PdfProbe.items(conn.resp_body), &(&1 =~ title)), q
        assert header(conn, "content-disposition") =~ "_DA-2.#{ext}"
      end
    end
  end

  describe "R4 holder" do
    test "a never commissioned card prints its unit and no person; a retired card prints", ctx do
      card = kzt_card!(ctx)
      conn = print(ctx, card, "form=da2&format=docx&lang=ru")
      assert conn.status == 200, conn.resp_body
      text = docx_text(conn)
      {:ok, unit} = Org.lookup(ctx.schema, ctx.ma.unit)
      assert text =~ unit["name"]
      assert text =~ entity(ctx.schema, ctx.ma.unit)["name"]
      refute text =~ employee_name(ctx.schema, ctx.ma.employee)
      refute text =~ employee_name(ctx.schema, ctx.ma.employee2)

      body = %{"idempotency_key" => Ecto.UUID.generate()}
      D.request(:post, "/cards/#{card}/retire", ctx.tok_a, body) |> D.status!(200)
      assert print(ctx, card, "form=da2").status == 200
    end
  end

  describe "R5 refusals" do
    test "a bad query is 422 and never bytes; the query is read before the card", ctx do
      {card, ctx} = commissioned!(ctx)

      for {q, why} <- [
            {"form=da1", "invalid_form"},
            {"form=da5", "invalid_form"},
            {"form=da2&format=xlsx", "invalid_format"},
            {"form=da2&lang=en", "invalid_lang"}
          ] do
        conn = print(ctx, card, q)
        assert reason(conn, 422) == why, q
        refute String.starts_with?(conn.resp_body, "%PDF")
        refute String.starts_with?(conn.resp_body, "PK")
      end

      assert reason(print(ctx, Ecto.UUID.generate(), "lang=en"), 422) == "invalid_lang"

      conn = D.request(:get, "/documents/#{Ecto.UUID.generate()}/print?form=da2", ctx.tok_a)
      assert reason(conn, 422) == "invalid_form"
    end
  end

  test "R6 another tenant's card is the same 404 as an unknown or malformed id, both ways", ctx do
    {card, ctx} = commissioned!(ctx)
    q = "form=da2&format=pdf"
    assert print(ctx, card, q).status == 200

    got = print(ctx, card, q, ctx.tok_b)
    unknown = print(ctx, Ecto.UUID.generate(), q, ctx.tok_b)
    malformed = print(ctx, "not-a-uuid", q, ctx.tok_b)
    assert got.status == 404
    refute String.starts_with?(got.resp_body, "%PDF")
    assert strip(got) == strip(unknown) and strip(got) == strip(malformed)

    card_b = D.card!(ctx.b.schema_name, "fixed", ctx.mb.unit)
    assert print(ctx, card_b, q, ctx.tok_b).status == 200
    back = print(ctx, card_b, q)
    assert back.status == 404 and strip(back) == strip(print(ctx, Ecto.UUID.generate(), q))
  end

  test "R7 a TASK_WORKER is forbidden", ctx do
    {card, ctx} = commissioned!(ctx)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-da2")
    assert D.status!(print(ctx, card, "form=da2", tok), 403)["title"] == "Forbidden"
  end

  test "R8 a Cyrillic inventory number is sanitised by the file name rule", ctx do
    card = D.card!(ctx.schema, "fixed", ctx.ma.unit, %{"inventory_number" => "ИНВ-1"})
    conn = print(ctx, card, "form=da2&format=pdf")
    assert conn.status == 200

    assert header(conn, "content-disposition") ==
             ~s(attachment; filename="#{safe_name("ИНВ-1", "pdf")}")
  end
end
