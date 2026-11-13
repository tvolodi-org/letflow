defmodule Letflow.Modules.MesCore.RegistrationTest do
  @moduledoc """
  T-1841 (MES M1) R-01..R-06: the empty `mes_core` shell is a valid, registered manifest with the
  four dependencies and nothing else. Pure: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.MesCore

  @deps ["catalog_items", "locations", "org", "stock"]

  test "R-01: Catalog.validate/1 accepts the mes_core manifest" do
    assert Catalog.validate(MesCore.manifest()) == :ok
  end

  test "R-02: id, version, the four dependencies, and nothing else declared" do
    m = MesCore.manifest()
    assert m.id == "mes_core"
    assert m.version == "0.1.0"
    assert Enum.sort(m.depends_on) == @deps
    assert m.permissions == []
    assert m.role_grants == %{}
    assert m.route_policies == []
    assert m.manages_entity_types == []
    assert m.pack == "modules/mes_core/pack.json"
    refute Map.get(m, :ledger)
    assert Map.get(m, :write_handlers, []) in [[], nil]
    refute function_exported?(MesCore, :on_install, 3)
    refute function_exported?(MesCore, :on_install, 2)
    refute function_exported?(MesCore, :router, 0)
  end

  test "R-03: entry_modules/0 has MesCore right after Assets; fetch/1 resolves it" do
    mods = Catalog.entry_modules()
    idx = Enum.find_index(mods, &(&1 == Letflow.Modules.Assets))
    assert Enum.at(mods, idx + 1) == MesCore
    assert Catalog.fetch("mes_core") == {:ok, MesCore}
  end

  test "R-04: config.exs and test.exs list MesCore right after Assets" do
    for file <- ["config/config.exs", "config/test.exs"] do
      assert File.read!(file) =~ ~r/Letflow\.Modules\.Assets,\s*Letflow\.Modules\.MesCore/
    end
  end

  test "R-05: every dependency id resolves in the catalogue" do
    for dep <- MesCore.manifest().depends_on do
      assert {:ok, _} = Catalog.fetch(dep), dep
    end
  end

  test "R-06: docs/roles.md has a mes_core section" do
    assert File.read!("docs/roles.md") =~ "Module `mes_core`"
  end
end
