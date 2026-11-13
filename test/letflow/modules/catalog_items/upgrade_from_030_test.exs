Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.UpgradeFrom030Test do
  @moduledoc """
  T-1882: a tenant that holds catalog_items 0.3.0 (the pack before MES U1, kept as
  `test/fixtures/previous_packs/catalog_items_0_3_0.json`) WITH records takes the 0.4.0 upgrade. U1 adds three
  strict decimals to `catalog_item`; the `decimal_strict` activation gate used to refuse that with
  `activation_refused` as soon as the type had a record. U1..U2. Committed tenants, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.TenantModule

  @old_hash String.duplicate("7", 64)
  @pack Path.expand("../../../fixtures/previous_packs/catalog_items_0_3_0.json", __DIR__)

  setup do
    %{schema: schema, slug: slug, tenant_id: tenant_id} = Fx.installed_tenant!("t1882")
    actor = Ecto.UUID.generate()
    document = @pack |> File.read!() |> Jason.decode!()
    owner = ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)
    names = ["catalog_uom", "catalog_item"]

    # Put the 0.3.0 shapes in place of the current ones: new rows, activated in dependency order.
    {:ok, created} =
      SolutionPack.install_entity_definitions(document, names, actor, [prefix: schema], owner)

    for name <- names do
      assert Enum.any?(created, &(&1.name == name))
      {:ok, _} = Definitions.activate_definition(name, actor, "T-1882 old shape", schema)
    end

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "catalog_items"),
        [set: [version: "0.3.0", manifest_hash: @old_hash]],
        prefix: schema
      )

    uom = Fx.uom!(schema, "KG")
    Fx.item!(schema, "ITEM-1", uom.record_id)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1882-user-#{Ecto.UUID.generate()}",
        display_name: "T-1882 test user",
        email: "t1882-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: tok}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{schema: schema, tenant_id: tenant_id, user: %{plaintext: tok, slug: slug}}
  end

  defp post_json(path, user, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp plan!(user) do
    conn = post_json("/api/v1/tenant/modules/catalog_items/upgrade/plan", user, %{})
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp apply_upgrade(user, report) do
    post_json("/api/v1/tenant/modules/catalog_items/upgrade", user, %{
      "plan_hash" => report["plan_hash"],
      "rationale" => "T-1882 test: upgrade from 0.3.0"
    })
  end

  test "U1 0.3.0 with item and unit records upgrades to the current version", %{
    schema: schema,
    user: user
  } do
    report = plan!(user)
    assert report["from_version"] == "0.3.0"
    assert report["upgrade_path_available"] == true

    conn = apply_upgrade(user, report)
    assert conn.status == 200, conn.resp_body

    m = Repo.get_by!(TenantModule, [module_id: "catalog_items"], prefix: schema)
    {:ok, entry} = Letflow.Modules.Catalog.fetch("catalog_items")
    assert m.version == entry.manifest().version
    assert plan!(user)["up_to_date"] == true

    # The old records stay readable and the new optional field can now be written.
    {:ok, active} = Definitions.get_active_definition_by_name("catalog_item", schema)
    names = Enum.map(active.definition_json["fields"], & &1["name"])
    assert "density_kg_per_l" in names
  end

  test "U2 a refused activation is reported with the entity and a closed reason token" do
    alias Letflow.ModuleUpgrade.Apply

    assert Apply.refusal_extras("catalog_item", :decimal_strict_change) ==
             %{"entity" => "catalog_item", "reason" => "decimal_strict_change"}

    assert Apply.refusal_extras("x", {:persistence, %Ecto.Changeset{}}) ==
             %{"entity" => "x", "reason" => "persistence"}

    assert Apply.refusal_extras("x", "raw text") == %{"entity" => "x", "reason" => "unknown"}
  end

  test "U3 a refused activation answers 409 with error_code, entity and reason", %{
    schema: schema,
    user: user
  } do
    report = plan!(user)
    parent = self()
    once = :atomics.new(1, [])
    handler = "t1882-corrupt-#{System.unique_integer([:positive])}"

    # Deterministic: inside the upgrade transaction (same process), give the active catalog_item a NON-strict density_kg_per_l (the record exists), so the strict flip is refused.
    :telemetry.attach(
      handler,
      [:letflow, :repo, :query],
      fn _event, _m, %{query: query}, _config ->
        # The row lock on tenant_modules is the last read before the pack is applied.
        if self() == parent and String.contains?(query, "tenant_modules") and
             String.contains?(query, "FOR UPDATE") and :atomics.add_get(once, 1, 1) == 1 do
          Repo.query!(
            "UPDATE \"#{schema}\".entity_definitions SET definition_json = jsonb_set(definition_json, '{fields}', " <>
              "definition_json->'fields' || '[{\"name\":\"density_kg_per_l\",\"type\":\"decimal\"," <>
              "\"decimal_precision\":12,\"decimal_scale\":4}]'::jsonb) " <>
              "WHERE name = 'catalog_item' AND status = 'active'"
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = apply_upgrade(user, report)
    :telemetry.detach(handler)
    assert conn.status == 409, conn.resp_body
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "upgrade_failed"
    assert body["error_code"] == "activation_refused"
    assert body["entity"] == "catalog_item"
    assert body["reason"] == "decimal_strict_change"
  end
end
