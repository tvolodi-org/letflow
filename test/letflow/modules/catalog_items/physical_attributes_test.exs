Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.PhysicalAttributesTest do
  @moduledoc """
  MES plan U1 (owner A.6): the optional `dimension` of `catalog_uom` and the optional
  positive decimals `density_kg_per_l`, `net_mass_kg`, `net_volume_l` of `catalog_item`, through
  the real import route on fresh tenants. PA1..PA10 of the design.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.UpgradePlan

  @schema_version "entities/record-export/v1"
  @fields ~w(density_kg_per_l net_mass_kg net_volume_l)

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req816-user-#{Ecto.UUID.generate()}",
        display_name: "MES-U1 test user",
        email: "req816-#{Ecto.UUID.generate()}@example.com",
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

  defp uom_row(id, extra \\ %{}),
    do: %{
      "external_ref" => ref(id),
      "field_values" =>
        Map.merge(%{"code" => id, "name" => "Unit #{id}", "active" => true}, extra)
    }

  defp item_row(id, uom_id, extra \\ %{}),
    do: %{
      "external_ref" => ref(id),
      "field_values" =>
        Map.merge(
          %{
            "code" => id,
            "name" => "Item #{id}",
            "base_uom_id" => uom_id,
            "kind" => "material",
            "active" => true
          },
          extra
        )
    }

  defp result(conn), do: hd(Jason.decode!(conn.resp_body)["results"])

  defp stored(schema, type, id) do
    {:ok, %Latest{field_values: fv, record_id: rid}} =
      Latest.get_by_external_ref(type, "erp", id, schema)

    {rid, fv}
  end

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  defp setup_uom(ctx, id \\ "U1") do
    assert result(upsert(ctx, "catalog_uom", [uom_row(id)]))["outcome"] == "created"
    id
  end

  test "PA1: a unit takes each dimension through import and read" do
    ctx = tenant_ctx("req816-pa1")

    for dim <- ~w(mass volume count other) do
      id = "U-" <> dim

      assert result(upsert(ctx, "catalog_uom", [uom_row(id, %{"dimension" => dim})]))["outcome"] ==
               "created"

      {rid, fv} = stored(ctx.schema, "catalog_uom", id)
      assert fv["dimension"] == dim
      assert {:ok, %{"dimension" => ^dim}} = CatalogItems.lookup(ctx.schema, rid)
    end
  end

  test "PA2: an item takes the three decimals through import and read" do
    ctx = tenant_ctx("req816-pa2")
    setup_uom(ctx)

    attrs = %{"density_kg_per_l" => "0.789", "net_mass_kg" => "25", "net_volume_l" => "31.7"}

    assert result(upsert(ctx, "catalog_item", [item_row("I1", "U1", attrs)]))["outcome"] ==
             "created"

    {rid, fv} = stored(ctx.schema, "catalog_item", "I1")
    {:ok, read} = CatalogItems.lookup(ctx.schema, rid)

    for {k, v} <- attrs do
      assert Decimal.equal?(Decimal.new(fv[k]), Decimal.new(v))
      assert Decimal.equal?(Decimal.new(read[k]), Decimal.new(v))
    end
  end

  test "PA3/PA4/PA10: bad values are refused with the field name, nothing written, not echoed" do
    ctx = tenant_ctx("req816-pa3")
    setup_uom(ctx)

    bad = [
      "0",
      "-1",
      "abc",
      "1e3",
      0.5,
      "0.0000000001",
      String.duplicate("9", 1200),
      %{},
      [],
      true
    ]

    for field <- @fields, value <- bad do
      conn = upsert(ctx, "catalog_item", [item_row("I-bad", "U1", %{field => value})])
      r = result(conn)
      # the import refuses non-positive and non-decimal values by name; a well-formed decimal the
      # strict definition refuses (exponent, scale 10) is refused by Records with the field path
      case r["reason"] do
        %{"type" => "field_invalid", "header" => header} ->
          assert header == field

        %{"type" => "record_payload_invalid", "violations" => [%{"path" => path}]} ->
          assert path == "/" <> field

        other ->
          flunk("#{field} #{inspect(value)}: #{inspect(other)}")
      end

      unless is_binary(value) and byte_size(value) > 100, do: refute(conn.resp_body =~ "abc\"")
      assert count(ctx.schema, "catalog_item") == 0
    end

    assert Repo.all(from(a in Entry, where: like(a.action, "catalog_item.%")), prefix: ctx.schema) ==
             []

    # a valid and a missing value are accepted; first bad field in the fixed order is reported
    assert result(upsert(ctx, "catalog_item", [item_row("I-ok", "U1", %{"net_mass_kg" => "1"})]))[
             "outcome"
           ] == "created"

    two = %{"net_volume_l" => "0", "density_kg_per_l" => "-2"}

    assert result(upsert(ctx, "catalog_item", [item_row("I-two", "U1", two)]))["reason"]["header"] ==
             "density_kg_per_l"

    # a dimension outside the enum is refused by the definition, value not echoed
    conn = upsert(ctx, "catalog_uom", [uom_row("U-x", %{"dimension" => "zzqq-weight"})])
    refute result(conn)["outcome"] in ["created", "updated"]
    refute conn.resp_body =~ "zzqq-weight"
    assert count(ctx.schema, "catalog_uom") == 1
  end

  test "PA5: an old-shape record reads back unchanged and re-imports as unchanged" do
    ctx = tenant_ctx("req816-pa5")
    setup_uom(ctx)
    assert result(upsert(ctx, "catalog_item", [item_row("I1", "U1")]))["outcome"] == "created"
    {_rid, fv} = stored(ctx.schema, "catalog_item", "I1")

    for k <- ["dimension" | @fields], do: refute(Map.has_key?(fv, k))
    assert result(upsert(ctx, "catalog_item", [item_row("I1", "U1")]))["outcome"] == "unchanged"
    assert {_, ^fv} = stored(ctx.schema, "catalog_item", "I1")

    # with the physical attributes: created, then unchanged (stable canonical form)
    row = item_row("I2", "U1", %{"density_kg_per_l" => "0.789"})
    assert result(upsert(ctx, "catalog_item", [row]))["outcome"] == "created"
    assert result(upsert(ctx, "catalog_item", [row]))["outcome"] == "unchanged"
  end

  test "PA6: the upgrade plan sees optional fields only (class A)" do
    root = Path.join([File.cwd!(), "priv", "modules", "catalog_items", "entity_definitions"])

    for type <- ~w(catalog_uom catalog_item) do
      new = root |> Path.join(type <> ".json") |> File.read!() |> Jason.decode!()

      added =
        if type == "catalog_uom", do: ["dimension"], else: @fields

      old = Map.update!(new, "fields", fn fs -> Enum.reject(fs, &(&1["name"] in added)) end)
      assert UpgradePlan.classify_entity(old, new) == {"A", "optional_field_added"}

      for f <- new["fields"], f["name"] in added do
        refute Map.get(f, "required")
      end
    end
  end

  test "PA7: created item audit entry holds the new fields" do
    ctx = tenant_ctx("req816-pa7")
    setup_uom(ctx)
    row = item_row("I1", "U1", %{"density_kg_per_l" => "1.2", "net_mass_kg" => "5"})
    assert result(upsert(ctx, "catalog_item", [row]))["outcome"] == "created"

    [entry] =
      Repo.all(from(a in Entry, where: a.action == "catalog_item.created"), prefix: ctx.schema)

    assert entry.after_state == elem(stored(ctx.schema, "catalog_item", "I1"), 1)
    assert Decimal.equal?(Decimal.new(entry.after_state["density_kg_per_l"]), Decimal.new("1.2"))
  end

  test "PA8: module version moved on purpose" do
    assert CatalogItems.manifest().version == "0.4.0"
  end

  test "PA9: another tenant does not see the item and keeps its own record" do
    a = tenant_ctx("req816-pa9a")
    b = tenant_ctx("req816-pa9b")
    setup_uom(a)
    setup_uom(b)

    row = item_row("I1", "U1", %{"density_kg_per_l" => "0.9"})
    assert result(upsert(a, "catalog_item", [row]))["outcome"] == "created"
    {rid_a, _} = stored(a.schema, "catalog_item", "I1")

    assert {:error, :not_found} = CatalogItems.lookup(b.schema, rid_a)
    assert result(upsert(b, "catalog_item", [item_row("I1", "U1")]))["outcome"] == "created"
    {rid_b, fv_b} = stored(b.schema, "catalog_item", "I1")
    assert rid_a != rid_b
    refute Map.has_key?(fv_b, "density_kg_per_l")
  end
end
