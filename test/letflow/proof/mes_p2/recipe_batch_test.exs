defmodule Letflow.Proof.MesP2.RecipeBatchTest do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE: R1..R3 and B0..B4 of the design (recipe version, batch record, consume, produce).
  `git rm -r test/support/mes_p2 test/letflow/proof/mes_p2` removes the proof.
  """

  use Letflow.DataCase, async: false

  import Letflow.Proof.MesP2.Scenario

  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP2.BatchStore

  setup do
    ctx = new_ctx()
    [a, b, f] = [id(), id(), id()]

    v =
      BatchStore.create_recipe(ctx.schema, "R", 1, [
        %{role: "input", sku: a, unit: "kg", quantity: "60"},
        %{role: "input", sku: b, unit: "l", quantity: "40.5"},
        %{role: "output", sku: f, unit: "kg", quantity: "100"}
      ])

    Map.merge(ctx, %{a: a, b: b, f: f, v: v})
  end

  describe "recipe version" do
    test "R1 lines with a unit per item are stored and read back", ctx do
      lines = BatchStore.recipe_lines(ctx.schema, ctx.v)
      assert length(lines) == 3
      units = Map.new(lines, &{&1.sku, &1.unit})
      assert units == %{ctx.a => "kg", ctx.b => "l", ctx.f => "kg"}
      q = Enum.find(lines, &(&1.sku == ctx.b)).quantity
      assert_dec(q, "40.5")
    end

    test "R2 an approved version is frozen; a change is a new version", ctx do
      :ok = BatchStore.approve(ctx.schema, ctx.v)
      n = BatchStore.recipe_line_count(ctx.schema)

      assert_raise Postgrex.Error, ~r/frozen/, fn ->
        BatchStore.insert_line!(ctx.schema, ctx.v, %{
          role: "input",
          sku: id(),
          unit: "kg",
          quantity: "1"
        })
      end

      for sql <- [
            ~s|UPDATE "#{ctx.schema}".proof_recipe_line SET quantity = 1|,
            ~s|DELETE FROM "#{ctx.schema}".proof_recipe_line|
          ] do
        assert_raise Postgrex.Error, ~r/frozen/, fn -> Letflow.Repo.query!(sql) end
      end

      assert BatchStore.recipe_line_count(ctx.schema) == n

      v2 =
        BatchStore.create_recipe(ctx.schema, "R", 2, [
          %{role: "input", sku: ctx.a, unit: "kg", quantity: "70"},
          %{role: "output", sku: ctx.f, unit: "kg", quantity: "70"}
        ])

      assert length(BatchStore.recipe_lines(ctx.schema, v2)) == 2
      assert length(BatchStore.recipe_lines(ctx.schema, ctx.v)) == 3
    end

    test "R3 a batch on a draft or retired version is refused", ctx do
      assert {:error, :version_not_approved} = BatchStore.create_batch(ctx.schema, "X-1", ctx.v)
      :ok = BatchStore.approve(ctx.schema, ctx.v)
      assert {:ok, _} = BatchStore.create_batch(ctx.schema, "X-2", ctx.v)
      :ok = BatchStore.retire(ctx.schema, ctx.v)
      assert {:error, :version_not_approved} = BatchStore.create_batch(ctx.schema, "X-3", ctx.v)
    end
  end

  describe "batch" do
    setup ctx do
      :ok = BatchStore.approve(ctx.schema, ctx.v)
      {:ok, batch} = BatchStore.create_batch(ctx.schema, "B-1", ctx.v)
      Map.put(ctx, :batch, batch)
    end

    test "B0 the batch row carries the recipe version and a status", ctx do
      assert %{number: "B-1", recipe_version_id: v, status: "running"} =
               BatchStore.get_batch(ctx.schema, ctx.batch)

      assert v == ctx.v
    end

    @tag timeout: 120_000
    test "B1 two raw lots consumed, in one call and in two calls", ctx do
      [la1, la2, lb1] = [id(), id(), id()]
      {:ok, _} = receipt(ctx, ctx.a, la1, "100")
      {:ok, _} = receipt(ctx, ctx.a, la2, "100")
      {:ok, _} = receipt(ctx, ctx.b, lb1, "100", unit: "l")

      assert {:ok, %{entry_id: e1}} =
               BatchStore.consume(ctx.schema, ctx.batch, [
                 c_line(ctx, ctx.a, la1, "50"),
                 c_line(ctx, ctx.b, lb1, "30", "l")
               ])

      assert {:ok, %{entry_id: e2}} =
               BatchStore.consume(ctx.schema, ctx.batch, [c_line(ctx, ctx.a, la2, "20")])

      assert on_hand(ctx, ctx.a, la1) == "50"
      assert on_hand(ctx, ctx.b, lb1) == "70"
      assert on_hand(ctx, ctx.a, la2) == "80"
      for e <- [e1, e2], do: assert(entry_column(ctx, e, "related_document_id") == ctx.batch)
      assert entry_column(ctx, e1, "cause") == "consume"
    end

    test "B2 an item or unit not in the recipe is refused, nothing posted", ctx do
      [la1, other] = [id(), id()]
      {:ok, _} = receipt(ctx, ctx.a, la1, "100")
      {:ok, _} = receipt(ctx, other, la1, "10")
      before = entry_count(ctx)

      assert {:error, :not_in_recipe} =
               BatchStore.consume(ctx.schema, ctx.batch, [c_line(ctx, other, la1, "1")])

      assert {:error, :not_in_recipe} =
               BatchStore.consume(ctx.schema, ctx.batch, [c_line(ctx, ctx.a, la1, "1", "l")])

      assert entry_count(ctx) == before
      assert on_hand(ctx, ctx.a, la1) == "100"
    end

    test "B3 consume or produce after finish is refused", ctx do
      la1 = id()
      {:ok, _} = receipt(ctx, ctx.a, la1, "100")
      :ok = BatchStore.finish(ctx.schema, ctx.batch)
      before = entry_count(ctx)

      assert {:error, :batch_finished} =
               BatchStore.consume(ctx.schema, ctx.batch, [c_line(ctx, ctx.a, la1, "5")])

      assert {:error, :batch_finished} =
               BatchStore.produce(ctx.schema, ctx.batch, p_line(ctx, ctx.f, id(), "5"))

      assert entry_count(ctx) == before
    end

    test "B4 produce one finished lot; an item not in the recipe output is refused", ctx do
      lf = id()

      assert {:ok, %{entry_id: e}} =
               BatchStore.produce(ctx.schema, ctx.batch, p_line(ctx, ctx.f, lf, "80"))

      assert on_hand(ctx, ctx.f, lf) == "80"
      assert entry_column(ctx, e, "cause") == "produce"
      assert entry_column(ctx, e, "related_document_id") == ctx.batch
      assert LotStatus.get(ctx.schema, lf) == "quarantine"

      before = entry_count(ctx)
      lx = id()
      # an input item is not an output item
      assert {:error, :not_in_recipe} =
               BatchStore.produce(ctx.schema, ctx.batch, p_line(ctx, ctx.a, lx, "1"))

      assert entry_count(ctx) == before
      assert LotStatus.get(ctx.schema, lx) == nil
    end
  end
end
