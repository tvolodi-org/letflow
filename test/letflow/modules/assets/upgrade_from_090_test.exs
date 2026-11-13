Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.UpgradeFrom090Test do
  @moduledoc """
  T-1882 (PM D-139): a tenant that holds assets 0.9.0 (the pack kept as
  `test/fixtures/previous_packs/assets_0_9_0.json`) WITH asset cards, a posted commission document
  and its balances takes the upgrade to the current version, through the real tenant routes.

  The 0.9.0 -> 0.16.0 class B row (`assets_card` `field_changed`: `org_unit_id` loses `required`) is
  covered by the plan classifier rule `required_relaxed` (class A, no data step): the stored cards
  all hold the value and `required` is enforced by record validation only. A1..A3. Committed
  tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.TenantModule

  @old_hash String.duplicate("8", 64)
  @pack Path.expand("../../../fixtures/previous_packs/assets_0_9_0.json", __DIR__)

  setup do
    ctx = S.setup_oidc!([:a])
    a = S.tenant!("ast-up", ctx.names.a)
    schema = a.schema_name

    # The 0.9.0 shape goes in BEFORE any card exists (the strict depreciation decimals of the
    # current shape are not declared by 0.9.0).
    document = @pack |> File.read!() |> Jason.decode!()
    actor = Ecto.UUID.generate()
    owner = ManagedTypes.owner_for!(Letflow.Modules.Assets)

    {:ok, _} =
      SolutionPack.install_entity_definitions(
        document,
        ["assets_card"],
        actor,
        [prefix: schema],
        owner
      )

    {:ok, _} = Definitions.activate_definition("assets_card", actor, "T-1882 old shape", schema)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "assets"),
        [set: [version: "0.9.0", manifest_hash: @old_hash]],
        prefix: schema
      )

    Map.merge(ctx, %{
      a: a,
      schema: schema,
      ma: D.masters!(schema),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])
    })
  end

  defp post(path, tok, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> tok)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp plan(ctx) do
    conn = post("/api/v1/tenant/modules/assets/upgrade/plan", ctx.tok_a, %{})
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  test "A1 the card change is class A, no B or C row, the path is available", ctx do
    report = plan(ctx)
    assert report["from_version"] == "0.9.0"
    assert report["upgrade_path_available"] == true

    card = Enum.find(report["entity_types"], &(&1["name"] == "assets_card"))
    assert card["class"] == "A"
    refute Enum.any?(report["entity_types"], &(&1["class"] in ["B", "C"]))
  end

  @tag timeout: 120_000
  test "A2 pre-existing cards survive; documents and balances work on them afterwards", ctx do
    m = ctx.ma
    report = plan(ctx)

    # Only the card type changes (the opening types are already there on the test tenant, new on a real
    # 0.9.0 tenant: class A): no document, register or
    # balance type is touched by 0.9.0 -> current. (Documents and balances cannot be WRITTEN in the
    # 0.9.0 shape by the current code: its process definitions write the new card fields.)
    changed =
      for %{"change" => change, "name" => name} <- report["entity_types"],
          change != "unchanged",
          do: name

    assert changed == ["assets_card"]

    conn =
      post("/api/v1/tenant/modules/assets/upgrade", ctx.tok_a, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1882 assets 0.9.0 upgrade"
      })

    assert conn.status == 200, conn.resp_body

    row = Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.schema)
    {:ok, entry} = Letflow.Modules.Catalog.fetch("assets")
    assert row.version == entry.manifest().version
    assert plan(ctx)["up_to_date"] == true

    # The cards made in the old shape take a commission and show their balances.
    D.commission!(ctx)
    assert D.balances(ctx, m.fixed) != []
  end

  test "A3 after the upgrade a card without an org unit can be written (the new shape)", ctx do
    report = plan(ctx)

    conn =
      post("/api/v1/tenant/modules/assets/upgrade", ctx.tok_a, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1882 assets 0.9.0 upgrade"
      })

    assert conn.status == 200, conn.resp_body

    values = Cards.values("INV-NO-UNIT") |> Map.delete("org_unit_id")
    assert {:ok, _} = Cards.create(ctx.schema, values)
  end
end
