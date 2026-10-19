defmodule Letflow.Modules.CatalogItems.RegistrationTest do
  @moduledoc """
  GH #2663 / REQ-474 AC2 (spec `test/specs/GH-2663.md`, tests R-01..R-04): the `catalog_items`
  manifest is accepted by `Catalog.validate/1` and the entry module is registered.

  Pure: no database. `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog

  @two ["catalog_item", "catalog_uom"]

  test "R-01: Catalog.validate/1 accepts the catalog_items manifest" do
    assert Catalog.validate(Letflow.Modules.CatalogItems.manifest()) == :ok
  end

  test "R-02: the manifest is id catalog_items, no dependencies, manages exactly the two types" do
    manifest = Letflow.Modules.CatalogItems.manifest()

    assert manifest.id == "catalog_items"
    assert manifest.depends_on == []
    assert Enum.sort(manifest.manages_entity_types) == @two
    assert manifest.pack == "modules/catalog_items/pack.json"
    assert manifest.permissions == []
    assert manifest.role_grants == %{}
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
end
