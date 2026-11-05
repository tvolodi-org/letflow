Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.TwoSideReversalTest do
  @moduledoc """
  REQ-721 / GH #3770 criterion 6: reversal and cancel of transfer, hand over and return restore both
  sides, and a reversal after the to side's quantity left is refused by the ledger. Committed tenant,
  Sandbox `:auto`, `async: false`. Tests: REV-1..5. REV-4 drains the to side with a second transfer, REV-5 with an issue document (REQ-715).
  """

  use Letflow.DataCase, async: false

  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  setup do
    ctx = P.setup!()
    Map.put(ctx, :m2, T.b2!(ctx))
  end

  defp qty(ctx, side), do: T.qty(ctx, side.location, side.employee)

  defp body(ctx, kind, from, to, quantity),
    do: T.body(kind, ctx.ma, from, to, %{"lines" => T.plain(ctx.ma, quantity)})

  defp reverse(ctx, id),
    do: P.req(ctx, :post, id, "reverse", %{"reason_code" => "wrong_document"})

  for {kind, n} <- [{"transfer", 1}, {"hand_over", 2}, {"return", 3}] do
    test "REV-#{n} #{kind}: post, reverse, cancel put both sides back", ctx do
      kind = unquote(kind)
      {from, to} = if kind == "return", do: {ctx.m2, ctx.ma}, else: {ctx.ma, ctx.m2}
      T.receive!(ctx, from, "10")
      before = {qty(ctx, from), qty(ctx, to)}

      doc = T.issue!(ctx, body(ctx, kind, from, to, "4"))
      P.post_and_complete!(ctx, doc["id"])
      assert {qty(ctx, from), qty(ctx, to)} == {"6", "4"}

      reverse(ctx, doc["id"]) |> P.status!(200)
      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "reverse"))
      read = P.get!(ctx, doc["id"])
      assert read["state"] == "reversed" and read["posting_check"] == "ok"
      assert {qty(ctx, from), qty(ctx, to)} == before
      assert P.counts(ctx, doc["id"]) == %{entries: %{kind => 1, "reversal" => 1}, marks: 2}

      cancelled = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"}) |> P.status!(200)
      assert cancelled["state"] == "cancelled" and cancelled["posting_check"] == "ok"
    end
  end

  test "REV-4 the to side's quantity left: the reversal is refused, nothing written, task pending",
       ctx do
    a = ctx.ma
    b = ctx.m2
    T.receive!(ctx, a, "10")
    first = T.issue!(ctx, body(ctx, "transfer", a, b, "4"))
    P.post_and_complete!(ctx, first["id"])

    # drain B with a second transfer out of B
    drain = T.issue!(ctx, body(ctx, "transfer", b, a, "4"))
    P.post_and_complete!(ctx, drain["id"])
    assert qty(ctx, b) == "0"

    reverse(ctx, first["id"]) |> P.status!(200)
    task = P.pending_task(ctx, first["id"], "reverse")
    assert {:error, _} = P.complete(ctx, task)

    assert P.counts(ctx, first["id"]) == %{entries: %{"transfer" => 1}, marks: 1}
    assert P.pending_task(ctx, first["id"], "reverse").id == task.id
    assert P.get!(ctx, first["id"])["state"] == "posted"
    assert qty(ctx, a) == "10"
  end

  test "REV-5 the to side issued out by an issue document: the reversal is refused", ctx do
    a = ctx.ma
    b = ctx.m2
    T.receive!(ctx, a, "10")
    first = T.issue!(ctx, body(ctx, "transfer", a, b, "4"))
    P.post_and_complete!(ctx, first["id"])

    out =
      b
      |> Map.put(:item, a.item)
      |> Map.put(:uom, a.uom)
      |> D.body(nil, %{
        "kind" => "issue",
        "org_unit_id" => b.unit,
        "location_id" => b.location,
        "responsible_id" => b.employee,
        "lines" => T.plain(a, "4")
      })
      |> Map.delete("counterparty_id")

    issued = P.issue!(ctx, out)
    P.post_and_complete!(ctx, issued["id"])
    assert qty(ctx, b) == "0"

    reverse(ctx, first["id"]) |> P.status!(200)
    task = P.pending_task(ctx, first["id"], "reverse")
    assert {:error, _} = P.complete(ctx, task)

    assert P.counts(ctx, first["id"]) == %{entries: %{"transfer" => 1}, marks: 1}
    assert P.pending_task(ctx, first["id"], "reverse").id == task.id
    assert P.get!(ctx, first["id"])["state"] == "posted"
    assert qty(ctx, a) == "6"
  end
end
