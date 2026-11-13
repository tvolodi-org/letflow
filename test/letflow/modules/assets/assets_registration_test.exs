defmodule Letflow.Modules.Assets.RegistrationTest do
  @moduledoc """
  GH #3894 / REQ-748 criteria 1 and 2 (tests A-REG-1, A-DEF-1): the manifest value by value, the
  catalog registration, the exact field set and constraints of the packed `assets_card`.

  Pure: no database. `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets
  alias Letflow.Modules.Catalog

  @pack Path.join([File.cwd!(), "priv", "modules", "assets", "pack.json"])

  test "A-REG-1: the manifest, value by value" do
    m = Assets.manifest()

    assert m.id == "assets"
    assert m.version == "0.20.0"
    assert m.depends_on == ["catalog_items", "locations", "org", "stock"]
    assert m.pack == "modules/assets/pack.json"

    assert m.permissions == [
             :AssetsCardWrite,
             :AssetsPost,
             :AssetsReverse,
             :AssetsRead,
             :AssetsReconcile
           ]

    assert m.role_grants == %{}

    assert m.route_policies == [
             {"POST", "/cards", :AssetsCardWrite},
             {"PATCH", "/cards/:id", :AssetsCardWrite},
             {"POST", "/cards/:id/retire", :AssetsCardWrite},
             {"GET", "/cards/:id/lock", :AssetsRead},
             {"GET", "/balances", :AssetsRead},
             {"GET", "/movements", :AssetsRead},
             {"GET", "/reconcile", :AssetsReconcile},
             {"POST", "/documents", :AssetsPost},
             {"PUT", "/documents/:id", :AssetsPost},
             {"DELETE", "/documents/:id", :AssetsPost},
             {"POST", "/documents/:id/issue", :AssetsPost},
             {"POST", "/documents/:id/check", :AssetsPost},
             {"POST", "/documents/:id/reverse", :AssetsReverse},
             {"GET", "/documents", :AssetsRead},
             {"GET", "/documents/:id", :AssetsRead}
           ]

    assert m.manages_entity_types ==
             ~w(assets_card assets_commission assets_commission_line assets_change assets_change_line
                assets_handover assets_handover_line assets_writeoff assets_writeoff_line
                assets_posting_mark assets_kind_change assets_kind_change_line assets_opening assets_opening_line)

    assert m.scope_declarations ==
             Map.new(m.manages_entity_types, &{&1, {:column, "org_unit_id"}})

    keys = Map.keys(m)
    assert :ledger in keys
    assert :write_handlers in keys

    assert m.settings_schema == %{
             "type" => "object",
             "properties" => %{
               "currency" => %{"type" => "string", "minLength" => 3, "maxLength" => 3},
               "expiry_reminder_lead_days" => %{
                 "type" => "integer",
                 "minimum" => 1,
                 "maximum" => 3650
               },
               "storekeeper_grants" => %{
                 "type" => "array",
                 "items" => %{"type" => "string", "enum" => ["AssetsRead", "AssetsPost"]},
                 "uniqueItems" => true
               }
             },
             "additionalProperties" => false
           }

    assert Assets.router() == Letflow.Modules.Assets.Router
    assert Catalog.fetch("assets") == {:ok, Assets}
    assert Catalog.validate(m, Catalog.all_manifests()) == :ok

    entry = Catalog.entry_modules()
    stock = Enum.find_index(entry, &(&1 == Letflow.Modules.Stock))
    assert Enum.at(entry, stock + 1) == Assets

    for file <- ~w(config/config.exs config/test.exs) do
      assert File.read!(file) =~ ~r/Letflow\.Modules\.Stock,\s*Letflow\.Modules\.Assets/
    end
  end

  test "A-REG-2: the managed list equals the private @types list on_install/3 activates" do
    source =
      File.read!(Path.join([File.cwd!(), "lib", "letflow", "modules", "assets", "assets.ex"]))

    [_, block] = Regex.run(~r/@types \[(.*?)\]/s, source)
    types = Regex.scan(~r/"([a-z_]+)"/, block) |> Enum.map(&List.last/1)
    assert types == Assets.manifest().manages_entity_types
  end

  test "A-DEF-1: the packed assets_card has exactly the REQ-748 fields and the two constraints" do
    doc = @pack |> File.read!() |> Jason.decode!()

    assert %{"definition_json" => def_json} =
             Enum.find(doc["entity_definitions"], &(&1["name"] == "assets_card"))

    dec = %{
      "type" => "decimal",
      "decimal_precision" => 24,
      "decimal_scale" => 9,
      "decimal_strict" => true
    }

    expected = [
      %{"name" => "inventory_number", "type" => "string", "required" => true, "queried" => true},
      %{"name" => "name", "type" => "string", "required" => true, "queried" => true},
      %{
        "name" => "kind",
        "type" => "enum",
        "required" => true,
        "queried" => true,
        "enum_values" => ["fixed", "low_value", "intangible"]
      },
      %{"name" => "org_unit_id", "type" => "string", "queried" => true},
      %{"name" => "acquisition_date", "type" => "date"},
      %{"name" => "currency", "type" => "string"},
      Map.put(dec, "name", "acquisition_cost"),
      Map.put(dec, "name", "accumulated_depreciation"),
      Map.put(dec, "name", "book_value"),
      %{"name" => "depreciation_as_of", "type" => "date"},
      %{"name" => "depreciation_method", "type" => "string"},
      Map.put(dec, "name", "depreciation_rate"),
      %{"name" => "valid_until", "type" => "date", "queried" => true},
      %{"name" => "active", "type" => "boolean", "required" => true, "queried" => true},
      %{"name" => "external_ref_system", "type" => "string", "queried" => true},
      %{"name" => "external_ref_id", "type" => "string", "queried" => true}
    ]

    assert def_json["fields"] == expected

    names = Enum.map(def_json["fields"], & &1["name"])

    refute Enum.any?(names, &String.starts_with?(&1, ["location", "responsible", "user"]))
    refute "quantity" in names

    assert def_json["constraints"] == [
             %{
               "name" => "uq_assets_card_inventory_number",
               "type" => "unique",
               "fields" => ["inventory_number"]
             },
             %{
               "name" => "uq_assets_card_external_ref",
               "type" => "unique",
               "fields" => ["external_ref_system", "external_ref_id"]
             }
           ]

    refute Map.has_key?(def_json, "foreign_keys")
  end

  test "A-DEF-2: section 3 of asset-register.md has an active row" do
    text = File.read!("docs/assets/asset-register.md")
    start = :binary.match(text, "## 3. The asset card") |> elem(0)
    section = binary_part(text, start, byte_size(text) - start)
    [section | _] = String.split(section, "## 4.", parts: 2)
    assert section =~ ~r/^\| active \| boolean \| required \|/m
  end
end
