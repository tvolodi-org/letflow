Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.XlsxExportTest do
  @moduledoc """
  REQ-728 / GH #3772: `format=xlsx` on the stock `balances` and `movements` routes (X-1..X-6) and the pure
  renderer `Letflow.Modules.Stock.XlsxExport`. The scoped-reader file test (X-5d) is not written here: the
  router guard `tenant_wide?/1` is lifted by P25 (REQ-682); masked legs are covered by the pure test X-4b.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Stock.XlsxExport
  alias Letflow.StockFixture, as: S

  @sku1 "11111111-1111-4111-8111-111111111111"
  @sku2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @l1 "33333333-3333-4333-8333-333333333333"
  @l2 "35353535-3535-4535-8535-353535353535"

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("stx-a", ctx.names.a)
    b = S.tenant!("stx-b", ctx.names.b)
    Map.merge(ctx, %{a: a, b: b, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp seed!(schema) do
    here = S.side(@u1, @l1)

    S.post!(schema, "receipt", %{
      document_type: "receipt_doc",
      document_id: "=cmd|doc-1",
      lines: [S.line(@sku1, "10", %{to: here})]
    })

    S.post!(schema, "receipt", %{lines: [S.line(@sku2, "4", %{to: here})]})

    S.post!(schema, "transfer", %{
      document_id: "doc-3",
      lines: [S.line(@sku1, "10", %{from: here, to: S.side(@u1, @l2)})]
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

  defp xml(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Enum.map_join(files, "\n", fn {_name, content} -> content end)
  end

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_integer(value), do: Integer.to_string(value)

  defp cell(value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  defp same_number?(cell, text), do: Decimal.equal?(Decimal.new(cell(cell)), Decimal.new(text))

  describe "format key" do
    test "X-1 json and absent are unchanged; a bad value is 422 with no ledger query", ctx do
      seed!(ctx.a.schema_name)

      for path <- ["/balances", "/movements"] do
        plain = path |> S.get(ctx.tok_a) |> ok!() |> Map.delete("trace_id")

        assert (path <> "?format=json") |> S.get(ctx.tok_a) |> ok!() |> Map.delete("trace_id") ==
                 plain

        # coverage is null without a subtree filter (main), and the file omits that row
        assert Map.get(plain, "coverage") == nil

        for bad <- ["csv", "", "XLSX", "xlsx%20", "[]=xlsx"] do
          {conn, statements} =
            Fx.record(fn -> S.get(path <> "?format" <> bad_query(bad), ctx.tok_a) end)

          assert conn.status == 422, "#{path} #{bad}: #{conn.resp_body}"
          assert S.json(conn)["reason"] == "invalid_filter"
          assert Enum.filter(statements, fn {sql, _} -> sql =~ "ledger_" end) == []
        end
      end
    end

    defp bad_query("[]=xlsx"), do: "[]=xlsx"
    defp bad_query(value), do: "=" <> value
  end

  describe "files" do
    test "X-2 balances file holds the rows of the JSON answer and the time basis", ctx do
      seed!(ctx.a.schema_name)
      json = ok!(S.get("/balances", ctx.tok_a))
      conn = assert_status(S.get("/balances?format=xlsx", ctx.tok_a), 200)

      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="stock-balances.xlsx")]

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

      sheets = sheets(conn.resp_body)
      [header | rows] = sheets["balances"]

      assert header ==
               ~w(sku location org_unit responsible lot unit_ref quantity last_posting_seq)

      assert length(rows) == length(json["rows"]) and rows != []

      for {row, j} <- Enum.zip(rows, json["rows"]) do
        assert Enum.take(row, 4) |> Enum.map(&cell/1) ==
                 Enum.map(~w(sku location org_unit responsible), &(j[&1] || ""))

        assert cell(Enum.at(row, 4)) == (j["lot"] || "")
        assert Enum.at(row, 5) == j["unit_ref"]
        assert same_number?(Enum.at(row, 6), j["quantity"])
        assert Enum.at(row, 7) == j["last_posting_seq"]
      end

      report = report(sheets)
      assert report["basis"] == json["basis"]
      assert report["cutoff_seq"] == json["cutoff_seq"]
      assert report["timezone"] == json["timezone"]
      assert Jason.decode!(report["filters"]) == json["filters"]
      assert cell(report["next_cursor"]) == (json["next_cursor"] || "")
      assert report["note"] =~ "0079 D1"
    end

    test "X-3 movements file has one row per leg in order and the report rows", ctx do
      seed!(ctx.a.schema_name)
      json = ok!(S.get("/movements", ctx.tok_a))
      conn = assert_status(S.get("/movements?format=xlsx&to_seq=2", ctx.tok_a), 200)

      assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="stock-movements.xlsx")]

      sheets = sheets(conn.resp_body)
      [header | rows] = sheets["movements"]
      assert hd(header) == "entry_id" and List.last(header) == "masked"
      json2 = ok!(S.get("/movements?to_seq=2", ctx.tok_a))
      expected = for e <- json2["rows"], l <- e["legs"], do: {e["entry_id"], l["leg_no"]}
      assert Enum.map(rows, &{Enum.at(&1, 0), Enum.at(&1, 11)}) == expected
      assert length(json["rows"]) == 3
      assert Enum.all?(rows, &(List.last(&1) == false))

      report = report(sheets)
      assert report["cutoff_seq"] == 2
      assert cell(report["as_of"]) == "" and cell(report["ledger_seq"]) == ""
      assert report["timezone"] == "Asia/Almaty"
      assert Jason.decode!(report["filters"]) == %{"to_seq" => 2}
    end

    test "X-5c following next_cursor through xlsx pages visits every balance key once", ctx do
      seed!(ctx.a.schema_name)
      all = ok!(S.get("/balances", ctx.tok_a))["rows"] |> Enum.map(&{&1["sku"], &1["location"]})
      assert length(all) == 3
      assert collect(ctx, "/balances?format=xlsx&limit=1", []) |> Enum.sort() == Enum.sort(all)
    end

    defp collect(ctx, path, acc) do
      sheets =
        path |> S.get(ctx.tok_a) |> assert_status(200) |> Map.fetch!(:resp_body) |> sheets()

      keys = for [sku, location | _] <- tl(sheets["balances"]), do: {sku, location}

      case cell(report(sheets)["next_cursor"]) do
        "" ->
          acc ++ keys

        cursor ->
          collect(
            ctx,
            "/balances?format=xlsx&limit=1&cursor=" <> URI.encode_www_form(cursor),
            acc ++ keys
          )
      end
    end

    test "X-4c headers carry no price, value, actor or payload column", ctx do
      seed!(ctx.a.schema_name)

      for path <- ["/balances", "/movements"] do
        sheets = sheets(assert_status(S.get(path <> "?format=xlsx", ctx.tok_a), 200).resp_body)
        header = sheets |> Map.drop(["report"]) |> Map.values() |> hd() |> hd()

        for forbidden <- ~w(price value actor subject client_op_id payload_hash) do
          refute forbidden in header
        end
      end
    end
  end

  describe "tenants and roles" do
    test "X-5a refusals are the JSON ones with format=xlsx", ctx do
      seed!(ctx.a.schema_name)
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

      for path <- ["/balances", "/movements"] do
        assert S.get(path <> "?format=xlsx", worker).status == 403
        assert S.get(path <> "?format=xlsx&x=1", ctx.tok_a).status == 422
        assert S.get(path <> "?format=xlsx", "not-a-token").status in [401, 404]
      end
    end

    test "X-5b tenant B exports no row of tenant A", ctx do
      seed!(ctx.a.schema_name)
      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])

      sheets = sheets(assert_status(S.get("/balances?format=xlsx", tok_b), 200).resp_body)
      assert length(sheets["balances"]) == 1

      sheets =
        sheets(
          assert_status(S.get("/movements?format=xlsx&document_id=doc-3", tok_b), 200).resp_body
        )

      assert length(sheets["movements"]) == 1
      assert S.get("/balances?format=xlsx&sku=#{@sku1}", tok_b) |> Map.fetch!(:status) == 200
    end
  end

  describe "renderer" do
    test "X-4a formula-looking values are string cells and no formula is written" do
      entry = %{
        entry_id: "e1",
        posting_seq: 1,
        cause: "=1+1",
        document_id: "@SUM(A1)",
        correlation_id: "-1",
        reason_code: "+1",
        legs: [%{leg_no: 1, sku: "=x", quantity: "10", unit_ref: "pcs", document_line_id: "@l"}]
      }

      {:ok, movements} = XlsxExport.movements(%{rows: [entry], next_cursor: nil}, %{})
      {:ok, balances} = XlsxExport.balances(%{rows: [%{sku: "=x", quantity: "1"}], filters: %{}})

      for binary <- [movements, balances] do
        refute Regex.match?(~r/<f[ >\/]/, xml(binary))
      end

      [_header, row] = sheets(movements)["movements"]
      assert "=1+1" in row and "@SUM(A1)" in row and "-1" in row and "+1" in row
    end

    test "X-4b quantity cells and masked legs" do
      body = %{
        rows: [
          %{sku: "s", quantity: "10", last_posting_seq: 1},
          %{sku: "s", quantity: "123456789012345678901234567890.5", last_posting_seq: 2},
          %{sku: "s", quantity: "-2.5", last_posting_seq: 3}
        ],
        filters: %{},
        coverage: :complete
      }

      {:ok, binary} = XlsxExport.balances(body)
      sheets = sheets(binary)

      assert [
               _,
               [_, _, _, _, _, _, 10.0, 1.0],
               [_, _, _, _, _, _, big, 2.0],
               [_, _, _, _, _, _, -2.5, 3.0]
             ] = sheets["balances"]

      assert big == "123456789012345678901234567890.5"
      assert report(sheets)["coverage"] == "complete"

      entry = %{
        entry_id: "e1",
        posting_seq: 1,
        legs: [%{leg_no: 1, quantity: "3", unit_ref: "pcs", masked: true}]
      }

      {:ok, binary} = XlsxExport.movements(%{rows: [entry], next_cursor: nil}, %{"to_seq" => 5})
      [_, row] = sheets(binary)["movements"]
      assert List.last(row) == true
      assert Enum.slice(row, 12, 5) |> Enum.map(&cell/1) == ["", "", "", "", ""]
      assert cell(Enum.at(row, 19)) == ""
      assert report(sheets(binary))["cutoff_seq"] == 5
    end

    test "X-6b the module names no Repo or Ecto.Query" do
      source = File.read!("lib/letflow/modules/stock/xlsx_export.ex")
      refute source =~ "Repo"
      refute source =~ "Ecto.Query"
    end
  end
end
