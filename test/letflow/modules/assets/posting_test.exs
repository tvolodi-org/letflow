Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.PostingTest do
  @moduledoc """
  GH #3890 / REQ-752 (assets C10): lazy activation and the posting of an issued commission from its
  human task, through the REAL HTTP path (rule D-098): the document is created and issued through the
  document routes, the `post` task is claimed and completed through `/api/v1/tasks/:id/claim` and
  `/complete` with a bearer token, and the ledger, the mark and the document read are checked.
  Tests: P1 the whole path, P2 post twice, P3 quantities and optional slots with real database types,
  P4 refusals (state and authority), P5 a lost start, P6 the binding check, T2 a foreign tenant.
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp definition(ctx, name),
    do: Repo.one!(from(d in ProcessDefinition, where: d.name == ^name), prefix: ctx.schema)

  defp line(asset, quantity), do: %{"asset_id" => asset, "quantity" => quantity}

  test "lazy activation: the first issue activates assets_commission and starts one instance",
       ctx do
    assert definition(ctx, "assets_commission").status == :draft
    doc = D.issue!(ctx)

    row = definition(ctx, "assets_commission")
    assert row.status == :active and row.owner_module == "assets"
    assert %{node_id: "post"} = D.pending_task(ctx, doc["id"], "post")
    # the reversal definition is activated by the reverse route only
    assert definition(ctx, "assets_reversal").status == :draft

    instances =
      Repo.aggregate(
        from(p in InstanceProjection,
          where: fragment("?->>'document_id' = ?", p.variables, ^doc["id"])
        ),
        :count,
        prefix: ctx.schema
      )

    assert instances == 1
  end

  test "an activator that cannot activate: 409 before a number is taken", ctx do
    doc = D.save!(ctx)
    actor = Ecto.UUID.generate()
    no_perm = %{permissions: [], entities_records_write?: true, user_id: actor, roles: []}

    for activator <- [nil, no_perm] do
      assert {:error, :definition_not_active} =
               Letflow.Modules.Assets.Documents.issue(ctx.schema, doc["id"], actor,
                 activator: activator
               )
    end

    assert D.get!(ctx, doc["id"])["state"] == "draft"
    assert definition(ctx, "assets_commission").status == :draft
    assert D.issue!(ctx, D.body(ctx.ma))["number"] =~ "-000001"
  end

  test "P1 D-098: create, issue, claim and complete over HTTP; the ledger, the mark, the read",
       ctx do
    m = ctx.ma
    doc = D.issue!(ctx)
    id = doc["id"]
    assert doc["state"] == "issued" and doc["posting_check"] == nil
    assert D.counts(ctx, id) == %{entries: %{}, marks: 0}

    posted = D.run_task!(ctx, id)

    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert is_binary(posted["posted_at"]) and is_binary(posted["entry_id"])
    assert is_binary(posted["posted_by"])
    assert D.counts(ctx, id) == %{entries: %{"commission" => 1}, marks: 1}

    [entry] = D.movements(ctx, id)
    assert entry["cause"] == "commission"
    assert entry["document_type"] == "assets_commission" and entry["document_id"] == id
    assert entry["entry_id"] == posted["entry_id"]

    # the entry event time is the header's, not the posting time (offline triple)
    {:ok, event, _} = DateTime.from_iso8601(entry["event_time"])
    {:ok, header, _} = DateTime.from_iso8601(doc["event_time"])
    assert abs(DateTime.diff(event, header, :second)) <= 1

    assert [leg] = entry["legs"]

    assert %{
             "asset" => m.fixed,
             "org_unit" => m.unit,
             "location" => m.location,
             "material_responsible" => m.employee,
             "actual_user" => m.employee2,
             "unit_ref" => "pcs"
           } ==
             Map.take(leg, ~w(asset org_unit location material_responsible actual_user unit_ref))

    assert Decimal.equal?(Decimal.new(leg["quantity"]), 1)
    assert leg["document_line_id"] == doc["lines"] |> hd() |> Map.fetch!("line_id")

    balances = Letflow.AssetsRegisterFixture.get("/balances", ctx.tok_a) |> D.status!(200)
    assert [row] = Enum.filter(balances["rows"], &(&1["asset"] == m.fixed))
    assert Decimal.equal?(Decimal.new(row["quantity"]), 1)

    # the list shows the derived state
    list = D.request(:get, "/documents?state=posted", ctx.tok_a) |> D.status!(200)
    assert Enum.map(list["rows"], & &1["id"]) == [id]
  end

  test "C3 a holderless card posts over HTTP; the register carries its holder (T-1488)", ctx do
    m = ctx.ma

    {:ok, card} =
      Letflow.Modules.Assets.Cards.create_card(
        ctx.schema,
        %{
          "inventory_number" => "C3-#{System.unique_integer([:positive])}",
          "name" => "C3",
          "kind" => "fixed"
        },
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    doc = D.issue!(ctx, D.body(m, %{"lines" => [line(card["record_id"], "1")]}))
    posted = D.run_task!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"

    balances =
      Letflow.AssetsRegisterFixture.get("/balances?asset=#{card["record_id"]}", ctx.tok_a)
      |> D.status!(200)

    assert [row] = balances["rows"]
    assert row["org_unit"] == m.unit and row["asset"] == card["record_id"]
  end

  test "P2 post twice: a second completion is refused; one entry, one mark", ctx do
    doc = D.issue!(ctx)
    id = doc["id"]
    first = D.pending_task(ctx, id, "post")
    instance = Repo.get!(InstanceProjection, first.instance_id, prefix: ctx.schema)

    assert D.claim_and_complete(first, ctx.tok_a).status == 200

    {:ok, _} =
      Engine.create(
        %{
          definition_name: "assets_commission",
          initial_variables: instance.variables,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "generic-dup-#{Ecto.UUID.generate()}"
        },
        prefix: ctx.schema
      )

    second = D.pending_task(ctx, id, "post")
    assert second.id != first.id

    conn = D.claim_and_complete(second, ctx.tok_a)
    # the unique mark rule: a typed 4xx, never a 500 (INV-8)
    assert conn.status == 422
    assert D.counts(ctx, id) == %{entries: %{"commission" => 1}, marks: 1}
    assert D.get!(ctx, id)["posting_check"] == "ok"
  end

  test "P3 low value in two documents sums; an intangible without location and user posts", ctx do
    m = ctx.ma

    for qty <- ["150", "50"] do
      doc = D.issue!(ctx, D.body(m, %{"lines" => [line(m.low, qty)]}))
      assert D.run_task!(ctx, doc["id"])["state"] == "posted"
    end

    balances = Letflow.AssetsRegisterFixture.get("/balances", ctx.tok_a) |> D.status!(200)
    rows = Enum.filter(balances["rows"], &(&1["asset"] == m.low))

    total =
      rows
      |> Enum.map(&Decimal.new(&1["quantity"]))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    assert Decimal.equal?(total, 200)

    bare =
      D.body(m, %{
        "location_id" => "",
        "actual_user_id" => "",
        "lines" => [line(m.intangible, "1")]
      })

    posted = D.run_task!(ctx, D.issue!(ctx, bare)["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
  end

  test "P4 refusals: an unauthorised completer writes no entry and no mark", ctx do
    doc = D.issue!(ctx)
    id = doc["id"]
    task = D.pending_task(ctx, id, "post")
    worker = TokenMintFixture.role_holder!(ctx.schema, ["TASK_WORKER"])

    result =
      Engine.complete_task(
        task.id,
        %{output_variables: %{}, actor_id: worker.id, idempotency_key: Ecto.UUID.generate()},
        prefix: ctx.schema,
        credential: :oidc
      )

    assert {:error, _refusal} = result
    assert D.counts(ctx, id) == %{entries: %{}, marks: 0}
    assert D.get!(ctx, id)["state"] == "issued"

    # reversing a draft and an issued (not posted) document is 409 document_not_posted
    draft = D.save!(ctx, D.body(ctx.ma, %{"lines" => [line(ctx.ma.low, "1")]}))

    for target <- [draft["id"], id] do
      conn =
        D.request(:post, "/documents/#{target}/reverse", ctx.tok_a, %{
          "reason_code" => "wrong_document"
        })

      assert D.status!(conn, 409)["reason"] == "document_not_posted"
    end
  end

  test "P5 a lost start after issue leaves an issued document with no instance", ctx do
    Application.put_env(:letflow, :assets_post_start_fail?, true)
    doc = D.issue!(ctx)

    assert doc["state"] == "issued" and doc["posting_check"] == nil and is_binary(doc["number"])
    assert D.pending_task(ctx, doc["id"], "post") == nil
  end

  test "P6 a changed posting variable still completes but reads posting_check mismatch", ctx do
    doc = D.issue!(ctx, D.body(ctx.ma, %{"lines" => [line(ctx.ma.low, "5")]}))
    id = doc["id"]
    task = D.pending_task(ctx, id, "post")
    instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)

    lines =
      List.update_at(instance.variables["posting"]["lines"], 0, &Map.put(&1, "quantity", "3"))

    output = %{"posting" => Map.put(instance.variables["posting"], "lines", lines)}

    holder = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: holder.id,
                 idempotency_key: Ecto.UUID.generate()
               },
               prefix: ctx.schema,
               credential: :oidc
             )

    read = D.get!(ctx, id)
    assert read["state"] == "posted" and read["posting_check"] == "mismatch"
    refute inspect(read) =~ "mismatch_detail"
  end

  test "T2 tenant B cannot reverse tenant A's posted document", ctx do
    doc = D.issue!(ctx)
    posted = D.run_task!(ctx, doc["id"])

    conn =
      D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_b, %{
        "reason_code" => "wrong_document"
      })

    D.status!(conn, 404)
    assert D.get!(ctx, doc["id"]) == posted
    assert D.counts(ctx, doc["id"]) == %{entries: %{"commission" => 1}, marks: 1}
  end
end
