defmodule Letflow.Modules.Maintenance.RegistrationTest do
  @moduledoc """
  REQ-893 criteria 1, 2 (source half) and 6: the `maintenance` skeleton is a valid registered manifest
  with no permission and no grant, the release flag is off in every config but `config/test.exs`, and
  the pack matches the entity definitions. Pure: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Maintenance

  test "M-01: Catalog.validate/1 accepts the manifest and it declares exactly the skeleton" do
    m = Maintenance.manifest()
    assert Catalog.validate(m) == :ok
    assert m.id == "maintenance"
    assert m.version == "0.1.0"
    assert m.depends_on == ["assets"]
    assert m.permissions == []
    assert m.role_grants == %{}
    assert m.required_roles == []
    assert m.route_policies == []
    assert m.manages_entity_types == ["maintenance_work_request", "maintenance_work_order"]

    assert m.scope_declarations == %{
             "maintenance_work_request" => {:column, "org_unit_id"},
             "maintenance_work_order" => {:column, "org_unit_id"}
           }

    refute function_exported?(Maintenance, :router, 0)
    assert Catalog.fetch("maintenance") == {:ok, Maintenance}
  end

  test "M-02: config.exs and test.exs list Maintenance right after MesCore" do
    for file <- ["config/config.exs", "config/test.exs"] do
      assert File.read!(file) =~ ~r/Letflow\.Modules\.MesCore,\s*Letflow\.Modules\.Maintenance/
    end
  end

  test "M-03: the flag is false in config.exs, set nowhere else but test.exs, read only by enabled?/0" do
    assert File.read!("config/config.exs") =~ ~r/config :letflow, :maintenance_enabled, false\n/

    others =
      Path.wildcard("config/*.exs")
      |> Enum.reject(&(&1 in ["config/config.exs", "config/test.exs"]))

    assert others != []

    for file <- others do
      refute File.read!(file) =~ "maintenance_enabled", file
    end

    assert File.read!("config/test.exs") =~ "config :letflow, :maintenance_enabled, true"

    readers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ":maintenance_enabled"))

    assert readers == ["lib/letflow/modules/maintenance/maintenance.ex"]
  end

  test "M-04: enabled?/0 follows the flag and is false when the key is absent" do
    on = Application.get_env(:letflow, :maintenance_enabled)
    on_exit(fn -> Application.put_env(:letflow, :maintenance_enabled, on) end)

    Application.put_env(:letflow, :maintenance_enabled, false)
    refute Maintenance.enabled?()
    Application.delete_env(:letflow, :maintenance_enabled)
    refute Maintenance.enabled?()
    Application.put_env(:letflow, :maintenance_enabled, true)
    assert Maintenance.enabled?()
  end

  test "M-05: the two document types are WR and WO, year scope, pad 6" do
    assert [
             %{key: "maintenance_request", number_prefix: "WR"},
             %{key: "maintenance_order", number_prefix: "WO"}
           ] = Maintenance.document_types()

    for t <- Maintenance.document_types() do
      assert t.owner_module == "maintenance"
      assert t.numbering_scope == :year
      assert t.number_pad == 6
      assert t.legal_entity_required == false
      assert t.declared_fields == %{}
    end
  end

  test "M-06: the pack holds the two types, request first; the order has a foreign key and no status" do
    pack = "priv/modules/maintenance/pack.json" |> File.read!() |> Jason.decode!()
    assert pack["pack_id"] == "letflow-maintenance"
    assert pack["version"] == Maintenance.manifest().version
    assert pack["definitions"] == []
    names = Enum.map(pack["entity_definitions"], & &1["name"])
    assert names == Maintenance.manifest().manages_entity_types

    order = Enum.find(pack["entity_definitions"], &(&1["name"] == "maintenance_work_order"))
    fields = Enum.map(order["definition_json"]["fields"], & &1["name"])
    refute "status" in fields
    assert "request_id" in fields

    assert [%{"field" => "request_id", "references_entity" => "maintenance_work_request"}] =
             order["definition_json"]["foreign_keys"]
  end

  test "M-07: docs/roles.md has a maintenance section saying no permission and no role grant" do
    assert File.read!("docs/roles.md") =~
             "Module `maintenance` (REQ-893, CMMS slice 1 part 1; behind the release flag `:maintenance_enabled`, off by default) has no permission and no role grant"
  end
end
