Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.TwoSideIssueTest do
  @moduledoc """
  REQ-721 / GH #3770 criterion 3: the issue step of transfer, hand over and return: numbers, the master
  checks of both sides (from before to, each failure names its side), the line checks and the event-time
  window. Committed tenant, Sandbox `:auto`, `async: false`.
  Tests: ISS-1..6. LINE-2 (the tracking checks of REQ-714) is deferred: REQ-714 is not on main.
  """

  use Letflow.DataCase, async: false

  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  setup do
    ctx = P.setup!()
    on_exit(fn -> Application.delete_env(:letflow, :stock_documents_clock) end)
    Map.put(ctx, :m2, T.b2!(ctx))
  end

  defp issue(ctx, id), do: D.request(:post, "/documents/#{id}/issue", ctx.tok_a)

  defp refusal(ctx, body, status \\ 422) do
    doc = P.save!(ctx, body)
    conn = issue(ctx, doc["id"])
    assert conn.status == status, "got #{conn.status}: #{conn.resp_body}"
    {doc, Letflow.StockFixture.json(conn)}
  end

  test "ISS-1..3 each kind issues with its own number prefix and starts one post task", ctx do
    for {kind, prefix} <- [{"transfer", "TRF"}, {"hand_over", "HOV"}, {"return", "RET"}] do
      doc = T.issue!(ctx, T.body(kind, ctx.ma, ctx.ma, ctx.m2))
      year = Date.utc_today().year
      assert doc["state"] == "issued" and doc["kind"] == kind
      assert doc["number"] == "#{prefix}-#{year}-000001"
      assert %{node_id: "post"} = P.pending_task(ctx, doc["id"], "post")
    end

    # a second transfer is number 2: numbering is per document type
    second = T.issue!(ctx, T.body("transfer", ctx.ma, ctx.ma, ctx.m2))
    assert second["number"] =~ "TRF-" and second["number"] =~ "-000002"
  end

  test "ISS-4 the from side: location not linked, employee not active (side from)", ctx do
    bad_location = %{ctx.ma | location: ctx.m2.location}
    {doc, body} = refusal(ctx, T.body("transfer", ctx.ma, bad_location, ctx.m2))
    assert %{"reason" => "not_linked", "side" => "from"} = body
    assert P.get!(ctx, doc["id"])["state"] == "draft"

    ghost = %{ctx.ma | employee: Ecto.UUID.generate()}
    {_doc, body} = refusal(ctx, T.body("hand_over", ctx.ma, ghost, ctx.m2))
    assert %{"reason" => "employee_not_active", "side" => "from"} = body

    {_doc, body} = refusal(ctx, T.body("return", ctx.ma, ghost, ctx.m2))
    assert %{"reason" => "employee_not_active", "side" => "from"} = body
  end

  test "ISS-5 the to side fails with side to; a from failure wins over a to failure", ctx do
    bad_to = %{ctx.m2 | location: ctx.ma.location}
    {_doc, body} = refusal(ctx, T.body("transfer", ctx.ma, ctx.ma, bad_to))
    assert %{"reason" => "not_linked", "side" => "to"} = body

    ghost = %{ctx.m2 | employee: Ecto.UUID.generate()}
    {_doc, body} = refusal(ctx, T.body("hand_over", ctx.ma, ctx.ma, ghost))
    assert %{"reason" => "employee_not_active", "side" => "to"} = body

    {_doc, body} = refusal(ctx, T.body("return", ctx.ma, ctx.ma, ghost))
    assert %{"reason" => "employee_not_active", "side" => "to"} = body

    both_bad = %{ctx.ma | employee: Ecto.UUID.generate()}
    {_doc, body} = refusal(ctx, T.body("transfer", ctx.ma, both_bad, ghost))
    assert %{"reason" => "employee_not_active", "side" => "from"} = body

    # nothing was numbered by the refused issues
    assert T.issue!(ctx, T.body("transfer", ctx.ma, ctx.ma, ctx.m2))["number"] =~ "-000001"
  end

  test "ISS-6 line checks with line_no, no counterparty check, event-time window", ctx do
    other_uom = ctx.m2.uom

    lines = [
      hd(T.lines(ctx.ma)),
      %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => other_uom, "quantity" => "1"}
    ]

    {_doc, body} = refusal(ctx, T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => lines}))
    assert %{"reason" => "unit_not_valid", "line_no" => 2} = body

    lot_line = %{
      "catalog_item_id" => ctx.ma.item,
      "catalog_uom_id" => ctx.ma.uom,
      "catalog_lot_id" => ctx.m2.lot,
      "quantity" => "1"
    }

    {_doc, body} =
      refusal(ctx, T.body("hand_over", ctx.ma, ctx.ma, ctx.m2, %{"lines" => [lot_line]}))

    assert %{"reason" => "lot_not_valid", "line_no" => 1} = body

    # the two-sided kinds have no counterparty: the key is refused at save, so nothing to check at issue
    assert D.request(
             :post,
             "/documents",
             ctx.tok_a,
             T.body("return", ctx.ma, ctx.ma, ctx.m2, %{"counterparty_id" => ctx.ma.supplier})
           )
           |> Map.get(:status) == 422

    # the event-time window applies (fixed clock)
    {:ok, now, _} = DateTime.from_iso8601("2026-11-04T12:00:00Z")
    Application.put_env(:letflow, :stock_documents_clock, fn -> now end)
    old = DateTime.to_iso8601(DateTime.add(now, -96 * 3600 - 1, :second))

    {_doc, body} =
      refusal(ctx, T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"event_time" => old}))

    assert body["reason"] == "event_time_too_old"
    future = DateTime.to_iso8601(DateTime.add(now, 301, :second))

    {_doc, body} =
      refusal(ctx, T.body("return", ctx.ma, ctx.ma, ctx.m2, %{"event_time" => future}))

    assert body["reason"] == "event_time_in_future"
    edge = DateTime.to_iso8601(DateTime.add(now, -96 * 3600, :second))

    assert T.issue!(ctx, T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"event_time" => edge}))[
             "state"
           ] ==
             "issued"
  end
end
