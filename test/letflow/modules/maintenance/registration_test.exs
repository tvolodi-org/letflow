defmodule Letflow.Modules.Maintenance.RegistrationTest do
  @moduledoc """
  REQ-893 criteria 1, 2 (source half) and 6 (as of REQ-897, version 0.5.0): the `maintenance` manifest is
  valid and registered, declares three permissions (REQ-894) and no grant, the release flag is off in every config but `config/test.exs`, and
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
    assert m.version == "0.5.0"
    assert m.depends_on == ["assets"]
    assert m.permissions == [:MaintenanceRequestCreate, :MaintenanceRead, :MaintenanceOrderManage]
    assert m.role_grants == %{}
    assert m.required_roles == []
    assert length(m.route_policies) == 12
    assert m.manages_entity_types == ["maintenance_work_request", "maintenance_work_order"]

    assert m.scope_declarations == %{
             "maintenance_work_request" => {:column, "org_unit_id"},
             "maintenance_work_order" => {:column, "org_unit_id"}
           }

    # REQ-897: the two write handlers, each with its own fields of the order type
    assert [done, closed] = m.write_handlers
    assert done.name == "record_done"
    assert done.targets == ["maintenance_work_order"]
    assert done.updates == %{"maintenance_work_order" => ["work_done", "done_by", "done_at"]}
    assert closed.name == "record_closed"
    assert closed.targets == ["maintenance_work_order"]
    assert closed.updates == %{"maintenance_work_order" => ["closed_by", "closed_at"]}
    # each handler reads the order to bind its write to the task's own instance
    assert done.reads == ["maintenance_work_order"]
    assert closed.reads == ["maintenance_work_order"]

    assert Maintenance.router() == Letflow.Modules.Maintenance.Router
    assert Catalog.fetch("maintenance") == {:ok, Maintenance}
  end

  test "M-01: the upgrade window reaches the current version, so a bump strands no tenant" do
    m = Maintenance.manifest()

    # The record shape of both types is the one of 0.1.0, so every version from there to this
    # one upgrades without a step. Without the window the version bump strands every tenant
    # that holds an older one (T-1860, `test/letflow/modules/upgrade_window_test.exs` G1).
    assert m.min_upgradable_from == "0.1.0"
    assert {:ok, []} = Catalog.upgrade_path(m, m.min_upgradable_from, m.version)
  end

  test "M-02: config.exs and test.exs list Maintenance right after MesCore" do
    for file <- ["config/config.exs", "config/test.exs"] do
      assert File.read!(file) =~ ~r/Letflow\.Modules\.MesCore,\s*Letflow\.Modules\.Maintenance/
    end
  end

  test "M-03: the flag is false in config.exs, set nowhere else but test.exs, read only by the flag module" do
    assert File.read!("config/config.exs") =~ ~r/config :letflow, :maintenance_enabled, false\n/

    others =
      Path.wildcard("config/*.exs")
      |> Enum.reject(&(&1 in ["config/config.exs", "config/test.exs"]))

    assert others != []

    for file <- others do
      refute File.read!(file) =~ "maintenance_enabled", file
    end

    assert File.read!("config/test.exs") =~ "config :letflow, :maintenance_enabled, true"

    # The reader is the READ itself, not a mention of the key in a doc: REQ-897 moved it into
    # its own file, because the entry module of a module with write handlers is scanned for
    # handler purity (the H4 scan forbids `Application` there).
    readers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "Application.get_env(:letflow, :maintenance_enabled"))

    assert readers == ["lib/letflow/modules/maintenance/flag.ex"]
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
    # REQ-896: the one process of the pack, a module-stamped draft at install;
    # REQ-897: version 1.1.0, the two tasks call the module's write handlers
    assert [%{"process_key" => "maintenance_work_order", "version" => "1.1.0"}] =
             pack["definitions"]

    names = Enum.map(pack["entity_definitions"], & &1["name"])
    assert names == Maintenance.manifest().manages_entity_types

    order = Enum.find(pack["entity_definitions"], &(&1["name"] == "maintenance_work_order"))
    fields = Enum.map(order["definition_json"]["fields"], & &1["name"])
    refute "status" in fields
    assert "request_id" in fields

    assert [%{"field" => "request_id", "references_entity" => "maintenance_work_request"}] =
             order["definition_json"]["foreign_keys"]
  end

  test "M-07: docs/roles.md has a maintenance section naming the three atoms and no role grant" do
    text = File.read!("docs/roles.md")

    assert text =~
             "Module `maintenance` (REQ-893, CMMS slice 1 part 1; REQ-894, part 2; REQ-895, part 3; REQ-896, part 4; REQ-897, part 5, version 0.5.0;"

    for atom <- ["MaintenanceRequestCreate", "MaintenanceRead", "MaintenanceOrderManage"],
        do: assert(text =~ "`#{atom}`")

    assert text =~ "It declares no `role_grants`"
  end

  test "M-08: the manifest declares an upgrade window from 0.1.0 that reaches its version (T-2400)" do
    manifest = Maintenance.manifest()
    assert manifest.min_upgradable_from == "0.1.0"
    assert {:ok, []} = Catalog.upgrade_path(manifest, "0.1.0", manifest.version)
  end
end
