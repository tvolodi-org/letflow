defmodule Letflow.Modules.CatalogImportFunctionsTest do
  @moduledoc """
  GH #3602 / REQ-651 criterion 1 (tests R1a..R1g): the optional manifest key `:import_functions`,
  rule 14 of `Letflow.Modules.Catalog.validate/2`, and the core resolution
  `Catalog.import_function/2`. Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.CatalogItems

  # The real catalog_items manifest (its id is registered, so the entry module resolves), with the
  # key under test replaced.
  defp with_fns(fns), do: Map.put(CatalogItems.manifest(), :import_functions, fns)

  defp fn_spec(name, fun \\ :import_row), do: %{entity_type: name, function: fun}

  test "R1a: a valid list passes, and so do absent and []" do
    assert Catalog.validate(CatalogItems.manifest()) == :ok
    assert Catalog.validate(with_fns([fn_spec("catalog_lot")])) == :ok
    assert Catalog.validate(with_fns([])) == :ok
    assert Catalog.validate(Map.delete(CatalogItems.manifest(), :import_functions)) == :ok
  end

  test "R1b: a name not in manages_entity_types" do
    assert Catalog.validate(with_fns([fn_spec("not_mine")])) ==
             {:error, {:import_function_type_not_managed, "not_mine"}}
  end

  test "R1c: a duplicate name" do
    assert Catalog.validate(with_fns([fn_spec("catalog_uom"), fn_spec("catalog_uom")])) ==
             {:error, {:duplicate_import_function, "catalog_uom"}}
  end

  test "R1d: a function the entry module does not export with arity 3" do
    # missing function
    assert Catalog.validate(with_fns([fn_spec("catalog_uom", :no_such_function)])) ==
             {:error, {:import_function_not_exported, "catalog_uom"}}

    # exported, but with arity 2 (lookup/2)
    assert Catalog.validate(with_fns([fn_spec("catalog_uom", :lookup)])) ==
             {:error, {:import_function_not_exported, "catalog_uom"}}
  end

  test "R1e: a malformed value" do
    for bad <- [
          :nope,
          nil,
          [:x],
          [%{entity_type: "catalog_uom"}],
          [fn_spec(:atom_name)],
          [%{entity_type: "catalog_uom", function: "import_row"}],
          [Map.put(fn_spec("catalog_uom"), :extra, 1)]
        ] do
      assert Catalog.validate(with_fns(bad)) == {:error, {:invalid_import_functions, bad}}
    end
  end

  test "R1f: the catalog_items manifest lists exactly the three catalog types" do
    names = for %{entity_type: name} <- CatalogItems.manifest().import_functions, do: name
    assert Enum.sort(names) == ["catalog_counterparty", "catalog_item", "catalog_uom"]
  end

  test "R1g: import_function/2 resolves the three and refuses everything else" do
    for type <- ["catalog_uom", "catalog_item", "catalog_counterparty"] do
      assert Catalog.import_function("catalog_items", type) == :ok
    end

    assert Catalog.import_function("catalog_items", "catalog_lot") == {:error, :not_found}
    assert Catalog.import_function("catalog_items", "unknown") == {:error, :not_found}
    assert Catalog.import_function("no_module", "catalog_uom") == {:error, :not_found}
    assert Catalog.import_function(:catalog_items, "catalog_uom") == {:error, :not_found}
    assert Catalog.import_function("catalog_items", nil) == {:error, :not_found}

    assert Catalog.call_import_function("catalog_items", "catalog_lot", "p", %{}, %{}) ==
             {:error, :not_found}
  end

  test "R1h: :import_functions is not part of the manifest hash" do
    assert Letflow.Modules.ManifestHash.compute(with_fns([])) ==
             Letflow.Modules.ManifestHash.compute(CatalogItems.manifest())
  end
end
