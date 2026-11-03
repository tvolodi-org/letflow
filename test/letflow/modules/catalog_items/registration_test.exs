defmodule Letflow.Modules.CatalogItems.RegistrationTest do
  @moduledoc """
  GH #2663 / REQ-474 AC2 (spec `test/specs/GH-2663.md`, tests R-01..R-04): the `catalog_items`
  manifest is accepted by `Catalog.validate/1` and the entry module is registered.

  Pure: no database. `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Catalog

  @four ["catalog_counterparty", "catalog_item", "catalog_lot", "catalog_uom"]

  test "R-01: Catalog.validate/1 accepts the catalog_items manifest" do
    assert Catalog.validate(Letflow.Modules.CatalogItems.manifest()) == :ok
  end

  test "R-02: the manifest is id catalog_items, no dependencies, manages exactly the four types" do
    manifest = Letflow.Modules.CatalogItems.manifest()

    assert manifest.id == "catalog_items"
    assert manifest.depends_on == []
    assert Enum.sort(manifest.manages_entity_types) == @four
    assert manifest.pack == "modules/catalog_items/pack.json"
    assert manifest.permissions == [:CatalogLotsWrite]
    assert manifest.role_grants == %{}
    assert manifest.version == "0.2.0"
    assert Letflow.Modules.CatalogItems.router() == Letflow.Modules.CatalogItems.Router

    assert Enum.sort(manifest.route_policies) ==
             Enum.sort([
               {"POST", "/lots", :CatalogLotsWrite},
               {"PATCH", "/lots/:id", :CatalogLotsWrite},
               {"POST", "/lots/:id/retire", :CatalogLotsWrite}
             ])
  end

  test "R-03: the manifest's managed list equals the private @types list on_install/3 activates" do
    source =
      File.read!(
        Path.join([File.cwd!(), "lib", "letflow", "modules", "catalog_items", "catalog_items.ex"])
      )

    [_, types_block] = Regex.run(~r/@types \[(.*?)\]/s, source)
    types = Regex.scan(~r/"([a-z_]+)"/, types_block) |> Enum.map(&List.last/1)

    assert types == Letflow.Modules.CatalogItems.manifest().manages_entity_types
  end

  test "R-04: Catalog.entry_modules/0 includes the module and fetch/1 resolves it" do
    assert Letflow.Modules.CatalogItems in Catalog.entry_modules()
    assert Catalog.fetch("catalog_items") == {:ok, Letflow.Modules.CatalogItems}
  end

  test "R-05 (decision 0051 M4, D6): scope_declarations is exactly the four tenant_wide types" do
    assert Letflow.Modules.CatalogItems.manifest().scope_declarations == %{
             "catalog_item" => :tenant_wide,
             "catalog_uom" => :tenant_wide,
             "catalog_counterparty" => :tenant_wide,
             "catalog_lot" => :tenant_wide
           }
  end
end
