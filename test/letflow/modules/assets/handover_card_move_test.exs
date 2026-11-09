Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.HandoverCardMoveTest do
  @moduledoc """
  T-1489 / G2 (owner decision D-111: one card is one org unit): a posted hand over moves the card's
  org unit in the SAME transaction as the ledger entry, its reversal restores it, through the REAL
  HTTP path (document routes, then the tasks routes with a bearer token).

  H1 move, H2 both-or-neither, H3 reversal restores, H4 tenant isolation, H5 scoped reader, H6 low
  value and intangible, H7 empty unit, H8 an old posting without `card_moves`, H9 the cap, H10 a
  hand over posted before this change, H11 forged `card_moves`. Committed tenants, Sandbox `:auto`,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Engine
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Assets.Documents.CardMoves
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.TokenMintFixture

  @moduletag timeout: 300_000

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp card(schema, id),
    do: Repo.get_by!(Latest, [record_id: id, entity_type: "assets_card"], prefix: schema)

  defp unit_of(ctx, id), do: card(ctx.schema, id).field_values["org_unit_id"]

  # Test-only raw write of the card's unit (a card moved by something else, or a legacy state).
  defp put_unit!(schema, id, unit) do
    values = card(schema, id).field_values

    values =
      if unit, do: Map.put(values, "org_unit_id", unit), else: Map.delete(values, "org_unit_id")

    {1, _} =
      Repo.update_all(
        from(l in Latest, where: l.record_id == ^id and l.entity_type == "assets_card"),
        [set: [field_values: values]],
        prefix: schema
      )

    :ok
  end

  defp reverse!(ctx, id) do
    D.request(:post, "/documents/#{id}/reverse", ctx.tok_a, %{"reason_code" => "wrong_document"})
    |> D.status!(200)

    D.run_task!(ctx, id, "reverse")
  end

  defp handover!(ctx, to, extra \\ %{}), do: D.issue!(ctx, D.handover_body(ctx.ma, to, extra))

  defp complete_with(ctx, doc, output) do
    task = D.pending_task(ctx, doc["id"], "post") || flunk("no pending post task")
    instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)
    holder = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    Engine.complete_task(
      task.id,
      %{
        output_variables: output.(instance.variables["posting"]),
        actor_id: holder.id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix: ctx.schema,
      credential: :oidc
    )
  end

  test "H1 a posted hand over moves the card; issuing alone does not", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    assert unit_of(ctx, m.fixed) == m.unit

    doc = handover!(ctx, to)
    assert unit_of(ctx, m.fixed) == m.unit

    posted = D.run_task!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert unit_of(ctx, m.fixed) == to.unit
    # the other cards of the tenant are untouched
    assert unit_of(ctx, m.fixed2) == m.unit

    update_events =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{ctx.schema}".events WHERE event_type = 'ENTITY_RECORD_UPDATED' AND payload::jsonb->>'record_id' = $1|,
        [m.fixed]
      )

    assert update_events.rows == [[1]]
  end

  test "H2 both or neither: a refused ledger entry leaves the card; a refused card leaves the ledger",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)

    # nothing commissioned: the ledger refuses at completion, the card is not moved
    doc = handover!(ctx, to)
    task = D.pending_task(ctx, doc["id"], "post")
    refute D.claim_and_complete(task, ctx.tok_a).status == 200
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert unit_of(ctx, m.fixed) == m.unit

    # commissioned, but the card was moved by someone else between issue and completion
    D.commission!(ctx)
    doc2 = handover!(ctx, to)
    other = D.unit!(ctx.schema)
    put_unit!(ctx.schema, m.fixed, other)
    task2 = D.pending_task(ctx, doc2["id"], "post")
    refute D.claim_and_complete(task2, ctx.tok_a).status == 200
    assert D.counts(ctx, doc2["id"]) == %{entries: %{}, marks: 0}
    assert unit_of(ctx, m.fixed) == other
    assert D.get!(ctx, doc2["id"])["state"] == "issued"
  end

  test "H3 the reversal moves the card back; a card moved on meanwhile is left", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    doc = D.run_task!(ctx, handover!(ctx, to)["id"])
    assert unit_of(ctx, m.fixed) == to.unit

    reversed = reverse!(ctx, doc["id"])
    assert reversed["state"] == "reversed"
    assert unit_of(ctx, m.fixed) == m.unit
    assert D.counts(ctx, doc["id"]).entries == %{"handover" => 1, "reversal" => 1}

    assert D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
             "reason_code" => "wrong_document"
           })
           |> D.status!(409)
           |> Map.fetch!("reason") == "document_reversed"

    # a second hand over of a fresh card, then the card is moved on by something else
    doc2 = D.run_task!(ctx, handover!(ctx, to)["id"])
    assert unit_of(ctx, m.fixed) == to.unit
    elsewhere = D.unit!(ctx.schema)
    put_unit!(ctx.schema, m.fixed, elsewhere)

    assert reverse!(ctx, doc2["id"])["state"] == "reversed"
    assert unit_of(ctx, m.fixed) == elsewhere
  end

  test "H4 tenant isolation: the other tenant's cards and documents are not touched", ctx do
    m = ctx.ma
    b = Map.merge(ctx, %{tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb})
    to = D.place!(ctx.schema)
    to_b = D.place!(b.schema)

    D.commission!(ctx)
    D.commission!(b)
    doc = D.run_task!(ctx, handover!(ctx, to)["id"])

    assert unit_of(ctx, m.fixed) == to.unit
    assert card(b.schema, ctx.mb.fixed).field_values["org_unit_id"] == ctx.mb.unit

    # tenant b cannot see or reverse tenant a's document: the uniform not found
    assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_b) |> D.status!(404)

    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_b, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(404)

    assert unit_of(ctx, m.fixed) == to.unit

    # tenant b's own hand over moves its card only
    D.run_task!(b, D.issue!(b, D.handover_body(ctx.mb, to_b))["id"])
    assert card(b.schema, ctx.mb.fixed).field_values["org_unit_id"] == to_b.unit
    assert unit_of(ctx, m.fixed) == to.unit
  end

  test "H5 a reader scoped to the old unit loses the card, the one scoped to the new unit gets it",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    schema = ctx.schema
    for id <- [m.unit, to.unit], do: ScopeNodePaths.write({:insert, id, nil}, schema)

    role = "TASK_WORKER"
    group = RSG.group_of!(schema, role)
    RSG.raw_delete_rows!(schema, group, role)

    holder = fn node ->
      user = TokenMintFixture.role_holder!(schema, [role])
      :ok = RSG.raw_user_row!(schema, user.id, role, node)
      user
    end

    fx = Map.merge(ctx.a, %{admin: nil})

    numbers = fn user ->
      conn =
        On.call(Letflow.Routers.Entities, :post, "/query", fx, user.id, [role], :on, %{
          "entity_type" => "assets_card"
        })

      assert conn.status == 200, conn.resp_body

      conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("items")
      |> Enum.map(& &1["record_id"])
    end

    at_old = holder.(m.unit)
    at_new = holder.(to.unit)
    assert m.fixed in numbers.(at_old)
    refute m.fixed in numbers.(at_new)

    D.commission!(ctx)
    D.run_task!(ctx, handover!(ctx, to)["id"])

    refute m.fixed in numbers.(at_old)
    assert m.fixed in numbers.(at_new)

    # a scoped principal cannot post through the module routes (the module admits tenant-wide
    # interactive principals only), so nothing is moved by one
    scoped_token = Letflow.AssetsRegisterFixture.token(ctx, :a, ["TASK_WORKER"], sub: "scoped-1")
    assert D.request(:post, "/documents", scoped_token, D.body(m)).status in [403, 404]
  end

  test "H6 an intangible card moves; a low value card keeps its unit (D-111, split is a follow-up)",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    one = fn id, q -> [%{"asset_id" => id, "quantity" => q}] end

    # an intangible asset sits in no location (`location_not_allowed`)
    body = D.body(m, %{"lines" => one.(m.intangible, "1")}) |> Map.delete("location_id")
    D.commission!(ctx, body)
    D.commission!(ctx, D.body(m, %{"lines" => one.(m.low, "200")}))

    hand = D.handover_body(m, to, %{"lines" => one.(m.intangible, "1")})
    doc = D.issue!(ctx, Map.drop(hand, ["from_location_id", "to_location_id"]))
    assert D.run_task!(ctx, doc["id"])["state"] == "posted"
    assert unit_of(ctx, m.intangible) == to.unit

    low = handover!(ctx, to, %{"lines" => one.(m.low, "50")})
    assert D.run_task!(ctx, low["id"])["state"] == "posted"
    assert unit_of(ctx, m.low) == m.unit
    assert reverse!(ctx, low["id"])["state"] == "reversed"
    assert unit_of(ctx, m.low) == m.unit
  end

  test "H7 a card with an empty unit gets the destination; the same unit generates no move",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    put_unit!(ctx.schema, m.fixed, nil)
    assert unit_of(ctx, m.fixed) == nil

    D.run_task!(ctx, handover!(ctx, to)["id"])
    assert unit_of(ctx, m.fixed) == to.unit

    header = %{"org_unit_id" => m.unit, "to_org_unit_id" => m.unit}
    assert CardMoves.forward(ctx.schema, header, [%{"asset_id" => m.fixed2}]) == {:ok, []}
    assert CardMoves.backward(ctx.schema, header, [%{"asset_id" => m.fixed2}]) == {:ok, []}
  end

  test "H8 a posting without card_moves (a document in flight before this change) moves nothing",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    doc = handover!(ctx, to)

    assert {:ok, _} =
             complete_with(ctx, doc, fn posting ->
               %{"posting" => Map.delete(posting, "card_moves")}
             end)

    assert D.get!(ctx, doc["id"])["state"] == "posted"
    assert unit_of(ctx, m.fixed) == m.unit
  end

  test "H9 the cap: 45 moved cards post, 46 are refused at issue and the draft stays a draft",
       ctx do
    schema = ctx.schema
    m = ctx.ma
    to = D.place!(schema)
    cards = for _ <- 1..46, do: D.card!(schema, "fixed", m.unit)
    lines = fn ids -> Enum.map(ids, &%{"asset_id" => &1, "quantity" => "1"}) end

    D.commission!(ctx, D.body(m, %{"lines" => lines.(cards)}))

    over = D.save!(ctx, D.handover_body(m, to, %{"lines" => lines.(cards)}))
    refused = D.request(:post, "/documents/#{over["id"]}/issue", ctx.tok_a) |> D.status!(422)
    assert refused["reason"] == "too_many_card_moves"
    assert D.get!(ctx, over["id"])["state"] == "draft"
    assert Enum.all?(cards, &(unit_of(ctx, &1) == m.unit))

    {first, _rest} = Enum.split(cards, 45)
    doc = D.issue!(ctx, D.handover_body(m, to, %{"lines" => lines.(first)}))
    assert D.run_task!(ctx, doc["id"])["state"] == "posted"
    assert Enum.all?(first, &(unit_of(ctx, &1) == to.unit))
    assert unit_of(ctx, List.last(cards)) == m.unit
  end

  test "H10 a hand over posted before this change (card never moved) reverses cleanly", ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    D.commission!(ctx)
    doc = D.run_task!(ctx, handover!(ctx, to)["id"])
    # the legacy state: the ledger moved, the card did not
    put_unit!(ctx.schema, m.fixed, m.unit)

    assert reverse!(ctx, doc["id"])["state"] == "reversed"
    assert unit_of(ctx, m.fixed) == m.unit
    assert D.counts(ctx, doc["id"]).entries == %{"handover" => 1, "reversal" => 1}
  end

  test "H11 a forged card_moves entry (a card outside the lines, a wrong destination) writes nothing",
       ctx do
    m = ctx.ma
    to = D.place!(ctx.schema)
    other = D.unit!(ctx.schema)
    D.commission!(ctx)
    doc = handover!(ctx, to)

    outsider = %{"asset" => m.fixed2, "from" => m.unit, "to" => to.unit}
    foreign = %{"asset" => ctx.mb.fixed, "from" => ctx.mb.unit, "to" => to.unit}
    wrong_to = %{"asset" => m.fixed, "from" => m.unit, "to" => other}

    for forged <- [[outsider], [foreign], [wrong_to], [outsider, wrong_to], "nope"] do
      result =
        complete_with(ctx, doc, fn posting ->
          %{"posting" => Map.put(posting, "card_moves", forged)}
        end)

      assert match?({:error, _}, result), inspect(forged)
      assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end

    assert unit_of(ctx, m.fixed) == m.unit
    assert unit_of(ctx, m.fixed2) == m.unit
    assert card(ctx.b.schema_name, ctx.mb.fixed).field_values["org_unit_id"] == ctx.mb.unit
    assert D.get!(ctx, doc["id"])["state"] == "issued"
  end
end
