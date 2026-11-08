Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindChangeRegistrationTest do
  @moduledoc """
  GH #3902 / REQ-759 (assets C15 part 2), criterion 1: R1 the manifest, the two record types, the
  document type and the exact field sets, R2 the new dependencies refuse an install without `stock`
  and `catalog_items`. `async: false`: R2 installs modules into a provisioned tenant.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Installs

  @pack Path.join([File.cwd!(), "priv", "modules", "assets", "pack.json"])

  defp definition(name) do
    @pack
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("entity_definitions")
    |> Enum.find(&(&1["name"] == name))
    |> Map.fetch!("definition_json")
  end

  defp fields(name), do: Map.new(definition(name)["fields"], &{&1["name"], &1})

  test "R1 manifest: version, dependencies, both types managed and scoped by org_unit_id" do
    m = Assets.manifest()
    assert Version.compare(m.version, "0.7.0") == :gt
    assert m.depends_on == ["catalog_items", "locations", "org", "stock"]

    for type <- ["assets_kind_change", "assets_kind_change_line"] do
      assert type in m.manages_entity_types
      assert m.scope_declarations[type] == {:column, "org_unit_id"}
    end

    assert "assets_kind_change_line" in m.manages_entity_types
    assert Letflow.Modules.Catalog.validate(m) == :ok
  end

  test "R1 the document type AKC is yearly, six digits, no legal entity" do
    assert %{
             owner_module: "assets",
             numbering_scope: :year,
             number_prefix: "AKC",
             number_pad: 6,
             legal_entity_required: false
           } = Enum.find(Assets.document_types(), &(&1.key == "assets_kind_change"))
  end

  test "R1 exact field sets of the header and the line; no price, value, number, status, posted_at" do
    assert Map.keys(fields("assets_kind_change")) |> Enum.sort() ==
             ~w(document_id event_time note org_unit_id reason_text)

    assert Map.keys(fields("assets_kind_change_line")) |> Enum.sort() ==
             ~w(actual_user_id asset_card_id asset_location_id asset_name asset_org_unit_id catalog_item_id
                catalog_lot_id catalog_uom_id header_id inventory_number line_no material_responsible_id
                org_unit_id quantity stock_location_id stock_responsible_id target_kind)

    forbidden = ~r/price|value|cost|amount|number$|status|posted|^state/

    for type <- ["assets_kind_change", "assets_kind_change_line"],
        name <- Map.keys(fields(type)),
        name != "inventory_number" do
      refute Regex.match?(forbidden, name), "#{type}.#{name}"
    end
  end

  test "R1 the line: strict quantity, enum target kind, foreign key to the header, queried keys" do
    line = definition("assets_kind_change_line")
    f = fields("assets_kind_change_line")

    assert %{"decimal_precision" => 24, "decimal_scale" => 9, "decimal_strict" => true} =
             f["quantity"]

    assert f["target_kind"]["enum_values"] == ["low_value", "fixed"]
    assert f["header_id"]["queried"] and f["org_unit_id"]["queried"]

    assert [%{"field" => "header_id", "references_entity" => "assets_kind_change"} = fk] =
             line["foreign_keys"]

    assert fk["name"] == "fk_assets_kind_change_line_header_id"
    assert fields("assets_kind_change")["document_id"]["queried"]
  end

  test "R2 an install without catalog_items, then without stock, is refused and leaves no trace" do
    fx = Fx.provisioned_tenant!("gh3902-dep")
    opts = [prefix: fx.schema_name, rationale: "GH-3902 dependency test"]

    for m <- ["org", "locations"], do: Fx.install_module!(fx.tenant_id, m)

    assert Installs.install("assets", Ecto.UUID.generate(), opts) ==
             {:error, {:dependency_not_installed, "catalog_items"}}

    for m <- ["catalog_items", "codes"], do: Fx.install_module!(fx.tenant_id, m)

    assert Installs.install("assets", Ecto.UUID.generate(), opts) ==
             {:error, {:dependency_not_installed, "stock"}}

    Fx.install_module!(fx.tenant_id, "stock")
    assert {:ok, _} = Installs.install("assets", Ecto.UUID.generate(), opts)
  end
end
