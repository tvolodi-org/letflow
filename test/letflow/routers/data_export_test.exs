Code.require_file("../modules/assets/register_fixture.exs", __DIR__)
Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Routers.DataExportTest do
  use Letflow.DataCase, async: false
  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  alias Letflow.AssetsRegisterFixture, as: A
  alias Letflow.StockFixture, as: S
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.{Audit, DataExport, Ledger, Repo, ScopeNodePaths}
  alias Letflow.Audit.Entry
  alias Letflow.Identity.User
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @unit "44444444-4444-4444-8444-444444444444"
  @other "46464646-4646-4646-8646-464646464646"
  @location "33333333-3333-4333-8333-333333333333"

  setup do
    ctx = S.setup_oidc!([:a, :b])
    Map.put(ctx, :tenant, S.tenant!("dx", ctx.names.a))
  end

  defp call(method, path, token, body \\ nil) do
    Plug.Test.conn(
      method,
      "/api/v1/data-export" <> path,
      if(body, do: Jason.encode!(body), else: nil)
    )
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp token(ctx, sub \\ "exporter"), do: S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub)

  defp request(id \\ "stock_balances", format \\ "json", filters \\ %{}),
    do: %{
      "ids" => "machine",
      "datasets" => [%{"id" => id, "format" => format, "filters" => filters}]
    }

  defp export(ctx, body), do: call(:post, "", token(ctx), body)

  defp json(conn) do
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp reason(conn, status, expected) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["reason"] == expected
  end

  defp post(schema, sku, unit \\ @unit) do
    S.post!(schema, "receipt", %{lines: [S.line(sku, "10", %{to: S.side(unit, @location)})]})
  end

  defp rows(conn), do: json(conn)["rows"]

  defp audit_rows(prefix),
    do: Repo.all(from(e in Entry, where: e.action == "data_export.downloaded"), prefix: prefix)

  @tag timeout: 120_000
  test "DX-1 DX-2 offered datasets follow installation and both routes refuse non-exporters",
       ctx do
    admin = token(ctx)

    assert Enum.map(json(call(:get, "/datasets", admin))["datasets"], & &1["id"]) ==
             ~w(stock_balances stock_movements)

    {:ok, _} =
      Letflow.Modules.Installs.install("assets", Ecto.UUID.generate(),
        prefix: ctx.tenant.schema_name,
        rationale: "test: data export"
      )

    assert Enum.map(json(call(:get, "/datasets", admin))["datasets"], & &1["id"]) ==
             ~w(stock_balances stock_movements asset_balances)

    for role <- ["STOREKEEPER", "TENANT_AUDITOR"] do
      tok = S.token(ctx, :a, [role], sub: role)

      for conn <- [call(:get, "/datasets", tok), call(:post, "", tok, request())] do
        assert conn.status == 403
        assert get_resp_header(conn, "content-type") |> hd() =~ "application/problem+json"
        assert get_resp_header(conn, "content-disposition") == []
      end
    end
  end

  @tag timeout: 120_000
  test "DX-3 tenant B reads only B and a supplied tenant id is refused", ctx do
    b = S.tenant!("dx-b", ctx.names.b)
    sku_a = S.uuid()
    sku_b = S.uuid()
    post(ctx.tenant.schema_name, sku_a)
    post(b.schema_name, sku_b)
    tok = S.token(ctx, :b, ["TENANT_ADMIN"])
    conn = call(:post, "", tok, request("stock_balances", "csv"))
    assert conn.status == 200
    assert conn.resp_body =~ sku_b
    refute conn.resp_body =~ sku_a

    reason(
      call(:post, "", tok, Map.put(request(), "tenant_id", ctx.tenant.tenant_id)),
      422,
      "invalid_body"
    )
  end

  @tag timeout: 120_000
  test "DX-4 machine files match module reads, filters and asset literal unit", ctx do
    schema = ctx.tenant.schema_name

    {:ok, _} =
      Letflow.Modules.Installs.install("assets", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "test: data export"
      )

    skus = [S.uuid(), S.uuid()]
    Enum.each(skus, &post(schema, &1))
    asset = A.uuid()
    A.post!(schema, "commission", %{lines: [A.line(asset, "1", %{to: A.side(@unit, A.uuid())})]})
    data = S.get("/balances?limit=200", token(ctx)) |> json()
    conn = export(ctx, request("stock_balances", "xlsx"))
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    {:ok, pkg} = XlsxReader.open(conn.resp_body, source: :binary)
    {:ok, [header | sheet]} = XlsxReader.sheet(pkg, "data")
    assert header == ~w(sku location org_unit responsible lot unit_ref quantity last_posting_seq)
    assert Enum.sort(Enum.map(sheet, &hd/1)) == Enum.sort(Enum.map(data["rows"], & &1["sku"]))

    for row <- sheet do
      expected = Enum.find(data["rows"], &(&1["sku"] == hd(row)))

      for {key, index} <- Enum.with_index(header) do
        value = Enum.at(row, index)

        cond do
          key == "quantity" ->
            assert Decimal.equal?(Decimal.from_float(value), Decimal.new(expected[key]))

          is_nil(expected[key]) ->
            assert value in [nil, ""]

          true ->
            assert value == expected[key]
        end
      end
    end

    moves = export(ctx, request("stock_movements", "csv"))
    assert moves.status == 200
    [header | lines] = String.split(moves.resp_body, "\r\n", trim: true)

    assert header ==
             "entry_id,posting_seq,posting_time,event_time,cause,reverses_entry_id,reason_code,document_type,document_id,document_number,related_document_id,correlation_id,leg_no,sku,location,org_unit,responsible,lot,quantity,unit_ref,document_line_id,masked"

    assert length(lines) == 2
    conn = export(ctx, request("asset_balances", "xlsx"))
    assert conn.status == 200
    {:ok, pkg} = XlsxReader.open(conn.resp_body, source: :binary)
    {:ok, [header, row]} = XlsxReader.sheet(pkg, "data")

    assert header ==
             ~w(asset org_unit location material_responsible actual_user unit_ref quantity last_posting_seq)

    assert hd(row) == asset and Enum.at(row, 5) == "pcs"

    assert [%{"sku" => chosen}] =
             rows(
               export(
                 ctx,
                 request("stock_balances", "json", %{"sku" => hd(skus), "org_unit" => @unit})
               )
             )

    assert chosen == hd(skus)
    today = Date.utc_today() |> Date.to_iso8601()
    dated = export(ctx, request("stock_balances", "json", %{"as_of_date" => today})) |> json()
    assert length(dated["rows"]) == 2
    assert dated["meta"]["as_of_date"] == today
  end

  @tag timeout: 120_000
  test "DX-7 pinned balance pages and monotone movement pages under late posts", ctx do
    schema = ctx.tenant.schema_name
    skus = for _ <- 1..5, do: S.uuid()
    Enum.each(skus, &post(schema, &1))
    original = Application.get_env(:letflow, :data_export_page_limit)
    Application.put_env(:letflow, :data_export_page_limit, 2)

    on_exit(fn ->
      if original,
        do: Application.put_env(:letflow, :data_export_page_limit, original),
        else: Application.delete_env(:letflow, :data_export_page_limit)
    end)

    user = Fx.user!(ctx.tenant, ["TENANT_ADMIN"])

    {:ok, auth} =
      Ledger.authorize(Fx.conn_for(ctx.tenant, user, ["TENANT_ADMIN"]), "stock", :read)

    provider = Letflow.Modules.Stock.DataExport
    {:ok, first} = provider.fetch_page("stock_balances", auth, %{}, nil)
    cutoff = first.meta |> Map.new() |> Map.fetch!("cutoff_seq")
    late = [S.uuid(), S.uuid()]
    Enum.each(late, &post(schema, &1))
    rest = pages(provider, "stock_balances", auth, first.next)
    assert Enum.all?([first | rest], &(Map.new(&1.meta)["cutoff_seq"] == cutoff))
    keys = Enum.flat_map([first | rest], &Enum.map(&1.rows, fn row -> row.sku end))
    assert Enum.sort(keys) == Enum.sort(skus)
    {:ok, first} = provider.fetch_page("stock_movements", auth, %{}, nil)
    Enum.each([S.uuid(), S.uuid()], &post(schema, &1))
    rest = pages(provider, "stock_movements", auth, first.next)
    seqs = Enum.flat_map([first | rest], &Enum.map(&1.rows, fn row -> row.posting_seq end))
    assert seqs == Enum.to_list(1..9)
  end

  defp pages(_provider, _id, _auth, nil), do: []

  defp pages(provider, id, auth, next) do
    {:ok, page} = provider.fetch_page(id, auth, %{}, next)
    [page | pages(provider, id, auth, page.next)]
  end

  @tag timeout: 120_000
  test "DX-11 validation refuses before ledger SQL", ctx do
    bads = [
      {request("stock_balances", "bad"), "invalid_format"},
      {request("unknown"), "dataset_unknown"},
      {request("asset_balances"), "dataset_unknown"},
      {request("stock_balances", "json", %{"bad" => true}), "invalid_filter"},
      {request("stock_balances", "json", %{"as_of_date" => "no"}), "invalid_filter"},
      {request("stock_balances", "json", %{"org_unit" => "not-uuid"}), "invalid_filter"},
      {request("stock_movements", "json", %{"as_of_date" => "2026-01-01"}), "invalid_filter"},
      {%{"ids" => "machine", "datasets" => []}, "invalid_body"},
      {Map.update!(request(), "datasets", &(&1 ++ &1)), "invalid_body"},
      {Map.delete(request(), "ids"), "invalid_body"},
      {Map.put(request(), "ids", "readable"), "invalid_body"},
      {Map.put(request(), "tenant_id", S.uuid()), "invalid_body"}
    ]

    for {body, expected} <- bads do
      {conn, statements} = Fx.record(fn -> export(ctx, body) end)
      reason(conn, 422, expected)
      assert Enum.filter(statements, fn {sql, _} -> sql =~ "ledger_" end) == []
    end
  end

  @tag timeout: 120_000
  test "DX-12 DX-13 audit records export metadata and insert failure releases no file", ctx do
    schema = ctx.tenant.schema_name
    post(schema, S.uuid())
    post(schema, S.uuid())
    Application.put_env(:letflow, :data_export_row_cap, 1)
    on_exit(fn -> Application.delete_env(:letflow, :data_export_row_cap) end)
    conn = export(ctx, request("stock_balances", "json", %{"org_unit" => @unit}))
    assert conn.status == 200
    assert get_resp_header(conn, "x-export-truncated") == ["stock_balances"]
    assert [entry] = audit_rows(schema)
    actor = Repo.one!(from(u in User, where: u.username == "exporter"), prefix: schema)
    assert entry.actor_id == actor.id

    assert entry.after_state["datasets"] == [
             %{
               "id" => "stock_balances",
               "format" => "json",
               "filters" => %{"org_unit" => @unit},
               "rows" => 1,
               "truncated" => true
             }
           ]

    reason(export(ctx, request("missing")), 422, "dataset_unknown")
    assert length(audit_rows(schema)) == 1
    # Keep the rate-count read working while forcing the subsequent audit INSERT to fail.
    Repo.query!(
      ~s|ALTER TABLE "#{schema}".audit_entries ADD CONSTRAINT dx_refuse_export CHECK (action <> 'data_export.downloaded') NOT VALID|
    )

    conn = export(ctx, request())
    assert conn.status == 500
    assert hd(get_resp_header(conn, "content-type")) =~ "application/problem+json"
    assert get_resp_header(conn, "content-disposition") == []
    assert length(audit_rows(schema)) == 1
  end

  @tag timeout: 120_000
  test "DX-14 rate window is per actor and expires after 600 seconds", ctx do
    tok = token(ctx)
    assert call(:get, "/datasets", tok).status == 200

    actor =
      Repo.one!(from(u in User, where: u.username == "exporter"), prefix: ctx.tenant.schema_name)

    for _ <- 1..10 do
      {:ok, _} =
        Audit.insert_entry(
          Repo,
          %{
            actor_id: actor.id,
            action: "data_export.downloaded",
            resource_type: "data_export",
            resource_id: S.uuid()
          },
          ctx.tenant.schema_name
        )
    end

    now = DateTime.utc_now()
    conn = call(:post, "", tok, request())
    reason(conn, 429, "rate_limited")
    assert get_resp_header(conn, "retry-after") == ["600"]
    assert call(:post, "", token(ctx, "other-exporter"), request()).status == 200

    refute DataExport.rate_limited?(
             ctx.tenant.schema_name,
             actor.id,
             DateTime.add(now, 601, :second)
           )

    assert DataExport.rate_limited?("missing_schema", actor.id, now)
  end

  @tag timeout: 120_000
  test "DX-15 read scope masks hidden legs, enforcement on refuses tenant-wide export", ctx do
    schema = ctx.tenant.schema_name
    sku = S.uuid()
    post(schema, sku)
    post(schema, S.uuid(), @other)

    S.post!(schema, "transfer", %{
      lines: [S.line(sku, "3", %{from: S.side(@unit, @location), to: S.side(@other, @location)})]
    })

    {:ok, _} = ScopeNodePaths.write({:insert, @unit, nil}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, @other, nil}, schema)
    tok = token(ctx, "scoped")
    assert call(:get, "/datasets", tok).status == 200
    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "TENANT_ADMIN"), "TENANT_ADMIN")
    user = Repo.one!(from(u in User, where: u.username == "scoped"), prefix: schema)
    :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", @unit)
    data = call(:post, "", tok, request()) |> rows()
    assert length(data) == 1 and Enum.all?(data, &(&1["org_unit"] == @unit))
    movements = call(:post, "", tok, request("stock_movements")) |> rows()
    assert [masked] = Enum.filter(movements, & &1["masked"])

    for key <- ~w(sku location org_unit responsible lot document_line_id),
        do: assert(is_nil(masked[key]))

    refute Enum.any?(movements, &(&1["org_unit"] == @other))

    Repo.update_all(from(t in Letflow.Identity.Tenant, where: t.id == ^ctx.tenant.tenant_id),
      set: [scope_enforcement: :on]
    )

    assert call(:post, "", tok, request()).status == 403
  end
end
