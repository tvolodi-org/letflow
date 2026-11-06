Code.require_file("register_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.XlsxExportTest do
  @moduledoc """
  REQ-763 / GH #3898 criteria 3 to 5 (C18-BAL-*): `format=xlsx` on `GET /balances` of module assets and
  the pure renderer `Letflow.Modules.Assets.XlsxExport`. Real OIDC bearer tokens through the full
  `Letflow.Router`, committed tenants, Sandbox `:auto`, `async: false`.

  C18 adds no write path (D-098): postings are made through the register fixture (the module's real
  policy and registration) and every read goes through the real router and database types.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Assets.XlsxExport
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @a1 "11111111-1111-4111-8111-111111111111"
  @a2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @p "47474747-4747-4747-8747-474747474747"
  @l1 "33333333-3333-4333-8333-333333333333"
  @r1 "55555555-5555-4555-8555-555555555555"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("axl-a", ctx.names.a)
    b = S.tenant!("axl-b", ctx.names.b)
    Map.merge(ctx, %{a: a, b: b, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp seed!(schema) do
    S.post!(schema, "commission", %{
      document_type: "commission_doc",
      document_id: "doc-1",
      lines: [S.line(@a1, "3", %{to: S.side(@u1, @r1, %{location: @l1})})]
    })

    S.post!(schema, "commission", %{
      document_id: "doc-2",
      lines: [S.line(@a2, "2", %{to: S.side(@u2, @r1)})]
    })
  end

  defp ok!(conn), do: assert_status(conn, 200) |> S.json()

  defp assert_status(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    conn
  end

  defp sheets(binary) do
    {:ok, pkg} = XlsxReader.open(binary, source: :binary)

    Map.new(XlsxReader.sheet_names(pkg), fn name ->
      {:ok, rows} = XlsxReader.sheet(pkg, name)
      {name, rows}
    end)
  end

  defp report(sheets),
    do:
      Map.new(sheets["report"], fn
        [k, v | _] -> {k, v}
        [k] -> {k, nil}
      end)

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_integer(value), do: Integer.to_string(value)

  defp cell(value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  defp same_number?(cell, text), do: Decimal.equal?(Decimal.new(cell(cell)), Decimal.new(text))

  defp ledger_statements(fun) do
    {result, statements} = Fx.record(fun)
    {result, Enum.filter(statements, fn {sql, _} -> sql =~ "ledger_" end)}
  end

  defp xml(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Enum.map_join(files, "\n", fn {_name, content} -> content end)
  end

  defp file_rows(binary) do
    [_header | rows] = sheets(binary)["balances"]

    Enum.map(rows, fn row ->
      row |> Enum.take(5) |> Enum.map(&cell/1) |> List.to_tuple()
    end)
  end

  defp json_rows(json),
    do:
      Enum.map(json["rows"], fn j ->
        {j["asset"], j["org_unit"], j["location"] || "", j["material_responsible"],
         j["actual_user"] || ""}
      end)

  describe "format key" do
    test "C18-BAL-1 json and absent are identical; a bad value is 422 with no ledger query",
         ctx do
      seed!(ctx.a.schema_name)
      plain = S.get("/balances", ctx.tok_a) |> ok!() |> Map.delete("trace_id")

      assert S.get("/balances?format=json", ctx.tok_a) |> ok!() |> Map.delete("trace_id") == plain

      for path <- [
            "/balances?format=pdf",
            "/balances?format=",
            "/balances?format=XLSX",
            "/movements?format=xlsx",
            "/reconcile?format=xlsx"
          ] do
        {conn, statements} = ledger_statements(fn -> S.get(path, ctx.tok_a) end)
        assert conn.status == 422, "#{path}: #{conn.resp_body}"
        assert S.json(conn)["reason"] == "invalid_filter"
        assert statements == [], path
      end
    end
  end

  describe "files" do
    test "C18-BAL-2 headers, balances sheet and report sheet equal the JSON answer", ctx do
      seed!(ctx.a.schema_name)
      json = S.get("/balances", ctx.tok_a) |> ok!()
      conn = assert_status(S.get("/balances?format=xlsx", ctx.tok_a), 200)

      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ @xlsx

      assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="asset-balances.xlsx")]

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

      sheets = sheets(conn.resp_body)
      [header | rows] = sheets["balances"]

      assert header ==
               ~w(asset org_unit location material_responsible actual_user unit_ref quantity last_posting_seq)

      assert length(rows) == 2 and length(json["rows"]) == 2
      assert file_rows(conn.resp_body) == json_rows(json)

      for {row, j} <- Enum.zip(rows, json["rows"]) do
        assert Enum.at(row, 5) == j["unit_ref"]
        assert same_number?(Enum.at(row, 6), j["quantity"])
        assert Enum.at(row, 7) == j["last_posting_seq"]
      end

      report = report(sheets)
      assert report["basis"] == json["basis"]
      assert report["cutoff_seq"] == json["cutoff_seq"]
      assert report["timezone"] == json["timezone"]
      assert Jason.decode!(report["filters"]) == json["filters"]
      assert report["ledger_seq"] == json["ledger_seq"]
      assert cell(report["next_cursor"]) == (json["next_cursor"] || "")
      refute Map.has_key?(report, "coverage")

      sub = S.get("/balances?format=xlsx&scope_subtree=#{@p}", ctx.tok_a)
      assert report(sheets(sub.resp_body))["coverage"] == "complete"
    end

    test "C18-BAL-2b an empty register gives a header-only sheet and the report", ctx do
      conn = assert_status(S.get("/balances?format=xlsx", ctx.tok_a), 200)
      sheets = sheets(conn.resp_body)
      assert length(sheets["balances"]) == 1
      assert report(sheets)["basis"] == "posting_seq"
    end

    test "C18-BAL-2c as_of_date adds the as_of_date row", ctx do
      seed!(ctx.a.schema_name)
      day = Date.utc_today() |> Date.to_iso8601()
      conn = assert_status(S.get("/balances?format=xlsx&as_of_date=#{day}", ctx.tok_a), 200)
      assert report(sheets(conn.resp_body))["as_of_date"] == day
    end

    @tag timeout: 120_000
    test "C18-BAL-3 a 200-row page, a smaller limit and next_cursor visiting every key once",
         ctx do
      schema = ctx.a.schema_name

      for doc <- 1..2 do
        lines = for _ <- 1..100, do: S.line(S.uuid(), "1", %{to: S.side(@u1, @r1)})
        S.post!(schema, "commission", %{document_id: "bulk-#{doc}", lines: lines})
      end

      full = S.get("/balances?format=xlsx&limit=200", ctx.tok_a)
      assert length(file_rows(full.resp_body)) == 200

      small = S.get("/balances?format=xlsx&limit=50", ctx.tok_a)
      assert length(file_rows(small.resp_body)) == 50
      cursor = report(sheets(small.resp_body))["next_cursor"]
      assert is_binary(cursor) and cursor != ""

      visit = fn visit, cursor, acc ->
        path = "/balances?format=xlsx&limit=50" <> if(cursor, do: "&cursor=#{cursor}", else: "")
        conn = assert_status(S.get(path, ctx.tok_a), 200)
        acc = acc ++ Enum.map(file_rows(conn.resp_body), &elem(&1, 0))

        case report(sheets(conn.resp_body))["next_cursor"] do
          next when is_binary(next) and next != "" -> visit.(visit, next, acc)
          _ -> acc
        end
      end

      assets = visit.(visit, nil, [])
      assert length(assets) == 200 and length(Enum.uniq(assets)) == 200
    end
  end

  describe "renderer" do
    defp body(rows),
      do: %{
        basis: "posting_seq",
        cutoff_seq: 1,
        as_of: nil,
        timezone: "Asia/Almaty",
        filters: %{},
        ledger_seq: 1,
        next_cursor: nil,
        coverage: nil,
        rows: rows
      }

    defp row(extra),
      do:
        Map.merge(
          %{
            asset: "a",
            org_unit: "u",
            location: nil,
            material_responsible: "r",
            actual_user: nil,
            unit_ref: "pcs",
            quantity: "1",
            last_posting_seq: 1
          },
          extra
        )

    test "C18-BAL-4 text starting with a formula sign is a string cell, a quantity a number" do
      rows = for t <- ["=1+1", "+x", "-x", "@x"], do: row(%{asset: t})
      assert {:ok, bin} = XlsxExport.balances(body(rows))
      refute xml(bin) =~ "<f>"
      assert Enum.map(file_rows(bin), &elem(&1, 0)) == ["=1+1", "+x", "-x", "@x"]

      assert {:ok, bin} =
               XlsxExport.balances(
                 body([row(%{quantity: "2.5"}), row(%{quantity: "12345678901234567890"})])
               )

      [_h, [_, _, _, _, _, _, q1, _], [_, _, _, _, _, _, q2, _]] = sheets(bin)["balances"]
      assert q1 == 2.5
      assert q2 == "12345678901234567890"

      [header | _] = sheets(bin)["balances"]

      for word <- ~w(price value money amount actor hash payload),
          do: refute(Enum.any?(header, &(&1 =~ word)))
    end

    test "C18-BAL-9 a body the writer cannot encode is {:error, :xlsx_write_failed}" do
      assert {:error, :xlsx_write_failed} =
               XlsxExport.balances(%{body([row(%{})]) | filters: %{a: {1, 2}}})
    end

    test "C18-BAL-8 the module names no Repo, Ecto.Query or Stock" do
      src =
        File.read!(Path.expand("../../../../lib/letflow/modules/assets/xlsx_export.ex", __DIR__))

      refute src =~ ~r/\bRepo\b|Ecto\.Query|Letflow\.Modules\.Stock\./
    end
  end

  describe "refusals, scope and tenancy" do
    test "C18-BAL-5 a caller who may not read gets the JSON refusal with format=xlsx", ctx do
      seed!(ctx.a.schema_name)
      tok = S.token(ctx, :a, ["TASK_WORKER"])

      for path <- ["/balances", "/balances?format=xlsx"] do
        {conn, statements} = ledger_statements(fn -> S.get(path, tok) end)
        assert conn.status == 403, path
        assert S.json(conn)["detail"] == "insufficient permissions"
        assert statements == []
      end
    end

    test "C18-BAL-6 a reader granted on U1 gets the U1 rows only in the file", ctx do
      s = S.tenant!("axl-s", ctx.names.s)
      schema = s.schema_name
      seed!(schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "reader-u1")
      ok!(S.get("/balances", tok))
      _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "TENANT_ADMIN"), "TENANT_ADMIN")
      user = Letflow.Repo.one!(from(u in User, where: u.username == "reader-u1"), prefix: schema)
      :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", @u1)

      json = S.get("/balances", tok) |> ok!()
      file = S.get("/balances?format=xlsx", tok) |> assert_status(200)
      assert file_rows(file.resp_body) == json_rows(json)
      assert file_rows(file.resp_body) != []
      assert file_rows(file.resp_body) |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [@u1]
    end

    test "C18-BAL-7 B's admin file holds B's rows only, also filtering on A's ids", ctx do
      seed!(ctx.a.schema_name)

      S.post!(ctx.b.schema_name, "commission", %{
        document_id: "b-1",
        lines: [S.line(S.uuid(), "1", %{to: S.side(S.uuid(), @r1)})]
      })

      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])
      file = S.get("/balances?format=xlsx", tok_b) |> assert_status(200)
      rows = file_rows(file.resp_body)
      assert length(rows) == 1
      refute Enum.any?(rows, &(elem(&1, 0) in [@a1, @a2] or elem(&1, 1) in [@u1, @u2]))

      for q <- ["asset=#{@a1}", "org_unit=#{@u1}"] do
        f = S.get("/balances?format=xlsx&#{q}", tok_b) |> assert_status(200)
        assert file_rows(f.resp_body) == [], q
      end
    end
  end
end
