Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.NegativeBalanceTest do
  @moduledoc """
  REQ-836 / GH #4545 (decision 0090), criteria 1 to 7: module stock opts its ledger into the
  per-tenant negative balance setting. Documents are saved, issued and posted through the real
  routes and the real task completion; the setting row is written with
  `Letflow.LedgerFixture.set_negative_balance!/3` (the settings route is REQ-835). Committed
  tenants, Sandbox `:auto`, `async: false`.
  Tests: NB-1..NB-3, NB-5a..NB-5e, NB-6a..NB-6c, NB-7a..NB-7c.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Stock.Documents.OpeningShape
  alias Letflow.Modules.Stock.PostingRules
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    ctx = Map.put(ctx, :m2, T.b2!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  defp allow!(ctx, allow? \\ true), do: Fx.set_negative_balance!(ctx.schema, "stock", allow?)

  defp line(m, qty),
    do: %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}

  defp one_side(ctx, kind, qty, extra \\ %{}) do
    ctx.ma
    |> D.body(nil, %{"kind" => kind, "lines" => [line(ctx.ma, qty)]})
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  defp receive!(ctx, qty) do
    doc = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => [line(ctx.ma, qty)]}))
    P.post_and_complete!(ctx, doc["id"])
  end

  defp qty(ctx, side), do: T.qty(ctx, side.location, side.employee) |> Decimal.new()

  defp total(ctx) do
    S.get("/balances?sku=#{ctx.ma.item}", ctx.tok_a)
    |> P.status!(200)
    |> Map.fetch!("rows")
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp eq?(value, expected), do: Decimal.equal?(value, expected)

  defp refused?(result), do: match?({:error, _}, result) and inspect(result) =~ "insufficient"

  # -- criterion 1: issue ------------------------------------------------------------------------

  test "NB-1 allow: issue 7 from 5 posts and reads -2; no row: refused, balance 5", ctx do
    receive!(ctx, "5")

    refuse_doc = P.issue!(ctx, one_side(ctx, "issue", "7"))
    assert refused?(P.complete(ctx, P.pending_task(ctx, refuse_doc["id"], "post")))
    assert eq?(total(ctx), 5)

    allow!(ctx)
    posted = P.post_and_complete!(ctx, refuse_doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert eq?(total(ctx), -2)

    rows = S.get("/balances", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    assert Enum.any?(rows, &(&1["sku"] == ctx.ma.item and &1["quantity"] == "-2.000000000"))
  end

  # -- criterion 2: transfer and write off -------------------------------------------------------

  test "NB-2 allow: transfer 4 from a key holding 1 and write off 2 from an empty key", ctx do
    T.receive!(ctx, ctx.ma, "1")
    body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => T.plain(ctx.ma, "4")})

    refused = T.issue!(ctx, body)
    assert refused?(P.complete(ctx, P.pending_task(ctx, refused["id"], "post")))
    assert eq?(qty(ctx, ctx.ma), 1)

    allow!(ctx)
    assert P.post_and_complete!(ctx, refused["id"])["state"] == "posted"
    assert eq?(qty(ctx, ctx.ma), -3)
    assert eq?(qty(ctx, ctx.m2), 4)
  end

  test "NB-2c allow: a write off of 2 from a key holding 0 reads -2", ctx do
    allow!(ctx)
    off = P.issue!(ctx, one_side(ctx, "write_off", "2", %{"reason_code" => "lost"}))
    assert P.post_and_complete!(ctx, off["id"])["state"] == "posted"
    assert eq?(total(ctx), -2)
  end

  test "NB-2b no row: the write off from an empty key is refused", ctx do
    off = P.issue!(ctx, one_side(ctx, "write_off", "2", %{"reason_code" => "lost"}))
    assert refused?(P.complete(ctx, P.pending_task(ctx, off["id"], "post")))
    assert eq?(total(ctx), 0)
  end

  # -- criterion 3: reversal ---------------------------------------------------------------------

  defp reverse_flow(ctx) do
    rcp = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => [line(ctx.ma, "10")]}))
    P.post_and_complete!(ctx, rcp["id"])
    iss = P.issue!(ctx, one_side(ctx, "issue", "8"))
    P.post_and_complete!(ctx, iss["id"])
    assert eq?(total(ctx), 2)

    P.req(ctx, :post, rcp["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    {rcp, P.pending_task(ctx, rcp["id"], "reverse")}
  end

  test "NB-3a allow: reversing a receipt whose key now holds 2 reads -8", ctx do
    allow!(ctx)
    {_rcp, task} = reverse_flow(ctx)
    assert {:ok, _} = P.complete(ctx, task)
    assert eq?(total(ctx), -8)
  end

  test "NB-3b refuse: the same reversal is refused insufficient_stock", ctx do
    {_rcp, task} = reverse_flow(ctx)
    assert refused?(P.complete(ctx, task))
    assert eq?(total(ctx), 2)
  end

  # -- criterion 5: opening balance --------------------------------------------------------------

  defp opening_line(ctx, qty), do: O.line(ctx.ma, %{"quantity" => qty})

  defp opening_body(ctx, quantities),
    do: O.body(ctx.ma, %{"lines" => Enum.map(quantities, &opening_line(ctx, &1))})

  defp save_opening(ctx, quantities),
    do: D.request(:post, "/documents", ctx.tok_a, opening_body(ctx, quantities))

  defp reason(conn, status), do: conn |> P.status!(status) |> Map.fetch!("reason")

  test "NB-5a allow: an all negative opening posts as opening_negative and the key reads -7",
       ctx do
    allow!(ctx)
    doc = save_opening(ctx, ["-7"]) |> P.status!(201)
    assert [%{"quantity" => "-7.000000000"}] = doc["lines"]

    issued = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
    approve = O.task(ctx, issued["id"], "approve", :pending)
    assert {:ok, _} = P.complete(ctx, approve, user: O.second_admin!(ctx))

    read = P.get!(ctx, doc["id"])
    assert read["state"] == "posted" and read["posting_check"] == "ok"
    assert P.counts(ctx, doc["id"]).entries == %{"opening_negative" => 1}
    assert eq?(total(ctx), -7)

    [entry] = P.movements(ctx, doc["id"])
    assert entry["cause"] == "opening_negative"
    assert [leg] = entry["legs"]
    assert eq?(Decimal.new(leg["quantity"]), -7)
  end

  test "NB-5b refuse: a negative opening line is quantity_invalid on save", ctx do
    assert reason(save_opening(ctx, ["-7"]), 422) == "quantity_invalid"
  end

  test "NB-5c zero and negative zero are quantity_invalid on both tenants", ctx do
    for allow? <- [false, true], q <- ["0", "-0", "-0.000"] do
      if allow?, do: allow!(ctx)
      assert reason(save_opening(ctx, [q]), 422) == "quantity_invalid", "#{allow?} #{q}"
    end
  end

  test "NB-5d allow: a document that mixes signs is quantity_invalid with the line", ctx do
    allow!(ctx)
    conn = save_opening(ctx, ["4", "-7"])
    body = P.status!(conn, 422)
    assert body["reason"] == "quantity_invalid"
    assert Jason.encode!(body) =~ "2"
    assert reason(save_opening(ctx, ["-4", "7"]), 422) == "quantity_invalid"
    assert save_opening(ctx, ["4", "7"]).status == 201
  end

  test "NB-5e the shape check is the one definition for save and import (pure)", ctx do
    body = opening_body(ctx, ["-7"])
    assert {:error, {"quantity_invalid", %{"line_no" => 1}}} = OpeningShape.parse(body, :create)

    assert {:ok, %{lines: [%{"quantity" => "-7.000000000"}]}} =
             OpeningShape.parse(body, :create, true)

    assert {:ok, %{lines: [%{"quantity" => "7.000000000"}]}} =
             OpeningShape.parse(opening_body(ctx, ["7"]), :create, true)
  end

  # -- criterion 6: GET /posting-rules -----------------------------------------------------------

  test "NB-6a answers refused, then allowed after the switch", ctx do
    assert S.get("/posting-rules", ctx.tok_a) |> P.status!(200) ==
             %{"negative_balance" => "refused"}

    allow!(ctx)

    assert S.get("/posting-rules", ctx.tok_a) |> P.status!(200) ==
             %{"negative_balance" => "allowed"}

    allow!(ctx, false)

    assert S.get("/posting-rules", ctx.tok_a) |> P.status!(200) ==
             %{"negative_balance" => "refused"}
  end

  test "NB-6b a caller without StockRead gets the answer of the other stock read routes", ctx do
    allow!(ctx)
    tok = S.token(ctx, :a, ["PROCESS_DESIGNER"])
    balances = S.get("/balances", tok)
    rules = S.get("/posting-rules", tok)
    assert balances.status in [403, 404]
    assert rules.status == balances.status

    assert Map.delete(Jason.decode!(rules.resp_body), "trace_id") ==
             Map.delete(Jason.decode!(balances.resp_body), "trace_id")
  end

  test "NB-6c INV-10: switching tenant A does not change tenant B's answer", ctx do
    allow!(ctx)

    assert S.get("/posting-rules", ctx.tok_a) |> P.status!(200) ==
             %{"negative_balance" => "allowed"}

    assert S.get("/posting-rules", ctx.tok_b) |> P.status!(200) ==
             %{"negative_balance" => "refused"}

    assert PostingRules.negative_allowed?(ctx.schema)
    refute PostingRules.negative_allowed?(ctx.b.schema_name)
  end

  test "NB-6d a query key is refused", ctx do
    assert S.get("/posting-rules?x=1", ctx.tok_a).status == 422
  end

  # -- criterion 7: unaffected registrations and pins --------------------------------------------

  test "NB-7a the plain stock registration declares the key, assets does not", _ctx do
    assert {:ok, %{negative_balance: :tenant_setting}} =
             Letflow.Modules.Catalog.fetch_ledger("stock", "stock")

    assert {:ok, assets} = Letflow.Modules.Catalog.fetch_ledger("assets", "assets")
    refute Map.has_key?(assets, :negative_balance)
  end

  test "NB-7b the cause opening_negative is negative and opening stays positive", _ctx do
    {:ok, reg} = Letflow.Modules.Catalog.fetch_ledger("stock", "stock")
    assert reg.causes["opening_negative"].sign_rule == :negative
    assert reg.causes["opening"].sign_rule == :positive
  end

  test "NB-7c the module version is above the one of origin/main (0.18.0)", _ctx do
    {:ok, version} = Version.parse(Letflow.Modules.Stock.manifest().version)
    assert Version.compare(version, Version.parse!("0.18.0")) == :gt
  end
end
