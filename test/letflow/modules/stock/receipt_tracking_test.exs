Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ReceiptTrackingTest do
  @moduledoc """
  REQ-714 / GH #3747 criterion 4: at issue the lot of each line is checked against the item's tracking
  policy (`lot_required`, `lot_not_allowed`, `lot_expiry_missing`, `tracking_policy_not_supported`), in the
  order unit, tracking, lot-belongs-to. Items through the owner-path fixture. Committed tenants,
  Sandbox `:auto`, `async: false`. Tests: TR-1..13.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Stock.Documents.Checks
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp uniq, do: System.unique_integer([:positive])

  defp item(ctx, policy, tok \\ :a) do
    {schema, m} = if tok == :a, do: {ctx.schema, ctx.ma}, else: {ctx.b.schema_name, ctx.mb}
    extra = if policy, do: %{"tracking_policy" => policy}, else: %{}
    Cat.item!(schema, "T#{uniq()}", m.uom, extra).record_id
  end

  defp lot(ctx, item_id, extra \\ %{}),
    do: Cat.lot!(ctx.schema, item_id, "TL#{uniq()}", extra).record_id

  defp ln(ctx, item_id, lot_id \\ nil) do
    base = %{"catalog_item_id" => item_id, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
    if lot_id, do: Map.put(base, "catalog_lot_id", lot_id), else: base
  end

  defp try_issue(ctx, lines) do
    doc = P.save!(ctx, D.body(ctx.ma, nil, %{"lines" => lines}))
    {doc, D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)}
  end

  defp refused(ctx, lines, reason, line_no) do
    {doc, conn} = try_issue(ctx, lines)
    assert conn.status == 422, conn.resp_body
    json = Jason.decode!(conn.resp_body)
    assert json["reason"] == reason
    assert json["line_no"] == line_no
    read = P.get!(ctx, doc["id"])
    assert read["state"] == "draft" and read["number"] == nil
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  defp accepted(ctx, lines) do
    {_doc, conn} = try_issue(ctx, lines)
    assert conn.status == 200, conn.resp_body
  end

  test("TR-1 lot policy without a lot", ctx,
    do: refused(ctx, [ln(ctx, item(ctx, "lot"))], "lot_required", 1)
  )

  test("TR-2 expiry policy without a lot", ctx,
    do: refused(ctx, [ln(ctx, item(ctx, "expiry"))], "lot_required", 1)
  )

  test "TR-3 none policy with a lot", ctx do
    i = item(ctx, "none")
    refused(ctx, [ln(ctx, i, lot(ctx, i))], "lot_not_allowed", 1)
  end

  test "TR-4 expiry policy with an undated lot", ctx do
    i = item(ctx, "expiry")
    refused(ctx, [ln(ctx, i, lot(ctx, i))], "lot_expiry_missing", 1)
  end

  test "TR-5 serial policy is not supported, with or without a lot", ctx do
    i = item(ctx, "serial")
    refused(ctx, [ln(ctx, i)], "tracking_policy_not_supported", 1)
    refused(ctx, [ln(ctx, i, lot(ctx, i))], "tracking_policy_not_supported", 1)
  end

  test "TR-6..9 the accepted combinations", ctx do
    accepted(ctx, [ln(ctx, item(ctx, "none"))])
    l = item(ctx, "lot")
    accepted(ctx, [ln(ctx, l, lot(ctx, l))])
    e = item(ctx, "expiry")
    accepted(ctx, [ln(ctx, e, lot(ctx, e, %{"expiry_date" => "2030-01-31"}))])
    accepted(ctx, [ln(ctx, item(ctx, nil))])
    n = item(ctx, nil)
    refused(ctx, [ln(ctx, n, lot(ctx, n))], "lot_not_allowed", 1)
  end

  test "TR-10 order: unit first, line number of the failing line, lot of another sku", ctx do
    other_uom = Cat.uom!(ctx.schema, "KG#{uniq()}").record_id
    bad_unit = %{ln(ctx, item(ctx, "lot")) | "catalog_uom_id" => other_uom}
    refused(ctx, [bad_unit], "unit_not_valid", 1)

    refused(ctx, [ln(ctx, item(ctx, "none")), ln(ctx, item(ctx, "lot"))], "lot_required", 2)

    a = item(ctx, "lot")
    b = item(ctx, "lot")
    refused(ctx, [ln(ctx, a, lot(ctx, b))], "lot_not_valid", 1)
  end

  test "TR-11 a refusal leaves no number and no posting (see refused/4)", ctx do
    {doc, conn} = try_issue(ctx, [ln(ctx, item(ctx, "lot"))])
    assert conn.status == 422
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "TR-12 unmapped results fall back to tracking_invalid" do
    assert Checks.tracking_reason({:error, :item_not_found}) == "tracking_invalid"
    assert Checks.tracking_reason({:error, :item_inactive}) == "tracking_invalid"
    assert Checks.tracking_reason({:error, :invalid_capture}) == "tracking_invalid"
    assert Checks.tracking_reason({:error, {:capture_required, "serial"}}) == "tracking_invalid"

    assert Checks.tracking_reason({:error, {:capture_invalid, "tracking_policy"}}) ==
             "tracking_invalid"

    assert Checks.tracking_reason({:error, {:capture_invalid, "expiry"}}) == "lot_expiry_missing"
  end

  test "TR-13 another tenant's item and lot ids are unknown on this tenant's line", ctx do
    foreign = item(ctx, "lot", :b)
    {_doc, conn} = try_issue(ctx, [ln(ctx, foreign)])
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["reason"] in ~w(unit_not_valid tracking_invalid)
  end
end
