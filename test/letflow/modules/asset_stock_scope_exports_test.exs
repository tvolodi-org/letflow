Code.require_file("stock/documents_fixture.exs", __DIR__)
Code.require_file("assets/register_fixture.exs", __DIR__)

defmodule Letflow.Modules.AssetStockScopeExportsTest do
  @moduledoc """
  T-1534: hidden legs and rows in the files a scoped reader can download. A reader granted on org unit U1
  asks the real `Letflow.Router` (real bearer token) for the stock and assets XLSX registers and the stock-card
  print while U2 holds stock and one movement has a visible leg (U1) and a hidden leg (U2). Each file is
  decoded (every worksheet cell) and searched for the hidden unit, item, location, document and line ids and
  the hidden quantity; a reader granted on the parent node is the control that must show every one of those
  sentinels, so the absence is not vacuous. S2 also pins the masked leg's cells (blank slots, `masked` true).
  S1 stock balances xlsx, S2 stock movements xlsx, S3 assets balances xlsx, S4 stock-card print (S4b: an item
  and place whose movements are all hidden answer like an absent identifier), S5 stock balances sheet print Z-7
  (T-1925; S5b: a place whose movements are all hidden answers like an absent one).
  Documents stay tenant-wide-only (assets S1, stock A-TEN-1; real assets documents: asset_documents_scoped_read_test.exs S6a) and counts keep their scoped contract
  (`asset_stock_isolation_test.exs`, S6). `async: false`, committed tenants, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsRegisterFixture, as: AS
  alias Letflow.Identity.TenantTimezone
  alias Letflow.Identity.User
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.ScopeNodePaths
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @p "47474747-4747-4747-8747-474747474747"
  @a1 "11111111-1111-4111-8111-111111111111"
  @a2 "12121212-1212-4212-8212-121212121212"
  @r1 "55555555-5555-4555-8555-555555555555"
  @r2 "56565656-5656-4656-8656-565656565656"
  @l1 "33333333-3333-4333-8333-333333333333"
  @hid_line "66666666-6666-4666-8666-666666666666"
  @hidden_qty "6.250000000"

  setup do
    ctx = S.setup_oidc!([:s, :t])

    # stock tenant: real catalog item and location, so the stock card can name them
    st = S.tenant!("stk-scx", ctx.names.s)
    m = SD.masters!(st.schema_name)
    # a second item and place that only U2 ever touches
    h = SD.masters!(st.schema_name)

    # assets tenant: raw ledger ids as the register tests use them
    at = AS.tenant!("ast-scx", ctx.names.t)

    for schema <- [st.schema_name, at.schema_name] do
      {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)
    end

    seed_stock!(st.schema_name, m, h)
    seed_assets!(at.schema_name)

    {s1, sp} = scoped!(ctx, :s, st.schema_name)
    {t1, tp} = scoped!(ctx, :t, at.schema_name)

    {:ok, Map.merge(ctx, %{m: m, h: h, s1: s1, sp: sp, t1: t1, tp: tp, st: st})}
  end

  # u1 receives 10 of the item, u2 receives 6.25 of the hidden item at the hidden place, u1 sends 3 to u2's
  # hidden place (a hidden leg of the transfer).
  defp seed_stock!(schema, m, h) do
    here = S.side(@u1, m.location)
    there = S.side(@u2, h.location)

    S.post!(schema, "receipt", %{
      document_id: "doc-vis",
      lines: [S.line(m.item, "10", %{to: here})]
    })

    S.post!(schema, "receipt", %{
      document_id: "doc-hid",
      lines: [S.line(h.item, "6.25", %{to: there}, %{line_id: @hid_line})]
    })

    S.post!(schema, "transfer", %{
      document_id: "doc-trf",
      lines: [S.line(m.item, "3", %{from: here, to: there})]
    })

    # U2 also holds the SAME item at the SAME place, so the print filter alone cannot hide it
    S.post!(schema, "receipt", %{
      document_id: "doc-same-u2",
      lines: [S.line(m.item, "4.5", %{to: S.side(@u2, m.location)})]
    })
  end

  defp seed_assets!(schema) do
    here = AS.side(@u1, @r1, %{location: @l1})

    AS.post!(schema, "commission", %{
      document_type: "commission_doc",
      document_id: "doc-1",
      lines: [AS.line(@a1, "3", %{to: here})]
    })

    AS.post!(schema, "handover", %{
      document_id: "doc-3",
      lines: [AS.line(@a1, "1", %{from: here, to: AS.side(@u2, @r1)})]
    })

    AS.post!(schema, "commission", %{
      document_id: "doc-4",
      lines: [AS.line(@a2, "2", %{to: AS.side(@u2, @r2)})]
    })
  end

  # Two readers of one tenant: the first granted on U1 only, the second on the parent node.
  defp scoped!(ctx, name, schema) do
    t1 = S.token(ctx, name, ["TENANT_ADMIN"], sub: "reader-u1")
    tp = S.token(ctx, name, ["TENANT_ADMIN"], sub: "reader-p")
    base = if name == :s, do: "/api/v1/modules/stock", else: "/api/v1/modules/assets"
    for tok <- [t1, tp], do: 200 = req(base <> "/balances", tok).status
    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "TENANT_ADMIN"), "TENANT_ADMIN")

    for {sub, node} <- [{"reader-u1", @u1}, {"reader-p", @p}] do
      user = Letflow.Repo.one!(from(u in User, where: u.username == ^sub), prefix: schema)
      :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", node)
    end

    {t1, tp}
  end

  defp req(path, token) do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  @stock "/api/v1/modules/stock"
  @assets "/api/v1/modules/assets"

  # Every cell of every worksheet of an xlsx, as a flat list (strings and numbers kept as they are).
  defp sheets(conn) do
    {:ok, pkg} = XlsxReader.open(conn.resp_body, source: :binary)

    Map.new(XlsxReader.sheet_names(pkg), fn name ->
      {:ok, rows} = XlsxReader.sheet(pkg, name)
      {name, rows}
    end)
  end

  defp cells(conn), do: conn |> sheets() |> Map.values() |> List.flatten()

  defp has?(cells, sentinel) when is_binary(sentinel),
    do: Enum.any?(cells, &(is_binary(&1) and String.contains?(&1, sentinel)))

  defp has?(cells, number) when is_number(number), do: Enum.any?(cells, &(&1 == number))

  # Every sentinel appears in the control file and in none of the scoped file.
  defp assert_hidden(scoped, control, sentinels) do
    for x <- sentinels do
      assert has?(control, x), "control lacks #{inspect(x)}: the absence below would be vacuous"
      refute has?(scoped, x), "scoped file leaks #{inspect(x)}"
    end
  end

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp ok!(conn, type) do
    assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
    [ct | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ type
    conn
  end

  defp hidden_sentinels(ctx),
    do: [@u2, ctx.h.item, ctx.h.location, "doc-hid", @hid_line, 6.25]

  test "S1 stock balances xlsx: a U1 reader's file holds no U2 row", ctx do
    scoped = req(@stock <> "/balances?format=xlsx", ctx.s1) |> ok!("spreadsheetml") |> cells()
    control = req(@stock <> "/balances?format=xlsx", ctx.sp) |> ok!("spreadsheetml") |> cells()
    assert has?(scoped, @u1)
    assert_hidden(scoped, control, [@u2, ctx.h.item, ctx.h.location, 6.25])
  end

  test "S2 stock movements xlsx: hidden leg masked cell by cell, hidden values absent", ctx do
    scoped_conn = req(@stock <> "/movements?format=xlsx", ctx.s1) |> ok!("spreadsheetml")
    control_conn = req(@stock <> "/movements?format=xlsx", ctx.sp) |> ok!("spreadsheetml")
    scoped = cells(scoped_conn)
    assert has?(scoped, "doc-vis") and has?(scoped, "doc-trf")
    assert_hidden(scoped, cells(control_conn), hidden_sentinels(ctx))

    # the transfer's U2 leg is the one masked row: marker set, every slot and the line id blank, the
    # quantity and unit kept (the contract of `Views.stock_movement_leg/1`)
    [header | rows] = sheets(scoped_conn)["movements"]
    col = fn name -> Enum.find_index(header, &(&1 == name)) end
    row_of = fn row, name -> Enum.at(row, col.(name)) end
    masked = Enum.filter(rows, &(row_of.(&1, "masked") == true))
    assert [m_row] = masked
    assert row_of.(m_row, "document_id") == "doc-trf"

    for slot <- ~w(sku location org_unit responsible lot document_line_id) do
      assert row_of.(m_row, slot) in [nil, ""], "masked row shows #{slot}"
    end

    assert row_of.(m_row, "quantity") == 3.0
    assert Enum.all?(rows -- masked, &(row_of.(&1, "masked") in [false, nil, ""]))

    # the control reader sees that same leg unmasked, with the hidden place in it
    [h2 | crows] = sheets(control_conn)["movements"]
    ccol = fn name -> Enum.find_index(h2, &(&1 == name)) end
    refute Enum.any?(crows, &(Enum.at(&1, ccol.("masked")) == true))
    assert Enum.any?(crows, &(Enum.at(&1, ccol.("location")) == ctx.h.location))
  end

  test "S3 assets balances xlsx: a U1 reader's file holds no U2 row, also by subtree", ctx do
    control =
      req(@assets <> "/balances?format=xlsx&scope_subtree=#{@p}", ctx.tp)
      |> ok!("spreadsheetml")
      |> cells()

    for q <- ["", "&scope_subtree=#{@p}"] do
      scoped =
        req(@assets <> "/balances?format=xlsx" <> q, ctx.t1) |> ok!("spreadsheetml") |> cells()

      assert has?(scoped, @u1), q
      assert_hidden(scoped, control, [@u2, @a2])
    end

    json = req(@assets <> "/balances?scope_subtree=#{@p}", ctx.t1)
    assert json.status == 200 and Jason.decode!(json.resp_body)["coverage"] == "visible_only"
  end

  test "S4 stock-card print through the router: U1 totals shown, U2 values absent", ctx do
    q = "sku=#{ctx.m.item}&location=#{ctx.m.location}&format=docx&lang=ru"
    scoped = req(@stock <> "/stock-card/print?" <> q, ctx.s1) |> ok!("wordprocessingml")
    text = docx_text(scoped)
    # U1 legs only: receipt 10 in, transfer 3 out, running balance 7.
    assert text =~ "10.000000000" and text =~ "3.000000000" and text =~ "7.000000000"
    refute text =~ @hidden_qty
    refute text =~ @u2
    refute text =~ "doc-hid"
    refute text =~ ctx.h.location
    # the U2 movement of the very same item and place: absent, and the totals stay U1-only
    refute text =~ "4.500000000"
    refute text =~ "doc-same-u2"
    refute text =~ "11.500000000"

    control = req(@stock <> "/stock-card/print?" <> q, ctx.sp) |> ok!("wordprocessingml")
    ctext = docx_text(control)
    assert ctext =~ "10.000000000"
    # unrestricted reader: the same-key U2 movement and the totals that include it
    assert ctext =~ "4.500000000"
    assert ctext =~ "11.500000000"
  end

  test "S4b an item and place with only hidden movements answer like an absent identifier", ctx do
    hidden = "sku=#{ctx.h.item}&location=#{ctx.h.location}&format=docx&lang=ru"
    absent = "sku=#{Ecto.UUID.generate()}&location=#{Ecto.UUID.generate()}&format=docx&lang=ru"
    path = @stock <> "/stock-card/print?"

    # the unrestricted reader prints the very same resource, so the 404 below is about scope alone
    full = req(path <> hidden, ctx.sp) |> ok!("wordprocessingml")
    assert docx_text(full) =~ @hidden_qty

    gone = req(path <> absent, ctx.s1)
    refused = req(path <> hidden, ctx.s1)
    assert gone.status == 404, gone.resp_body
    assert refused.status == 404, refused.resp_body
    strip = fn c -> c.resp_body |> Jason.decode!() |> Map.delete("trace_id") end
    assert strip.(refused) == strip.(gone)
    refute refused.resp_body =~ ctx.h.item
  end

  defp sheet_q(ctx, location) do
    {:ok, today} = TenantTimezone.today(CountPaperworkSource.zone(ctx.st.tenant_id))
    "location=#{location}&from=2020-01-01&to=#{today}&format=docx&lang=ru"
  end

  test "S5 stock balances sheet (Z-7) through the router: U1 totals shown, U2 values absent",
       ctx do
    q = sheet_q(ctx, ctx.m.location)
    scoped = req(@stock <> "/stock-sheet/print?" <> q, ctx.s1) |> ok!("wordprocessingml")
    text = docx_text(scoped)
    # U1 legs only: receipt 10 in, transfer 3 out, closing 7.
    assert text =~ "10.000000000" and text =~ "3.000000000" and text =~ "7.000000000"
    refute text =~ @hidden_qty
    refute text =~ @u2
    refute text =~ "14.500000000"
    refute text =~ "11.500000000"

    control = req(@stock <> "/stock-sheet/print?" <> q, ctx.sp) |> ok!("wordprocessingml")
    ctext = docx_text(control)
    # unrestricted reader: the same-key U2 receipt is income too (10 + 4.5), closing 14.5 - 3
    assert ctext =~ "14.500000000" and ctext =~ "3.000000000" and ctext =~ "11.500000000"
  end

  test "S5b a place with only hidden movements answers like an absent place", ctx do
    path = @stock <> "/stock-sheet/print?"
    full = req(path <> sheet_q(ctx, ctx.h.location), ctx.sp) |> ok!("wordprocessingml")
    assert docx_text(full) =~ @hidden_qty

    gone = req(path <> sheet_q(ctx, Ecto.UUID.generate()), ctx.s1)
    refused = req(path <> sheet_q(ctx, ctx.h.location), ctx.s1)
    assert gone.status == 404, gone.resp_body
    assert refused.status == 404, refused.resp_body
    strip = fn c -> c.resp_body |> Jason.decode!() |> Map.delete("trace_id") end
    assert strip.(refused) == strip.(gone)
    refute refused.resp_body =~ ctx.h.location
  end
end
