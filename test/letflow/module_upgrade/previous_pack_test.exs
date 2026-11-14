Code.require_file("../modules/assets/assets_fixture.exs", __DIR__)

defmodule Letflow.ModuleUpgrade.PreviousPackTest do
  @moduledoc """
  T-1882 (PM D-139): a module version bump must be proven by an upgrade from the PREVIOUS released
  pack, through the real tenant routes. Each case below installs the current module on a committed
  tenant, puts the old entity shapes (the pack kept under `test/fixtures/previous_packs/`) in place of
  the current ones, sets the module row to the old version and runs `POST .../upgrade/plan` and
  `POST .../upgrade` as a tenant admin. The old shapes go in BEFORE any record is written, so the
  `decimal_strict` gate never sees records of a removed strict field.

  Limits (named, not hidden): only entity definitions are rolled back to the old shape; process
  definitions and settings stay current, so the plan shows entity-type changes only. Stock and
  locations hold no records in these cases (their writers need documents and masters); the records
  cases are catalog_items 0.3.0 (`upgrade_from_030_test.exs`) and assets 0.9.0
  (`assets/upgrade_from_090_test.exs`).

  `G1` is the guard: it pins, per module, the current version the upgrade tests were last run for.
  A version bump fails it until a new previous-pack case exists and the pin is moved. P1..P6 the
  cases, G1 the guard. `async: false` (committed tenants).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule

  @old_hash String.duplicate("9", 64)
  @dir Path.expand("../../fixtures/previous_packs", __DIR__)

  # The upgrade pairs with a test behind them: {module, old version, fixture, current version}.
  @pairs [
    {"catalog_items", "0.2.0", "catalog_items_0_2_0.json", "0.4.0"},
    {"locations", "0.4.0", "locations_0_4_0.json", "0.5.0"},
    {"stock", "0.10.0", "stock_0_10_0.json", "0.17.0"},
    {"stock", "0.14.0", "stock_0_14_0.json", "0.17.0"},
    {"codes", "0.3.0", "codes_0_3_0.json", "0.4.0"},
    {"org", "0.2.0", "org_0_2_0.json", "0.3.0"}
  ]

  # The current version each module's upgrade test was last run for (G1). A first release has no
  # previous pack and is pinned as such.
  @tested %{
    "assets" => "0.23.0",
    "catalog_items" => "0.4.0",
    "codes" => "0.4.0",
    "locations" => "0.5.0",
    "org" => "0.3.0",
    "stock" => "0.17.0",
    "exam" => "0.1.0",
    "mes_core" => "0.1.0",
    "procurement" => "0.1.0"
  }

  setup do
    fx = Letflow.AssetsFixture.installed_tenant!("t1882p")
    slug = Repo.get!(Identity.Tenant, fx.tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1882p-#{Ecto.UUID.generate()}",
        display_name: "T-1882 test user",
        email: "t1882p-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: fx.schema_name)

    {:ok, %{plaintext: tok}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: fx.schema_name
      )

    %{schema: fx.schema_name, tok: tok, slug: slug}
  end

  defp downgrade!(schema, module_id, version, fixture) do
    {:ok, entry} = Catalog.fetch(module_id)
    document = @dir |> Path.join(fixture) |> File.read!() |> Jason.decode!()
    owner = ManagedTypes.owner_for!(entry)
    actor = Ecto.UUID.generate()

    # A type whose old shape equals the active one has nothing to roll back (and the shape index
    # refuses a duplicate row).
    names =
      for %{"name" => name, "definition_json" => json} <- document["entity_definitions"],
          name in Map.get(entry.manifest(), :manages_entity_types, []),
          differs?(name, json, schema),
          do: name

    created =
      if names == [] do
        []
      else
        {:ok, created} =
          SolutionPack.install_entity_definitions(
            document,
            names,
            actor,
            [prefix: schema],
            owner
          )

        created
      end

    for name <- names, Enum.any?(created, &(&1.name == name)) do
      {:ok, _} = Definitions.activate_definition(name, actor, "T-1882 old shape", schema)
    end

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == ^module_id),
        [set: [version: version, manifest_hash: @old_hash]],
        prefix: schema
      )

    names
  end

  defp differs?(name, json, schema) do
    {:ok, active} = Definitions.get_active_definition_by_name(name, schema)
    OwnerStamp.graph_hash(active.definition_json) != OwnerStamp.graph_hash(json)
  end

  defp post_json(ctx, path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.tok)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp upgrade!(ctx, module_id) do
    plan = post_json(ctx, "/api/v1/tenant/modules/#{module_id}/upgrade/plan", %{})
    assert plan.status == 200, plan.resp_body
    report = Jason.decode!(plan.resp_body)
    assert report["upgrade_path_available"] == true
    refute report["up_to_date"]

    conn =
      post_json(ctx, "/api/v1/tenant/modules/#{module_id}/upgrade", %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1882 previous pack upgrade"
      })

    assert conn.status == 200, conn.resp_body
    report
  end

  for {{module_id, old, fixture, current}, i} <- Enum.with_index(@pairs, 1) do
    @tag timeout: 120_000
    test "P#{i} #{module_id} #{old} -> #{current} upgrades through the routes", ctx do
      module_id = unquote(module_id)
      _names = downgrade!(ctx.schema, module_id, unquote(old), unquote(fixture))
      report = upgrade!(ctx, module_id)
      assert report["from_version"] == unquote(old)
      assert report["to_version"] == unquote(current)

      m = Repo.get_by!(TenantModule, [module_id: module_id], prefix: ctx.schema)
      {:ok, entry} = Catalog.fetch(module_id)
      assert m.version == entry.manifest().version
      assert m.version == unquote(current)

      again = post_json(ctx, "/api/v1/tenant/modules/#{module_id}/upgrade/plan", %{})
      assert Jason.decode!(again.resp_body)["up_to_date"] == true
    end
  end

  test "G1 every module's current version is the one its upgrade test was last run for" do
    current =
      Catalog.all_manifests()
      |> Enum.reject(&String.starts_with?(&1.id, "fixture"))
      |> Map.new(&{&1.id, &1.version})
      |> Map.drop(["runtime_demo"])

    assert current == @tested,
           "a module version changed: add or refresh its previous-pack upgrade test " <>
             "(test/fixtures/previous_packs, PreviousPackTest and, where the module holds records, " <>
             "an upgrade test with real records), then move the pin. got #{inspect(current)}"

    for {module_id, _old, _fixture, version} <- @pairs do
      assert Map.fetch!(@tested, module_id) == version
    end
  end
end
