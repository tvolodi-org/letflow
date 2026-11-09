Code.require_file("stock/documents_fixture.exs", __DIR__)
Code.require_file("assets/register_fixture.exs", __DIR__)

defmodule Letflow.Modules.AssetStockScopeExportsTest do
  @moduledoc """
  T-1534: hidden legs and rows in the files a scoped reader can download. A reader granted on org unit U1
  asks the real `Letflow.Router` (real bearer token) for the stock and assets XLSX registers and the stock-card
  print while U2 holds stock and one movement has a visible leg (U1) and a hidden leg (U2). Each file is
  decoded and every part of it searched for the hidden unit, its quantities and its document ids; a reader
  granted on the parent node is the control that shows the same values, so the absence is not vacuous.
  S1 stock balances xlsx, S2 stock movements xlsx, S3 assets balances xlsx, S4 stock-card print.
  Documents stay tenant-wide-only (assets S1, stock A-TEN-1) and counts keep their scoped contract
  (`asset_stock_isolation_test.exs`, S6). `async: false`, committed tenants, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsRegisterFixture, as: AS
  alias Letflow.Identity.User
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
  @hidden_qty "6.250000000"

  setup do
    ctx = S.setup_oidc!([:s, :t])

    # stock tenant: real catalog item and location, so the stock card can name them
    st = S.tenant!("stk-scx", ctx.names.s)
    m = SD.masters!(st.schema_name)

    # assets tenant: raw ledger ids as the register tests use them
    at = AS.tenant!("ast-scx", ctx.names.t)

    for schema <- [st.schema_name, at.schema_name] do
      {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
      {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)
    end

    seed_stock!(st.schema_name, m)
    seed_assets!(at.schema_name)

    {s1, sp} = scoped!(ctx, :s, st.schema_name)
    {t1, tp} = scoped!(ctx, :t, at.schema_name)

    {:ok, Map.merge(ctx, %{m: m, s1: s1, sp: sp, t1: t1, tp: tp, st: st})}
  end

  # u1 receives 10 of the item, u2 receives 6.25, u1 sends 3 to u2 (a hidden leg of the transfer).
  defp seed_stock!(schema, m) do
    here = S.side(@u1, m.location)
    there = S.side(@u2, m.location)

    S.post!(schema, "receipt", %{
      document_id: "doc-vis",
      lines: [S.line(m.item, "10", %{to: here})]
    })

    S.post!(schema, "receipt", %{
      document_id: "doc-hid",
      lines: [S.line(m.item, "6.25", %{to: there})]
    })

    S.post!(schema, "transfer", %{
      document_id: "doc-trf",
      lines: [S.line(m.item, "3", %{from: here, to: there})]
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

  # Every part of an xlsx (sheets, shared strings) as one string.
  defp xlsx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    files |> Enum.map_join("\n", fn {_, bin} -> bin end)
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

  test "S1 stock balances xlsx: a U1 reader's file holds no U2 row", ctx do
    scoped = req(@stock <> "/balances?format=xlsx", ctx.s1) |> ok!("spreadsheetml")
    text = xlsx_text(scoped)
    assert text =~ @u1
    refute text =~ @u2
    refute text =~ @hidden_qty

    control = req(@stock <> "/balances?format=xlsx", ctx.sp) |> ok!("spreadsheetml")
    assert xlsx_text(control) =~ @u2
  end

  test "S2 stock movements xlsx: hidden leg blanked, hidden documents and units absent", ctx do
    scoped = req(@stock <> "/movements?format=xlsx", ctx.s1) |> ok!("spreadsheetml")
    text = xlsx_text(scoped)
    assert text =~ "doc-vis" and text =~ "doc-trf"
    refute text =~ @u2
    refute text =~ "doc-hid"
    refute text =~ @hidden_qty

    control = req(@stock <> "/movements?format=xlsx", ctx.sp) |> ok!("spreadsheetml")
    full = xlsx_text(control)
    assert full =~ "doc-hid" and full =~ @u2
  end

  test "S3 assets balances xlsx: a U1 reader's file holds no U2 row, also by subtree", ctx do
    for q <- ["", "&scope_subtree=#{@p}"] do
      scoped = req(@assets <> "/balances?format=xlsx" <> q, ctx.t1) |> ok!("spreadsheetml")
      text = xlsx_text(scoped)
      assert text =~ @u1, q
      refute text =~ @u2, q
      refute text =~ @a2, q
    end

    control = req(@assets <> "/balances?format=xlsx&scope_subtree=#{@p}", ctx.tp)
    full = control |> ok!("spreadsheetml") |> xlsx_text()
    assert full =~ @u2 and full =~ @a2

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

    control = req(@stock <> "/stock-card/print?" <> q, ctx.sp) |> ok!("wordprocessingml")
    assert docx_text(control) =~ @hidden_qty
  end
end
