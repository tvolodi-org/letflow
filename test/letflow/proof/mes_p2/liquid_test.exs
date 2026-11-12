defmodule Letflow.Proof.MesP2.LiquidTest do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE: U1..U3 of the design, the liquid case. A tank is a location; the unit is per item
  (litres for one item, kg for another); one ledger key never changes unit. `git rm -r test/support/mes_p2
  test/letflow/proof/mes_p2` removes the proof.
  """

  use Letflow.DataCase, async: false

  import Letflow.Proof.MesP2.Scenario

  alias Letflow.Proof.MesP2.BatchStore

  @moduletag timeout: 120_000

  setup do
    ctx = new_ctx()
    Map.merge(ctx, %{tank: id(), liquid: id(), solid: id(), product: id()})
  end

  test "U1 litres and kg side by side at one tank location", ctx do
    {lot_l, lot_k} = {id(), id()}
    assert {:ok, _} = receipt(ctx, ctx.liquid, lot_l, "1000.5", unit: "l", location: ctx.tank)
    assert {:ok, _} = receipt(ctx, ctx.solid, lot_k, "20", unit: "kg", location: ctx.tank)
    assert on_hand(ctx, ctx.liquid, lot_l, ctx.tank) == "1000.5"
    assert on_hand(ctx, ctx.solid, lot_k, ctx.tank) == "20"
  end

  test "U2 a kg posting on a litre key is refused, nothing written", ctx do
    lot = id()
    assert {:ok, _} = receipt(ctx, ctx.liquid, lot, "100", unit: "l", location: ctx.tank)
    before = entry_count(ctx)

    assert {:error, {:ledger_refused, :unit_mismatch, _, _}} =
             receipt(ctx, ctx.liquid, lot, "5", unit: "kg", location: ctx.tank)

    assert entry_count(ctx) == before
    assert on_hand(ctx, ctx.liquid, lot, ctx.tank) == "100"
  end

  test "U3 a batch with a litre item and a kg item; the balance is never summed across units",
       ctx do
    {lot_l, lot_k, lot_p} = {id(), id(), id()}

    v =
      BatchStore.create_recipe(ctx.schema, "blend", 1, [
        %{role: "input", sku: ctx.liquid, unit: "l", quantity: "800"},
        %{role: "input", sku: ctx.solid, unit: "kg", quantity: "50"},
        %{role: "output", sku: ctx.product, unit: "l", quantity: "850"}
      ])

    :ok = BatchStore.approve(ctx.schema, v)
    {:ok, batch} = BatchStore.create_batch(ctx.schema, "BL-1", v)
    {:ok, _} = receipt(ctx, ctx.liquid, lot_l, "1000", unit: "l", location: ctx.tank)
    {:ok, _} = receipt(ctx, ctx.solid, lot_k, "60", unit: "kg", location: ctx.tank)

    before = entry_count(ctx)

    assert {:error, :not_in_recipe} =
             BatchStore.consume(ctx.schema, batch, [c_line(ctx, ctx.liquid, lot_l, "1", "kg")])

    assert entry_count(ctx) == before

    tank_side = side(ctx, ctx.tank)

    assert {:ok, _} =
             BatchStore.consume(ctx.schema, batch, [
               %{sku: ctx.liquid, lot: lot_l, unit: "l", quantity: "800", from: tank_side},
               %{sku: ctx.solid, lot: lot_k, unit: "kg", quantity: "50", from: tank_side}
             ])

    assert {:ok, _} =
             BatchStore.produce(ctx.schema, batch, %{
               sku: ctx.product,
               lot: lot_p,
               unit: "l",
               quantity: "845",
               to: tank_side
             })

    bal = BatchStore.balance(ctx.schema, batch)
    assert Map.keys(bal) |> Enum.sort() == ["kg", "l"]
    assert_dec(bal["l"].in, "800")
    assert_dec(bal["l"].out, "845")
    assert_dec(bal["kg"].in, "50")
    assert_dec(bal["kg"].out, "0")
    assert on_hand(ctx, ctx.liquid, lot_l, ctx.tank) == "200"
    assert on_hand(ctx, ctx.product, lot_p, ctx.tank) == "845"
  end
end
