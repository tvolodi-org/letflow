Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.DefaultLocationTest do
  @moduledoc """
  Qoimeks parity G3 (catalog_items 0.5.0): the one optional `default_location_id` of a `catalog_item`
  (the usual place), written by the real import route with the place given by external id, and read back
  through `CatalogItems.lookup/2`. DL1..DL6. No second place, no list of places.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Installs

  @schema_version "entities/record-export/v1"

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    for id <- ["org", "locations"] do
      {:ok, _} =
        Installs.install(id, Ecto.UUID.generate(),
          prefix: schema,
          rationale: "test: G3 default location"
        )
    end

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "g3-user-#{Ecto.UUID.generate()}",
        display_name: "G3 test user",
        email: "g3-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{schema: schema, slug: slug, plaintext: plaintext}
  end

  defp upsert(ctx, type, records) do
    body = %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => records,
      "upsert_by" => "external_ref"
    }

    conn(:post, "/api/v1/entities/records/#{type}/import", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp ref(id), do: %{"system" => "erp", "id" => id}

  defp row(id, values),
    do: %{"external_ref" => ref(id), "field_values" => values}

  defp item_row(id, extra \\ %{}),
    do:
      row(
        id,
        Map.merge(
          %{
            "code" => id,
            "name" => "Item #{id}",
            "base_uom_id" => "U1",
            "kind" => "material",
            "active" => true
          },
          extra
        )
      )

  defp result(conn), do: hd(Jason.decode!(conn.resp_body)["results"])

  defp stored(schema, "location_node", id) do
    {:ok, %{"record_id" => rid} = fv} =
      Letflow.Modules.ReadApi.lookup_by_external_ref(schema, "location_node", "erp", id, [
        "location_node"
      ])

    {rid, fv}
  end

  defp stored(schema, type, id) do
    {:ok, %Latest{field_values: fv, record_id: rid}} =
      Latest.get_by_external_ref(type, "erp", id, schema)

    {rid, fv}
  end

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  defp place(id, extra \\ %{}),
    do:
      row(
        id,
        Map.merge(
          %{
            "code" => id,
            "name" => "Place #{id}",
            "node_kind" => "location",
            "external_ref_system" => "erp",
            "external_ref_id" => id
          },
          extra
        )
      )

  defp masters!(ctx) do
    assert result(
             upsert(ctx, "catalog_uom", [
               row("U1", %{"code" => "U1", "name" => "U1", "active" => true})
             ])
           )[
             "outcome"
           ] == "created"

    for id <- ["P1", "P2"] do
      assert result(upsert(ctx, "location_node", [place(id)]))["outcome"] == "created"
    end
  end

  test "DL1: the usual place is given by external id and stored as the record id of the place" do
    ctx = tenant_ctx("g3-dl1")
    masters!(ctx)
    {place, _} = stored(ctx.schema, "location_node", "P1")

    r = result(upsert(ctx, "catalog_item", [item_row("I1", %{"default_location_id" => "P1"})]))
    assert r["outcome"] == "created"

    {rid, fv} = stored(ctx.schema, "catalog_item", "I1")
    assert fv["default_location_id"] == place
    # read: the card's data source returns it
    assert {:ok, %{"default_location_id" => ^place}} = CatalogItems.lookup(ctx.schema, rid)
  end

  test "DL2: an unknown place is a per-row error and nothing of the row is written" do
    ctx = tenant_ctx("g3-dl2")
    masters!(ctx)
    before = count(ctx.schema, "catalog_item")

    r = result(upsert(ctx, "catalog_item", [item_row("I2", %{"default_location_id" => "NOPE"})]))
    refute r["outcome"] in ["created", "updated", "unchanged"]
    assert inspect(r) =~ "reference_not_found"
    assert inspect(r) =~ "default_location_id"
    assert count(ctx.schema, "catalog_item") == before
  end

  test "DL3: a retired place is refused as inactive; a record id is not an external id" do
    ctx = tenant_ctx("g3-dl3")
    masters!(ctx)
    {pid, _} = stored(ctx.schema, "location_node", "P2")

    assert result(upsert(ctx, "location_node", [place("P3")]))["outcome"] == "created"
    {p3, _} = stored(ctx.schema, "location_node", "P3")

    opts = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
    assert {:ok, _} = Letflow.Modules.Locations.Tree.retire_node(ctx.schema, p3, opts)

    r = result(upsert(ctx, "catalog_item", [item_row("I3", %{"default_location_id" => "P3"})]))
    assert inspect(r) =~ "reference_inactive"

    r = result(upsert(ctx, "catalog_item", [item_row("I3", %{"default_location_id" => pid})]))
    assert inspect(r) =~ "reference_not_found"
    assert count(ctx.schema, "catalog_item") == 0
  end

  test "DL4: a re-import with the place changes it; with the column blank it clears it" do
    ctx = tenant_ctx("g3-dl4")
    masters!(ctx)
    {p1, _} = stored(ctx.schema, "location_node", "P1")
    {p2, _} = stored(ctx.schema, "location_node", "P2")

    upsert(ctx, "catalog_item", [item_row("I4", %{"default_location_id" => "P1"})])
    assert {_, %{"default_location_id" => ^p1}} = stored(ctx.schema, "catalog_item", "I4")

    r = result(upsert(ctx, "catalog_item", [item_row("I4", %{"default_location_id" => "P2"})]))
    assert r["outcome"] == "updated"
    assert {_, %{"default_location_id" => ^p2}} = stored(ctx.schema, "catalog_item", "I4")

    # a re-import replaces the whole row, as for every other field: the file is the truth
    r = result(upsert(ctx, "catalog_item", [item_row("I4")]))
    assert r["outcome"] == "updated"
    {_, fv} = stored(ctx.schema, "catalog_item", "I4")
    refute Map.has_key?(fv, "default_location_id")
  end

  test "DL5: an item without a place is still valid; the definition holds one single string field" do
    ctx = tenant_ctx("g3-dl5")
    masters!(ctx)
    assert result(upsert(ctx, "catalog_item", [item_row("I5")]))["outcome"] == "created"
    {_, fv} = stored(ctx.schema, "catalog_item", "I5")
    refute Map.has_key?(fv, "default_location_id")

    def =
      "priv/modules/catalog_items/entity_definitions/catalog_item.json"
      |> File.read!()
      |> Jason.decode!()

    place_fields = Enum.filter(def["fields"], &String.contains?(&1["name"], "location"))
    assert [%{"name" => "default_location_id", "type" => "string"} = f] = place_fields
    refute f["required"]
  end

  test "DL6: a row of another tenant place is not found (the lookup is scoped by the tenant schema)" do
    a = tenant_ctx("g3-dl6a")
    b = tenant_ctx("g3-dl6b")
    masters!(a)
    masters!(b)
    # a place that only tenant A has
    assert result(upsert(a, "location_node", [place("ONLY-A")]))["outcome"] == "created"

    r = result(upsert(b, "catalog_item", [item_row("I6", %{"default_location_id" => "ONLY-A"})]))
    assert inspect(r) =~ "reference_not_found"
    assert count(b.schema, "catalog_item") == 0
  end
end
