Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.TwoSidePostingTest do
  @moduledoc """
  REQ-721 / GH #3770 criteria 4 and 5: posting transfer, hand over and return from their post task (two
  legs per line, the cause of the kind), a scenario over the balances, the ledger refusal of a quantity
  the from side does not hold, and the binding check on read. Committed tenant, Sandbox `:auto`,
  `async: false`. Tests: POST-1..3, BIND-1, BIND-2.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  setup do
    ctx = P.setup!()
    Map.put(ctx, :m2, T.b2!(ctx))
  end

  defp q(text), do: Decimal.new(text)
  defp qty(ctx, side), do: T.qty(ctx, side.location, side.employee)

  defp plain_body(ctx, kind, from, to, quantity),
    do: T.body(kind, ctx.ma, from, to, %{"lines" => T.plain(ctx.ma, quantity)})

  test "POST-1 each kind posts one entry with two legs per line, the cause and the type of the kind",
       ctx do
    for kind <- T.kinds() do
      {from, to} = if kind == "return", do: {ctx.m2, ctx.ma}, else: {ctx.ma, ctx.m2}
      T.receive!(ctx, from, "10")

      body =
        T.body(kind, ctx.ma, from, to, %{
          "lines" => [
            %{
              "catalog_item_id" => ctx.ma.item,
              "catalog_uom_id" => ctx.ma.uom,
              "quantity" => "4"
            },
            %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
          ]
        })

      doc = T.issue!(ctx, body)
      posted = P.post_and_complete!(ctx, doc["id"])
      assert posted["state"] == "posted" and posted["posting_check"] == "ok"
      assert P.counts(ctx, doc["id"]) == %{entries: %{kind => 1}, marks: 1}

      [entry] = P.movements(ctx, doc["id"])
      spec = Kinds.get(kind)
      assert entry["cause"] == kind and entry["document_type"] == spec.type_key
      assert entry["document_id"] == doc["id"] and entry["entry_id"] == posted["entry_id"]
      {:ok, event, _} = DateTime.from_iso8601(entry["event_time"])
      {:ok, header, _} = DateTime.from_iso8601(doc["event_time"])
      assert abs(DateTime.diff(event, header, :second)) <= 1

      legs = Enum.sort_by(entry["legs"], & &1["leg_no"])
      assert length(legs) == 4

      line_ids = doc["lines"] |> Enum.sort_by(& &1["line_no"]) |> Enum.map(& &1["line_id"])

      for {line_id, [out, into]} <- Enum.zip(line_ids, Enum.chunk_every(legs, 2)) do
        assert out["document_line_id"] == line_id and into["document_line_id"] == line_id
        assert Decimal.negative?(q(out["quantity"])) and Decimal.positive?(q(into["quantity"]))
        assert Decimal.equal?(Decimal.negate(q(out["quantity"])), q(into["quantity"]))

        assert {out["location"], out["org_unit"], out["responsible"]} ==
                 {from.location, from.unit, from.employee}

        assert {into["location"], into["org_unit"], into["responsible"]} ==
                 {to.location, to.unit, to.employee}

        assert out["sku"] == ctx.ma.item and out["unit_ref"] == ctx.ma.uom
      end
    end
  end

  test "POST-2 scenario: receive, transfer, hand over, return move the balances", ctx do
    a = ctx.ma
    b = ctx.m2
    e = %{unit: b.unit, location: b.location, employee: a.employee}

    T.receive!(ctx, a, "10")
    assert qty(ctx, a) == "10"

    doc = T.issue!(ctx, plain_body(ctx, "transfer", a, b, "4"))
    P.post_and_complete!(ctx, doc["id"])
    assert {qty(ctx, a), qty(ctx, b)} == {"6", "4"}

    doc = T.issue!(ctx, plain_body(ctx, "hand_over", b, e, "3"))
    P.post_and_complete!(ctx, doc["id"])
    assert {qty(ctx, b), qty(ctx, e)} == {"1", "3"}

    doc = T.issue!(ctx, plain_body(ctx, "return", e, b, "2"))
    P.post_and_complete!(ctx, doc["id"])
    assert {qty(ctx, b), qty(ctx, e), qty(ctx, a)} == {"3", "1", "6"}
  end

  test "POST-3 more than the from side holds: insufficient_stock, nothing written, task pending",
       ctx do
    a = ctx.ma
    T.receive!(ctx, a, "6")

    for {kind, from, to, quantity} <- [
          {"transfer", a, ctx.m2, "7"},
          {"return", ctx.m2, a, "2"}
        ] do
      doc = T.issue!(ctx, plain_body(ctx, kind, from, to, quantity))
      task = P.pending_task(ctx, doc["id"], "post")
      assert {:error, _} = P.complete(ctx, task)

      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
      assert P.pending_task(ctx, doc["id"], "post").id == task.id
      assert P.get!(ctx, doc["id"])["state"] == "issued"
    end

    assert {qty(ctx, a), qty(ctx, ctx.m2)} == {"6", "0"}
  end

  test "BIND-1 a changed to side on the post task: posted + mismatch, no detail; untouched: ok",
       ctx do
    a = ctx.ma
    T.receive!(ctx, a, "10")

    clean = T.issue!(ctx, plain_body(ctx, "transfer", a, ctx.m2, "2"))
    assert P.post_and_complete!(ctx, clean["id"])["posting_check"] == "ok"

    doc = T.issue!(ctx, plain_body(ctx, "transfer", a, ctx.m2, "2"))
    task = P.pending_task(ctx, doc["id"], "post")

    instance =
      Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

    lines =
      List.update_at(instance.variables["posting"]["lines"], 0, fn line ->
        put_in(line, ["to", "location"], Ecto.UUID.generate())
      end)

    output = %{"posting" => Map.put(instance.variables["posting"], "lines", lines)}
    assert {:ok, _} = P.complete(ctx, task, output: output)
    read = P.get!(ctx, doc["id"])
    assert read["state"] == "posted" and read["posting_check"] == "mismatch"
    refute inspect(read) =~ "mismatch_detail"
  end

  test "BIND-2 a cancelled document is ok when each entry of the kind's cause is reversed", ctx do
    for kind <- T.kinds() do
      {from, to} = if kind == "return", do: {ctx.m2, ctx.ma}, else: {ctx.ma, ctx.m2}
      T.receive!(ctx, from, "3")
      doc = T.issue!(ctx, plain_body(ctx, kind, from, to, "2"))
      P.post_and_complete!(ctx, doc["id"])

      P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
      |> P.status!(200)

      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "reverse"))
      cancelled = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"}) |> P.status!(200)
      assert cancelled["state"] == "cancelled" and cancelled["posting_check"] == "ok"
    end
  end
end
