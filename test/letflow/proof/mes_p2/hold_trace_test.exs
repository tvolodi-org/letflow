defmodule Letflow.Proof.MesP2.HoldTraceTest do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE: H1..H4 (quality hold and release of the finished lot) and T1..T6 (trace backward and
  forward) of the design, on the fixed scenario of section 5. `git rm -r test/support/mes_p2 test/letflow/proof/mes_p2`
  removes the proof.
  """

  use Letflow.DataCase, async: false

  import Letflow.Proof.MesP2.Scenario

  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP2.BatchStore
  alias Letflow.Proof.MesP2.Trace

  @moduletag timeout: 180_000

  setup do
    ctx = new_ctx()
    Map.merge(ctx, scenario(ctx))
  end

  # [{sku, lot, unit, "qty"}] sorted, quantities as normalized strings
  defp consumed(list),
    do: list |> Enum.map(&{&1.sku, &1.lot, &1.unit, norm(&1.quantity)}) |> Enum.sort()

  defp norm(d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  describe "hold and release of the finished lot" do
    test "H1 the finished lot is quarantine after produce; issue is refused, nothing written",
         ctx do
      assert LotStatus.get(ctx.schema, ctx.lf1) == "quarantine"
      before = entry_count(ctx)
      assert {:error, {:held, "lot-quarantine"}} = issue(ctx, ctx.f, ctx.lf1, "25")
      assert entry_count(ctx) == before
      assert on_hand(ctx, ctx.f, ctx.lf1) == "80"
    end

    test "H2 release, then the issue posts", ctx do
      assert :ok = LotStatus.set!(ctx.schema, ctx.lf1, "released")
      assert {:ok, _} = issue(ctx, ctx.f, ctx.lf1, "25")
      assert on_hand(ctx, ctx.f, ctx.lf1) == "55"
    end

    test "H3 consume of a quarantined raw lot is refused", ctx do
      :ok = LotStatus.set!(ctx.schema, ctx.la1, "quarantine")
      before = entry_count(ctx)

      assert {:error, {:held, "lot-quarantine"}} =
               BatchStore.consume(ctx.schema, ctx.b1, [c_line(ctx, ctx.a, ctx.la1, "1")])

      assert entry_count(ctx) == before
      :ok = LotStatus.set!(ctx.schema, ctx.la1, "released")
      assert {:ok, _} = BatchStore.consume(ctx.schema, ctx.b1, [c_line(ctx, ctx.a, ctx.la1, "1")])
    end

    test "H4 a rejected lot cannot be released and cannot be shipped", ctx do
      assert :ok = LotStatus.set!(ctx.schema, ctx.lf2, "rejected")
      assert {:error, :transition_not_allowed} = LotStatus.set!(ctx.schema, ctx.lf2, "released")
      assert LotStatus.get(ctx.schema, ctx.lf2) == "rejected"
      assert {:error, {:held, "lot-rejected"}} = issue(ctx, ctx.f, ctx.lf2, "1")
    end
  end

  describe "trace" do
    test "T1 backward: finished lot -> batch -> raw lots and receipts", ctx do
      assert %{batches: [b]} = Trace.backward(ctx.schema, ctx.f, ctx.lf1)
      assert %{batch_id: id1, number: "B-1"} = b
      assert id1 == ctx.b1

      assert consumed(b.consumed) ==
               Enum.sort([{ctx.a, ctx.la1, "kg", "50"}, {ctx.b, ctx.lb1, "kg", "30"}])

      assert Enum.sort_by(b.receipts, & &1.lot) ==
               Enum.sort_by(
                 [
                   %{sku: ctx.a, lot: ctx.la1, document_id: ctx.ra1},
                   %{sku: ctx.b, lot: ctx.lb1, document_id: ctx.rb1}
                 ],
                 & &1.lot
               )

      assert %{batches: [b2]} = Trace.backward(ctx.schema, ctx.f, ctx.lf2)
      assert b2.number == "B-2"

      assert consumed(b2.consumed) ==
               Enum.sort([{ctx.a, ctx.la2, "kg", "20"}, {ctx.b, ctx.lb1, "kg", "20"}])
    end

    test "T2 forward: raw lot LA1 -> batch 1 -> LF1, shipped 25", ctx do
      :ok = LotStatus.set!(ctx.schema, ctx.lf1, "released")
      {:ok, _} = issue(ctx, ctx.f, ctx.lf1, "25")

      assert %{batches: [%{number: "B-1", produced: [p]}]} =
               Trace.forward(ctx.schema, ctx.a, ctx.la1)

      assert %{sku: f, lot: lf1, unit: "kg"} = p
      assert {f, lf1} == {ctx.f, ctx.lf1}
      assert_dec(p.quantity, "80")
      assert_dec(p.shipped, "25")
      assert p.shipped_unit == "kg"
    end

    test "T3 forward: LB1 -> two batches, LF1 shipped 25 and LF2 shipped 0", ctx do
      :ok = LotStatus.set!(ctx.schema, ctx.lf1, "released")
      {:ok, _} = issue(ctx, ctx.f, ctx.lf1, "25")

      assert %{batches: [%{number: "B-1", produced: [p1]}, %{number: "B-2", produced: [p2]}]} =
               Trace.forward(ctx.schema, ctx.b, ctx.lb1)

      assert {p1.lot, p2.lot} == {ctx.lf1, ctx.lf2}
      assert_dec(p1.quantity, "80")
      assert_dec(p1.shipped, "25")
      assert_dec(p2.quantity, "40")
      assert_dec(p2.shipped, "0")
      assert on_hand(ctx, ctx.b, ctx.lb1) == "50"
    end

    test "T4 a transfer to a customer location counts as shipped", ctx do
      :ok = LotStatus.set!(ctx.schema, ctx.lf2, "released")
      {:ok, _} = issue(ctx, ctx.f, ctx.lf2, "5")
      {:ok, _} = customer_transfer(ctx, ctx.f, ctx.lf2, "10", id())
      # a plain plant transfer is not a shipment
      other = id()

      {:ok, _} =
        Letflow.Proof.MesP1.StockCopy.post(ctx.schema, %{
          cause: "transfer",
          lines: [
            %{
              line_id: id(),
              sku: ctx.f,
              lot: ctx.lf2,
              unit: "kg",
              quantity: "3",
              from: side(ctx),
              to: side(ctx, other)
            }
          ],
          document_type: "proof_transfer",
          document_id: id()
        })

      assert %{batches: [%{produced: [p]}]} = Trace.forward(ctx.schema, ctx.a, ctx.la2)
      assert_dec(p.shipped, "15")
    end

    test "T5 a reversed consume drops out of both traces; an unknown lot is empty", ctx do
      assert {:ok, _} = reversal(ctx, ctx.c2)

      assert %{batches: [%{number: "B-2", consumed: []}]} =
               Trace.backward(ctx.schema, ctx.f, ctx.lf2)

      assert %{batches: [%{number: "B-1"}]} = Trace.forward(ctx.schema, ctx.b, ctx.lb1)
      assert %{batches: []} = Trace.forward(ctx.schema, ctx.a, ctx.la2)
      assert %{batches: []} = Trace.backward(ctx.schema, ctx.f, id())
      assert %{batches: []} = Trace.forward(ctx.schema, id(), id())
    end

    test "T6 the trace is per tenant; a bad schema name raises", ctx do
      other = another_ctx()
      assert %{batches: []} = Trace.backward(other.schema, ctx.f, ctx.lf1)
      assert %{batches: []} = Trace.forward(other.schema, ctx.a, ctx.la1)
      assert %{batches: [_]} = Trace.backward(ctx.schema, ctx.f, ctx.lf1)

      for bad <- ["public", "tenant_x", ~s|x"; DROP TABLE y; --|] do
        assert_raise MatchError, fn -> Trace.backward(bad, ctx.f, ctx.lf1) end
      end
    end
  end
end
