Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindsPostingTest do
  @moduledoc """
  GH #3889 / REQ-753 (assets C11): posting and reversal of the change of responsible or user, the hand
  over and the write off, through the REAL HTTP path (rule D-098): a commission is created, issued
  and posted first; the new document is created and issued through the document routes, its `post`
  task is claimed and completed through `/api/v1/tasks/:id/claim` and `/complete` with a bearer
  token, and the balances, movements and marks are read back through the module read routes.
  Tests: P1 change, P2 hand over (the card org unit follows, G2), P3 write off, P4 low
  value quantities, P5 a from side without a balance, P6 and P7 reversal, P8 a reversal after the
  asset moved on, P9 double completion and double reverse, P10 authority, P11 the binding check,
  H1 and H2 the handler. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Assets.Handlers
  alias Letflow.Repo
  alias Letflow.Support.TokenMintFixture

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp one(rows), do: assert([row] = rows) && row

  defp qty(row), do: Decimal.new(row["quantity"])

  defp legs(ctx, id) do
    entry = D.movements(ctx, id) |> Enum.find(&(&1["cause"] != "reversal"))
    Enum.sort_by(entry["legs"], &Decimal.to_float(Decimal.new(&1["quantity"])))
  end

  defp leg_slots(leg),
    do: Map.take(leg, ~w(asset org_unit location material_responsible actual_user unit_ref))

  defp complete(ctx, id) do
    task = D.pending_task(ctx, id, "post") || flunk("no pending post task")
    D.claim_and_complete(task, ctx.tok_a)
  end

  test "P1 change: two legs, the balance moves to the new responsible and user", ctx do
    m = ctx.ma
    D.commission!(ctx)
    doc = D.issue!(ctx, D.change_body(m))
    assert doc["number"] =~ ~r/\AACH-\d{4}-000001\z/ and doc["kind"] == "change"
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}

    posted = D.run_task!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert is_binary(posted["posted_by"]) and is_binary(posted["entry_id"])
    assert D.counts(ctx, doc["id"]) == %{entries: %{"change" => 1}, marks: 1}

    assert [minus, plus] = legs(ctx, doc["id"])
    assert Decimal.equal?(Decimal.new(minus["quantity"]), -1)
    assert Decimal.equal?(Decimal.new(plus["quantity"]), 1)

    assert leg_slots(minus) == %{
             "asset" => m.fixed,
             "org_unit" => m.unit,
             "location" => m.location,
             "material_responsible" => m.employee,
             "actual_user" => m.employee2,
             "unit_ref" => "pcs"
           }

    assert leg_slots(plus)["material_responsible"] == m.employee2
    assert leg_slots(plus)["actual_user"] == m.employee

    row = one(D.balances(ctx, m.fixed))
    assert row["material_responsible"] == m.employee2 and row["actual_user"] == m.employee
    assert Decimal.equal?(qty(row), 1)
  end

  test "P2 hand over: two legs, the balance moves to the new unit and place", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    doc = D.issue!(ctx, D.handover_body(m, to))
    assert doc["number"] =~ ~r/\AAHO-/ and doc["to_org_unit_id"] == to.unit

    posted = D.run_task!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert D.counts(ctx, doc["id"]) == %{entries: %{"handover" => 1}, marks: 1}

    row = one(D.balances(ctx, m.fixed))

    assert {row["org_unit"], row["location"], row["material_responsible"], row["actual_user"]} ==
             {to.unit, to.location, to.employee, nil}

    # G2 (T-1489): the card follows the posted hand over in the same transaction
    card = Repo.get_by!(Letflow.Entities.Record.Latest, [record_id: m.fixed], prefix: ctx.schema)
    assert card.field_values["org_unit_id"] == to.unit
  end

  test "P3 write off: one negative leg with the reason, the balance is gone", ctx do
    m = ctx.ma
    D.commission!(ctx)
    doc = D.issue!(ctx, D.writeoff_body(m))
    assert doc["number"] =~ ~r/\AAWO-/ and doc["reason_code"] == "disposed"

    posted = D.run_task!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert D.counts(ctx, doc["id"]) == %{entries: %{"writeoff" => 1}, marks: 1}

    entry = D.movements(ctx, doc["id"]) |> one()
    assert entry["cause"] == "writeoff" and entry["reason_code"] == "disposed"
    assert [leg] = entry["legs"]
    assert Decimal.equal?(Decimal.new(leg["quantity"]), -1)
    assert D.balances(ctx, m.fixed) == []
  end

  test "P4 low value: a partial write off and a partial change split the balance", ctx do
    m = ctx.ma

    D.commission!(ctx, D.body(m, %{"lines" => [%{"asset_id" => m.low, "quantity" => "200"}]}))

    wo =
      D.issue!(
        ctx,
        D.writeoff_body(m, %{"lines" => [%{"asset_id" => m.low, "quantity" => "50"}]})
      )

    assert D.run_task!(ctx, wo["id"])["state"] == "posted"
    assert Decimal.equal?(qty(one(D.balances(ctx, m.low))), 150)

    ch =
      D.issue!(ctx, D.change_body(m, %{"lines" => [%{"asset_id" => m.low, "quantity" => "50"}]}))

    assert D.run_task!(ctx, ch["id"])["state"] == "posted"

    rows = D.balances(ctx, m.low)
    by = Map.new(rows, &{&1["material_responsible"], qty(&1)})
    assert map_size(by) == 2
    assert Decimal.equal?(by[m.employee], 100) and Decimal.equal?(by[m.employee2], 50)
  end

  test "P5 a from side without a balance is refused by the ledger at completion", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    # nothing was ever commissioned: issue succeeds, posting is refused
    for body <- [D.change_body(m), D.handover_body(m, to), D.writeoff_body(m)] do
      doc = D.issue!(ctx, body)
      assert doc["state"] == "issued"
      conn = complete(ctx, doc["id"])
      assert conn.status in [409, 422], conn.resp_body
      assert conn.resp_body =~ "insufficient_balance"
      assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
      assert D.get!(ctx, doc["id"])["state"] == "issued"
      assert D.pending_task(ctx, doc["id"], "post")
    end

    # a commissioned asset with another user does not match either
    D.commission!(ctx)
    doc = D.issue!(ctx, D.change_body(m, %{"from_actual_user_id" => m.employee}))
    assert complete(ctx, doc["id"]).status in [409, 422]
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "P6 reverse a change: the balance returns to the from key", ctx do
    m = ctx.ma
    D.commission!(ctx)
    doc = D.issue!(ctx, D.change_body(m))
    D.run_task!(ctx, doc["id"])

    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(200)

    reversed = D.run_task!(ctx, doc["id"], "reverse")
    assert reversed["state"] == "reversed" and reversed["posting_check"] == "ok"
    assert D.counts(ctx, doc["id"]) == %{entries: %{"change" => 1, "reversal" => 1}, marks: 2}

    reversal = D.movements(ctx, doc["id"]) |> Enum.find(&(&1["cause"] == "reversal"))
    assert length(reversal["legs"]) == 2

    row = one(D.balances(ctx, m.fixed))
    assert row["material_responsible"] == m.employee and row["actual_user"] == m.employee2
  end

  test "P7 reverse a hand over and a write off: the balances are restored", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)

    for body <- [D.handover_body(m, to), D.writeoff_body(m)] do
      doc = D.issue!(ctx, body)
      D.run_task!(ctx, doc["id"])

      D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
        "reason_code" => "wrong_document"
      })
      |> D.status!(200)

      assert D.run_task!(ctx, doc["id"], "reverse")["state"] == "reversed"
      row = one(D.balances(ctx, m.fixed))
      assert {row["org_unit"], row["material_responsible"]} == {m.unit, m.employee}
    end
  end

  test "P8 reversing the first change after a second one is refused by the core", ctx do
    m = ctx.ma
    D.commission!(ctx)
    first = D.issue!(ctx, D.change_body(m))
    D.run_task!(ctx, first["id"])

    second =
      D.issue!(
        ctx,
        D.change_body(m, %{
          "from_material_responsible_id" => m.employee2,
          "from_actual_user_id" => m.employee,
          "to_material_responsible_id" => m.employee,
          "to_actual_user_id" => m.employee2
        })
      )

    D.run_task!(ctx, second["id"])

    D.request(:post, "/documents/#{first["id"]}/reverse", ctx.tok_a, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(200)

    # the asset is back at the first key, so the reversal of the first change finds no balance at
    # the key it must take from: the observed answer is pinned
    task = D.pending_task(ctx, first["id"], "reverse")
    conn = D.claim_and_complete(task, ctx.tok_a)
    assert conn.status in [409, 422], conn.resp_body
    assert conn.resp_body =~ "insufficient_balance"
    assert D.counts(ctx, first["id"]).entries == %{"change" => 1}
    assert D.get!(ctx, first["id"])["state"] == "posted"
  end

  test "P9 a second completion and a second reverse keep the C10 answers", ctx do
    m = ctx.ma
    D.commission!(ctx)
    doc = D.issue!(ctx, D.change_body(m))
    task = D.pending_task(ctx, doc["id"], "post")
    assert D.claim_and_complete(task, ctx.tok_a).status == 200
    refute D.task_route(task, ctx.tok_a, "complete", ~s({"output_variables":{}})).status == 200
    assert D.counts(ctx, doc["id"]) == %{entries: %{"change" => 1}, marks: 1}

    body = %{"reason_code" => "wrong_document"}
    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, body) |> D.status!(200)

    assert D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, body)
           |> D.status!(409)
           |> Map.fetch!("reason") == "reversal_pending"

    D.run_task!(ctx, doc["id"], "reverse")

    assert D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, body)
           |> D.status!(409)
           |> Map.fetch!("reason") == "document_reversed"
  end

  test "P10 a task completed by a holder without AssetsPost writes nothing", ctx do
    m = ctx.ma
    D.commission!(ctx)
    doc = D.issue!(ctx, D.change_body(m))
    task = D.pending_task(ctx, doc["id"], "post")
    worker = worker_token(ctx)

    refute D.task_route(task, worker, "claim", "{}").status == 200 and
             D.task_route(task, worker, "complete", ~s({"output_variables":{}})).status == 200

    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert D.get!(ctx, doc["id"])["state"] == "issued"
  end

  defp worker_token(ctx),
    do: Letflow.AssetsRegisterFixture.token(ctx, :a, ["TASK_WORKER"], sub: "w-1")

  test "P11 a changed posting variable of a hand over posts but reads mismatch", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    doc = D.issue!(ctx, D.handover_body(m, to))
    task = D.pending_task(ctx, doc["id"], "post")
    instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)

    # the to side of the line points at the original place instead of the new one
    lines =
      List.update_at(instance.variables["posting"]["lines"], 0, fn line ->
        Map.put(line, "to", Map.put(line["to"], "location", to.location))
        |> then(fn l -> put_in(l, ["to", "org_unit"], to.unit) end)
        |> Map.put("quantity", "1")
        |> Map.put("from", Map.put(line["from"], "actual_user", nil))
      end)

    holder = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    output = %{"posting" => Map.put(instance.variables["posting"], "lines", lines)}

    result =
      Engine.complete_task(
        task.id,
        %{output_variables: output, actor_id: holder.id, idempotency_key: Ecto.UUID.generate()},
        prefix: ctx.schema,
        credential: :oidc
      )

    case result do
      {:ok, _} ->
        read = D.get!(ctx, doc["id"])
        assert read["state"] == "posted" and read["posting_check"] == "mismatch"

      {:error, _refused} ->
        # the ledger refused the changed from key: nothing is written
        assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end
  end

  describe "handler" do
    test "H1 an unknown cause and a two-leg cause without a from side are refused" do
      multi = Ecto.Multi.new()

      assert {:error, :invalid_arguments} =
               Handlers.post_document(multi, nil, %{"posting" => %{"cause" => "nope"}})

      assert {:error, :invalid_arguments} =
               Handlers.post_document(multi, nil, %{"posting" => %{}})

      args = %{
        "document_id" => Ecto.UUID.generate(),
        "document_type" => "assets_change",
        "version_no" => 1,
        "org_unit_id" => Ecto.UUID.generate(),
        "mark" => "posted",
        "posting" => %{"cause" => "change", "lines" => "not a list"}
      }

      assert {:error, :invalid_arguments} = Handlers.post_document(multi, nil, args)
    end

    test "H2 forged tenant keys in the posting variable are not copied", ctx do
      m = ctx.ma
      D.commission!(ctx)
      doc = D.issue!(ctx, D.change_body(m))
      task = D.pending_task(ctx, doc["id"], "post")
      instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)

      forged =
        Map.merge(instance.variables["posting"], %{
          "prefix" => ctx.b.schema_name,
          "subject_id" => Ecto.UUID.generate(),
          "credential" => "forged",
          "ledger_id" => "stock"
        })

      holder = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

      assert {:ok, _} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"posting" => forged},
                   actor_id: holder.id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 prefix: ctx.schema,
                 credential: :oidc
               )

      assert D.counts(ctx, doc["id"]) == %{entries: %{"change" => 1}, marks: 1}
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{ctx.b.schema_name}".ledger_entry|)
      assert n == 0
    end
  end
end
