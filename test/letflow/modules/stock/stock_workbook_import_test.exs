Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.StockWorkbookImportTest do
  @moduledoc """
  REQ-884 / GH #4607: the check of a Qoimeks-layout balances workbook. Criteria 1 to 9 as named in
  the requirement: access (T-WI-1), round trip (T-WI-2), normalising (T-WI-3), changes (T-WI-4),
  remarks (T-WI-5), header and caps (T-WI-6), read only and tenancy (T-WI-7), one parse (T-WI-8).
  Byte bounds T-WI-10..14; reference padding (forged `r` references) T-WI-15..19; huge index texts T-WI-20.
  Committed tenants in Sandbox `:auto` mode; `async: false` (app env seams, DDL).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [put_req_header: 3]

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.StockWorkbookImport, as: WI
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.StockDocsFixture, as: Docs
  alias Letflow.StockFixture, as: S

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ["Артикул", "Номенклатура", "Конечный остаток", "Зона", "Стеллаж", "Полка"]

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("wbi-a", ctx.names.a)
    b = S.tenant!("wbi-b", ctx.names.b)
    Map.merge(ctx, %{a: a, b: b, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  # -- helpers -----------------------------------------------------------------------------------

  defp xlsx!(rows, sheet \\ "Лист1") do
    wb = %Elixlsx.Workbook{sheets: [%Elixlsx.Sheet{name: sheet, rows: rows}]}
    {:ok, {_name, bin}} = Elixlsx.write_to_memory(wb, "t.xlsx")
    bin
  end

  defp book(rows), do: xlsx!([@header | rows])

  defp parse!(rows) do
    {:ok, parsed} = WI.parse(book(rows))
    parsed
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp loc!(schema, code) do
    {:ok, node} =
      Locations.create_node(
        schema,
        %{"code" => code, "name" => code, "node_kind" => "zone"},
        opts()
      )

    node["record_id"]
  end

  defp post_check(path, token, body, ct \\ @xlsx) do
    Plug.Test.conn(:post, S.base() <> path, body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", ct)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp check(ctx, unit, bytes, tok \\ nil) do
    conn = post_check("/stock-workbook/check?org_unit_id=#{unit}", tok || ctx.tok_a, bytes)
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp reason!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)["reason"]
  end

  # Items Z-1 (10 at RI2, 3 at LA1), Z-2 (5 at RK2, usual place LA1), Z-3 (nothing).
  defp seed!(schema) do
    unit = Docs.unit!(schema)
    uom = Cat.uom!(schema, "pcs")
    ri2 = loc!(schema, "RI2")
    la1 = loc!(schema, "LA1")
    rk2 = loc!(schema, "RK2")
    z1 = Cat.item!(schema, "Z-1", uom.record_id, %{"name" => "Один"})
    z2 = Cat.item!(schema, "Z-2", uom.record_id, %{"name" => "Два", "default_location_id" => la1})
    z3 = Cat.item!(schema, "Z-3", uom.record_id, %{"name" => "Три"})

    S.post!(schema, "receipt", %{
      document_id: "wbi-1",
      lines: [
        S.line(z1.record_id, "10", %{to: S.side(unit, ri2)}),
        S.line(z1.record_id, "3", %{to: S.side(unit, la1)}),
        S.line(z2.record_id, "5", %{to: S.side(unit, rk2)})
      ]
    })

    %{unit: unit, uom: uom, ri2: ri2, la1: la1, rk2: rk2, z1: z1, z2: z2, z3: z3}
  end

  defp texts(answer), do: Enum.map(answer["remarks"], & &1["text"])

  # -- criterion 1 -------------------------------------------------------------------------------

  describe "access" do
    test "T-WI-1 roles, scoped reader, org unit and query keys", ctx do
      m = seed!(ctx.a.schema_name)
      bytes = book([["Z-1", "Один", 10, "R", "I", 2]])
      path = "/stock-workbook/check?org_unit_id=#{m.unit}"

      for roles <- [["TENANT_ADMIN"], ["STOREKEEPER"]] do
        tok = S.token(ctx, :a, roles, sub: "wbi-#{hd(roles)}")
        assert post_check(path, tok, bytes).status == 200
      end

      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "wbi-worker")
      conn = post_check(path, worker, bytes)
      body = S.json(conn)
      assert conn.status == 403 and body["detail"] == "insufficient permissions"

      assert reason!(post_check("/stock-workbook/check", ctx.tok_a, bytes), 422) ==
               "org_unit_required"

      unknown = Ecto.UUID.generate()
      c1 = post_check("/stock-workbook/check?org_unit_id=#{unknown}", ctx.tok_a, bytes)
      assert reason!(c1, 422) == "org_unit_not_found"

      other = Docs.unit!(ctx.b.schema_name)
      c2 = post_check("/stock-workbook/check?org_unit_id=#{other}", ctx.tok_a, bytes)
      assert reason!(c2, 422) == "org_unit_not_found"
      assert M.strip(S.json(c1)) == M.strip(S.json(c2))

      assert reason!(post_check(path <> "&x=1", ctx.tok_a, bytes), 422) == "invalid_filter"

      assert reason!(
               post_check(
                 "/stock-workbook/check?org_unit_id=#{m.unit}&format=json",
                 ctx.tok_a,
                 bytes
               ),
               422
             ) == "invalid_filter"
    end

    test "T-WI-1b a scoped reader gets the unknown-path 404", ctx do
      s = S.tenant!("wbi-s", ctx.names.s)
      node = Letflow.Support.RoleScopeGrantsFixture.node!(s.schema_name)
      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "wbi-scoped")
      assert S.get("/balances", tok).status == 200

      _ =
        Letflow.Support.RoleScopeGrantsFixture.raw_delete_rows!(
          s.schema_name,
          Letflow.Support.RoleScopeGrantsFixture.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      import Ecto.Query, only: [from: 2]

      user =
        Letflow.Repo.one!(from(u in Letflow.Identity.User, where: u.username == "wbi-scoped"),
          prefix: s.schema_name
        )

      :ok =
        Letflow.Support.RoleScopeGrantsFixture.raw_user_row!(
          s.schema_name,
          user.id,
          "TENANT_ADMIN",
          node
        )

      unit = Docs.unit!(s.schema_name)
      conn = post_check("/stock-workbook/check?org_unit_id=#{unit}", tok, book([]))
      reference = S.json(S.get("/stock-workbook", tok))
      assert conn.status == 404
      assert M.strip(S.json(conn)) == M.strip(reference)
    end
  end

  # -- criterion 2 -------------------------------------------------------------------------------

  describe "round trip" do
    test "T-WI-2 the REQ-865 workbook checks clean", ctx do
      m = seed!(ctx.a.schema_name)
      conn = S.get("/stock-workbook", ctx.tok_a)
      assert conn.status == 200

      answer = check(ctx, m.unit, conn.resp_body)
      assert answer["changes"] == [] and answer["remarks"] == []
      assert answer["unchanged_count"] == 3
      assert answer["too_many_changes"] == false
    end
  end

  describe "round trip place codes (T-2287)" do
    test "T-WI-2b an unchanged export of many place shapes reads back with no R11", ctx do
      schema = ctx.a.schema_name
      unit = Docs.unit!(schema)
      uom = Cat.uom!(schema, "pcs")

      codes =
        ~w(LA3 RA1 RA12 RB7 RB10 O1 OO1 RO5 L A7 RA007 RB0 Z99 WH-01 LA 0)

      sides =
        Enum.map(codes, fn code ->
          {code, S.side(unit, loc!(schema, code))}
        end)

      lines =
        sides
        |> Enum.with_index(1)
        |> Enum.map(fn {{_code, side}, i} ->
          item = Cat.item!(schema, "RT-#{i}", uom.record_id, %{"name" => "Товар #{i}"})
          S.line(item.record_id, "#{i}", %{to: side})
        end)

      S.post!(schema, "receipt", %{document_id: "wbi-rt", lines: lines})

      conn = S.get("/stock-workbook", ctx.tok_a)
      assert conn.status == 200
      answer = check(ctx, unit, conn.resp_body)
      r11 = Enum.filter(texts(answer), &String.contains?(&1, "прочитано как"))
      assert r11 == []
      assert answer["changes"] == []
    end
  end

  # -- criterion 3 -------------------------------------------------------------------------------

  describe "normalising" do
    test "T-WI-3 look-alike letters, zero and quantity cells" do
      parsed =
        parse!([
          ["A", "n", 1, "К", "р", 2],
          ["B", "n", 1, "r", "a", 1],
          ["C", "n", 1, "L", "0", 1],
          ["D", "n", "1 234,5"],
          ["E", "n", "1.234,5"],
          ["F", "n", "1,234.5"],
          ["G", "n", "1’234"],
          ["H", "n", "12,0"],
          ["I", "n", 7.25],
          ["J", "n", "-3"],
          ["K", "n", "abc"],
          ["L", "n", "1,2,3.4.5"]
        ])

      [a, b, c | rest] = parsed.rows
      assert a.place == "KP2"
      assert a.remarks == [~s(строка 2: A: место "К" "р" 2 прочитано как KP2)]
      assert b.place == "RA1" and b.remarks == []
      assert c.place == "LO1" and length(c.remarks) == 1

      {good, bad} = Enum.split(rest, 6)

      values =
        Enum.map(
          good,
          &(elem(&1.quantity, 1) |> Decimal.normalize() |> Decimal.to_string(:normal))
        )

      assert values == ["1234.5", "1234.5", "1234.5", "1234", "12", "7.25"]

      assert Enum.map(bad, & &1.quantity) == [
               {:error, "-3"},
               {:error, "abc"},
               {:error, "1,2,3.4.5"}
             ]
    end

    test "T-WI-3b H is read only when D to F are empty" do
      parsed =
        parse!([["A", "n", 1, "", "", "", "", "ка2"], ["B", "n", 1, "L", "", "", "", "ZZ9"]])

      assert Enum.map(parsed.rows, & &1.place) == ["KA2", "L"]
    end
  end

  # -- criterion 4 -------------------------------------------------------------------------------

  describe "changes" do
    test "T-WI-4 sums, emptied places, untouched items, unchanged", ctx do
      m = seed!(ctx.a.schema_name)

      answer =
        check(
          ctx,
          m.unit,
          book([["Z-1", "Один", 7, "R", "I", 2], ["Z-1", "Один", 1, "R", "I", 2]])
        )

      assert [la1, ri2] = answer["changes"]

      assert %{
               "place_code" => "RI2",
               "book_quantity" => "10",
               "file_quantity" => "8",
               "difference" => "-2",
               "item_code" => "Z-1",
               "row" => 2
             } = ri2

      assert %{
               "place_code" => "LA1",
               "book_quantity" => "3",
               "file_quantity" => "0",
               "difference" => "-3",
               "row" => nil
             } = la1

      assert Enum.any?(texts(answer), &(&1 =~ "место RI2 указано повторно, остатки сложены: 8"))
      assert Enum.all?(answer["changes"], &(&1["item_code"] == "Z-1"))

      same = check(ctx, m.unit, book([["Z-2", "Два", 5, "R", "K", 2]]))
      assert same["changes"] == [] and same["unchanged_count"] == 1
    end
  end

  # -- criterion 5 -------------------------------------------------------------------------------

  describe "remarks" do
    test "T-WI-5 R1 R3 R5 R6 R8 R9 and R10", ctx do
      m = seed!(ctx.a.schema_name)
      Cat.item!(ctx.a.schema_name, "LOT-1", m.uom.record_id, %{"tracking_policy" => "lot"})

      one = fn rows -> check(ctx, m.unit, book(rows)) end
      none = fn a -> Enum.filter(a["changes"], &(&1["item_code"] == "Z-1")) end

      a = one.([["Z-1", "Один", "abc", "R", "I", 2]])

      assert texts(a) == [
               ~s(строка 2: Z-1: остаток "abc" не является количеством. Остатки этого товара в системе не изменяются)
             ]

      assert none.(a) == []

      a = one.([["Z-1", "Один", 1, "", "I", 2]])

      assert texts(a) == [
               ~s(строка 2: Z-1: в месте "" "I" "2" не указана зона. Остатки этого товара в системе не изменяются)
             ]

      assert none.(a) == []

      a = one.([["Z-1", "Один", 4]])

      assert texts(a) == [
               "строка 2: Z-1: остаток 4 без места. Остатки этого товара в системе не изменяются"
             ]

      assert none.(a) == []

      a = one.([["Z-1", "Один", 1, "Q", "Q", 9]])

      assert texts(a) == [
               "строка 2: Z-1: место QQ9 не найдено. Остатки этого товара в системе не изменяются"
             ]

      assert none.(a) == []

      a = one.([["NOPE", "x", 1, "R", "I", 2]])
      assert texts(a) == ["строка 2: NOPE: артикул не найден, строка пропущена"]
      assert a["changes"] == []

      a = one.([["LOT-1", "x", 1, "R", "I", 2]])

      assert texts(a) == [
               "строка 2: LOT-1: товар учитывается по партиям или серийным номерам. Остатки этого товара в системе не изменяются"
             ]

      assert a["changes"] == []

      a = one.([["Z-1", "Один", 10, "R", "I", 2], ["Z-1", "Другое", 3, "L", "A", 1]])

      assert Enum.any?(
               texts(a),
               &(&1 ==
                   ~s(строка 3: Z-1: артикул повторяется с другим названием "Другое". Остатки сложены))
             )

      assert a["changes"] == []
    end

    test "T-WI-5b R4 with a place ?, R7 for a second org unit", ctx do
      m = seed!(ctx.a.schema_name)
      one = fn rows -> check(ctx, m.unit, book(rows)) end

      r7 = Docs.unit!(ctx.a.schema_name)
      other = loc!(ctx.a.schema_name, "OT1")

      S.post!(ctx.a.schema_name, "receipt", %{
        lines: [S.line(m.z3.record_id, "2", %{to: S.side(r7, other)})]
      })

      a = one.([["Z-3", "Три", 1, "R", "I", 2]])

      assert texts(a) == [
               "строка 2: Z-3: остаток ведётся отдельно по подразделениям, ответственным, партиям или единицам. Остатки этого товара в системе не изменяются"
             ]

      assert a["changes"] == []

      _q = loc!(ctx.a.schema_name, "?")
      a = one.([["Z-2", "Два", 2]])

      assert [%{"place_code" => "?", "file_quantity" => "2", "book_quantity" => "0"} | _] =
               a["changes"]

      assert texts(a) == [~s(строка 2: Z-2: остаток 2 без места, записан в место "?")]
    end
  end

  # -- criterion 6 -------------------------------------------------------------------------------

  describe "header and caps" do
    test "T-WI-6 header, unreadable, caps", ctx do
      m = seed!(ctx.a.schema_name)

      titled = xlsx!([["Отчёт"], [], @header, ["Z-1", "Один", 7, "R", "I", 2]])
      titled_answer = check(ctx, m.unit, titled)
      assert titled_answer["rows_read"] == 1 and titled_answer["sheet"] == "Лист1"

      assert [%{"place_code" => "RI2", "row" => 4}] =
               titled_answer["changes"] |> Enum.filter(&(&1["place_code"] == "RI2"))

      path = "/stock-workbook/check?org_unit_id=#{m.unit}"

      assert reason!(post_check(path, ctx.tok_a, xlsx!([["a", "b"], ["Z-1", "x"]])), 422) ==
               "header_missing"

      assert reason!(post_check(path, ctx.tok_a, "not a workbook"), 422) == "xlsx_unreadable"

      rows = for i <- 1..4, do: ["Z-#{i}", "n", 1, "R", "I", 2]
      Application.put_env(:letflow, :stock_workbook_import_max_rows, 3)

      try do
        assert reason!(post_check(path, ctx.tok_a, book(rows)), 422) == "workbook_too_large"
        Application.put_env(:letflow, :stock_workbook_import_max_rows, 4)
        assert post_check(path, ctx.tok_a, book(rows)).status == 200
      after
        Application.delete_env(:letflow, :stock_workbook_import_max_rows)
      end

      many =
        book([
          ["Z-1", "Один", 1, "R", "I", 2],
          ["Z-1", "Один", 0, "L", "A", 1],
          ["Z-2", "Два", 1, "R", "I", 2]
        ])

      Application.put_env(:letflow, :stock_workbook_import_max_changes, 2)

      try do
        assert check(ctx, m.unit, many)["too_many_changes"] == true

        assert check(
                 ctx,
                 m.unit,
                 book([["Z-1", "Один", 1, "R", "I", 2], ["Z-1", "Один", 0, "L", "A", 1]])
               )["too_many_changes"] == false
      after
        Application.delete_env(:letflow, :stock_workbook_import_max_changes)
      end
    end
  end

  # -- criterion 7 -------------------------------------------------------------------------------

  describe "read only and tenancy" do
    test "T-WI-7 nothing is written; B reads only B's book", ctx do
      m = seed!(ctx.a.schema_name)
      mb = seed_b!(ctx.b.schema_name)
      bytes = book([["Z-1", "Один", 1, "R", "I", 2]])
      # the first request of a token creates its user (an audit entry of the login, not the check)
      _ = check(ctx, m.unit, bytes)
      before = counts(ctx.a.schema_name)
      _ = check(ctx, m.unit, bytes)
      assert counts(ctx.a.schema_name) == before

      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])
      answer = check(ctx, mb.unit, bytes, tok_b)
      assert [%{"book_quantity" => "4", "file_quantity" => "1"} | _] = answer["changes"]
    end

    test "T-WI-8 one parse: no :zip call, DOCTYPE refused" do
      src = File.read!("lib/letflow/modules/stock/stock_workbook_import.ex")
      refute src =~ ":zip"
      assert src =~ "XlsxImport.read_text_rows"

      good = book([["Z-1", "n", 1]])
      {:ok, files} = :zip.unzip(good, [:memory])

      patched =
        for {name, data} <- files do
          if to_string(name) =~ "sheet1.xml",
            do:
              {name,
               String.replace(data, "?>", "?><!DOCTYPE x [<!ENTITY a \"b\">]>", global: false)},
            else: {name, data}
        end

      {:ok, {_n, bad}} = :zip.create(~c"x.xlsx", patched, [:memory])
      assert WI.parse(bad) == {:error, :xlsx_unreadable}
    end
  end

  describe "byte bounds (INV-8)" do
    @tag timeout: 60_000
    test "T-WI-10 one huge shared string in many cells is refused fast, not normalised" do
      big = String.duplicate("ab ", 350_000)
      rows = for _ <- 1..20, do: [big, big, 1]
      bytes = book(rows)
      assert byte_size(bytes) < 100_000

      {micros, result} = :timer.tc(fn -> WI.parse(bytes) end)
      assert result == {:error, :workbook_too_large}
      assert micros < 2_000_000
    end

    test "T-WI-11 a cell over its byte cap refuses the file, one at the cap does not" do
      ok = String.duplicate("a", 256)
      assert {:ok, %{rows_read: 1}} = WI.parse(book([[ok, "n", 1]]))
      assert WI.parse(book([[ok <> "a", "n", 1]])) == {:error, :workbook_too_large}
      assert {:ok, %{rows_read: 1}} = WI.parse(book([["A-1", String.duplicate("n", 512), 1]]))

      assert WI.parse(book([["A-1", String.duplicate("n", 513), 1]])) ==
               {:error, :workbook_too_large}

      assert WI.parse(book([["A-1", "n", String.duplicate("1", 65)]])) ==
               {:error, :workbook_too_large}

      assert WI.parse(book([["A-1", "n", 1, String.duplicate("z", 257)]])) ==
               {:error, :workbook_too_large}

      # column G is not read, so its length is not a reason
      assert {:ok, %{rows_read: 1}} =
               WI.parse(book([["A-1", "n", 1, nil, nil, nil, String.duplicate("g", 5000)]]))
    end

    test "T-WI-12 a long cell above the header is skipped, never normalised" do
      big = String.duplicate("x y ", 100_000)
      bytes = xlsx!([[big], [big, big], @header, ["Z-1", "Один", 7]])
      assert {:ok, %{rows_read: 1, rows: [%{article: "Z-1"}]}} = WI.parse(bytes)
    end

    @tag timeout: 60_000
    test "T-WI-14 many huge-exponent numeric cells are not expanded to text" do
      # 31337 is a marker the patch below swaps for 1E6144 (a 27-byte cell that would render as a
      # 6 KB string); Decimal parses it, so the cost is in rendering, not in reading.
      rows = for _ <- 1..400, do: ["A-1", "n", 31_337, 31_337, 31_337]
      {:ok, files} = :zip.unzip(book(rows), [:memory])

      patched =
        for {name, data} <- files do
          if to_string(name) =~ "sheet1.xml",
            do: {name, String.replace(data, "<v>31337</v>", "<v>1E6144</v>")},
            else: {name, data}
        end

      {:ok, {_n, bomb}} = :zip.create(~c"x.xlsx", patched, [:memory])
      assert {:ok, files2} = :zip.unzip(bomb, [:memory])
      assert Enum.any?(files2, fn {_n, d} -> d =~ "1E6144" end)

      {micros, result} = :timer.tc(fn -> WI.parse(bomb) end)
      assert result == {:error, :workbook_too_large}
      assert micros < 500_000

      # read_text_rows alone returns a short placeholder, never the 6 KB digits
      assert {:ok, _name, [_header, {_line, cells} | _]} =
               Letflow.Entities.XlsxImport.read_text_rows(bomb)

      assert Enum.all?(cells, &(byte_size(&1) <= 1024))
    end

    test "T-WI-13 the row cap is checked on cheap counts before any row is read" do
      Application.put_env(:letflow, :stock_workbook_import_max_rows, 2)

      try do
        rows = for i <- 1..3, do: ["Z-#{i}", "n", 1]
        assert WI.parse(book(rows)) == {:error, :workbook_too_large}
      after
        Application.delete_env(:letflow, :stock_workbook_import_max_rows)
      end
    end
  end

  describe "reference padding (INV-8)" do
    # The reader fills in the rows and cells a sheet omits from the `r` references, so a few bytes
    # of XML can name millions of cells. Each forged book is parsed in a process capped at 64 MiB
    # of heap (killed past it); the answer must be a bounded refusal from a live process.
    test "T-WI-15 a far row after a wide row is refused within 64 MiB" do
      bytes = padded!(~s(<row r="1001"><c r="XFD1001"/></row>))
      assert {:ok, {micros, {:error, :workbook_too_large}}} = capped(fn -> WI.parse(bytes) end)
      assert micros < 500_000
    end

    test "T-WI-16 many far-column cells are refused within 64 MiB; the route says 422", ctx do
      bytes = padded!(Enum.map_join(2..1001, &~s(<row r="#{&1}"><c r="XFD#{&1}"/></row>)))
      assert {:ok, {micros, {:error, :workbook_too_large}}} = capped(fn -> WI.parse(bytes) end)
      assert micros < 500_000

      unit = Docs.unit!(ctx.a.schema_name)
      path = "/stock-workbook/check?org_unit_id=#{unit}"
      assert reason!(post_check(path, ctx.tok_a, bytes), 422) == "workbook_too_large"
    end

    test "T-WI-17 a lower row number starts a new gap; columns past H are not read" do
      far = ~s(<row r="15000"><c r="A15000" t="inlineStr"><is><t>a</t></is></c></row>)
      back = ~s(<row r="2"><c r="A2" t="inlineStr"><is><t>a</t></is></c></row>)
      # one gap of 15 000 rows is under the 20 000-row sheet budget; two such gaps are not
      assert {:ok, %{rows_read: 0}} = WI.parse(padded!(far))
      assert WI.parse(padded!(far <> back <> far)) == {:error, :workbook_too_large}

      # a real row with a cell far to the right is read, and only A..H become text
      wide =
        ~s(<row r="2"><c r="A2" t="inlineStr"><is><t>Z-1</t></is></c>) <>
          ~s(<c r="B2" t="inlineStr"><is><t>n</t></is></c><c r="C2"><v>1</v></c>) <>
          ~s(<c r="XFD2" t="inlineStr"><is><t>far</t></is></c></row>)

      assert {:ok, %{rows_read: 1, rows: [%{article: "Z-1"}]}} = WI.parse(padded!(wide))

      assert {:ok, _sheet, [_header, {2, cells}]} =
               Letflow.Entities.XlsxImport.read_text_rows(padded!(wide), max_columns: 8)

      assert length(cells) == 8
    end

    test "T-WI-18 a BOM in front of the sheet does not hide far references; the route says 422",
         ctx do
      bom = <<0xEF, 0xBB, 0xBF>>
      wide_far = padded!(~s(<row r="1001"><c r="XFD1001"/></row>), bom)
      many_far = padded!(Enum.map_join(2..1001, &~s(<row r="#{&1}"><c r="XFD#{&1}"/></row>)), bom)
      one_far = padded!(~s(<row r="2"><c r="ZZZZZ2"/></row>), bom)

      for bytes <- [wide_far, many_far, one_far] do
        assert {:ok, {micros, {:error, :workbook_too_large}}} = capped(fn -> WI.parse(bytes) end)
        assert micros < 500_000
      end

      # a second BOM, which the reader would strip again, is refused as unreadable
      assert WI.parse(padded!(~s(<row r="2"><c r="ZZZZZ2"/></row>), bom <> bom)) ==
               {:error, :xlsx_unreadable}

      unit = Docs.unit!(ctx.a.schema_name)
      path = "/stock-workbook/check?org_unit_id=#{unit}"
      assert reason!(post_check(path, ctx.tok_a, one_far), 422) == "workbook_too_large"

      # a legitimate book with a BOM is still read
      row =
        ~s(<row r="2"><c r="A2" t="inlineStr"><is><t>Z-1</t></is></c>) <>
          ~s(<c r="B2" t="inlineStr"><is><t>n</t></is></c><c r="C2"><v>1</v></c></row>)

      assert {:ok, %{rows_read: 1, rows: [%{article: "Z-1"}]}} = WI.parse(padded!(row, bom))
    end

    test "T-WI-19 cells outside a row or under a nested row count too; the route says 422",
         ctx do
      outside = padded!(String.duplicate(~s(<row></row><c r="XFD1"/>), 19_000))
      wide = padded!(String.duplicate(~s(<row></row><c r="ABJDH1"/>), 100))

      nested =
        padded!(
          ~s(<row r="2">) <> String.duplicate(~s(<c r="XFD2"/><row></row>), 19_000) <> "</row>"
        )

      for bytes <- [outside, wide, nested] do
        assert {:ok, {micros, {:error, :workbook_too_large}}} = capped(fn -> WI.parse(bytes) end)
        assert micros < 500_000
      end

      unit = Docs.unit!(ctx.a.schema_name)
      path = "/stock-workbook/check?org_unit_id=#{unit}"
      assert reason!(post_check(path, ctx.tok_a, outside), 422) == "workbook_too_large"
    end

    test "T-WI-20 huge index texts are refused before they become integers; the route says 422",
         ctx do
      # before the 10-byte caps these took seconds and hundreds of MiB, or were killed past 4 GiB
      si = "1" <> String.duplicate("0", 300_000)
      digits = String.duplicate("9", 1_200_000)

      formula = padded!(~s(<f t="shared" ref="A1" si="#{si}">x</f>))
      formulas = padded!(Enum.map_join(1..3, &~s(<f t="shared" ref="A1" si="#{&1}#{si}">x</f>)))
      letters = padded!(~s(<row r="2"><c r="#{String.duplicate("Z", 60_000)}2"/></row>))
      row_digits = padded!(~s(<row r="2"><c r="A1#{String.duplicate("0", 60_000)}"/></row>))

      index =
        padded!(
          ~s(<row r="2">) <> String.duplicate(~s(<c t="s"><v>#{digits}</v></c>), 20) <> "</row>"
        )

      style =
        padded!(
          ~s(<row r="2">) <> String.duplicate(~s(<c s="#{digits}"><v>1</v></c>), 20) <> "</row>"
        )

      for bytes <- [formula, formulas, letters, row_digits, index, style] do
        assert {:ok, {micros, {:error, :workbook_too_large}}} = capped(fn -> WI.parse(bytes) end)
        assert micros < 500_000
      end

      unit = Docs.unit!(ctx.a.schema_name)
      path = "/stock-workbook/check?org_unit_id=#{unit}"
      assert reason!(post_check(path, ctx.tok_a, formula), 422) == "workbook_too_large"

      # a real shared formula with a shared-string index and a style is still read
      row =
        ~s(<row r="2"><c r="A2" t="inlineStr"><is><t>Z-1</t></is></c>) <>
          ~s(<c r="B2" t="inlineStr"><is><t>n</t></is></c>) <>
          ~s(<c r="C2" s="0"><f t="shared" ref="C2:C3" si="0">1</f><v>1</v></c></row>)

      assert {:ok, %{rows_read: 1, rows: [%{article: "Z-1"}]}} = WI.parse(padded!(row))
    end
  end

  describe "docs" do
    test "T-WI-9 runbook and moduledoc name the route and the remarks" do
      runbook = File.read!("docs/runbooks/stock-workbook-import.md")
      assert runbook =~ "POST /api/v1/modules/stock/stock-workbook/check"
      for id <- ~w(R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11), do: assert(runbook =~ "| #{id} |")
      assert Letflow.Modules.Stock.__info__(:attributes) |> is_list()
      assert File.read!("lib/letflow/modules/stock/stock.ex") =~ "POST /stock-workbook/check"
    end
  end

  # A book whose first sheet is the header row (A1 = Артикул) followed by `rows_xml`, verbatim.
  defp padded!(rows_xml, prefix \\ "") do
    xml =
      prefix <>
        ~s(<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns=) <>
        ~s("http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>) <>
        ~s(<row r="1"><c r="A1" t="inlineStr"><is><t>Артикул</t></is></c></row>) <>
        rows_xml <> "</sheetData></worksheet>"

    Letflow.XlsxFixture.build([[["x"]]], replace: %{"xl/worksheets/sheet1.xml" => xml})
  end

  # Runs `fun` in a process killed past 64 MiB of heap: `{:ok, {micros, result}}` or `{:died, why}`.
  defp capped(fun) do
    parent = self()
    words = div(64 * 1024 * 1024, :erlang.system_info(:wordsize))

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
        send(parent, {:capped, self(), :timer.tc(fun)})
      end)

    receive do
      {:capped, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, why} ->
        {:died, why}
    end
  end

  defp seed_b!(schema) do
    unit = Docs.unit!(schema)
    uom = Cat.uom!(schema, "pcs")
    ri2 = loc!(schema, "RI2")
    z1 = Cat.item!(schema, "Z-1", uom.record_id)
    S.post!(schema, "receipt", %{lines: [S.line(z1.record_id, "4", %{to: S.side(unit, ri2)})]})
    %{unit: unit}
  end

  defp counts(schema) do
    for table <- ~w(ledger_entry ledger_leg audit_entries entity_record_latest), into: %{} do
      {table, Letflow.Repo.aggregate(table, :count, prefix: schema)}
    end
  end
end
